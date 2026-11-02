import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// The window's content: the launcher, or the guided setup before it. It owns the one `LauncherStores` and `GameLibrary` both use,
/// so what the setup detects, installs and chooses is what the launcher shows.
struct RootView: View {
    private enum Mode { case checking, onboarding, launcher }
    /// Holds the two objects without publishing, so this view does not redraw with every line of a build log.
    @MainActor private final class Shared: ObservableObject {
        let stores = LauncherStores(); let library = GameLibrary(); let controls = ControlLayout()
        /// The console mode's driver over this window's model, library and controls.
        lazy var console = LiveConsoleDriver(library: library, controls: controls, repo: { [stores] in stores.repo.path }, lang: { [stores] in stores.localizer.lang },
                                             labels: { [stores] in stores.localizer.t($0) })
    }
    @StateObject private var shared = Shared()
    private var stores: LauncherStores { shared.stores }
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
                        ConsoleView(driver: shared.console, lang: stores.localizer.lang, onExit: { console.exit(); shared.console.returnFromGame() })
                            .onAppear { shared.console.reloadCovers() }
                            .transition(CalmTransition.console)
                    } else {
                        ContentView(stores: stores, library: library, onRunSetup: runSetupAgain, enterConsole: { console.enter() },
                                    controllerDriver: AnyConsoleDriver(shared.console), controls: shared.controls)
                            .transition(CalmTransition.desktop)
                    }
                }
                .animation(.easeInOut(duration: CalmTransition.reduceMotion ? 0.25 : ConsoleCoordinator.transitionSeconds), value: console.active)
            }
        }
        .background(LauncherPalette.background)
        .preferredColorScheme(.dark)
        .frame(minWidth: 900, idealWidth: 1280, minHeight: 680, idealHeight: 900)
        .task {
            shared.console.prepareLaunch = { [console] launch in console.leaveFullScreenForGame(then: launch) }
            shared.console.pointerHidden = { [console] in console.pointerHidden }
            shared.console.gameEnded = { [console] in console.resumeFullScreenAfterGame() }
            await decide()
        }
        .onChange(of: mode) { console.available = $0 == .launcher }
    }

    /// On launch: a setup marked done, or one that is complete already, goes straight to the launcher (and is marked done);
    /// anything else starts or resumes the guided setup.
    private func decide() async {
        let defaults = UserDefaults.standard
        // NSPB_ONBOARDING_FORCE=1: the real flow with real detection whatever the state, leaving no trace until it is finished
        if OnboardingLaunch.forced() { show(fresh: false, ephemeral: true); return }
        if defaults.bool(forKey: OnboardingDefaults.completed) { mode = .launcher; return }
        await stores.dependencies.refreshDepsAndWait()
        let env = OnboardingEnvironment()
        let keysKnown = stores.build.slot("keys").ok || !env.keyCandidates(gamesFolder: library.folder).isEmpty || library.games.contains(where: \.isReady)
        let gamesKnown = !library.folder.isEmpty || !library.games.isEmpty
        let complete = OnboardingLaunch.setupComplete(depsPresent: stores.dependencies.allPresent, keysKnown: keysKnown, gamesKnown: gamesKnown)
        if OnboardingLaunch.shouldShow(completed: false, setupComplete: complete) {
            show(fresh: false)
        } else {
            defaults.set(true, forKey: OnboardingDefaults.completed)
            mode = .launcher
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
