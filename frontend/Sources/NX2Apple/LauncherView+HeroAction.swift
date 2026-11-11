import AppKit
import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// The hero's primary action, the built version beside it (#868, #849), and Mac / device launch lifecycle tracking.
extension LauncherView {
    static func needsImmediateGatekeeperHint(for game: LibraryGame) -> Bool {
        game.isReady && game.lastPlayed == nil
    }

    func isLaunchingMacGame(_ game: LibraryGame) -> Bool {
        launching && game.primary == .play && (launchingGameID == nil || launchingGameID == game.id)
    }

    @ViewBuilder func heroPrimary(_ game: LibraryGame, compact: Bool) -> some View {
        let macStarting = isLaunchingMacGame(game)
        let title = macStarting ? loc.t("library.launching")
            : (game.primary == .play ? loc.t("library.play")
                : (game.primary == .openOnDevice ? String(format: loc.t("dev.open"), devices.deviceName(game.installedDevice))
                    : loc.t("library.setUpBuild")))
        let symbol = game.primary == .play ? "play.fill" : (game.primary == .openOnDevice ? "iphone" : "hammer.fill")
        let button = Button { primaryAction(game) } label: {
            LauncherHeroActionLabel(title: title, symbol: symbol, loading: macStarting)
        }
        .buttonStyle(.plain).launcherHover(enabled: artworkEditor == nil && !launching)
        .disabled(launching || (m.running && !game.isReady) || artworkEditor != nil)
        .keyboardShortcut(.return, modifiers: [])
        .padTarget("hero.play", scope: "main", radius: 30) { if !launching { primaryAction(game) } }
        if let version = game.playVersion {
            let label = Text(String(format: loc.t("console.version"), version))
                .font(.manrope(13)).foregroundStyle(.secondary).lineLimit(1)
            if compact {
                VStack(alignment: .leading, spacing: 6) {
                    button
                    label
                }
            } else {
                HStack(spacing: 12) {
                    button
                    label
                }
            }
        } else {
            button
        }
    }

    func openOnDevice(_ game: LibraryGame) {
        guard !launching else { return }
        launching = true
        launchingGameID = game.id
        showGatekeeperHint = false
        m.openOnDevice(udid: game.installedDevice, app: game.iosAppPath) { error in
            endGameLaunch()
            if let error { launchError = error }
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
        let configuration = NSWorkspace.OpenConfiguration()
        let environment = GameStart.environment(
            for: game,
            library: library,
            controls: controls,
            repo: stores.repo.path,
            labels: loc.t,
            lang: loc.lang,
            player: stores.players.active,
            saves: (stores.saveSettings.global, stores.saveSettings.game(game.titleID)),
            sticks: stores.sticks.settings
        )
        let withRecording = environment
            .merging(FrameTimes.recordingEnvironment(for: game, library: library.folder)) { $1 }
            .merging(cloudChoice) { $1 }
        if !withRecording.isEmpty { configuration.environment = withRecording }
        let generation = launchHintGeneration
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: game.appPath), configuration: configuration) { app, error in
            let pid = app?.processIdentifier
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let error {
                        if launchHintGeneration == generation { endGameLaunch() }
                        launchError = error.localizedDescription
                        return
                    }
                    library.recordPlayed(game.id)
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

    func checkTools() {
        toolsAge.check(games: library.games, repo: stores.repo.path)
    }
}
