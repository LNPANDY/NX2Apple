import Foundation

/// An app installed on a device, as `devicectl device info apps` lists it.
struct InstalledApp: Equatable {
    let bundle: String
    let name: String
}

/// Finding the game on the device itself, so the Saves sheet needs neither the launcher's install record nor the signed app
/// it cached (#250): a game exported as an IPA and signed by another tool (LCSign, Sideloadly, AltStore) has a data container
/// the Mac can read all the same, under whatever bundle ID that tool gave it.
enum SaveDiscovery {
    static func listCommand(device: String, json: String) -> [String] {
        ["device", "info", "apps", "--device", device, "--include-default-apps", "--include-removable-apps", "--json-output", json]
    }

    /// `result.apps` of the listing. nil for JSON that cannot be read.
    static func parseApps(_ data: Data) -> [InstalledApp]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any], let list = result["apps"] as? [[String: Any]] else { return nil }
        return list.compactMap { app in
            guard let bundle = app["bundleIdentifier"] as? String, !bundle.isEmpty else { return nil }
            return InstalledApp(bundle: bundle, name: app["name"] as? String ?? "")
        }
    }

    /// The apps on the device. A failure is the device's (not connected, locked, timed out), never "no apps".
    static func apps(device: String, devicectl: DeviceControl, scratch: URL = FileManager.default.temporaryDirectory) throws -> [InstalledApp] {
        let json = scratch.appendingPathComponent("nxnative-apps-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: json) }
        let r = devicectl.run(listCommand(device: device, json: json.path))
        guard r.ok, let data = try? Data(contentsOf: json) else { throw SaveTransfer.failure(r.output) }
        guard let apps = parseApps(data) else { throw SaveTransfer.Failure.device("devicectl") }
        return apps
    }

    /// The installed app that is this game, best match first: the bundle ID this launcher recorded, the launcher's own
    /// (`org.nxnative.<title ID>`), any bundle ID with the title ID in it (a team suffix, a re-signer's prefix), then the
    /// app's display name against the game's name or its title ID. Of equal matches the first by bundle ID wins, so the
    /// answer does not change between refreshes.
    static func match(_ apps: [InstalledApp], titleID: String, name: String, recordedBundle: String?) -> InstalledApp? {
        let id = titleID.lowercased(), wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        func rank(_ app: InstalledApp) -> Int? {
            let bundle = app.bundle.lowercased(), shown = app.name.trimmingCharacters(in: .whitespaces).lowercased()
            if let recordedBundle, !recordedBundle.isEmpty, app.bundle == recordedBundle { return 0 }
            if !id.isEmpty, bundle == "org.nxnative." + id { return 1 }
            if !id.isEmpty, bundle.contains(id) { return 2 }
            if !wanted.isEmpty, shown == wanted { return 3 }
            if !id.isEmpty, shown.contains(id) { return 3 }
            return nil
        }
        return apps.compactMap { app in rank(app).map { (rank: $0, app: app) } }
            .min { ($0.rank, $0.app.bundle) < ($1.rank, $1.app.bundle) }?.app
    }

    /// The game's app on one device and what its save holds. nil when the device has no app that is this game. `template`
    /// carries the Mac side and the title ID (its device and bundle are replaced).
    static func find(template: SaveTransfer, name: String, recordedBundle: String?, device: String) throws -> (transfer: SaveTransfer, contents: SaveTransfer.Contents)? {
        let installed = try apps(device: device, devicectl: template.devicectl, scratch: template.scratch)
        guard let app = match(installed, titleID: template.titleID, name: name, recordedBundle: recordedBundle) else { return nil }
        var transfer = SaveTransfer(titleID: template.titleID, macSave: template.macSave, legacySave: template.legacySave,
                                    device: device, bundle: app.bundle, devicectl: template.devicectl)
        transfer.scratch = template.scratch
        transfer.now = template.now
        return (transfer, try transfer.readDevice())
    }
}

/// What the Saves sheet shows and does: which device is asked, what it holds, and when it is safe to ask again.
///
/// Only one query runs at a time. Refresh does nothing while one runs, a query that takes longer than `timeout` ends as
/// `.timedOut` (the command underneath has its own deadline, DeviceControl.xcrun, but a hang anywhere in the chain must not
/// leave the sheet reading for good), and choosing another device cancels the one running: a result that arrives after
/// its query was given up or replaced is dropped. Used on the main thread.
final class SavesModel: ObservableObject {
    enum DeviceState: Equatable {
        case noDevices                     // no paired iPhone or iPad
        case notConnected                  // the chosen device is paired but not connected: nothing is asked of it
        case notInstalled                  // connected, and this game is not on it
        case reading
        case ready(SaveTransfer.Contents)
        case failed(String)                // devicectl's last line
        case timedOut
    }

    let template: SaveTransfer             // the Mac side, and the title ID
    let name: String
    let recordedBundle: String?
    let recordedDevice: String
    let installTarget: String              // the device Builds installs to
    let listDevices: () -> [AppleDevice]
    var timeout: TimeInterval
    var rememberChoice: (String) -> Void
    private var remembered: String

    @Published private(set) var devices: [AppleDevice] = []
    @Published private(set) var selected = ""
    @Published private(set) var deviceState = DeviceState.reading
    @Published private(set) var macSave = SaveTransfer.Contents()
    @Published private(set) var macLocation: SaveTransfer.MacLocation
    @Published private(set) var found: SaveTransfer?   // the game's app on the selected device, once it is ready
    private var generation = 0
    private var started = false

    init(template: SaveTransfer, name: String, recordedBundle: String?, recordedDevice: String, installTarget: String,
         remembered: String = "", rememberChoice: @escaping (String) -> Void = { _ in },
         listDevices: @escaping () -> [AppleDevice], timeout: TimeInterval = 30) {
        self.template = template; self.name = name; self.recordedBundle = recordedBundle; self.recordedDevice = recordedDevice
        self.installTarget = installTarget; self.remembered = remembered; self.rememberChoice = rememberChoice
        self.listDevices = listDevices; self.timeout = timeout
        self.macLocation = template.macLocation()
    }

    var isReading: Bool { deviceState == .reading }
    var canRefresh: Bool { !isReading }
    var deviceSave: SaveTransfer.Contents? { if case .ready(let c) = deviceState { return c }; return nil }
    var selectedDevice: AppleDevice? { devices.first { $0.id == selected } }
    /// The selector shows when there is a choice to make.
    var showsSelector: Bool { devices.count > 1 }

    /// The device to ask first: the one picked here before, the one this game was installed on, the one Builds installs to,
    /// each only while connected; else the first connected one; else whichever of those is paired, so its name is shown.
    static func defaultDevice(in list: [AppleDevice], remembered: String, recorded: String, installTarget: String) -> String? {
        let preferred = [remembered, recorded, installTarget].filter { !$0.isEmpty }
        if let id = preferred.first(where: { id in list.contains { $0.id == id && $0.reachable } }) { return id }
        if let first = list.first(where: \.reachable) { return first.id }
        return preferred.first { id in list.contains { $0.id == id } } ?? list.first?.id
    }

    /// Reads the Mac save and asks the device again, device list included. Does nothing while a query runs.
    func refresh() {
        guard canRefresh else { return }
        start(relist: true)
    }

    /// The sheet opened: the first query.
    func begin() {
        guard !started else { return }
        started = true
        start(relist: true)
    }

    /// Asks another device. A query still running is given up.
    func select(_ id: String) {
        guard id != selected || !isReading else { return }
        selected = id
        remembered = id
        rememberChoice(id)
        start(relist: false)
    }

    private func start(relist: Bool) {
        generation += 1
        let mine = generation
        macSave = template.readMac()
        macLocation = template.macLocation()
        deviceState = .reading
        found = nil
        let known = devices, current = selected
        let (template, name, recordedBundle) = (self.template, self.name, self.recordedBundle)
        let (remembered, recorded, target, listDevices) = (self.remembered, recordedDevice, installTarget, self.listDevices)
        DispatchQueue.global(qos: .userInitiated).async {
            let list = relist ? listDevices() : known
            let id = (list.contains { $0.id == current } ? current
                : SavesModel.defaultDevice(in: list, remembered: remembered, recorded: recorded, installTarget: target)) ?? ""
            // The list and the choice show at once, while the query still runs: the sheet says which device it is asking,
            // and another one can be chosen if this one never answers.
            DispatchQueue.main.async {
                guard mine == self.generation else { return }
                self.devices = list; self.selected = id
            }
            var state = DeviceState.reading, transfer: SaveTransfer?
            if list.isEmpty || id.isEmpty {
                state = .noDevices
            } else if list.first(where: { $0.id == id })?.reachable != true {
                state = .notConnected
            } else {
                do {
                    if let hit = try SaveDiscovery.find(template: template, name: name, recordedBundle: recordedBundle, device: id) {
                        state = .ready(hit.contents); transfer = hit.transfer
                    } else {
                        state = .notInstalled
                    }
                } catch SaveTransfer.Failure.timeout { state = .timedOut } catch SaveTransfer.Failure.device(let line) { state = .failed(line) } catch { state = .failed(error.localizedDescription) }
            }
            DispatchQueue.main.async {
                guard mine == self.generation else { return }   // given up or replaced meanwhile
                self.deviceState = state; self.found = transfer
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, mine == self.generation, self.deviceState == .reading else { return }
            self.generation += 1   // whatever the query still says is stale
            self.deviceState = .timedOut
        }
    }
}
