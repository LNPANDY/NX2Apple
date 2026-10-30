import AppKit
import Darwin
import SwiftUI

/// `xcrun devicectl` for the save transfer, as one function: the tests hand in a stand-in, so no test ever reaches a device.
/// It takes devicectl's arguments and returns whether it exited 0 and what it printed.
struct DeviceControl {
    let run: ([String]) -> (ok: Bool, output: String)

    /// What a command that ran out of time prints in place of devicectl's own output (and what a stand-in prints to say the same).
    static let timedOut = "devicectl timed out"

    /// Every command has a deadline: devicectl's own (`--timeout`), and behind it one on the process, because CoreDevice can
    /// stall on a paired device whose connection is not ready, and a command that never returns leaves the Saves sheet at
    /// "Reading..." for good. A copy gets the longer deadline, a query the shorter one.
    static func xcrun(_ path: String, queryTimeout: TimeInterval = 10, copyTimeout: TimeInterval = 180) -> DeviceControl {
        DeviceControl { args in
            let timeout = args.starts(with: ["device", "copy"]) ? copyTimeout : queryTimeout
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["devicectl", "--timeout", String(max(1, Int(timeout.rounded(.up))))] + args
            p.standardOutput = out; p.standardError = out; p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return (false, error.localizedDescription) }
            let fired = Fired()
            let deadline = DispatchWorkItem {
                fired.set()
                if p.isRunning { p.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 2, execute: deadline)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            deadline.cancel()
            if fired.value { return (false, timedOut) }
            return (p.terminationStatus == 0, String(decoding: data, as: UTF8.self))
        }
    }

    private final class Fired {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.lock(); flag = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }
}

/// A game's save on this Mac and in its app on a paired iPhone or iPad (#66), copied either way over the route the install
/// takes (devicectl and the app's data container). The save that is replaced is backed up on the Mac
/// first, so a copy in the wrong direction loses nothing.
///
/// Where the saves are: the Mac app keeps them beside itself in <app's folder>/save/<title ID> when that folder holds the
/// library marker (.nx2apple-library, which the launcher's build writes, fork patch mac-library-folder), else in ~/Library/Application Support/nxnative/<title ID>/save (dm/mac/launcher.c, DM_SAVE;
/// the device save is DM_SAVE + "_device", dm/host/hle_fs.c); the iPhone app in Documents/games/<title ID>/save (dm/ios/Sources/main.m), the per-game folder it uses when the
/// game files come from Documents/games/<title ID>/, which is where the launcher's install puts them, or in Documents/save
/// for a sideloaded IPA with the game files inside. Both are read (resolveDevice), and the one in use decides where a copy
/// goes. The app itself is found on the device (SaveDiscovery), not from the launcher's install records.
struct SaveTransfer {
    /// The committed save folders (dm/host/hle_fs.c): `save`, and `save_device` for a game that mounts device save data beside
    /// its account save (Mario Kart 8 Deluxe). The `.work` and `.new` folders beside them are one session's uncommitted copy,
    /// cloned again from the committed folder at every mount, so they are not part of the save.
    static let folders = ["save", "save_device"]

    let titleID: String
    let macSave: URL      // the Mac app's DM_SAVE
    var legacySave: URL?  // the ~/Library save the Mac app copies into macSave on its next start, while macSave is empty
    let device: String    // the device's UDID
    let bundle: String    // the installed app's bundle ID: its data container
    let devicectl: DeviceControl
    var scratch = FileManager.default.temporaryDirectory
    var now: () -> Date = Date.init

    enum Failure: Error, Equatable {
        case noMacSave, noDeviceSave
        case device(String)   // devicectl's last line
        case timeout          // a command ran out of time (DeviceControl.timedOut)
    }

    /// What the device holds: the save folders with files in them, and the newest file's date.
    struct Contents: Equatable {
        var folders: [String] = []
        var newest: Date?
    }

    static func legacyMacSave(titleID: String,
                              support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) -> URL {
        support.appendingPathComponent("nxnative").appendingPathComponent(titleID).appendingPathComponent("save")
    }

    /// The Mac app's DM_SAVE, by launcher.c's rule: beside the app when the app's folder holds the library marker, else ~/Library.
    /// The second value is the ~/Library save the app copies across on its first start in a library folder (nil without the marker).
    static func macSave(titleID: String, appPath: String,
                        support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) -> (save: URL, legacy: URL?) {
        let legacy = legacyMacSave(titleID: titleID, support: support)
        guard !appPath.isEmpty else { return (legacy, nil) }
        let folder = URL(fileURLWithPath: appPath).deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(GameLog.marker).path) else { return (legacy, nil) }
        return (folder.appendingPathComponent("save").appendingPathComponent(titleID), legacy)
    }

    /// A save folder on the Mac: `save` is DM_SAVE itself, `save_device` sits beside it as DM_SAVE + "_device".
    static func macPath(_ folder: String, save: URL) -> URL {
        folder == "save" ? save : URL(fileURLWithPath: save.path + "_device")
    }

    /// Where a save folder is read from: macSave, or while that is still empty the ~/Library save the app brings across.
    func macSource(_ folder: String) -> URL? {
        let current = Self.macPath(folder, save: macSave)
        if Self.newest(in: current) != nil { return current }
        if let legacySave, Self.newest(in: Self.macPath("save", save: macSave)) == nil, Self.newest(in: Self.macPath("save_device", save: macSave)) == nil {
            let old = Self.macPath(folder, save: legacySave)
            if Self.newest(in: old) != nil { return old }
        }
        return nil
    }

    /// The per-game layout (patch 0003, the launcher's install). The other is Documents itself (resolveDevice).
    var deviceFolder: String { "Documents/games/\(titleID)" }
    /// Backups go beside the save, one folder per copy: "<date> mac" holds the Mac save a copy from the device replaced,
    /// "<date> device" the device save a copy from the Mac replaced.
    var backups: URL { macSave.deletingLastPathComponent().appendingPathComponent(macSave.lastPathComponent + "-backups") }

    // ---- reading ----

    /// Which Mac save the Saves window reads, for the line under "This Mac".
    enum MacLocation: Equatable {
        case library(URL)    // beside the app, the library folder's save/<title ID>: what the game reads
        case standard(URL)   // ~/Library/Application Support, the default location (no library folder)
        case pending(URL)    // the ~/Library save of a game in a library folder, which the game copies across on its next start
    }

    /// The folder the game reads its save from, by the launcher's rule. In a library folder that is save/<title ID> beside the
    /// app, also when both exist (the game reads that one and copies the ~/Library save only while it is empty), and the
    /// ~/Library one only while nothing is beside the app yet.
    func macLocation() -> MacLocation {
        guard legacySave != nil else { return .standard(macSave) }
        for f in Self.folders {
            if let source = macSource(f), Self.macPath(f, save: macSave) != source { return .pending(Self.macPath("save", save: legacySave!)) }
        }
        return .library(macSave)
    }

    func readMac() -> Contents {
        Self.folders.reduce(into: Contents()) { c, f in
            guard let source = macSource(f), let date = Self.newest(in: source) else { return }
            c.folders.append(f)
            c.newest = max(c.newest ?? date, date)
        }
    }

    /// What the device holds, from the layout the app uses (resolveDevice).
    func readDevice() throws -> Contents { try resolveDevice().contents }

    /// Which of the two save layouts the app on the device uses, and what is in it. Documents is listed first: when that
    /// fails the device or the app cannot be reached, which is an error (a timeout is one too, never an empty save). The
    /// layout that holds a save is the one in use. With saves in both, or in neither, it is the per-game folder when that
    /// holds the game's files (the runtime then uses it, dm/ios/Sources/main.m), else Documents.
    func resolveDevice() throws -> (base: String, contents: Contents) {
        let documents = try list("Documents", recurse: false)
        let games = try readDevice(at: deviceFolder), plain = try readDevice(at: "Documents")
        switch (games.folders.isEmpty, plain.folders.isEmpty) {
        case (false, true): return (deviceFolder, games)
        case (true, false): return ("Documents", plain)
        default:
            let hasGames = Self.names(documents).contains("games")
            let files = hasGames ? (try? list(deviceFolder, recurse: false)).map(Self.names) ?? [] : []
            let perGame = !files.isDisjoint(with: ["romfs.img", "romfs"])
            return perGame ? (deviceFolder, games) : ("Documents", plain)
        }
    }

    /// The save folders under a layout. A folder that cannot be listed is one the app has not made yet, except when the
    /// command timed out: that is rethrown.
    private func readDevice(at base: String) throws -> Contents {
        var c = Contents()
        for f in Self.folders {
            let data: Data
            do { data = try list(base + "/" + f, recurse: true) } catch Failure.timeout { throw Failure.timeout } catch { continue }
            guard let entries = Self.parseListing(data), entries.files > 0 else { continue }
            c.folders.append(f)
            if let date = entries.newest { c.newest = max(c.newest ?? date, date) }
        }
        return c
    }

    private func list(_ subdirectory: String, recurse: Bool) throws -> Data {
        let json = scratch.appendingPathComponent("nxnative-files-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: json) }
        let r = devicectl.run(Self.listCommand(device: device, bundle: bundle, subdirectory: subdirectory, recurse: recurse, json: json.path))
        guard r.ok, let data = try? Data(contentsOf: json) else { throw Self.failure(r.output) }
        return data
    }

    /// The file and folder names in a non-recursive listing, lowercased.
    static func names(_ data: Data) -> Set<String> {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any], let files = result["files"] as? [[String: Any]] else { return [] }
        return Set(files.compactMap { ($0["name"] as? String).map { ($0 as NSString).lastPathComponent.lowercased() } })
    }

    static func failure(_ output: String) -> Failure {
        output.contains(DeviceControl.timedOut) || output.lowercased().contains("timed out") ? .timeout : .device(lastLine(output))
    }

    // ---- copying ----

    /// The device's save replaces the Mac's. The device save comes into a folder beside the Mac's first, so a copy that
    /// fails leaves the Mac save as it was; then the Mac save moves into the backup and the copy takes its place.
    /// Returns the backup, nil when the Mac had no save.
    func deviceToMac() throws -> URL? {
        let (folder, there) = try resolveDevice()
        guard !there.folders.isEmpty else { throw Failure.noDeviceSave }
        let fm = FileManager.default
        let incoming = macSave.deletingLastPathComponent().appendingPathComponent(".save-incoming-\(UUID().uuidString)")
        try fm.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: incoming) }
        for f in there.folders {
            try copyFrom(folder + "/" + f, to: incoming.appendingPathComponent(f))
        }
        var backup: URL?
        // A ~/Library save the app has not brought across yet stays where it is: macSave gets the copy, so the app keeps it
        for f in there.folders where fm.fileExists(atPath: Self.macPath(f, save: macSave).path) {
            let into = try backup ?? makeBackup("mac")
            backup = into
            try fm.moveItem(at: Self.macPath(f, save: macSave), to: into.appendingPathComponent(f))
        }
        for f in there.folders { try fm.moveItem(at: incoming.appendingPathComponent(f), to: Self.macPath(f, save: macSave)) }
        return backup
    }

    /// The Mac's save replaces the device's. The device save is copied to the Mac first; if that fails nothing is replaced.
    /// Returns the backup, nil when the device had no save.
    func macToDevice() throws -> URL? {
        let here = readMac()
        guard !here.folders.isEmpty else { throw Failure.noMacSave }
        let (folder, there) = try resolveDevice()
        var backup: URL?
        if !there.folders.isEmpty {
            let into = try makeBackup("device")
            backup = into
            for f in there.folders { try copyFrom(folder + "/" + f, to: into.appendingPathComponent(f)) }
        }
        for f in here.folders {
            let r = devicectl.run(Self.copyToCommand(device: device, bundle: bundle, source: (macSource(f) ?? Self.macPath(f, save: macSave)).path, destination: folder + "/" + f))
            guard r.ok else { throw Self.failure(r.output) }
        }
        return backup
    }

    private func copyFrom(_ source: String, to local: URL) throws {
        let r = devicectl.run(Self.copyFromCommand(device: device, bundle: bundle, source: source, destination: local.path))
        guard r.ok else { throw Self.failure(r.output) }
        Self.hoist(local)
        guard Self.newest(in: local) != nil else { throw Failure.device(source) }   // the device listed files that did not come
    }

    private func makeBackup(_ side: String) throws -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stamp = f.string(from: now())
        var url = backups.appendingPathComponent("\(stamp) \(side)"), n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = backups.appendingPathComponent("\(stamp) \(side) \(n)"); n += 1 }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // ---- devicectl's command lines (the same domain as the install's archiveCopy) ----

    static func listCommand(device: String, bundle: String, subdirectory: String, recurse: Bool, json: String) -> [String] {
        ["device", "info", "files", "--device", device, "--domain-type", "appDataContainer", "--domain-identifier", bundle,
         "--subdirectory", subdirectory, recurse ? "--recurse" : "--no-recurse", "--json-output", json]
    }

    static func copyFromCommand(device: String, bundle: String, source: String, destination: String) -> [String] {
        ["device", "copy", "from", "--device", device, "--source", source, "--destination", destination,
         "--domain-type", "appDataContainer", "--domain-identifier", bundle]
    }

    /// The destination is the folder itself, as in the install's archiveCopy. Never `--remove-existing-content true`: on a
    /// real device it also deletes the destination's siblings (Documents/romfs.img, env.txt), not only its contents (#250).
    /// Without it devicectl merges and overwrites, so a file the Mac no longer has can stay in the device's folder, which
    /// costs far less than wiping game data (devicectl has no command to delete a single file). The backup has the old save.
    static func copyToCommand(device: String, bundle: String, source: String, destination: String) -> [String] {
        ["device", "copy", "to", "--device", device, "--source", source, "--destination", destination,
         "--domain-type", "appDataContainer", "--domain-identifier", bundle]
    }

    // ---- pure helpers ----

    /// The newest modification date of a file in the folder, nil when it has no files (a save the game has not written).
    static func newest(in folder: URL) -> Date? {
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return nil }
        var newest: Date?
        for case let url as URL in walk {
            guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]), v.isRegularFile == true,
                  let date = v.contentModificationDate else { continue }
            newest = max(newest ?? date, date)
        }
        return newest
    }

    /// `devicectl device info files --json-output`: the entries that carry a `modificationDate` (or `lastModDate` in the
    /// `metadata` of the current CoreDevice), wherever the JSON nests them, directories left out when an entry says it is one. nil for JSON that
    /// cannot be read.
    static func parseListing(_ data: Data) -> (files: Int, newest: Date?)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var files = 0, newest: Date?
        func walk(_ node: Any) {
            if let list = node as? [Any] { list.forEach(walk); return }
            guard let dict = node as? [String: Any] else { return }
            let metadata = dict["metadata"] as? [String: Any]
            let raw = dict["modificationDate"] ?? metadata?["modificationDate"] ?? metadata?["lastModDate"]
            if let raw {
                let kind = ["fileType", "type", "kind"].compactMap { dict[$0] as? String }.joined().lowercased()
                if !kind.contains("dir") && (dict["resources"] as? [String: Any])?["isDirectory"] as? Bool != true {
                    files += 1
                    if let date = date(raw) { newest = max(newest ?? date, date) }
                }
            }
            for (key, value) in dict where key != "metadata" || raw == nil { walk(value) }
        }
        walk(root)
        return (files, newest)
    }

    /// An ISO 8601 date, with or without fractions of a second, or a number of seconds (since 1970, or since 2001 as
    /// Foundation's reference date when it is small enough to be one).
    static func date(_ raw: Any) -> Date? {
        if let n = raw as? Double { return n > 1_000_000_000 ? Date(timeIntervalSince1970: n) : Date(timeIntervalSinceReferenceDate: n) }
        guard let s = raw as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// A copy that put the folder inside the destination (local/save/save) instead of being it: its contents move up one
    /// level, so either way the copy is the save folder itself.
    static func hoist(_ local: URL) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard let items = try? fm.contentsOfDirectory(atPath: local.path), items == [local.lastPathComponent],
              fm.fileExists(atPath: local.appendingPathComponent(items[0]).path, isDirectory: &isDir), isDir.boolValue else { return }
        let aside = local.deletingLastPathComponent().appendingPathComponent(".hoist-\(UUID().uuidString)")
        guard (try? fm.moveItem(at: local.appendingPathComponent(items[0]), to: aside)) != nil else { return }
        try? fm.removeItem(at: local)
        try? fm.moveItem(at: aside, to: local)
    }

    static func lastLine(_ output: String) -> String {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.last(where: { $0.lowercased().contains("error") }) ?? lines.last ?? "devicectl"
    }

    enum Side { case mac, device }

    /// The newer of the two saves; nil when neither has one or they were written within the same few seconds.
    static func newer(mac: Date?, device: Date?) -> Side? {
        switch (mac, device) {
        case (nil, nil): return nil
        case (_, nil): return .mac
        case (nil, _): return .device
        case let (m?, d?): return abs(m.timeIntervalSince(d)) < 3 ? nil : (m > d ? .mac : .device)
        }
    }

    /// A copy of the game is running on this Mac: one of the running apps is a build of it (DMTitleID in its Info.plist).
    /// Its save may be half written, and it would write its own over the copy when it saves next.
    static func running(titleID: String, apps: [URL]) -> Bool {
        apps.contains { app in
            (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["DMTitleID"] as? String)?.uppercased() == titleID.uppercased()
        }
    }

    static func runningOnMac(titleID: String) -> Bool {
        running(titleID: titleID, apps: NSWorkspace.shared.runningApplications.compactMap(\.bundleURL))
    }
}

/// The Saves sheet: the game's save on this Mac and on the device it was installed on, which is newer, and a copy either way.
/// A copy asks first, in the sheet itself (a controller reaches it), and says where the save it replaced went.
struct SavesView: View {
    @ObservedObject var m: BuildModel
    @ObservedObject var library: GameLibrary
    let gameID: UUID
    var support: URL? = nil               // the Application Support folder; tests use a temporary one
    @StateObject private var model: SavesModel
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var focus: PadFocus

    @State private var asking: SaveTransfer.Side?   // the side whose save a copy would replace
    @State private var busy = false
    @State private var result: (text: String, ok: Bool)?

    /// `devicectl` and `listDevices` are what tests and the visual QA hand in as stand-ins: with a stand-in devicectl and no
    /// device list, the devices are the ones the launcher already knows, so nothing asks the system for them.
    init(m: BuildModel, library: GameLibrary, gameID: UUID, devicectl: DeviceControl? = nil, support: URL? = nil,
         listDevices: (() -> [AppleDevice])? = nil, timeout: TimeInterval = 30) {
        self.m = m; self.library = library; self.gameID = gameID; self.support = support
        let game = library.games.first { $0.id == gameID } ?? LibraryGame(titleID: "", name: "")
        let mac = support.map { SaveTransfer.macSave(titleID: game.titleID, appPath: game.appPath, support: $0) }
            ?? SaveTransfer.macSave(titleID: game.titleID, appPath: game.appPath)
        let control = devicectl ?? .xcrun(m.xcrunPath)
        let template = SaveTransfer(titleID: game.titleID, macSave: mac.save, legacySave: mac.legacy, device: "", bundle: "", devicectl: control)
        let known = m.devices, xcrun = m.xcrunPath
        let list: () -> [AppleDevice] = listDevices ?? (devicectl == nil ? { DeviceTools.devices(xcrun: xcrun, timeout: 10) } : { known })
        let key = "saveTransfer.device." + game.titleID
        _model = StateObject(wrappedValue: SavesModel(
            template: template, name: game.name,
            recordedBundle: NSDictionary(contentsOfFile: game.iosAppPath + "/Info.plist")?["CFBundleIdentifier"] as? String,
            recordedDevice: game.installedDevice, installTarget: m.installDevice,
            remembered: UserDefaults.standard.string(forKey: key) ?? "",
            rememberChoice: { UserDefaults.standard.set($0, forKey: key) },
            listDevices: list, timeout: timeout))
    }

    private var game: LibraryGame? { library.games.first { $0.id == gameID } }
    private var macSave: SaveTransfer.Contents { model.macSave }
    private var deviceSave: SaveTransfer.Contents? { model.deviceSave }
    /// Which folder the Mac save is read from, so "No save yet" says where it looked.
    private var macLocationText: String {
        func shown(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }
        switch model.macLocation {
        case .library(let url): return String(format: m.t("saves.macLibrary"), shown(url))
        case .standard(let url): return String(format: m.t("saves.macStandard"), shown(url))
        case .pending(let url): return String(format: m.t("saves.macPending"), shown(url))
        }
    }
    /// The device the sheet asks: its name, or what the launcher recorded when the list has not come yet.
    private var deviceName: String { model.selectedDevice?.name ?? game.map { m.deviceName($0.installedDevice) } ?? "iPhone" }
    private var transfer: SaveTransfer { model.found ?? model.template }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(m.t("saves.title")).font(.manrope(26, .heavy)).tracking(-0.6)
                if let game { Text(game.name).font(.manrope(14)).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 30).padding(.top, 28).padding(.bottom, model.showsSelector ? 12 : 20)
            if model.showsSelector {
                HStack(spacing: 12) {
                    Text(m.t("saves.device")).font(.manrope(13)).foregroundStyle(.secondary)
                    LauncherMenuPicker(options: model.devices.map { d in
                        (value: d.id, label: d.name + (d.reachable ? "" : " (" + m.t("dev.notConnected") + ")"))
                    }, selection: model.selected) { model.select($0) }
                    .padTarget("saves.device", scope: "saves") {}
                }
                .padding(.horizontal, 30).padding(.bottom, 16)
            }
            VStack(alignment: .leading, spacing: 18) {
                card {
                    sideRow(.mac)
                    Divider().opacity(0.25).padding(.leading, 18)
                    sideRow(.device)
                }
                if let asking { confirmation(asking) } else { actions }
                if busy {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(m.t("saves.copying")).font(.manrope(13)).foregroundStyle(.secondary)
                    }
                } else if let result {
                    Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.manrope(13)).foregroundStyle(result.ok ? LauncherPalette.ready : LauncherPalette.building)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 30)
            Divider().opacity(0.3)
            HStack(spacing: 14) {
                Text(String(format: m.t("saves.note"), deviceName)).font(.manrope(12)).foregroundStyle(.secondary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button { dismiss() } label: {
                    Text(m.t("launch.done")).font(.manrope(13.5, .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 22).padding(.vertical, 9)
                        .background(LauncherPalette.cream, in: Capsule())
                }
                .buttonStyle(.plain).keyboardShortcut(asking == nil ? .defaultAction : nil).disabled(busy)
                .padTarget("saves.done", scope: "saves", radius: 20) { if !busy { dismiss() } }
            }
            .padding(.horizontal, 30).padding(.vertical, 16)
        }
        .padScope("saves", focus)
        .frame(width: 600, height: 520)
        .background(LauncherPalette.background)
        .font(.manrope(13))
        .preferredColorScheme(.dark)
        .tint(LauncherPalette.cream)
        .onAppear { model.begin() }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(LauncherPalette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.06)))
    }

    private func sideRow(_ side: SaveTransfer.Side) -> some View {
        let newer = SaveTransfer.newer(mac: macSave.newest, device: deviceSave?.newest)
        let detail: String
        switch side {
        case .mac: detail = macSave.newest.map { String(format: m.t("saves.saved"), dateText($0)) } ?? m.t("saves.none")
        case .device:
            switch model.deviceState {
            case .noDevices: detail = m.t("saves.noDevices")
            case .notConnected: detail = String(format: m.t("saves.notConnected"), deviceName)
            case .notInstalled: detail = String(format: m.t("saves.notInstalled"), deviceName)
            case .reading: detail = String(format: m.t("saves.reading"), deviceName)
            case .failed(let why): detail = String(format: m.t("saves.unreachable"), why)
            case .timedOut: detail = String(format: m.t("saves.timeout"), deviceName)
            case .ready(let c): detail = c.newest.map { String(format: m.t("saves.saved"), dateText($0)) } ?? m.t("saves.none")
            }
        }
        return HStack(spacing: 14) {
            Image(systemName: side == .mac ? "desktopcomputer" : (model.selectedDevice?.model.lowercased().contains("ipad") == true ? "ipad" : "iphone")).font(.system(size: 18, weight: .light))
                .foregroundStyle(.secondary).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(side == .mac ? m.t("saves.mac") : deviceName).font(.manrope(14, .medium))
                Text(detail).font(.manrope(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if side == .mac {
                    Text(macLocationText).font(.manrope(11)).foregroundStyle(.tertiary).lineLimit(2).truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            if newer == side && (side == .mac || deviceSave != nil) {
                Text(m.t("saves.newer").uppercased()).font(.manrope(10.5, .bold)).tracking(1.1).foregroundStyle(.black)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(LauncherPalette.cream, in: Capsule())
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .frame(minHeight: 60)
    }

    /// The two copies, Refresh and the backups folder. A copy needs both sides readable and a save on the side it copies from.
    private var actions: some View {
        let toDevice = !busy && deviceSave != nil && !macSave.folders.isEmpty
        let toMac = !busy && !(deviceSave?.folders.isEmpty ?? true)
        return HStack(spacing: 10) {
            Button(String(format: m.t("saves.toDevice"), deviceName)) { ask(.device) }.disabled(!toDevice)
                .padTarget("saves.toDevice", scope: "saves") { if toDevice { ask(.device) } }
            Button(String(format: m.t("saves.toMac"), deviceName)) { ask(.mac) }.disabled(!toMac)
                .padTarget("saves.toMac", scope: "saves") { if toMac { ask(.mac) } }
            Spacer(minLength: 8)
            Button(m.t("dev.refresh")) { model.refresh() }.disabled(busy || !model.canRefresh)
                .padTarget("saves.refresh", scope: "saves") { if !busy { model.refresh() } }
            if FileManager.default.fileExists(atPath: transfer.backups.path) {
                Button(m.t("saves.backups")) { NSWorkspace.shared.open(transfer.backups) }
                    .padTarget("saves.backups", scope: "saves") { NSWorkspace.shared.open(transfer.backups) }
            }
        }
        .buttonStyle(LauncherSecondaryButtonStyle())
    }

    /// Asking before a copy replaces a save: which one, where its backup goes, and that the game must be closed on the device.
    private func confirmation(_ replacing: SaveTransfer.Side) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(replacing == .device ? String(format: m.t("saves.askToDevice"), deviceName) : String(format: m.t("saves.askToMac"), deviceName))
                .font(.manrope(15, .semibold)).fixedSize(horizontal: false, vertical: true)
            Text(String(format: m.t("saves.askNote"), deviceName, m.shortPath(transfer.backups.path)))
                .font(.manrope(12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Spacer()
                Button(m.t("saves.cancel")) { asking = nil }.buttonStyle(LauncherSecondaryButtonStyle())
                    .padTarget("saves.cancel", scope: "saves") { asking = nil }
                Button { copy(replacing) } label: {
                    Text(m.t("saves.replace")).font(.manrope(13, .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 18).padding(.vertical, 9)
                        .background(LauncherPalette.cream, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain).keyboardShortcut(.defaultAction)
                .padTarget("saves.replace", scope: "saves") { copy(replacing) }
            }
        }
        .padding(18)
        .background(LauncherPalette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LauncherPalette.cream.opacity(0.35)))
    }

    private func dateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = m.lang == .zh ? Locale(identifier: "zh_Hans") : (Locale.current.identifier.hasPrefix("zh") ? Locale(identifier: "en_US") : .current)
        f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: date)
    }

    private func ask(_ replacing: SaveTransfer.Side) {
        result = nil
        guard let game, !SaveTransfer.runningOnMac(titleID: game.titleID) else {
            result = (String(format: m.t("saves.running"), game?.name ?? ""), false)
            return
        }
        asking = replacing
        focus.focused = "saves.cancel"   // the controller's focus moves to the question it has to answer
    }

    private func copy(_ replacing: SaveTransfer.Side) {
        asking = nil
        guard let game, let transfer = model.found else { return }
        if SaveTransfer.runningOnMac(titleID: game.titleID) {   // started while the question was open
            result = (String(format: m.t("saves.running"), game.name), false)
            return
        }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: (String, Bool)
            do {
                let backup = try replacing == .device ? transfer.macToDevice() : transfer.deviceToMac()
                outcome = (backup.map { String(format: m.t("saves.copiedBackup"), m.shortPath($0.path)) } ?? m.t("saves.copied"), true)
            } catch { outcome = (String(format: m.t("saves.failed"), message(error)), false) }
            DispatchQueue.main.async {
                busy = false
                result = outcome
                model.refresh()
                focus.focused = "saves.done"
            }
        }
    }

    private func message(_ error: Error) -> String {
        switch error as? SaveTransfer.Failure {
        case .noMacSave: return m.t("saves.noMacSave")
        case .noDeviceSave: return String(format: m.t("saves.noDeviceSave"), deviceName)
        case .device(let line): return line
        case .timeout: return String(format: m.t("saves.timeout"), deviceName)
        case nil: return error.localizedDescription
        }
    }
}
