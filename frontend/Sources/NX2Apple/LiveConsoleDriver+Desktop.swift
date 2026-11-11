import Foundation
import Combine
import NXCore
import NXModel

/// What console mode takes from the desktop launcher, through the same stores and files the desktop uses, so a change here shows
/// there and back: a game's mods (GameLibrary.setMod), its cheats (CheatFiles), its options back to the defaults (SavedChoices and
/// the library), the General page's switches (the defaults Settings binds with @AppStorage), the app's update (AppUpdateStore, which
/// waits while the desktop builds) and the way to the desktop with a game selected. The desktop's build shows in the top bar's
/// activity chip (bindActivity). Nothing here builds or picks a
/// folder: those stay on the desktop.
extension LiveConsoleDriver {
    // MARK: Wiring

    /// The session passes the launcher's update and build stores once (OnboardingRoot): their changes redraw the General page's
    /// update row.
    func attach(updates: AppUpdateStore, builds: BuildStore) {
        appUpdates = updates
        self.builds = builds
        updates.objectWillChange.merge(with: builds.objectWillChange)
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshDesktop() } }
            .store(in: &cancellables)
        refreshDesktop()
    }

    /// The General page's switches, the update row and the Home button setting, read again.
    func refreshDesktop() {
        var prefs = state.prefs
        prefs.values = [.startInConsole: ConsolePrompt.startInConsole, .promptOnController: ConsolePrompt.enabled,
                        .returnAfterPlay: ReturnAfterPlay.enabled, .onlyBuilt: LibraryFilter.load() == .built]
        if let updates = appUpdates {
            prefs.appVersion = updates.version
            prefs.update = Self.update(updates, buildRunning: builds?.running == true)
            prefs.updateStatus = updates.status
        }
        if prefs != state.prefs { state.prefs = prefs }
        if state.homeButtonAvailable != isMacOS27 { state.homeButtonAvailable = isMacOS27 }
    }

    static func update(_ u: AppUpdateStore, buildRunning: Bool) -> ConsoleAppUpdate {
        if u.staged != nil { return buildRunning ? .waitingForBuild : .ready }
        if let progress = u.downloadProgress { return .downloading(Int((progress * 100).rounded())) }
        if let release = u.update {
            guard u.installability == .ok else { return .cannotInstall(release.tag) }
            if let reason = u.blocked, !u.busy { return .failed(tag: release.tag, reason: reason) }   // the last try failed: say why, A tries again
            return buildRunning ? .waitingForBuild : .available(release.tag)
        }
        return u.busy ? .checking : .upToDate
    }

    // MARK: A game's options

    /// Its mods, its cheats, whether its options differ from the defaults and its cloud save: read when its options open.
    func loadDetails(_ gameID: String) {
        guard let game = libraryGame(gameID), let i = state.games.firstIndex(where: { $0.id == gameID }) else { return }
        let mods = GameMod.list(in: GameMod.folder(for: game, library: library.folder), titleID: game.titleID)
        state.games[i].mods = mods.map { ConsoleMod(name: $0.name, usable: $0.usable, on: $0.usable && game.mods.contains($0.name)) }
        state.games[i].cheats = cheats(game)
        let settings = state.games[i].settings
        state.games[i].canReset = game.hasLauncherOptions || SavedChoices(app: game.appPath, titleID: game.titleID).hasChoices(settings)
        state.games[i].save = game.isReady
            ? ConsoleCloudSaves.row(id: gameID, title: game.name, saves: GameCloudSaves(titleID: game.titleID, appPath: game.appPath)) : nil
    }

    /// The cheats file for the build the game has, as CheatsView shows it: headings, always-on rows and switches.
    func cheats(_ game: LibraryGame) -> ConsoleCheats {
        let files = CheatFiles(titleID: game.titleID)
        var result = ConsoleCheats(masterOn: files.masterOn)
        guard let buildID = CheatFiles.buildID(appPath: game.appPath, iosAppPath: game.iosAppPath) else { result.note = t("console.cheats.noBuild"); return result }
        guard let file = files.found().first(where: { $0.buildID == buildID }), let all = files.cheats(of: file) else {
            result.note = t("console.cheats.noFile"); return result
        }
        let on = files.enabled(buildID)
        result.items = all.compactMap { c in
            if c.pairOff || (c.kind == .label && (c.name.isEmpty || c.name.hasPrefix("--Section"))) { return nil }
            switch c.kind {
            case .label: return ConsoleCheat(key: c.key, name: c.name, kind: .label, on: false)
            case .master: return ConsoleCheat(key: c.key, name: c.name, kind: .alwaysOn, on: true)
            case .cheat: return c.switchable ? ConsoleCheat(key: c.key, name: c.name, kind: .cheat, on: on.contains(c.key)) : nil
            }
        }
        return result
    }

    /// The game whose options (or a page over them) are open: its details are read again after the list is rebuilt (refresh) or an
    /// option changes, so the mods, cheats, save and Reset stay on the page.
    var openOptionsGameID: String? {
        for sheet in state.sheets.reversed() {
            switch sheet {
            case let .options(id), let .advanced(id), let .confirmReset(id), let .gamePad(id): return id
            default: continue
            }
        }
        return nil
    }
    func reloadOpenDetails() { if let id = openOptionsGameID { loadDetails(id) } }

    func openOptions(_ gameID: String) {
        loadDetails(gameID)
        state.openOptions(gameID)
    }

    func setMod(gameID: String, name: String, on: Bool) {
        guard let game = libraryGame(gameID), state.games.first(where: { $0.id == gameID })?.mods.contains(where: { $0.name == name && $0.usable }) == true else { return }
        library.setMod(name, on: on, for: game.id)
        loadDetails(gameID)
    }

    func setCheatsMaster(gameID: String, on: Bool) {
        guard let game = libraryGame(gameID) else { return }
        do { try CheatFiles(titleID: game.titleID).setMaster(on) } catch { showToast(String(format: t("cheats.writeFailed"), error.localizedDescription)); return }
        loadDetails(gameID)
    }

    func setCheat(gameID: String, key: String, on value: Bool) {
        guard let game = libraryGame(gameID), let buildID = CheatFiles.buildID(appPath: game.appPath, iosAppPath: game.iosAppPath) else { return }
        let files = CheatFiles(titleID: game.titleID)
        guard let file = files.found().first(where: { $0.buildID == buildID }), let all = files.cheats(of: file),
              all.contains(where: { $0.key == key && $0.switchable }) else { return }
        var on = files.enabled(buildID)
        if value { on.insert(key) } else { on.remove(key) }
        do { try files.writeEnabled(buildID, cheats: all, on: on) } catch { showToast(String(format: t("cheats.writeFailed"), error.localizedDescription)); return }
        loadDetails(gameID)
    }

    func openAdvanced(_ gameID: String) {
        guard state.games.first(where: { $0.id == gameID })?.advancedSettings.isEmpty == false else { return }
        state.push(.advanced(gameID))
    }

    func askResetOptions(_ gameID: String) {
        guard state.games.first(where: { $0.id == gameID })?.canReset == true else { return }
        state.push(.confirmReset(gameID))
    }

    /// As the desktop's Reset: the choices saved in the game's app and the launcher's own options for it.
    func resetOptions(_ gameID: String) {
        guard state.presentedSheet == .confirmReset(gameID) else { return }
        state.back()
        guard let game = libraryGame(gameID), let settings = state.games.first(where: { $0.id == gameID })?.settings else { return }
        SavedChoices(app: game.appPath, titleID: game.titleID).reset(settings)
        library.resetLaunchOptions(for: game.id)
        refresh()
        loadDetails(gameID)
    }

    /// Leaves console mode with the game selected on the desktop, where it is built or its files are chosen.
    func openOnDesktop(_ gameID: String) {
        if state.pausedGameID != nil { state.askQuitPaused(then: .leave(selecting: gameID)); return }   // the paused game quits first (#952)
        if let id = UUID(uuidString: gameID) { library.selectedID = id }
        state.exitToDesktop()
    }

    // MARK: The launcher's switches

    func setPref(_ pref: ConsolePref, on: Bool) {
        let defaults = UserDefaults.standard
        switch pref {
        case .startInConsole: defaults.set(on, forKey: ConsolePrompt.startKey)
        case .promptOnController: defaults.set(on, forKey: ConsolePrompt.defaultsKey)
        case .returnAfterPlay: defaults.set(on, forKey: ReturnAfterPlay.defaultsKey)
        case .onlyBuilt: (on ? LibraryFilter.built : .owned).save()
        }
        refreshDesktop()
        if pref == .onlyBuilt { refresh() }
    }

    /// A on the update row: ask before installing or restarting, else check again.
    func appUpdateAction() {
        refreshDesktop()
        switch state.prefs.update {
        case .available, .ready, .failed: state.push(.confirmUpdate)
        case .upToDate: _ = appUpdates?.checkForUpdate()
        case .checking, .downloading, .cannotInstall, .waitingForBuild: break
        }
    }

    func confirmAppUpdate() {
        guard state.presentedSheet == .confirmUpdate, let updates = appUpdates else { return }
        state.back()
        if updates.staged != nil { updates.restartNow() } else { updates.performUpdate() }
        refreshDesktop()
    }

    func openSystemHomeSettings() { openHomeSettings() }
}
