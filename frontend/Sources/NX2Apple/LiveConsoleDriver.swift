import SwiftUI
import Combine
import AppKit
import GameController
import CoreHaptics
import os
import NXCore
import NXLauncher
import NXModel

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
    var kindOverride: ConsoleController.Kind? = nil

    /// The level to show, or nil when the controller has not really reported one. GameController gives 0 with an unknown state for a
    /// DualShock 4 over Bluetooth and before the first report, and some pads over USB report no battery or an unknown one: those are
    /// never guessed (no number, outline only). Charging is a real state and shows the bolt, full is a level and does not.
    static func batteryReading(level: Double, state: PadBatteryState) -> (level: Double?, charging: Bool) {
        switch state {
        case .unknown: return (nil, false)
        case .charging: return (level.isFinite ? min(max(level, 0), 1) : nil, true)   // the real level, with the bolt
        case .full: return (1, false)   // full says nothing about a cable (#1033): the full battery, no bolt
        case .discharging: return (level.isFinite ? min(max(level, 0), 1) : nil, false)
        }
    }

    var controller: ConsoleController {
        let family = ConsoleGlyphs.Family(category: category)
        let c = (category ?? "").lowercased().replacingOccurrences(of: "-", with: "")
        let kind: ConsoleController.Kind
        if let kindOverride { kind = kindOverride }
        else if c.contains("joycon") { kind = .paired }
        else if family == .nintendo { kind = .fullSize }
        else if family == .xbox { kind = .xbox }
        else { kind = .gamepad }
        return ConsoleController(id: id, name: name, player: playerIndex, kind: kind, battery: battery, charging: charging, canIdentify: canIdentify)
    }
}

/// The console mode over the launcher's real data. It reuses what the desktop launcher uses and keeps no second copy of anything:
/// the games and their status come from `GameLibrary`, covers from `GameLibrary.artwork`, launch options from `SavedChoices` and the
/// library (as LaunchOptionsView reads and writes them), Play from `GameStart.environment`, the player-mode setting from
/// `ControlLayout`, and the controllers from GameController.
@MainActor final class LiveConsoleDriver: ConsoleDriver {
    @Published var state = ConsoleState()

    let library: GameLibrary
    /// The Controls page's layout: the player mode, the Joy-Con split and the button mapping (LiveConsoleDriver+Mapping.swift).
    let controls: ControlLayout
    let repo: () -> String
    let lang: () -> Lang
    private let labels: (String) -> String
    private let saves: (String) -> (global: SaveGlobalSettings, game: SaveGameOverride)?   // the save settings (SaveSettingsStore)
    private let sticks: () -> StickDeadzoneSettings?   // StickDeadzoneStore
    private let player: () -> PlayerProfile?   // whose saves the game plays with (PlayerProfileStore)
    private let pads: () -> [ConsolePadSnapshot]
    private let steamPads: () -> [ConsolePadSnapshot]
    private let launch: (LibraryGame, [String: String], @escaping (Int32?, Error?) -> Void) -> Void
    private let artwork: (LibraryGame, String) -> NSImage?
    private let startingTimeout: TimeInterval
    var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var refreshQueued = false
    private var covers: [UUID: (path: String, image: NSImage?)] = [:]
    private var launchedPID: Int32?
    /// The check of the cloud's save before a start, and the game it is for (LiveConsoleDriver+CloudSave.swift). Tests give it a fake download.
    var cloudGate = CloudSaveGate() { didSet { watchCloudGate() } }
    var cloudGameID: String?
    var cloudWatch: AnyCancellable?
    var timeoutTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var notices = ConsoleNoticeQueue()
    private var clock: Timer?
    /// Real controllers by id, for Identify and player assignment.
    var devices: [String: GCController] = [:]
    /// #816 and #952 (LiveConsoleDriver+Sessions.swift): the play history, the game running now (paused, stopped, quit before another)
    /// and the games built with older tools than the engine has.
    let sessions: PlaySessionStore
    let tracking = ConsoleGameTracking()
    let toolsAge = ToolsAge()

    init(library: GameLibrary, controls: ControlLayout, repo: @escaping () -> String, lang: @escaping () -> Lang, labels: @escaping (String) -> String,
         pads: (() -> [ConsolePadSnapshot])? = nil, steamPads: (() -> [ConsolePadSnapshot])? = nil,
         launch: ((LibraryGame, [String: String], @escaping (Int32?, Error?) -> Void) -> Void)? = nil,
         artwork: ((LibraryGame, String) -> NSImage?)? = nil, startingTimeout: TimeInterval = 20, observeSystem: Bool = true, playerOutput: ((String, Int) -> Void)? = nil,
         player: @escaping () -> PlayerProfile? = { nil },
         saves: @escaping (String) -> (global: SaveGlobalSettings, game: SaveGameOverride)? = { _ in nil },
         sticks: @escaping () -> StickDeadzoneSettings? = { nil }) {
        sessions = PlaySessionStore(file: observeSystem ? PlaySessionStore.defaultFile : nil)   // a test keeps its history in memory
        tracking.observesSystem = observeSystem
        self.saves = saves
        self.sticks = sticks
        self.sendPlayerOutput = playerOutput
        self.player = player
        self.library = library; self.controls = controls; self.repo = repo; self.lang = lang; self.labels = labels
        self.startingTimeout = startingTimeout
        self.pads = pads ?? { [] }
        self.steamPads = steamPads ?? { pads == nil ? SteamLinkGamepads.shared.snapshots : [] }
        self.launch = launch ?? Self.openApplication
        self.artwork = artwork ?? { [banners = library.artworkDirectory] game, repo in
            GameLibrary.artwork(for: game, slot: .thumbnail, repo: repo, banners: banners, maxPixel: Self.tilePixels)
        }
        if pads == nil { self.devicePads = true }
        state.padMerge = controls.padMerge
        state.joyconSplit = controls.joyconSplit
        library.objectWillChange.sink { [weak self] _ in self?.queueRefresh() }.store(in: &cancellables)
        controls.$padMerge.sink { [weak self] merged in self?.state.padMerge = merged }.store(in: &cancellables)
        // A @Published sink runs before the value is stored: the layout is read on the next turn of the run loop.
        controls.$pad.combineLatest(controls.$padMode).dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshPadLayout() } }.store(in: &cancellables)
        controls.$joyconSplit.dropFirst().sink { [weak self] split in
            guard let self, self.state.joyconSplit != split else { return }
            self.state.joyconSplit = split
            self.resetPairedDevicePlayerIndices()
            self.refreshControllers(announce: false)
        }.store(in: &cancellables)
        watchCloudGate()
        watchTools()
        refresh()
        refreshControllers(announce: false)
        refreshPadLayout()
        announced = Set(state.controllers.map(\.id))   // controllers there at launch are not announced again by a repeated notification
        if observeSystem { scheduleBatteryRereads() }   // a controller there at launch may not have its battery yet either
        guard observeSystem else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .steamLinkPadsChanged, object: SteamLinkGamepads.shared, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshControllers(announce: false) }
            },
            center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.padsChanged(connected: true, note: note) }
            },
            center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.padsChanged(connected: false, note: note) }
            },
        ]
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.gameWindowAppeared() }
        })
        clock = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.state.time = Date(); self?.refreshControllers(announce: false) } }   // the battery has no change callback: it is read again each tick
    }
    private var devicePads = false
    /// Runs before the game is opened and calls its argument when the launch may go on (the window leaves full screen first,
    /// see ConsoleCoordinator). `gameEnded` runs when the game quit or did not start.
    var prepareLaunch: (@escaping () -> Void) -> Void = { $0() }
    var gameEnded: () -> Void = {}
    /// Whether the console has the pointer hidden right now (ConsolePointer.swift).
    var pointerHidden: () -> Bool = { false }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        clock?.invalidate()
        primeTask?.cancel()
        batteryRereadTask?.cancel()
    }

    // MARK: Games

    func t(_ key: String) -> String { L10n.string(key, lang()) }

    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in self?.refreshQueued = false; self?.refresh() }
    }

    /// The library as console games, the ones ready on this Mac first, keeping the focus and each game's shown values.
    func refresh() {
        let focus = state.focusedGameID
        let heroes = Dictionary(state.games.compactMap { g in g.hero.map { (g.id, ($0, g.heroFocus)) } }) { a, _ in a }   // kept across a refresh: no flash
        let shown = LibraryFilter.load() == .built ? library.games.filter(LibraryFilter.built.includes) : library.games   // the desktop's filter
        let games = ConsoleGame.readyFirst(shown.map { var g = consoleGame($0); (g.hero, g.heroFocus) = heroes[g.id].map { ($0.0, $0.1) } ?? (nil, .center); return g })
        state.games = games
        refreshPages(shown)   // all games' order, the search's results (LiveConsoleDriver+Pages.swift)
        state.focusedGameID = games.contains { $0.id == focus } ? focus : (library.selected.map { $0.id.uuidString }.flatMap { id in games.contains { $0.id == id } ? id : nil } ?? games.first?.id)
        state.time = Date(); loadHero()
        reloadOpenDetails()   // the open options page keeps its mods, cheats, save and Reset
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
        return withHistory(of: game, ConsoleGame(id: game.id.uuidString, title: game.displayName(lang()), version: version(of: game),
                           platforms: Self.platforms(of: game), artwork: cover(game), artworkFocus: game.artwork.focus(for: .thumbnail),
                           status: Self.status(of: game, brokenMessage: t("console.broken")), settings: settings, values: values,
                           mapsButtons: game.isReady && SavedChoices.appReadsControllerMappings(app: game.appPath)
                               && game.controllerSavingEnabled(environment: game.launchOptions)))
    }

    /// The library's game behind a console game (LiveConsoleDriver+Mapping.swift reads its own button mapping).
    func libraryGame(_ id: String) -> LibraryGame? { library.games.first { $0.id.uuidString == id } }

    var versions: [String: String] = [:]   // LiveConsoleDriver+Version.swift

    /// Covers through the launcher's own lookup, decoded once per image path.
    private func cover(_ game: LibraryGame) -> NSImage? {
        let key = "\(game.artwork)|\(game.artworkPath)|" + game.titleID + "|" + game.name
        if let cached = covers[game.id], cached.path == key { return cached.image }
        let image = artwork(game, repo())
        covers[game.id] = (key, image)
        return image
    }

    /// Covers downloaded after the first draw (ArtworkStore) show up when the console asks again.
    func reloadCovers() { covers = [:]; for i in state.games.indices { state.games[i].hero = nil }; refresh() }

    func focus(_ gameID: String) { state.focus(gameID); loadHero() }

    func play(_ gameID: String) {
        if state.pausedGameID == gameID { resume(gameID); return }   // the paused game plays on where it was (#952)
        state.play(gameID)
        guard state.startingGameID == gameID, let game = library.games.first(where: { $0.id.uuidString == gameID }) else { return }
        let environment = GameStart.environment(for: game, library: library, controls: controls, repo: repo(), labels: labels, lang: lang(), fullscreen: true, player: player(), saves: saves(game.titleID), sticks: sticks(), homeMenu: true)   // the Home menu's way back here (#952)
            .merging(pointerHidden() ? ["DM_CURSOR_HIDDEN": "1"] : [:]) { $1 }   // the game is a new process: without this its pointer shows until its own idle wait ends
            .merging(FrameTimes.recordingEnvironment(for: game, library: library.folder)) { $1 }   // a frame-time recording, as the desktop Play adds (FrameTimes.swift)
        state.starting = .preparing
        cloudGameID = gameID
        cloudGate.begin(game, proceed: { [weak self] choice in   // the cloud's save first (LiveConsoleDriver+CloudSave.swift, #957)
            guard let self, self.state.startingGameID == gameID else { return }
            self.state.starting = .preparing
            self.prepareLaunch { [weak self] in
                guard let self else { return }
                guard self.state.startingGameID == gameID else { self.gameEnded(); return }
                self.openGame(game, environment: environment.merging(choice) { $1 }, gameID: gameID)
            }
        }, ended: { [weak self] in self?.state.returnFromGame() })
    }

    private func openGame(_ game: LibraryGame, environment: [String: String], gameID: String) {
        launch(game, environment) { [weak self] pid, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.state.startingGameID == gameID else { return }
                    if let error { self.state.returnFromGame(); self.gameEnded(); self.showToast(error.localizedDescription, kind: "error"); return }
                    self.launchedPID = pid
                    self.library.recordPlayed(game.id)   // the Recently played order (#937)
                    if let pid { self.beginTracking(game, pid: pid, environment: environment) }   // the session, its pause and its end (+Sessions)
                    self.launchedGame = game
                    if let pid { GameReturnWatcher.shared.didStart(pid: pid) { [weak self] in self?.gameDidTerminate(pid: pid) } }   // the launcher's one watcher and its switch (ReturnAfterPlay.swift)
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

    /// The app to hand the front to instead of letting LaunchServices activate the game: an app LaunchServices activates shows the pointer for up to
    /// 150 ms whatever it hid before, one that takes a yielded activation itself keeps it hidden (issue #380). Only with the pointer hidden
    /// (DM_CURSOR_HIDDEN), as the game hides it before it activates itself then.
    static func yieldTarget(environment: [String: String], appPath: String) -> String? {
        guard environment["DM_CURSOR_HIDDEN"] == "1" else { return nil }
        return Bundle(url: URL(fileURLWithPath: appPath))?.bundleIdentifier
    }

    private static func openApplication(_ game: LibraryGame, _ environment: [String: String], _ done: @escaping (Int32?, Error?) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        if !environment.isEmpty { configuration.environment = environment }
        if #available(macOS 14, *), let target = yieldTarget(environment: environment, appPath: game.appPath) {
            configuration.activates = false
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: target)
        }
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

    /// The game this console started quit (GameReturnWatcher, which then brings the launcher forward when Settings > App
    /// leaves that on, as for the desktop Play): Starting ends, the selected game is kept.
    func gameDidTerminate(pid: Int32) {
        guard pid == launchedPID else { return }
        launchedPID = nil
        timeoutTask?.cancel()
        let game = launchedGame
        launchedGame = nil
        gameSessionEnded(game)   // the history, a crash, what waited for a paused game (+Sessions), then the Home button hint
    }

    // MARK: Home button (#336)

    var launchedGame: LibraryGame?
    /// The Home button setting the game's last session wrote to its log (HomeButtonHint), the switch "already shown", whether this
    /// is macOS 27 and the way to the setting. Tests replace them.
    var homeButtonReported: (LibraryGame) -> String? = { HomeButtonSettings.reported(by: $0) }
    var homeHintDefaults: UserDefaults = .standard
    var isMacOS27 = HomeButtonSettings.available
    var openHomeSettings: () -> Void = { HomeButtonSettings.open() }

    /// After a game quit: the hint, once, when that game found that the system keeps the Home button for itself.
    func offerHomeButtonHint(after game: LibraryGame) {
        let shown = homeHintDefaults.bool(forKey: HomeButtonHint.shownKey)
        guard HomeButtonHint.shouldShow(setting: homeButtonReported(game), shown: shown, macOS27: isMacOS27) else { return }
        homeHintDefaults.set(true, forKey: HomeButtonHint.shownKey)
        state.showHomeButtonHint()
    }

    func openHomeButtonSettings() {
        state.back()
        openHomeSettings()
    }

    // MARK: Options


    func setOption(gameID: String, setting env: String, value: String) {
        state.setOption(game: gameID, setting: env, value: value)
        guard let game = library.games.first(where: { $0.id.uuidString == gameID }),
              let shown = state.games.first(where: { $0.id == gameID }), let s = shown.settings.first(where: { $0.env == env }),
              let stored = shown.values[env] else { return }
        if s.storeBacked { SavedChoices(app: game.appPath, titleID: game.titleID).set(s, stored) } else { library.setLaunchOption(s, stored, for: game.id) }
        // Reset to defaults shows once something differs. Only that is read again here: the rest of the details (the cloud save's
        // state reads the whole game log) stays as the options page loaded it, so a slider moves without waiting on the disk.
        if let updated = library.games.first(where: { $0.id == game.id }), let i = state.games.firstIndex(where: { $0.id == gameID }) {
            state.games[i].canReset = !updated.launchOptions.isEmpty
                || SavedChoices(app: updated.appPath, titleID: updated.titleID).hasChoices(state.games[i].settings)
        }
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
        showToast(t("console.mergeOff"), kind: "controller")
    }

    /// The next press from any controller is taken as the answer, for 8 seconds.
    private func startCapture() {
        assignTimeout?.cancel()
        assignTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.captureSeconds ?? 8) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.state.assigningPlayer != nil else { return }
            self.cancelCapture()
            self.showToast(self.t("console.assignTimeout"), kind: "controller")
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
        let resolvedID: String
        if let target = state.assigningControllerID {
            guard target == controllerID || Self.baseControllerID(target) == controllerID else { return true }
            resolvedID = target
        } else if state.controllers.contains(where: { $0.id == controllerID }) {
            resolvedID = controllerID
        } else if let split = state.controllers.first(where: { Self.baseControllerID($0.id) == controllerID }) {
            resolvedID = split.id
        } else {
            resolvedID = controllerID
        }
        if isBack { cancelCapture(); showToast(t("console.assignCancelled"), kind: "controller"); return true }
        assignPlayer(controllerID: resolvedID, player: player)
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
        for (id, value) in overrides where !id.hasSuffix(".R") {
            devices[id]?.playerIndex = value == 0 ? .indexUnset : (GCControllerPlayerIndex(rawValue: value - 1) ?? .indexUnset)
        }
        refreshControllers(announce: false)
        showToast(String(format: t("console.assignedTo"), pad.name, player), kind: "controller")
    }
    func setPadMerge(_ enabled: Bool) { controls.padMerge = enabled }
    func setJoyconSplit(_ enabled: Bool) {
        controls.joyconSplit = enabled
        state.joyconSplit = enabled
        resetPairedDevicePlayerIndices()
        refreshControllers(announce: false)
    }

    /// Clears hardware playerIndex on paired Joy-Con `GCController` instances when toggling split mode so auto-assignment starts cleanly from P1/P2.
    private func resetPairedDevicePlayerIndices() {
        guard devicePads else { return }
        for c in GCController.controllers() {
            let cat = c.productCategory.lowercased().replacingOccurrences(of: "-", with: "")
            if cat.contains("joycon") { c.playerIndex = .indexUnset }
        }
    }

    static func baseControllerID(_ id: String) -> String {
        (id.hasSuffix(".L") || id.hasSuffix(".R")) ? String(id.dropLast(2)) : id
    }

    /// Expands each paired Joy-Con snapshot into separate `Joy-Con (L)` and `Joy-Con (R)` sideways controller snapshots when `enabled` is true (#740).
    static func splitJoyConSnapshots(_ pads: [ConsolePadSnapshot], enabled: Bool) -> [ConsolePadSnapshot] {
        guard enabled else { return pads }
        var out: [ConsolePadSnapshot] = []
        for pad in pads {
            if pad.controller.kind == .paired {
                out.append(ConsolePadSnapshot(id: pad.id + ".L", name: "Joy-Con (L)", category: "Nintendo Switch Joy-Con (L)",
                                              playerIndex: pad.playerIndex, battery: pad.battery, charging: pad.charging, canIdentify: pad.canIdentify, kindOverride: .gamepad))
                out.append(ConsolePadSnapshot(id: pad.id + ".R", name: "Joy-Con (R)", category: "Nintendo Switch Joy-Con (R)",
                                              playerIndex: nil, battery: pad.battery, charging: pad.charging, canIdentify: pad.canIdentify, kindOverride: .gamepad))
            } else {
                out.append(pad)
            }
        }
        return out
    }

    /// What this controller can do for Identify. The player lights have no capability flag in GameController, so any gamepad counts.
    static func identifyActions(_ c: GCController) -> [IdentifyPlan.Action] {
        IdentifyPlan.actions(playerLights: c.extendedGamepad != nil, lightBar: c.light != nil, rumble: c.haptics != nil)
    }

    static let log = Logger(subsystem: "NX2Apple", category: "console.identify")
    var identifyEngines: [String: CHHapticEngine] = [:]   // kept alive: an engine that is released stops its pattern
    var identifyTask: Task<Void, Never>?
    var identifyPlayers: [String: CHHapticPatternPlayer] = [:]   // the running pattern of each controller, stopped by hand
    var rumbleStops: [String: Task<Void, Never>] = [:]
    var identifyRunning: String?   // the controller whose Identify is going: a second press only shows the toast again, so the player and the light it restores are the real ones
    static let rumbleSeconds = 0.9

    /// macOS offers apps no way to drop a Bluetooth controller, so this says where to do it instead.
    func disconnect(controllerID: String) { showToast(t("console.disconnectHint"), kind: "controller") }

    /// The launcher's app updates and builds, for the General page's update row, which waits while a build runs (LiveConsoleDriver+Desktop). Set by the session.
    weak var appUpdates: AppUpdateStore?
    weak var builds: BuildStore?

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
    private var remembered: [String: Int] = [:]
    /// The player each controller was last told about (player lights and light bar), so the output is sent once per assignment.
    private var primedPlayer: [String: Int] = [:]
    private var primeTask: Task<Void, Never>?
    private var batteryRereadTask: Task<Void, Never>?
    /// Writes the player to a controller: its player lights and, when it has one, its light bar. Tests replace it.
    var sendPlayerOutput: ((String, Int) -> Void)?

    /// A calm colour per player for the light bar: blue, red, green, amber.
    static func playerLightColor(_ player: Int) -> (red: Float, green: Float, blue: Float) {
        switch player {
        case 1: return (0.25, 0.55, 1.0)
        case 2: return (1.0, 0.35, 0.35)
        case 3: return (0.3, 0.85, 0.5)
        default: return (1.0, 0.75, 0.3)
        }
    }

    /// A DualShock 4 over Bluetooth (and the pads that copy it) only sends the report that carries its battery after the host has
    /// sent it an output report, so every connected controller is sent one harmless one: its player. It also shows the player on the
    /// controller. The battery is read again shortly after (and the key-value observer catches it). No rumble.
    private func primeOutputs(_ pads: [ConsolePadSnapshot]) {
        primedPlayer = primedPlayer.filter { key, _ in pads.contains { $0.id == key } }
        var sent = false
        for pad in pads {
            guard let player = pad.playerIndex, primedPlayer[pad.id] != player else { continue }
            primedPlayer[pad.id] = player
            if let sendPlayerOutput {
                if !pad.id.hasSuffix(".R") { sent = true; sendPlayerOutput(pad.id, player) }
                continue
            }
            // A split Joy-Con pair shares one underlying GCController instance between `.L` and `.R`. Writing `.R`'s playerIndex back to
            // that shared instance overwrites `.L`'s hardware playerIndex and causes P1/P2 to ping-pong on every reread (#740).
            guard let device = devices[pad.id], !pad.id.hasSuffix(".R") else { continue }
            sent = true
            device.playerIndex = GCControllerPlayerIndex(rawValue: player - 1) ?? .indexUnset
            if let light = device.light {
                let c = Self.playerLightColor(player)
                light.color = GCColor(red: c.red, green: c.green, blue: c.blue)
            }
            Self.hidLog.debug("player output to \(pad.name, privacy: .public): player \(player), light bar \(device.light != nil)")
        }
        if sent {
            primeTask?.cancel()
            primeTask = Task { [weak self] in
                for seconds in [0.5, 1.5] {
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self?.refreshControllers(announce: false)
                }
            }
        }
    }

    private var batteryWatchers: [String: (object: ObjectIdentifier, watcher: KeyValueWatcher)] = [:]

    /// A battery's level and state are key-value observable: a change refreshes the list at once instead of waiting for the next read.
    func watchBattery(id: String, object: NSObject) {
        if batteryWatchers[id]?.object == ObjectIdentifier(object) { return }
        let watcher = KeyValueWatcher(object: object, keys: ["batteryLevel", "batteryState"]) { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refreshControllers(announce: false) } }
        }
        batteryWatchers[id] = (ObjectIdentifier(object), watcher)
    }

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
        guard let pad else { controllerListChanged(connectedName: nil, disconnectedName: nil); return }
        let id = String(UInt(bitPattern: ObjectIdentifier(pad).hashValue), radix: 16)
        handleConnection(id: id, name: pad.vendorName ?? pad.productCategory, connected: connected, including: connected ? pad : nil, excluding: connected ? nil : pad)
    }

    private var announced = Set<String>()

    /// One connect or disconnect of one controller instance. GameController posts the notification two or three times for a single
    /// connect (and twice for a disconnect), so the list is rebuilt every time (harmless, it is keyed by instance) but the toast, the
    /// battery re-reads and the rest only happen on the first. Returns whether this was the first.
    @discardableResult
    func handleConnection(id: String, name: String, connected: Bool, including: GCController? = nil, excluding: GCController? = nil) -> Bool {
        let first = connected ? announced.insert(id).inserted : announced.remove(id) != nil
        controllerListChanged(connectedName: connected ? name : nil, disconnectedName: connected ? nil : name, including: including, excluding: excluding)
        guard first else { Self.hidLog.debug("repeated \(connected ? "connect" : "disconnect") for \(id, privacy: .public) ignored"); return false }
        guard connected else { showToast(String(format: t("console.disconnected"), name), kind: "controller"); return true }
        if let player = state.padMerge ? 1 : state.controllers.first(where: { $0.id == id })?.player {
            showToast(String(format: t("console.connected"), name, player), kind: "controller")
        } else { showToast(t("console.noFreePlayer"), glyph: ConsoleGlyphs.current().glyph(for: .menu), kind: "controller") }
        scheduleBatteryRereads()
        return true
    }

    /// The part of a connect or disconnect that does not need a GCController, so tests can drive it.
    func controllerListChanged(connectedName: String?, disconnectedName: String?, including: GCController? = nil, excluding: GCController? = nil) {
        refreshControllers(announce: false, including: including, excluding: excluding)
    }

    private func tearDown(_ pad: GCController) {
        let id = String(UInt(bitPattern: ObjectIdentifier(pad).hashValue), radix: 16)
        pad.physicalInputProfile.valueDidChangeHandler = nil
        for key in [id, id + ".L", id + ".R"] {
            stopRumble(key)
            identifyEngines.removeValue(forKey: key)
            if identifyRunning == key { identifyRunning = nil }
            if state.identifyingControllerID == key { identifyTask?.cancel(); state.identifyingControllerID = nil }
            devices[key] = nil
            overrides[key] = nil
            primedPlayer[key] = nil
        }
        batteryWatchers[id] = nil
        Self.hidLog.debug("torn down \(id, privacy: .public)")
    }

    /// Right after a connect GameController may still report 0 or an unknown battery (a Bluetooth reconnect): read it again soon.
    private func scheduleBatteryRereads() {
        batteryRereadTask?.cancel()
        batteryRereadTask = Task { [weak self] in
            for seconds in [2.0, 3.0] {   // reads at 2 and 5 seconds after a connect, then the 20 second tick
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.refreshControllers(announce: false)
            }
        }
    }

    func refreshControllers(announce: Bool, including: GCController? = nil, excluding: GCController? = nil) {
        var snapshots = pads()
        if devicePads {
            devices = [:]
            var all = GCController.controllers().filter { $0 !== excluding }
            if let including, !all.contains(where: { $0 === including }) { all.append(including) }
            snapshots = all.compactMap { c in   // every controller, whatever its vendor or profile, read fresh from its own instance
                let id = String(UInt(bitPattern: ObjectIdentifier(c).hashValue), radix: 16)
                devices[id] = c
                if let battery = c.battery { watchBattery(id: id, object: battery) }
                let reading = c.battery.map { b -> (level: Double?, charging: Bool) in
                    let state: PadBatteryState = b.batteryState == .charging ? .charging : b.batteryState == .full ? .full : b.batteryState == .discharging ? .discharging : .unknown
                    return ConsolePadSnapshot.batteryReading(level: Double(b.batteryLevel), state: state)
                }
                let index = c.playerIndex.rawValue
                Self.hidLog.debug("battery read \(id, privacy: .public) \(c.vendorName ?? c.productCategory, privacy: .public): object \(c.battery != nil), level \(c.battery.map { Double($0.batteryLevel) } ?? -1), state \(c.battery.map { "\($0.batteryState.rawValue)" } ?? "none", privacy: .public)")
                return ConsolePadSnapshot(id: id, name: c.vendorName ?? c.productCategory, category: c.productCategory,
                                          playerIndex: (0...3).contains(index) ? index + 1 : nil, battery: reading?.level,
                                          charging: reading?.charging ?? false, canIdentify: !Self.identifyActions(c).isEmpty)
            }
        }
        snapshots += steamPads()
        snapshots = Self.splitJoyConSnapshots(snapshots, enabled: controls.joyconSplit)
        if devicePads, controls.joyconSplit {
            for snap in snapshots where snap.id.hasSuffix(".L") || snap.id.hasSuffix(".R") {
                let base = Self.baseControllerID(snap.id)
                if let dev = devices[base] { devices[snap.id] = dev }
            }
        }
        let live = Set(snapshots.map(\.id))
        let liveBase = Set(snapshots.map { Self.baseControllerID($0.id) })
        batteryWatchers = batteryWatchers.filter { liveBase.contains($0.key) || !devicePads }
        overrides = overrides.filter { live.contains($0.key) }
        snapshots = snapshots.map { snap in
            guard let chosen = overrides[snap.id] else { return snap }
            var s = snap; s.playerIndex = chosen == 0 ? nil : chosen
            return s
        }
        let assigned = Self.autoAssigned(snapshots, remembered: remembered)
        for (old, new) in zip(snapshots, assigned) where old.playerIndex != new.playerIndex && !new.id.hasSuffix(".R") {
            devices[new.id]?.playerIndex = GCControllerPlayerIndex(rawValue: (new.playerIndex ?? 1) - 1) ?? .indexUnset
        }
        for pad in assigned { if let p = pad.playerIndex { remembered[Self.memoryKey(pad)] = p } }
        primeOutputs(assigned)
        let list = assigned.map(\.controller)
        if list != state.controllers {
            Self.hidLog.debug("publish \(list.count) controllers at \(self.stamp(), privacy: .public): \(list.map { "\($0.name)" }.joined(separator: ", "), privacy: .public)")
            state.controllers = list
        }
        if controls.padMode == .auto { refreshPadLayout() }   // Auto's buttons follow the controller connected now
    }

    // MARK: Navigation

    func dismissToast() { toastTask?.cancel(); notices.clear(); state.toast = nil; state.identifyingControllerID = nil }
    func exitToDesktop() { if state.pausedGameID != nil { state.askQuitPaused(then: .leave(selecting: nil)) } else { state.exitToDesktop() } }
    func returnFromGame() { state.returnFromGame() }

    /// A passing message goes through the one queue (ConsoleNotices.swift): one at a time, same kinds replace each other, none while a game starts.
    /// The top bar's activity chip follows the build store: the operation line and the current stage's share (ConsoleActivity).
    func bindActivity(_ build: BuildStore) {
        let update: () -> Void = { [weak self, weak build] in
            guard let self, let build else { return }
            guard build.running else { self.state.activity = nil; return }
            let title = build.operationTitle ?? build.t("library.preparing")
            let share = build.stages.last { $0.state == .running }?.percent.map { min(max($0 / 100, 0), 1) }
            self.state.activity = ConsoleActivity(title: title, stageProgress: share,
                                                  spokenProgress: share.map { String(format: build.t("console.stageProgress"), Int($0 * 100)) } ?? "")
        }
        build.$running.sink { _ in DispatchQueue.main.async(execute: update) }.store(in: &cancellables)
        build.$operation.sink { _ in DispatchQueue.main.async(execute: update) }.store(in: &cancellables)
        build.$stages.sink { _ in DispatchQueue.main.async(execute: update) }.store(in: &cancellables)
        update()
    }

    func showToast(_ message: String, glyph: ConsoleGlyphs.Glyph? = nil, kind: String = "general") {
        notices.post(kind: kind, message: message, glyph: glyph, now: Date(), suppressed: state.startingGame != nil)
        publishNotices()
    }

    private func publishNotices() {
        notices.advance(now: Date(), suppressed: state.startingGame != nil)
        let shown = notices.current
        if state.toast?.id != shown?.id {
            state.toast = shown.map { ConsoleToast(id: $0.id, glyph: $0.glyph, message: $0.message) }
        }
        if shown == nil { state.identifyingControllerID = nil }
        toastTask?.cancel()
        guard let until = notices.until else { return }
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.05, until.timeIntervalSinceNow) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.publishNotices()
        }
    }
}
