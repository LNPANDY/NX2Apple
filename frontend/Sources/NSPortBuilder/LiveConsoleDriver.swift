import SwiftUI
import Combine
import AppKit
import GameController
import CoreHaptics
import os

/// A controller as GameController reports it, reduced to what the console mode shows. Tests build these instead of hardware.
/// What a controller reports about its battery.
enum PadBatteryState: Equatable { case unknown, discharging, charging, full }

/// What Identify can use on a controller, in the order it is tried: the player lights, the light bar, a rumble.
struct IdentifyPlan: Equatable {
    enum Action: Equatable { case playerLights, lightBar, rumble }
    static func actions(playerLights: Bool, lightBar: Bool, rumble: Bool) -> [Action] {
        (playerLights ? [.playerLights] : []) + (lightBar ? [.lightBar] : []) + (rumble ? [.rumble] : [])
    }
}

struct ConsolePadSnapshot: Equatable {
    var id: String
    var name: String
    var category: String?
    var playerIndex: Int?   // 1...4, nil when unset
    var battery: Double?
    var charging = false
    var canIdentify = true
    /// Whether GameController gives the controller a battery object at all. Without one it can only be powered by its cable.
    var hasBattery = true

    /// The level to show, or nil when the controller has not really reported one. GameController gives 0 with an unknown state for a
    /// DualShock 4 over Bluetooth and before the first report, and some pads over USB report no battery or an unknown one: those are
    /// never guessed (no number, outline only). Charging and full are real states, shown with the bolt.
    static func batteryReading(level: Double, state: PadBatteryState) -> (level: Double?, charging: Bool) {
        switch state {
        case .unknown: return (nil, false)
        case .charging: return (level.isFinite ? min(max(level, 0), 1) : nil, true)   // the real level, with the bolt
        case .full: return (1, true)   // plugged in and full: the full battery with the bolt
        case .discharging: return (level.isFinite ? min(max(level, 0), 1) : nil, false)
        }
    }

    var controller: ConsoleController {
        let family = ConsoleGlyphs.Family(category: category)
        let c = (category ?? "").lowercased().replacingOccurrences(of: "-", with: "")
        let kind: ConsoleController.Kind
        if c.contains("joycon") { kind = .paired }
        else if family == .nintendo { kind = .fullSize }
        else if family == .xbox { kind = .xbox }
        else { kind = .gamepad }
        return ConsoleController(id: id, name: name, player: playerIndex, kind: kind, battery: battery, charging: charging, canIdentify: canIdentify, wired: !hasBattery && kind != .keyboard)
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
         artwork: ((LibraryGame, String) -> NSImage?)? = nil, startingTimeout: TimeInterval = 20, observeSystem: Bool = true, watchHardware: Bool = true) {
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
        if watchHardware { hidWatcher = HIDControllerWatcher { [weak self] event in MainActor.assumeIsolated { self?.hidEvent(event) } } }
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
        clock = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.state.time = Date(); self?.refreshControllers(announce: false) } }   // the battery has no change callback: it is read again each tick
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
        if game.hasIOSBuild || game.onDevice { return .iphoneOnly }   // built for iPhone: this Mac cannot play it until it is built for Mac
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

    private var versions: [String: String] = [:]

    /// The version of the build the library knows: the Mac app's Info.plist (pack_app.py writes CFBundleShortVersionString), else the
    /// iPhone app's, else the one inside the IPA. Empty only when none of them states one.
    private func version(of game: LibraryGame) -> String {
        for path in [game.appPath, game.iosAppPath, game.ipaPath] where !path.isEmpty {
            if let cached = versions[path] { if !cached.isEmpty { return cached }; continue }
            let found = Self.version(at: path)
            versions[path] = found
            if !found.isEmpty { return found }
        }
        return ""
    }

    /// The display version in a build: a .app (Contents/Info.plist), an iOS .app (Info.plist) or an IPA (Payload/*.app/Info.plist).
    static func version(at path: String) -> String {
        let url = URL(fileURLWithPath: path)
        if url.pathExtension.lowercased() == "ipa" {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-p", path, "Payload/*.app/Info.plist"]
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return version(plist: data)
        }
        for relative in ["Contents/Info.plist", "Info.plist"] {
            if let data = try? Data(contentsOf: url.appendingPathComponent(relative)) { let v = version(plist: data); if !v.isEmpty { return v } }
        }
        return ""
    }

    static func version(plist data: Data) -> String {
        guard let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return "" }
        let v = (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String) ?? ""
        return v.trimmingCharacters(in: .whitespaces)
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

    private var overrides: [String: Int] = [:]   // player chosen by hand per controller id, 0 for none
    private var assignTimeout: Task<Void, Never>?

    /// Picking a player turns "all controllers are player 1" off: a per-player choice means nothing while it is on.
    private func leaveMergeForAssignment() {
        guard state.padMerge else { return }
        controls.padMerge = false
        state.padMerge = false
        showToast(t("console.mergeOff"))
    }

    /// The next press from any controller is taken as the answer, for 8 seconds.
    private func startCapture() {
        assignTimeout?.cancel()
        assignTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.captureSeconds ?? 8) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.state.assigningPlayer != nil else { return }
            self.cancelCapture()
            self.showToast(self.t("console.assignTimeout"))
        }
    }
    var captureSeconds: TimeInterval = 8

    private func cancelCapture() {
        assignTimeout?.cancel()
        state.assigningPlayer = nil
        state.assigningControllerID = nil
    }

    func requestPlayer(_ player: Int) {
        guard state.presentedSheet == .controllers, (1...4).contains(player) else { return }
        leaveMergeForAssignment()
        state.assigningPlayer = player
        startCapture()
    }
    func requestAssignment(controllerID: String) {
        guard state.presentedSheet == .controllers, let c = state.controllers.first(where: { $0.id == controllerID }) else { return }
        leaveMergeForAssignment()
        state.assigningControllerID = controllerID
        state.assigningPlayer = state.assigningPlayer ?? c.player ?? 1
        startCapture()
    }

    /// While a player is being assigned, the next button press is the answer: it goes to the controller it came from and is not
    /// used to navigate. B on the controller that is assigning cancels. Presses from the other controller while one is chosen by
    /// hand are taken and ignored.
    func consumePress(controllerID: String, isBack: Bool) -> Bool {
        guard let player = state.assigningPlayer, state.presentedSheet == .controllers else { return false }
        if let target = state.assigningControllerID, target != controllerID { return true }
        if isBack { cancelCapture(); showToast(t("console.assignCancelled")); return true }
        assignPlayer(controllerID: controllerID, player: player)
        return true
    }

    /// The controller takes the player. Whoever held that player gets the number this controller had (or the next free one), and the
    /// controller's own player lights follow.
    func assignPlayer(controllerID: String, player: Int) {
        guard (1...4).contains(player), let pad = state.controllers.first(where: { $0.id == controllerID }) else { return }
        let old = pad.player
        if let holder = state.controllers.first(where: { $0.player == player && $0.id != controllerID }) { overrides[holder.id] = old ?? 0 }
        overrides[controllerID] = player
        state.assigningPlayer = nil; state.assigningControllerID = nil
        assignTimeout?.cancel()
        for (id, value) in overrides {
            devices[id]?.playerIndex = value == 0 ? .indexUnset : (GCControllerPlayerIndex(rawValue: value - 1) ?? .indexUnset)
        }
        refreshControllers(announce: false)
        showToast(String(format: t("console.assignedTo"), pad.name, player))
    }
    func setPadMerge(_ enabled: Bool) { controls.padMerge = enabled }

    /// What this controller can do for Identify. The player lights have no capability flag in GameController, so any gamepad counts.
    static func identifyActions(_ c: GCController) -> [IdentifyPlan.Action] {
        IdentifyPlan.actions(playerLights: c.extendedGamepad != nil, lightBar: c.light != nil, rumble: c.haptics != nil)
    }

    private static let log = Logger(subsystem: "NX2Apple", category: "console.identify")
    private var identifyEngines: [String: CHHapticEngine] = [:]   // kept alive: an engine that is released stops its pattern
    private var identifyTask: Task<Void, Never>?

    /// Everything the controller has: its player lights step through 1 to 4, the light bar pulses, it rumbles. The assigned player
    /// and the light's colour are restored after.
    func identify(controllerID: String) {
        guard let c = state.controllers.first(where: { $0.id == controllerID }) else { return }
        state.identifyingControllerID = controllerID
        showToast(String(format: t("console.identifyingName"), c.name))
        guard let pad = devices[controllerID] else { return }
        let actions = Self.identifyActions(pad)
        Self.log.debug("identify \(c.name, privacy: .public): \(actions.map { "\($0)" }.joined(separator: ","), privacy: .public)")
        identifyTask?.cancel()
        identifyTask = Task { [weak self] in
            let player = pad.playerIndex
            let color = pad.light?.color
            if actions.contains(.rumble) { self?.rumble(pad, id: controllerID) }
            for step in 0..<8 {
                guard !Task.isCancelled else { break }
                if actions.contains(.playerLights) { pad.playerIndex = GCControllerPlayerIndex(rawValue: step % 4) ?? .indexUnset }
                if actions.contains(.lightBar) { pad.light?.color = step % 2 == 0 ? GCColor(red: 1, green: 0.1, blue: 0.9) : GCColor(red: 0.1, green: 0.9, blue: 1) }
                try? await Task.sleep(nanoseconds: 140_000_000)
            }
            pad.playerIndex = player
            if let color { pad.light?.color = color }
        }
    }

    private func rumble(_ pad: GCController, id: String) {
        guard let haptics = pad.haptics else { Self.log.debug("identify: no haptics on this controller"); return }
        let localities: [GCHapticsLocality] = [.default, .all, .handles, .leftHandle, .rightHandle]
        guard let engine = localities.lazy.compactMap({ haptics.createEngine(withLocality: $0) }).first else {
            Self.log.debug("identify: haptics exist but no engine could be created (supported localities: \(haptics.supportedLocalities.map(\.rawValue).joined(separator: ","), privacy: .public))")
            return
        }
        identifyEngines[id] = engine
        do {
            try engine.start()
            let events = [CHHapticEvent(eventType: .hapticContinuous, parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                                                                                  CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6)],
                                        relativeTime: 0, duration: 0.9)]
            try engine.makePlayer(with: CHHapticPattern(events: events, parameters: [])).start(atTime: CHHapticTimeImmediate)
        } catch { Self.log.debug("identify: rumble failed: \(error.localizedDescription, privacy: .public)") }
    }

    /// macOS offers apps no way to drop a Bluetooth controller, so this says where to do it instead.
    func disconnect(controllerID: String) { showToast(t("console.disconnectHint")) }

    /// Controllers that have no player take the next free one, in the order they are listed, as a console does. A fifth has none.
    static func autoAssigned(_ pads: [ConsolePadSnapshot], remembered: [String: Int] = [:]) -> [ConsolePadSnapshot] {
        var used = Set(pads.compactMap(\.playerIndex))
        return pads.map { pad in
            guard pad.playerIndex == nil else { return pad }
            // the same physical controller coming back takes its old player when that is free, else the next free one
            let free = remembered[Self.memoryKey(pad)].flatMap { used.contains($0) ? nil : $0 } ?? (1...4).first(where: { !used.contains($0) })
            guard let free else { return pad }
            used.insert(free)
            var assigned = pad; assigned.playerIndex = free
            return assigned
        }
    }
    static func memoryKey(_ pad: ConsolePadSnapshot) -> String { pad.name + "|" + (pad.category ?? "") }

    private static let hidLog = Logger(subsystem: "NX2Apple", category: "console.controllers")
    private var presence = HIDPresence()
    private var hidWatcher: HIDControllerWatcher?
    private var remembered: [String: Int] = [:]
    private var pollTask: Task<Void, Never>?

    private func stamp() -> String { String(format: "%.3f", Date().timeIntervalSince1970) }

    /// A controller connected or disconnected: the list is rebuilt and published at once (no debounce, no polling), then the toast.
    /// The notification's own controller is added when GameController's list does not have it yet, and left out when it still has it
    /// on a disconnect, so a wired controller shows up the moment it is plugged in. A disconnect tears down everything kept for that
    /// instance: its input handler, its haptics engine and any Identify in progress.
    func padsChanged(connected: Bool, note: Notification) {
        let pad = note.object as? GCController
        if let pad {
            Self.hidLog.debug("\(connected ? "connect" : "disconnect") \(self.stamp(), privacy: .public): vendor \(pad.vendorName ?? "?", privacy: .public), category \(pad.productCategory, privacy: .public), extendedGamepad \(pad.extendedGamepad != nil), battery \(pad.battery != nil)")
            if !connected { tearDown(pad) }
        }
        let name = pad.map { $0.vendorName ?? $0.productCategory } ?? ""
        controllerListChanged(connectedName: connected ? name : nil, disconnectedName: connected ? nil : name, including: connected ? pad : nil, excluding: connected ? nil : pad)
        guard pad != nil else { return }
        guard connected else { showToast(String(format: t("console.disconnected"), name)); return }
        let id = pad.map { String(UInt(bitPattern: ObjectIdentifier($0).hashValue), radix: 16) } ?? ""
        if let player = state.padMerge ? 1 : state.controllers.first(where: { $0.id == id })?.player {
            showToast(String(format: t("console.connected"), name, player))
        } else { showToast(t("console.noFreePlayer"), glyph: ConsoleGlyphs.current().glyph(for: .controllers)) }
        scheduleBatteryRereads()
    }

    /// The part of a connect or disconnect that does not need a GCController, so tests can drive it.
    func controllerListChanged(connectedName: String?, disconnectedName: String?, including: GCController? = nil, excluding: GCController? = nil) {
        if let connectedName { presence.gcConnected(name: connectedName) }
        if let disconnectedName { presence.gcDisconnected(name: disconnectedName) }
        refreshControllers(announce: false, including: including, excluding: excluding)
    }

    private func tearDown(_ pad: GCController) {
        let id = String(UInt(bitPattern: ObjectIdentifier(pad).hashValue), radix: 16)
        pad.physicalInputProfile.valueDidChangeHandler = nil
        identifyEngines.removeValue(forKey: id)?.stop(completionHandler: nil)
        if state.identifyingControllerID == id { identifyTask?.cancel(); state.identifyingControllerID = nil }
        devices[id] = nil
        overrides[id] = nil
        Self.hidLog.debug("torn down \(id, privacy: .public)")
    }

    /// Right after a connect GameController may still report 0 or an unknown battery (a Bluetooth reconnect): read it again soon.
    private func scheduleBatteryRereads() {
        Task { [weak self] in
            for seconds in [2.0, 5.0] {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                self?.refreshControllers(announce: false)
            }
        }
    }

    // MARK: Hardware (IOKit registry) events

    func hidEvent(_ event: HIDControllerWatcher.Event) {
        Self.hidLog.debug("hid \(event.kind == .attach ? "attach" : "detach", privacy: .public) \(event.name, privacy: .public) at \(self.stamp(), privacy: .public)")
        switch event.kind {
        case .attach:
            // GameController already lists it (a controller there at launch): no placeholder
            if state.controllers.contains(where: { !$0.connecting && HIDPresence.matches($0.name, event.name) }) {
                Self.hidLog.debug("hid attach \(event.name, privacy: .public): already listed by GameController")
            } else { presence.attached(id: event.id, name: event.name); watchForGameController() }
        case .detach: presence.detached(id: event.id, name: event.name)
        }
        refreshControllers(announce: false)
    }

    /// GameController can lag the hardware by seconds, and has been seen missing a re-plug: after a plug-in, look at its list every half
    /// second for ten seconds, and drop the placeholder when the time is up.
    private func watchForGameController() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            for _ in 0..<21 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { return }
                self.refreshControllers(announce: false)
                if self.presence.pending.isEmpty { return }
            }
        }
    }

    func refreshControllers(announce: Bool, including: GCController? = nil, excluding: GCController? = nil) {
        let before = Set(state.controllers.filter { !$0.connecting }.map(\.id))
        var snapshots = pads()
        if devicePads {
            devices = [:]
            var all = GCController.controllers().filter { $0 !== excluding }
            if let including, !all.contains(where: { $0 === including }) { all.append(including) }
            snapshots = all.compactMap { c in   // every controller, whatever its vendor or profile, read fresh from its own instance
                let id = String(UInt(bitPattern: ObjectIdentifier(c).hashValue), radix: 16)
                devices[id] = c
                let reading = c.battery.map { b -> (level: Double?, charging: Bool) in
                    let state: PadBatteryState = b.batteryState == .charging ? .charging : b.batteryState == .full ? .full : b.batteryState == .discharging ? .discharging : .unknown
                    return ConsolePadSnapshot.batteryReading(level: Double(b.batteryLevel), state: state)
                }
                let index = c.playerIndex.rawValue
                return ConsolePadSnapshot(id: id, name: c.vendorName ?? c.productCategory, category: c.productCategory,
                                          playerIndex: (0...3).contains(index) ? index + 1 : nil, battery: reading?.level,
                                          charging: reading?.charging ?? false, canIdentify: !Self.identifyActions(c).isEmpty, hasBattery: c.battery != nil)
            }
        }
        presence.expire()
        snapshots = snapshots.filter { !presence.isHidden($0.name) }   // unplugged according to the hardware, GameController not told yet
        let live = Set(snapshots.map(\.id))
        overrides = overrides.filter { live.contains($0.key) }
        snapshots = snapshots.map { snap in
            guard let chosen = overrides[snap.id] else { return snap }
            var s = snap; s.playerIndex = chosen == 0 ? nil : chosen
            return s
        }
        let assigned = Self.autoAssigned(snapshots, remembered: remembered)
        for (old, new) in zip(snapshots, assigned) where old.playerIndex != new.playerIndex {
            devices[new.id]?.playerIndex = GCControllerPlayerIndex(rawValue: (new.playerIndex ?? 1) - 1) ?? .indexUnset
        }
        for pad in assigned { if let p = pad.playerIndex { remembered[Self.memoryKey(pad)] = p } }
        // a controller GameController reports that the hardware watch has a placeholder for replaces it (also without a notification)
        for pad in assigned where !before.contains(pad.id) { presence.gcConnected(name: pad.name, orOldest: false) }
        var list = assigned.map(\.controller)
        for p in presence.pending { list.append(ConsoleController(id: "hid." + String(p.id), name: p.name.isEmpty ? t("console.connecting") : p.name, player: nil, kind: .gamepad, canIdentify: false, connecting: true)) }
        if list != state.controllers {
            Self.hidLog.debug("publish \(list.count) controllers at \(self.stamp(), privacy: .public): \(list.map { "\($0.name)\($0.connecting ? " (connecting)" : "")" }.joined(separator: ", "), privacy: .public)")
            state.controllers = list
        }
    }

    // MARK: Navigation

    func dismissToast() { toastTask?.cancel(); state.toast = nil; state.identifyingControllerID = nil }
    func back() { state.back() }
    func exitToDesktop() { state.exitToDesktop() }
    func returnFromGame() { state.returnFromGame() }

    private func showToast(_ message: String, glyph: ConsoleGlyphs.Glyph? = nil) {
        toastTask?.cancel()
        state.toast = ConsoleToast(glyph: glyph, message: message)
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.state.toast = nil
            self?.state.identifyingControllerID = nil
        }
    }
}
