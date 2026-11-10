import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// App-lifetime state shared by setup and every launcher window. A build and its log must outlive the window that started it.
/// Nothing is published here, so log output redraws only the views observing the individual stores.
@MainActor final class LauncherSession: ObservableObject {
    let stores: LauncherStores
    let library: GameLibrary
    let controls = ControlLayout()
    /// Records the builds in the library whichever view is up: console mode takes LauncherView down while a build runs on.
    let recorder: BuildRecorder
    lazy var console: LiveConsoleDriver = {
        let driver = LiveConsoleDriver(library: library, controls: controls, repo: { [stores] in stores.repo.path }, lang: { [stores] in stores.localizer.lang },
                                       labels: { [stores] in stores.localizer.t($0) }, player: { [stores] in stores.players.active },
                                       saves: { [stores] in (stores.saveSettings.global, stores.saveSettings.game($0)) },
                                       sticks: { [stores] in stores.sticks.settings })
        driver.bindActivity(stores.build)   // the top bar's chip shows the desktop's build (#1004)
        driver.bindBuilds(stores.build, queue: stores.queue)   // the Builds page (#816)
        return driver
    }()

    init(stores: LauncherStores? = nil, library: GameLibrary? = nil) {
        self.stores = stores ?? LauncherStores()
        self.library = library ?? GameLibrary()
        recorder = BuildRecorder(stores: self.stores, library: self.library)
    }
}

/// The window's content: the launcher, or the guided setup before it. The app owns the shared session.
struct RootView: View {
    private enum Mode { case checking, onboarding, launcher }
    @ObservedObject var shared: LauncherSession
    var stores: LauncherStores { shared.stores }
    private var library: GameLibrary { shared.library }
    @State private var mode: Mode = .checking
    @State private var driver: LiveOnboardingDriver?
    @StateObject private var gamepad = LauncherGamepad()
    @ObservedObject var console: ConsoleCoordinator

    var body: some View {
        Group {
            switch mode {
            case .checking:
                LauncherPalette.background.overlay(ProgressView().controlSize(.small))
            case .onboarding:
                if let driver { OnboardingView(driver: driver, lang: stores.localizer.lang, gamepad: gamepad) }
            case .launcher:
                ZStack {
                    if console.active {
                        ConsoleInLanguage(localizer: stores.localizer) { lang in
                            ConsoleView(driver: shared.console, lang: lang, onExit: { console.exit(); shared.console.returnFromGame() },
                                        chooseLanguage: { code in stores.localizer.choose(code); shared.console.refresh() })
                        }
                            .onAppear { shared.console.reloadCovers() }
                            .transition(CalmTransition.console)
                    } else {
                        LauncherView(stores: stores, library: library, onRunSetup: runSetupAgain, enterConsole: { console.enter() },
                                    controllerDriver: AnyConsoleDriver(shared.console), controls: shared.controls, recorder: shared.recorder)
                            .transition(CalmTransition.desktop)
                    }
                }
                .animation(.easeInOut(duration: CalmTransition.reduceMotion ? 0.25 : ConsoleCoordinator.transitionSeconds), value: console.active)
            }
        }
        .background(LauncherPalette.background)
        .launcherAppearance(forceDark: mode == .launcher && console.active)   // the window is Dark while the console shows
        .frame(minWidth: 900, idealWidth: 1280, minHeight: 680, idealHeight: 900)
        .task {
            shared.console.prepareLaunch = { [console] launch in console.startGameInFullScreen(then: launch) }   // the console stays full screen into the game (seedds/nxnative#665)
            shared.console.pointerHidden = { [console] in console.pointerHidden }
            shared.console.gameEnded = { [console] in console.resumeFullScreenAfterGame() }
            shared.console.attach(updates: stores.appUpdates, builds: stores.build)   // the General page's update row
            // quitting the launcher while a game is paused in the background asks first in console mode (#952)
            AppDelegate.deferTermination = { [console, shared] in shared.console.shouldDeferTermination(consoleShown: console.active) }
            shared.console.tracking.showConsole = { [console] in console.enter() }   // a game paused from its Home menu comes back to console mode
            await decide()
        }
        .onChange(of: mode) { console.available = $0 == .launcher }
    }

    /// On launch: a setup marked done, or one that is complete already, goes straight to the launcher (and is marked done);
    /// anything else starts or resumes the guided setup.
    private func decide() async {
        let destination = await OnboardingLaunch.decide(defaults: .standard, force: OnboardingLaunch.forced(), keysSlotIsEmpty: stores.build.keysPath.isEmpty) {
            await stores.dependencies.refreshDepsAndWait()
            let env = OnboardingEnvironment()
            let keysKnown = stores.build.keysReady || !env.keyCandidates(gamesFolder: library.folder).isEmpty || library.games.contains(where: \.isReady)
            let gamesKnown = !library.folder.isEmpty || !library.games.isEmpty
            return OnboardingLaunch.setupComplete(depsPresent: stores.dependencies.allPresent, keysKnown: keysKnown, gamesKnown: gamesKnown)
        }
        switch destination {
        case .launcher: mode = .launcher
        case .onboarding: show(fresh: false)
        case .forced: show(fresh: false, ephemeral: true)
        }
    }

    private func show(fresh: Bool, ephemeral: Bool = false) {
        let d = LiveOnboardingDriver(stores: stores, library: library, fresh: fresh, ephemeral: ephemeral)
        d.onExit = { _ in mode = .launcher; driver = nil }
        driver = d
        mode = .onboarding
        d.activate()
    }

    private func runSetupAgain() { show(fresh: true) }
}

/// The console mode redrawn in the language its General page picks (the root view itself does not observe the localizer).
private struct ConsoleInLanguage<Content: View>: View {
    @ObservedObject var localizer: Localizer
    let content: (Lang) -> Content
    var body: some View { content(localizer.lang) }
}
