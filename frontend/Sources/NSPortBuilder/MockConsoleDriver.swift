import SwiftUI

@MainActor final class MockConsoleDriver: ConsoleDriver {
    enum Scenario: String, CaseIterable { case full, few, empty, controllers, controllersMixed, starting }
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
            LaunchSetting(env: "DM_FULLSCREEN", kind: "toggle", label: t("console.fullscreen"), note: "", def: "1", section: nil,
                          options: nil, min: nil, max: nil, step: nil, on: nil, off: nil),
            LaunchSetting(env: "DM_RUMBLE", kind: "toggle", label: t("console.rumble"), note: "", def: "1", section: nil,
                          options: nil, min: nil, max: nil, step: nil, on: nil, off: nil)
        ]
        // Library-style titles. Covers come from the launcher's own artwork lookup in the repo copy (nothing is bundled or downloaded).
        let titles = ["Hollow Knight: Silksong", "Celeste", "Hades", "Sea of Stars", "Portal", "Balatro", "Animal Well", "Cuphead", "Stardew Valley", "Return of the Obra Dinn", "Blasphemous", "Hades II"]
        let noBanners = FileManager.default.temporaryDirectory.appendingPathComponent("console-demo-no-banners")   // the demo ids are invented: no eShop banner to find
        let games = titles.enumerated().map { index, title in
            ConsoleGame(id: "demo.\(index)", title: title, version: "1.0.\(index % 3)", platforms: index % 3 == 1 ? [.mac] : [.mac, .iphone],
                        artwork: artworkRepo.flatMap { repo in
                            GameLibrary.artwork(for: LibraryGame(titleID: String(format: "%016X", index), name: title), repo: repo, banners: noBanners)
                        }.map { Image(nsImage: $0) },   // nil: the view draws a placeholder cover from the title
                        status: index == 3 ? .needsBuild : index == 5 ? .needsData : index == 7 ? .broken(t("console.demoBroken")) : index == 9 ? .iphoneOnly : .ready,
                        settings: settings)
        }
        var snapshot = ConsoleState(games: scenario == .empty ? [] : scenario == .few ? Array(games.prefix(2)) : games,
                                    focusedGameID: scenario == .empty ? nil : "demo.0",
                                    controllers: [.init(id: "pad.1", name: t("console.demoController"), player: 1)],
                                    time: Date(timeIntervalSince1970: 1_793_210_400))
        snapshot.isPreview = true
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

    func openOptions(_ gameID: String) { state.openOptions(gameID) }
    func setOption(gameID: String, setting: String, value: String) { state.setOption(game: gameID, setting: setting, value: value) }
    func openControllers() { state.openControllers() }
    deinit { toastTask?.cancel(); startingTask?.cancel() }
    func requestPlayer(_ player: Int) {
        guard state.presentedSheet == .controllers, (1...4).contains(player) else { return }
        state.assigningPlayer = player
    }
    func assignPlayer(controllerID: String, player: Int) { state.assignPlayer(controller: controllerID, player: player) }
    func back() { state.back() }
    func exitToDesktop() { startingTask?.cancel(); state.exitToDesktop() }
    func returnFromGame() { startingTask?.cancel(); state.returnFromGame() }
    func identify(controllerID: String) {
        guard let controller = state.controllers.first(where: { $0.id == controllerID }) else { return }
        state.identifyingControllerID = controllerID
        showToast(String(format: L10n.string("console.identifyingName", lang), controller.name))
    }
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
