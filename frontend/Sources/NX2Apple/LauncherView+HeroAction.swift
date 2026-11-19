import AppKit
import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// The hero primary action and Mac / device launch lifecycle tracking.
extension LauncherView {
    static func needsImmediateGatekeeperHint(for game: LibraryGame) -> Bool {
        game.isReady && game.lastPlayed == nil
    }

    func isLaunchingMacGame(_ game: LibraryGame) -> Bool {
        launching && game.primary == .play && (launchingGameID == nil || launchingGameID == game.id)
    }

    @ViewBuilder func heroPrimary(_ game: LibraryGame) -> some View {
        let macStarting = isLaunchingMacGame(game)
        let title = macStarting ? loc.t("library.launching")
            : (game.primary == .play ? loc.t("library.play")
                : (game.primary == .openOnDevice ? String(format: loc.t("dev.open"), devices.deviceName(game.installedDevice))
                    : loc.t("library.setUpBuild")))
        let symbol = game.primary == .play ? "play.fill" : (game.primary == .openOnDevice ? "iphone" : "hammer.fill")
        let button = Button { primaryAction(game) } label: {
            LauncherHeroActionLabel(title: title, symbol: symbol, loading: macStarting)
        }
        .buttonStyle(LauncherActionButtonStyle()).fixedSize(horizontal: false, vertical: true).launcherHover(enabled: artworkEditor == nil && !launching, lightBrightness: 0)
        .disabled(launching || (m.running && !game.isReady) || artworkEditor != nil)
        .keyboardShortcut(keyboardCard == nil && libraryInputAvailable ? KeyboardShortcut(.return, modifiers: []) : nil)
        .padTarget("hero.play", scope: "main", focusColor: LauncherPalette.onCream, enabled: !launching && (!m.running || game.isReady) && artworkEditor == nil) { if !launching && !profileHelpOpen && artworkEditor == nil && (!m.running || game.isReady) { primaryAction(game) } }
        button.id(game.id)
    }

    func heroActions(_ game: LibraryGame, lightHero: Bool, compact: Bool) -> some View {
        let showsRefresh = !(m.running && activeBuildID == game.id) && gameNeedsRefresh(game)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                heroPrimary(game)
                if showsRefresh { heroSingleRefreshButton(game, lightHero: lightHero, compact: compact) }
                heroDeviceActions(game)
                heroManage(game)
            }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) { heroPrimary(game); heroManage(game) }
                if showsRefresh { heroSingleRefreshButton(game, lightHero: lightHero, compact: compact) }
                heroDeviceActions(game)
            }
        }
    }

    private func heroManage(_ game: LibraryGame) -> some View {
        heroUtilityButton("ellipsis", label: loc.t("library.manage"), id: "hero.manage") { manageOpenFor = game.id }
            .anchorPreference(key: ManageAnchorKey.self, value: .bounds) { $0 }
    }

    func heroUtilityButton(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                .foregroundStyle(LauncherPalette.text)
                .frame(width: LauncherHeroAction.height, height: LauncherHeroAction.height)
                .background(LauncherPalette.secondaryFill, in: Circle())
                .overlay(Circle().strokeBorder(LauncherPalette.secondaryBorder))
                .contentShape(Circle())
        }
        .buttonStyle(.plain).launcherHover(enabled: artworkEditor == nil).accessibilityLabel(label)
        .help(label).padTarget(id, scope: "main", activate: action)
    }

    @ViewBuilder private func heroDeviceActions(_ game: LibraryGame) -> some View {
        if game.onDevice {
            HStack(spacing: 12) {
                if !game.isOlderIOSBuild {
                    let expiry = signatureExpiry[game.id].map { AppSignature.describe($0, loc.t) } ?? loc.t("dev.expiryUnknown")
                    heroSecondary(loc.t("dev.resign"), symbol: "checkmark.seal", id: "hero.resign", enabled: !m.running,
                                  help: expiry + "\n" + loc.t("dev.resignHelp")) { resign(game) }
                }
                if game.isReady {
                    heroSecondary(loc.t("dev.openIOS"), symbol: "iphone", id: "hero.device", enabled: !launching,
                                  help: devices.deviceName(game.installedDevice)) { openOnDevice(game) }
                }
            }
        }
    }

    private func heroSecondary(_ title: String, symbol: String, id: String, enabled: Bool, help: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LauncherHeroActionLabel(title: title, symbol: symbol)
                .foregroundStyle(LauncherPalette.text)
                .background(LauncherPalette.secondaryFill, in: Capsule())
                .overlay(Capsule().strokeBorder(LauncherPalette.secondaryBorder))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).fixedSize(horizontal: false, vertical: true).disabled(!enabled || artworkEditor != nil)
        .opacity(enabled && artworkEditor == nil ? 1 : 0.45)
        .launcherHover(enabled: enabled && artworkEditor == nil).help(help)
        .padTarget(id, scope: "main", enabled: enabled && artworkEditor == nil) { if enabled && artworkEditor == nil { action() } }
    }

    func openOnDevice(_ game: LibraryGame) {
        guard !launching else { return }
        launching = true
        launchingGameID = game.id
        showGatekeeperHint = false
        m.openOnDevice(udid: game.installedDevice, app: game.iosAppPath) { error in
            endGameLaunch()
            if let error { launchError = error }
            else { library.recordPlayed(game.id) }
        }
    }

    func beginMacLaunch(_ game: LibraryGame) {
        launchHintGeneration &+= 1
        let generation = launchHintGeneration
        launching = true
        launchingGameID = game.id
        if Self.needsImmediateGatekeeperHint(for: game) {
            showGatekeeperHint = true
        } else {
            showGatekeeperHint = false
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                if launching, launchHintGeneration == generation {
                    showGatekeeperHint = true
                }
            }
        }
    }

    func endGameLaunch() {
        launchHintGeneration &+= 1
        launching = false
        launchingGameID = nil
        showGatekeeperHint = false
    }

    func primaryAction(_ game: LibraryGame) {
        if game.primary == .openOnDevice {
            openOnDevice(game)
            return
        }
        guard game.isReady else {
            configureBuild(game)
            return
        }
        do {
            _ = try MacGameBundle.read(URL(fileURLWithPath: game.appPath))
            beginMacLaunch(game)
            cloudGate.begin(
                game,
                proceed: { startMacGame(game, cloudChoice: $0) },
                ended: { endGameLaunch() }
            )
        } catch {
            launchError = error.localizedDescription
        }
    }

    private func startMacGame(_ game: LibraryGame, cloudChoice: [String: String]) {
        let currentGame = library.games.first(where: { $0.id == game.id }) ?? game
        let configuration = NSWorkspace.OpenConfiguration()
        let environment = GameStart.environment(
            for: currentGame,
            library: library,
            controls: controls,
            repo: stores.repo.path,
            labels: loc.t,
            lang: loc.lang,
            player: stores.players.active,
            saves: (stores.saveSettings.global, stores.saveSettings.game(currentGame.titleID)),
            sticks: stores.sticks.settings
        )
        let withRecording = environment
            .merging(FrameTimes.recordingEnvironment(for: currentGame, library: library.folder)) { $1 }
            .merging(cloudChoice) { $1 }
        if !withRecording.isEmpty { configuration.environment = withRecording }
        let generation = launchHintGeneration
        MacGameMode.shared.prepareForLaunch(enabled: currentGame.macGameModeDesired, forApp: currentGame.appPath) { error in
            MainActor.assumeIsolated {
                guard launchHintGeneration == generation else { return }
                if let error {
                    endGameLaunch()
                    launchError = error.localizedDescription
                    return
                }
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: currentGame.appPath), configuration: configuration) { app, error in
                    let pid = app?.processIdentifier
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            if let error {
                                if launchHintGeneration == generation { endGameLaunch() }
                                launchError = error.localizedDescription
                                return
                            }
                            library.recordPlayed(currentGame.id)
                            if let pid { GameReturnWatcher.shared.didStart(pid: pid) }
                            if let app, !app.isFinishedLaunching, !app.isTerminated {
                                Task { @MainActor in
                                    let deadline = Date().addingTimeInterval(5.0)
                                    while !app.isFinishedLaunching && !app.isTerminated && Date() < deadline {
                                        try? await Task.sleep(nanoseconds: 150_000_000)
                                        if launchHintGeneration != generation { return }
                                    }
                                    if launchHintGeneration == generation { endGameLaunch() }
                                }
                            } else if launchHintGeneration == generation {
                                endGameLaunch()
                            }
                        }
                    }
                }
            }
        }
    }

    func checkTools() {
        toolsAge.check(
            games: library.games,
            repo: stores.repo.path,
            libraryFolder: library.folder,
            seedRoot: BuildSeedCache.defaultRoot(home: stores.build.home),
            shellRoot: stores.build.shellCachePath
        )
    }
}
