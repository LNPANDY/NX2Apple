import SwiftUI
import NXCore
import NXLauncher

@MainActor final class MockConsoleDriver: ConsoleDriver {
    /// The supported games' covers, by decoded size: set by a capture or a test (MockConsoleDriver+Pages.swift).
    var supportedCoverSource: ((Int) -> SupportedCovers)?
    enum Scenario: String, CaseIterable { case full, few, empty, controllers, controllersMixed, starting, paused }
    @Published var state: ConsoleState
    private var toastTask: Task<Void, Never>?
    private var startingTask: Task<Void, Never>?
    private var lang: Lang = .initial()
    private var animated = true

    init(state: ConsoleState, lang: Lang = .initial(), animated: Bool = true) { self.state = state; self.lang = lang; self.animated = animated }
    /// `artworkRepo`: a repository checkout whose docs/images supply covers, found the way the desktop launcher finds a game's
    /// artwork (`GameLibrary.artwork`). Nil (tests) or a title without an image gets the generated placeholder.
    convenience init(scenario: Scenario = .full, lang: Lang = .initial(), animated: Bool = true, artworkRepo: String? = nil) {
        func t(_ key: String) -> String { L10n.string(key, lang) }
        let settings = [
            LaunchSetting(env: "DM_RENDER_SCALE", kind: "range", label: t("console.resolution"), note: "", def: "1", section: nil,
                          options: nil, min: 0.5, max: 2, step: 0.25, on: nil, off: nil),
            LaunchSetting(env: "DM_FPS_TARGET", kind: "choice", label: t("console.frameRate"), note: "", def: "60", section: nil,
                          options: [["30", t("console.fps30")], ["60", t("console.fps60")]], min: nil, max: nil, step: nil, on: nil, off: nil),
            LaunchSetting(env: "DM_LANG", kind: "choice", label: t("console.language"), note: "", def: "en", section: nil,
                          options: [["en", t("console.english")], ["zh", t("console.chinese")], ["ja", t("console.japanese")]], min: nil, max: nil, step: nil, on: nil, off: nil),
            LaunchSetting(env: "DM_RUMBLE", kind: "toggle", label: t("console.rumble"), note: "", def: "1", section: ConsoleGame.controlsSection,
                          options: nil, min: nil, max: nil, step: nil, on: nil, off: nil),
            LaunchSetting(env: "DM_RUMBLE_GAIN", kind: "range", label: t("console.rumbleStrength"), note: "", def: "1", section: ConsoleGame.controlsSection,
                          options: nil, min: 0, max: 3, step: 0.1, on: nil, off: nil),
            // two advanced options (not in LaunchSetting.basicByDefault), for the Advanced page
            LaunchSetting(env: "DM_VSYNC", kind: "toggle", label: t("console.demoVsync"), note: "", def: "1", section: nil,
                          options: nil, min: nil, max: nil, step: nil, on: nil, off: nil),
            LaunchSetting(env: "DM_AUDIO_LATENCY", kind: "range", label: t("console.demoLatency"), note: "", def: "40", section: nil,
                          options: nil, min: 10, max: 120, step: 10, on: nil, off: nil)
        ]
        // Library-style titles. Covers come from the launcher's own artwork lookup in the repo copy (nothing is bundled or downloaded).
        let titles = ["Hollow Knight: Silksong", "Celeste", "Hades", "Sea of Stars", "Portal", "Balatro", "Animal Well", "Cuphead", "Stardew Valley", "Return of the Obra Dinn", "Blasphemous", "Hades II"]
        let noBanners = FileManager.default.temporaryDirectory.appendingPathComponent("console-demo-no-banners")   // the demo ids are invented: no eShop banner to find
        let games = ConsoleGame.readyFirst(titles.enumerated().map { index, title in
            ConsoleGame(id: "demo.\(index)", title: title, version: "1.0.\(index % 3)", platforms: index % 3 == 1 ? [.mac] : [.mac, .iphone],
                        artwork: artworkRepo.flatMap { repo in
                            GameLibrary.artwork(for: LibraryGame(titleID: String(format: "%016X", index), name: title), slot: .thumbnail, repo: repo, banners: noBanners, maxPixel: ArtworkImages.cardPixels)
                        },   // nil: the view draws a placeholder cover from the title
                        status: index == 3 ? .needsBuild : index == 5 ? .needsData : index == 7 ? .broken(t("console.demoBroken")) : index == 9 ? .iphoneOnly : .ready,
                        settings: settings, mapsButtons: !(index == 3 || index == 5 || index == 7 || index == 9))
        })
        var snapshot = ConsoleState(games: scenario == .empty ? [] : scenario == .few ? Array(games.prefix(2)) : games,
                                    focusedGameID: scenario == .empty ? nil : "demo.0",
                                    controllers: [.init(id: "pad.1", name: t("console.demoController"), player: 1)],
                                    time: Date(timeIntervalSince1970: 1_793_210_400))
        snapshot.isPreview = true
        // two games played before (#816's Continue playing), with their play time
        for (id, days, hours) in [("demo.2", 1.0, 12.5), ("demo.4", 6.0, 3.0)] {
            if let i = snapshot.games.firstIndex(where: { $0.id == id }) {
                snapshot.games[i].lastPlayed = snapshot.time.addingTimeInterval(-days * 86_400); snapshot.games[i].playSeconds = hours * 3600
            }
        }
        snapshot.builds = ConsoleBuilds(running: true, title: t("console.demoBuild"),
                                        stages: [.init(id: 1, name: t("console.demoStage1"), state: .done), .init(id: 2, name: t("console.demoStage2"), state: .running, progress: 0.4),
                                                 .init(id: 3, name: t("console.demoStage3"), state: .pending)],
                                        queue: [.init(id: UUID(), name: titles[3], statusKey: "queue.status.queued")])
        if scenario == .paused { snapshot.gamePaused("demo.2") }
        snapshot.prefs = ConsolePrefs(values: [:], appVersion: "1.2.3", update: .available("1.2.4"))
        snapshot.homeButtonAvailable = true
        if scenario == .controllers {
            snapshot.controllers += [.init(id: "pad.2", name: t("console.demoController2"), player: 2),
                                     .init(id: "pad.3", name: t("console.demoController3"), player: nil)]
            snapshot.openControllers(); snapshot.assigningPlayer = 3
        }
        if scenario == .controllersMixed {
            snapshot.controllers = [
                .init(id: "pad.1", name: t("console.demoController2"), player: 1, kind: .fullSize, battery: 0.76),
                .init(id: "pad.2", name: t("console.demoXbox"), player: 2, kind: .xbox, battery: 0.12),
                .init(id: "keyboard", name: t("console.demoKeyboard"), player: 3, kind: .keyboard),
                .init(id: "pad.4", name: t("console.demoPaired"), player: 4, kind: .paired, battery: 0.48, charging: true)
            ]
            snapshot.openControllers()
        }
        if scenario == .starting { snapshot.play("demo.0"); snapshot.starting = .compilingShaders(completed: 18, total: 48) }
        self.init(state: snapshot, lang: lang, animated: animated)
        if scenario == .starting, animated { animateStarting("demo.0") }
    }
    func focus(_ gameID: String) { state.focus(gameID) }
    func play(_ gameID: String) {
        if state.pausedGameID == gameID { resume(gameID); return }
        let wasStarting = state.startingGameID != nil
        state.play(gameID)
        if !wasStarting, state.startingGameID != nil, animated { animateStarting(gameID) }
    }
    private func animateStarting(_ gameID: String) {
        startingTask?.cancel()
        startingTask = Task { [weak self] in
            for count in stride(from: 0, through: 48, by: 4) {
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled, let self, self.state.startingGameID == gameID else { return }
                self.state.starting = .compilingShaders(completed: count, total: 48)
            }
            self?.state.starting = .opening
        }
    }

    /// The preview's mods, cheats and cloud save for a ready game: two mods (one that changes code), a cheats file with a heading,
    /// an always-on row and three switches.
    private var demoMods: [String: [ConsoleMod]] = [:]
    private var demoCheats: [String: ConsoleCheats] = [:]
    private var demoChanged: Set<String> = []
    func openOptions(_ gameID: String) {
        loadDemoDetails(gameID)
        state.openOptions(gameID)
    }
    func loadDemoDetails(_ gameID: String) {
        guard let i = state.games.firstIndex(where: { $0.id == gameID }), state.games[i].status == .ready else { return }
        func t(_ key: String) -> String { L10n.string(key, lang) }
        state.games[i].mods = demoMods[gameID] ?? [ConsoleMod(name: t("console.demoMod1"), usable: true, on: true),
                                                   ConsoleMod(name: t("console.demoMod2"), usable: false, on: false)]
        state.games[i].cheats = demoCheats[gameID] ?? ConsoleCheats(masterOn: true, items: [
            ConsoleCheat(key: "m", name: t("console.demoCheatMaster"), kind: .alwaysOn, on: true),
            ConsoleCheat(key: "l", name: t("console.demoCheatGroup"), kind: .label, on: false),
            ConsoleCheat(key: "c1", name: t("console.demoCheat1"), kind: .cheat, on: true),
            ConsoleCheat(key: "c2", name: t("console.demoCheat2"), kind: .cheat, on: false),
            ConsoleCheat(key: "c3", name: t("console.demoCheat3"), kind: .cheat, on: false)])
        state.games[i].canReset = demoChanged.contains(gameID) || !state.games[i].values.isEmpty
        state.games[i].save = ConsoleSaveRow(id: gameID, title: state.games[i].title, status: .synced, updated: state.time.addingTimeInterval(-3600), updatedFrom: .cloudSave)
    }
    func setMod(gameID: String, name: String, on: Bool) {
        guard let i = state.games.firstIndex(where: { $0.id == gameID }), let m = state.games[i].mods.firstIndex(where: { $0.name == name && $0.usable }) else { return }
        state.games[i].mods[m].on = on; demoMods[gameID] = state.games[i].mods
    }
    func setCheatsMaster(gameID: String, on: Bool) {
        guard let i = state.games.firstIndex(where: { $0.id == gameID }), state.games[i].cheats != nil else { return }
        state.games[i].cheats?.masterOn = on; demoCheats[gameID] = state.games[i].cheats
    }
    func setCheat(gameID: String, key: String, on: Bool) {
        guard let i = state.games.firstIndex(where: { $0.id == gameID }), let c = state.games[i].cheats?.items.firstIndex(where: { $0.key == key && $0.kind == .cheat }) else { return }
        state.games[i].cheats?.items[c].on = on; demoCheats[gameID] = state.games[i].cheats
    }
    func openAdvanced(_ gameID: String) {
        guard state.games.first(where: { $0.id == gameID })?.advancedSettings.isEmpty == false else { return }
        state.push(.advanced(gameID))
    }
    func askResetOptions(_ gameID: String) {
        guard state.games.first(where: { $0.id == gameID })?.canReset == true else { return }
        state.push(.confirmReset(gameID))
    }
    func resetOptions(_ gameID: String) {
        guard state.presentedSheet == .confirmReset(gameID), let i = state.games.firstIndex(where: { $0.id == gameID }) else { return }
        state.back()
        state.games[i].values = [:]; demoChanged.remove(gameID)
        loadDemoDetails(gameID)
    }
    func setPref(_ pref: ConsolePref, on: Bool) { state.prefs.values[pref] = on }
    func appUpdateAction() {
        switch state.prefs.update {
        case .available, .ready: state.push(.confirmUpdate)
        default: break
        }
    }
    func confirmAppUpdate() {
        guard state.presentedSheet == .confirmUpdate else { return }
        state.back()
        state.prefs.update = state.prefs.update == .ready ? .upToDate : .ready
    }
    func setOption(gameID: String, setting: String, value: String) {
        state.setOption(game: gameID, setting: setting, value: value)
        if let i = state.games.firstIndex(where: { $0.id == gameID }) { demoChanged.insert(gameID); state.games[i].canReset = true }
    }
    func openControllers() { state.openControllers() }
    deinit { toastTask?.cancel(); startingTask?.cancel() }
    func requestPlayer(_ player: Int) {
        guard state.presentedSheet == .controllers, (1...4).contains(player) else { return }
        state.assigningPlayer = player
    }
    func assignPlayer(controllerID: String, player: Int) { state.assignPlayer(controller: controllerID, player: player) }
    func back() {
        let wasGame = state.mappingGameID != nil
        state.back()
        if wasGame, state.mappingGameID == nil { state.padLayout = globalLayout }
    }
    func exitToDesktop() { startingTask?.cancel(); state.exitToDesktop() }
    func returnFromGame() { startingTask?.cancel(); state.returnFromGame() }
    func identify(controllerID: String) {
        guard let controller = state.controllers.first(where: { $0.id == controllerID }) else { return }
        state.identifyingControllerID = controllerID
        showToast(String(format: L10n.string("console.identifyingName", lang), controller.name))
    }
    func openMenu() { state.openMenu() }
    func openLibrary() { state.openLibrary() }
    func openSettings() { state.openSettings() }
    func openLanguage() { state.openLanguage() }
    func setMenuSwapAB(_ on: Bool) {
        if state.mappingOrigin != nil { state.pendingMenuSwapAB = on } else { state.menuSwapAB = on }
    }
    /// Discard puts back the layout the page opened with, and the game's own buttons as they were.
    private var undoGamePads: [String: [String: String]] = [:]
    private var undoCustomPad: [String: String] = [:]
    func finishMapping(save: Bool) {
        guard state.presentedSheet == .confirmMapping else { return }
        let wasGame = state.mappingGameID != nil
        if save {
            if let swap = state.pendingMenuSwapAB { state.menuSwapAB = swap }
        } else if let origin = state.mappingOrigin {
            if wasGame { gamePads = undoGamePads } else { customPad = undoCustomPad; state.padLayout = origin }
        }
        state.endMappingEdit()
        if wasGame { state.padLayout = globalLayout }
    }
    func confirmExit() { state.confirmExit() }
    /// The preview's cloud saves: one game in each state, the times an hour, a day and a week back.
    func openCloudSaves() {
        let statuses = ConsoleSaveStatus.allCases
        let now = Date()
        let rows = state.games.filter { $0.status == .ready }.enumerated().map { i, game in
            ConsoleSaveRow(id: game.id, title: game.title, status: statuses[i % statuses.count],
                           updated: i % 4 == 3 ? nil : now.addingTimeInterval(-[3600, 86400, 604800][i % 3]),
                           updatedFrom: i % 4 == 3 ? nil : (i % 2 == 0 ? .cloudSave : .lastSession))
        }
        state.openCloudSaves(rows)
    }
    func openMapping() {
        guard state.presentedSheet != .mapping else { return }
        state.openMapping()
        undoCustomPad = customPad
        state.padLayout.custom = customPad
        state.beginMappingEdit(undo: ConsoleMappingUndo(mode: state.padLayout.mode, pad: customPad))
    }
    /// The preview's own mapping per game, a copy of all games' until it is changed.
    private var gamePads: [String: [String: String]] = [:]
    private var globalLayout = ConsolePadLayout()
    func openGameMapping(_ gameID: String) {
        guard let game = state.games.first(where: { $0.id == gameID }), game.mapsButtons else { return }
        globalLayout = state.padLayout
        state.openMapping(game: gameID)
        state.padLayout = ConsolePadLayout(mode: .custom, gameTitle: game.title, baseline: globalLayout.sends, sends: gamePads[gameID] ?? globalLayout.sends)
        undoGamePads = gamePads
        state.beginMappingEdit(undo: ConsoleMappingUndo())
    }
    func openGamePad(_ gameID: String) { state.openGamePad(gameID) }
    func openMappingRow(_ button: String?) { state.openMappingRow(button) }
    /// The preview's layout, as ControlLayout keeps it: a preset's buttons, or the Custom ones, which a button changed by hand starts from.
    private var customPad: [String: String] = [:]
    func setPadMode(_ mode: PadMode) {
        guard state.mappingGameID == nil else { return }
        state.padLayout.mode = mode
        switch mode {
        case .standard: state.padLayout.sends = [:]
        case .byLabel: state.padLayout.sends = ControlLayout.byLabelPad
        case .auto: state.padLayout.sends = ControlLayout.autoMode(category: nil) == .byLabel ? ControlLayout.byLabelPad : [:]
        case .custom: state.padLayout.sends = customPad
        }
    }
    func setPadSends(button: String, to output: String) {
        guard ConsolePadLayout.buttons.contains(button) else { return }
        if let id = state.mappingGameID {
            var map = state.padLayout.sends
            map[button] = output == button ? nil : output
            gamePads[id] = map
            state.padLayout.sends = map
            return
        }
        if state.padLayout.mode != .custom { customPad = state.padLayout.sends; state.padLayout.mode = .custom }
        customPad[button] = output == button ? nil : output
        state.padLayout.sends = customPad
        state.padLayout.custom = customPad
    }
    func resetPadMapping() {
        if let id = state.mappingGameID { gamePads[id] = nil; state.padLayout.sends = state.padLayout.baseline; return }
        customPad = [:]; state.padLayout = ConsolePadLayout()   // custom empty too
    }
    /// Disconnect in the preview: the controller goes away from the list.
    func disconnect(controllerID: String) {
        guard let controller = state.controllers.first(where: { $0.id == controllerID }) else { return }
        state.controllers.removeAll { $0.id == controllerID }
        if state.assigningControllerID == controllerID { state.assigningControllerID = nil; state.assigningPlayer = nil }
        showToast(String(format: L10n.string("console.disconnected", lang), controller.name))
    }
    func requestAssignment(controllerID: String) {
        guard state.presentedSheet == .controllers, let controller = state.controllers.first(where: { $0.id == controllerID }) else { return }
        state.assigningControllerID = controllerID
        state.assigningPlayer = state.assigningPlayer ?? controller.player ?? 1
    }
    func setPadMerge(_ enabled: Bool) { state.padMerge = enabled }
    func dismissToast() { toastTask?.cancel(); state.toast = nil; state.identifyingControllerID = nil }
    /// A transport event simulated by tests or a preview coordinator, without hardware discovery.
    func connect(_ controller: ConsoleController) {
        state.controllers.removeAll { $0.id == controller.id }
        var connected = controller
        if let player = connected.player, state.controllers.contains(where: { $0.player == player }) {
            connected.player = (1...4).first { player in !state.controllers.contains(where: { $0.player == player }) }
        }
        state.controllers.append(connected)
        if let player = state.padMerge ? 1 : connected.player {
            showToast(String(format: L10n.string("console.connected", lang), connected.name, player))
        } else { showToast(String(format: L10n.string("console.connectedUnassigned", lang), connected.name)) }
    }
    private func showToast(_ message: String) {
        toastTask?.cancel()
        state.toast = ConsoleToast(message: message)
        guard animated else { return }
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.state.toast = nil
            self?.state.identifyingControllerID = nil
        }
    }
}
