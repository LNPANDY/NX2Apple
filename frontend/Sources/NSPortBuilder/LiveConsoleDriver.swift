import SwiftUI
import Combine
import AppKit
import GameController
import CoreHaptics

/// A controller as GameController reports it, reduced to what the console mode shows. Tests build these instead of hardware.
struct ConsolePadSnapshot: Equatable {
    var id: String
    var name: String
    var category: String?
    var playerIndex: Int?   // 1...4, nil when unset
    var battery: Double?
    var charging = false

    var controller: ConsoleController {
        let family = ConsoleGlyphs.Family(category: category)
        let c = (category ?? "").lowercased().replacingOccurrences(of: "-", with: "")
        let kind: ConsoleController.Kind
        if c.contains("joycon") { kind = .paired }
        else if family == .nintendo { kind = .fullSize }
        else if family == .xbox { kind = .xbox }
        else { kind = .gamepad }
        return ConsoleController(id: id, name: name, player: playerIndex, kind: kind, battery: battery, charging: charging)
    }
}

/// The console mode over the launcher's real data. It reuses what the desktop launcher uses and keeps no second copy of anything:
/// the games and their status come from `GameLibrary`, covers from `GameLibrary.artwork`, launch options from `SavedChoices` and the
/// library (as LaunchOptionsView reads and writes them), Play from `GameStart.environment`, the player-mode setting from
/// `ControlLayout`, and the controllers from GameController.
@MainActor final class LiveConsoleDriver: ConsoleDriver {
    @Published var state = ConsoleState()

    private let library: GameLibrary
    private let controls: ControlLayout
    private let repo: () -> String
    private let lang: () -> Lang
    private let labels: (String) -> String
    private let pads: () -> [ConsolePadSnapshot]
    private let launch: (LibraryGame, [String: String], @escaping (Int32?, Error?) -> Void) -> Void
    private let artwork: (LibraryGame, String) -> NSImage?
    private let startingTimeout: TimeInterval
    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var refreshQueued = false
    private var covers: [UUID: (path: String, image: Image?)] = [:]
    private var launchedPID: Int32?
    private var timeoutTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var clock: Timer?
    /// Real controllers by id, for Identify and player assignment.
    private var devices: [String: GCController] = [:]

    init(library: GameLibrary, controls: ControlLayout, repo: @escaping () -> String, lang: @escaping () -> Lang, labels: @escaping (String) -> String,
         pads: (() -> [ConsolePadSnapshot])? = nil,
         launch: ((LibraryGame, [String: String], @escaping (Int32?, Error?) -> Void) -> Void)? = nil,
         artwork: ((LibraryGame, String) -> NSImage?)? = nil, startingTimeout: TimeInterval = 20, observeSystem: Bool = true) {
        self.library = library; self.controls = controls; self.repo = repo; self.lang = lang; self.labels = labels
        self.startingTimeout = startingTimeout
        self.pads = pads ?? { [] }
        self.launch = launch ?? Self.openApplication
        self.artwork = artwork ?? { game, repo in GameLibrary.artwork(for: game, repo: repo) }
        if pads == nil { self.devicePads = true }
        state.padMerge = controls.padMerge
        library.objectWillChange.sink { [weak self] _ in self?.queueRefresh() }.store(in: &cancellables)
        controls.$padMerge.sink { [weak self] merged in self?.state.padMerge = merged }.store(in: &cancellables)
        refresh()
        refreshControllers(announce: false)
        guard observeSystem else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.padsChanged(connected: true, note: note) }
            },
            center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.padsChanged(connected: false, note: note) }
            },
        ]
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { if let pid { self?.gameDidTerminate(pid: pid) } }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.gameWindowAppeared() }
        })
        clock = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.state.time = Date() } }
    }
    private var devicePads = false

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        clock?.invalidate()
    }

    // MARK: Games

    private func t(_ key: String) -> String { L10n.string(key, lang()) }

    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in self?.refreshQueued = false; self?.refresh() }
    }

    /// The library as console games, in the library's order, keeping the focus and each game's shown values.
    func refresh() {
        let focus = state.focusedGameID
        let games = library.games.map { consoleGame($0) }
        state.games = games
        state.focusedGameID = games.contains { $0.id == focus } ? focus : (library.selected.map { $0.id.uuidString }.flatMap { id in games.contains { $0.id == id } ? id : nil } ?? games.first?.id)
        state.time = Date()
    }

    static func status(of game: LibraryGame, brokenMessage: String) -> ConsoleGame.Status {
        if game.isReady { return .ready }
        if !game.appPath.isEmpty { return .broken(brokenMessage) }   // an app is recorded but is not a complete game app
        return game.inputs.values.contains { !$0.isEmpty } ? .needsBuild : .needsData
    }

    static func platforms(of game: LibraryGame) -> [ConsoleGame.Platform] {
        var result: [ConsoleGame.Platform] = []
        if game.isReady { result.append(.mac) }
        if game.hasIOSBuild || game.onDevice { result.append(.iphone) }
        return result.isEmpty ? [.mac] : result
    }

    private func consoleGame(_ game: LibraryGame) -> ConsoleGame {
        let settings = game.isReady ? (LaunchSetting.forMac(app: game.appPath, titleID: game.titleID, repo: repo(), labels: labels) ?? []) : []
        let store = SavedChoices(app: game.appPath, titleID: game.titleID)
        var values: [String: String] = [:]
        for s in settings { values[s.env] = s.storeBacked ? store.current(s) : game.launchValue(s) }
        return ConsoleGame(id: game.id.uuidString, title: game.name, version: version(of: game),
                           platforms: Self.platforms(of: game), artwork: cover(game),
                           status: Self.status(of: game, brokenMessage: t("console.broken")), settings: settings, values: values)
    }

    /// The app's version as its Info.plist states it; empty for a game that has no app yet.
    private func version(of game: LibraryGame) -> String {
        let plist = URL(fileURLWithPath: game.appPath).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return "" }
        return info["CFBundleShortVersionString"] as? String ?? ""
    }

    /// Covers through the launcher's own lookup, decoded once per image path.
    private func cover(_ game: LibraryGame) -> Image? {
        let key = game.artworkPath + "|" + game.titleID + "|" + game.name
        if let cached = covers[game.id], cached.path == key { return cached.image }
        let image = artwork(game, repo()).map { Image(nsImage: $0) }
        covers[game.id] = (key, image)
        return image
    }

    /// Covers downloaded after the first draw (ArtworkStore) show up when the console asks again.
    func reloadCovers() { covers = [:]; refresh() }

    func focus(_ gameID: String) { state.focus(gameID) }

    func play(_ gameID: String) {
        state.play(gameID)
        guard state.startingGameID == gameID, let game = library.games.first(where: { $0.id.uuidString == gameID }) else { return }
        let environment = GameStart.environment(for: game, library: library, controls: controls, repo: repo(), labels: labels)
        state.starting = .preparing
        launch(game, environment) { [weak self] pid, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.state.startingGameID == gameID else { return }
                    if let error { self.state.returnFromGame(); self.showToast(error.localizedDescription); return }
                    self.launchedPID = pid
                    self.state.starting = .opening
                    self.timeoutTask?.cancel()
                    self.timeoutTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64((self?.startingTimeout ?? 20) * 1_000_000_000))
                        guard !Task.isCancelled else { return }
                        self?.gameWindowAppeared()
                    }
                }
            }
        }
    }

    private static func openApplication(_ game: LibraryGame, _ environment: [String: String], _ done: @escaping (Int32?, Error?) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        if !environment.isEmpty { configuration.environment = environment }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: game.appPath), configuration: configuration) { app, error in
            done(app?.processIdentifier, error)
        }
    }

    /// The game's window took the front (or the wait ran out): Starting ends, the console stays selected on the game.
    func gameWindowAppeared() {
        guard state.startingGameID != nil, launchedPID != nil || !devicePads else { return }
        timeoutTask?.cancel()
        state.returnFromGame()
    }

    /// The game this console started quit: the console comes back to the front (PR #110's launcher-wide return does the same for the desktop).
    func gameDidTerminate(pid: Int32) {
        guard pid == launchedPID else { return }
        launchedPID = nil
        timeoutTask?.cancel()
        state.returnFromGame()
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Options

    func openOptions(_ gameID: String) { state.openOptions(gameID) }

    func setOption(gameID: String, setting env: String, value: String) {
        state.setOption(game: gameID, setting: env, value: value)
        guard let game = library.games.first(where: { $0.id.uuidString == gameID }),
              let shown = state.games.first(where: { $0.id == gameID }), let s = shown.settings.first(where: { $0.env == env }),
              let stored = shown.values[env] else { return }
        if s.storeBacked { SavedChoices(app: game.appPath, titleID: game.titleID).set(s, stored) } else { library.setLaunchOption(s, stored, for: game.id) }
    }

    // MARK: Controllers

    func openControllers() { state.openControllers() }
    func requestPlayer(_ player: Int) {
        guard state.presentedSheet == .controllers, (1...4).contains(player) else { return }
        state.assigningPlayer = player
    }
    func requestAssignment(controllerID: String) {
        guard state.presentedSheet == .controllers, let c = state.controllers.first(where: { $0.id == controllerID }) else { return }
        state.assigningControllerID = controllerID
        state.assigningPlayer = state.assigningPlayer ?? c.player ?? 1
    }
    func assignPlayer(controllerID: String, player: Int) {
        state.assignPlayer(controller: controllerID, player: player)
        guard let pad = devices[controllerID] else { return }
        for other in devices.values where other !== pad && other.playerIndex.rawValue == player - 1 { other.playerIndex = .indexUnset }
        pad.playerIndex = GCControllerPlayerIndex(rawValue: player - 1) ?? .indexUnset
        refreshControllers(announce: false)
    }
    func setPadMerge(_ enabled: Bool) { controls.padMerge = enabled }

    /// A short rumble when the controller has haptics, nothing otherwise (and never an error).
    func identify(controllerID: String) {
        guard let c = state.controllers.first(where: { $0.id == controllerID }) else { return }
        state.identifyingControllerID = controllerID
        showToast(String(format: t("console.identifyingName"), c.name))
        guard let engine = devices[controllerID]?.haptics?.createEngine(withLocality: .default) else { return }
        do {
            try engine.start()
            let events = [CHHapticEvent(eventType: .hapticContinuous, parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.8),
                                                                                  CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)],
                                        relativeTime: 0, duration: 0.45)]
            try engine.makePlayer(with: CHHapticPattern(events: events, parameters: [])).start(atTime: 0)
        } catch { /* no rumble on this controller: the toast is the answer */ }
    }

    /// macOS offers apps no way to drop a Bluetooth controller, so this says where to do it instead.
    func disconnect(controllerID: String) { showToast(t("console.disconnectHint")) }

    func padsChanged(connected: Bool, note: Notification) {
        refreshControllers(announce: false)
        guard let pad = note.object as? GCController else { return }
        let name = pad.vendorName ?? pad.productCategory
        let player = state.padMerge ? 1 : state.controllers.first { $0.name == name }?.player
        if connected {
            showToast(player.map { String(format: t("console.connected"), name, $0) } ?? String(format: t("console.connectedUnassigned"), name))
        } else { showToast(String(format: t("console.disconnected"), name)) }
    }

    func refreshControllers(announce: Bool) {
        var snapshots = pads()
        if devicePads {
            devices = [:]
            snapshots = GCController.controllers().compactMap { c in
                guard c.extendedGamepad != nil else { return nil }
                let id = String(UInt(bitPattern: ObjectIdentifier(c).hashValue), radix: 16)
                devices[id] = c
                let level = c.battery.map { Double($0.batteryLevel) }
                let index = c.playerIndex.rawValue
                return ConsolePadSnapshot(id: id, name: c.vendorName ?? c.productCategory, category: c.productCategory,
                                          playerIndex: (0...3).contains(index) ? index + 1 : nil, battery: level,
                                          charging: c.battery.map { $0.batteryState == .charging } ?? false)
            }
        }
        state.controllers = snapshots.map(\.controller)
    }

    // MARK: Navigation

    func dismissToast() { toastTask?.cancel(); state.toast = nil; state.identifyingControllerID = nil }
    func back() { state.back() }
    func exitToDesktop() { state.exitToDesktop() }
    func returnFromGame() { state.returnFromGame() }

    private func showToast(_ message: String) {
        toastTask?.cancel()
        state.toast = ConsoleToast(message: message)
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.state.toast = nil
            self?.state.identifyingControllerID = nil
        }
    }
}
