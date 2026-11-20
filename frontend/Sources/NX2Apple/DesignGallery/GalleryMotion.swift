import SwiftUI
import AppKit
import NXCore
import NXModel
import NXLauncher

/// The scenes with motion (LNPANDY/NX2Apple#1459): each one starts in its "before" state and plays its change shortly after it appears,
/// so the transition runs as it does in the launcher. The gallery's Play builds the scene again with a fresh identity (the same
/// before state, the same change), Slow motion plays it at a quarter of the speed (DS.Motion's speed, `dsMotionSpeed`).
enum GalleryMotion: String, CaseIterable {
    case startGame, buildFinishing, iconReveal, noticeAppears, cardFocus, rowScroll, sheetPresentation, toastAppears

    var title: String {
        switch self {
        case .startGame: return "Console: starting a game"
        case .buildFinishing: return "A build finishing"
        case .iconReveal: return "Build icon: the progress colour reveal"
        case .noticeAppears: return "A notice appearing"
        case .cardFocus: return "Console: card focus moving"
        case .rowScroll: return "Console: the home row scrolling"
        case .sheetPresentation: return "A sheet opening"
        case .toastAppears: return "Console: a controller toast"
        }
    }

    /// How long after the scene appears the change starts: the before state is seen first.
    static let lead: TimeInterval = 0.6
}

extension GalleryFixtures {
    func motionView(_ motion: GalleryMotion, stores: LauncherStores, library: GameLibrary, launcher: (GalleryLauncher) -> AnyView) -> AnyView {
        let build = stores.build
        switch motion {
        case .startGame:
            let driver = MockConsoleDriver(scenario: .full, lang: lang, animated: true)
            dress(driver)
            let view = console(driver)
            return AnyView(GalleryMotionHost(play: { driver.play("demo.0") }) { view })
        case .cardFocus, .rowScroll:
            let driver = consoleDriver(.full)
            let steps = motion == .cardFocus ? 3 : 8
            let view = console(driver)
            return AnyView(GalleryMotionHost(play: {
                for step in 0..<steps {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * (motion == .cardFocus ? 0.5 : 0.3)) { driver.state.moveFocus(1) }
                }
            }) { view })
        case .toastAppears:
            let driver = consoleDriver(.full)
            let message = String(format: L10n.string("console.connected", lang), L10n.string("console.demoController2", lang), 2)
            let view = console(driver)
            return AnyView(GalleryMotionHost(play: { driver.state.toast = ConsoleToast(message: message) }) { view })
        case .buildFinishing:
            configureBuild(stores, library: library)
            let app = makeMacApp(for: 0, in: library)
            build.buildingGame = true
            build.running = true
            build.runningTarget = BuildTarget.mac
            build.overallProgress = 0.92
            build.stages = [Stage(id: 1, name: "Shaders", state: .done), Stage(id: 2, name: "Package", state: .running, detail: "", percent: 92)]
            let path = library.games.first { $0.id == app }?.appPath ?? ""
            let view = launcher(GalleryLauncher())
            return AnyView(GalleryMotionHost(play: {
                build.overallProgress = 1
                build.stages = [Stage(id: 1, name: "Shaders", state: .done), Stage(id: 2, name: "Package", state: .done)]
                build.macAppPath = path
                build.buildingGame = false
                build.running = false
                build.done = true
            }) { view })
        case .iconReveal:
            configureBuild(stores, library: library)
            build.buildingGame = true
            build.running = true
            build.overallProgress = 0
            build.stages = [Stage(id: 1, name: "Shaders", state: .running, detail: "0 / 50", percent: 0)]
            let view = launcher(GalleryLauncher(page: .builds, editor: true))
            return AnyView(GalleryMotionHost(play: {
                for step in 1...20 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.15) {
                        build.overallProgress = Double(step) / 20
                        build.stages = [Stage(id: 1, name: "Shaders", state: .running, detail: "\(step * 50 / 20) / 50", percent: Double(step * 5))]
                    }
                }
            }) { view })
        case .noticeAppears:
            let view = launcher(GalleryLauncher())
            return AnyView(GalleryMotionHost(play: { stores.engineSync.failure = BuildFailure(kind: .engineOffline, gameName: nil) }) { view })
        case .sheetPresentation:
            let game = library.games.first ?? LibraryGame(titleID: catalog[0].titleID, name: catalog[0].name)
            let back = launcher(GalleryLauncher())
            return AnyView(GallerySheetPresentation(background: back) { AnyView(RenameGameSheet(game: game)) })
        }
    }

    /// The preview driver with the gallery's games, animated (its start runs through its steps).
    private func dress(_ driver: MockConsoleDriver) {
        let dressed = consoleDriver(.full)
        driver.state.games = dressed.state.games
        driver.state.builds = ConsoleBuilds()
    }
}

/// Runs a scene's change once, `GalleryMotion.lead` after it appears, with no animation of its own: what moves is what the
/// launcher's views animate, at the scene's motion speed.
struct GalleryMotionHost<Content: View>: View {
    let play: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var played = false
    var body: some View {
        content().onAppear {
            guard !played else { return }
            played = true
            DispatchQueue.main.asyncAfter(deadline: .now() + GalleryMotion.lead) { play() }   // as the stores change it: the views animate it themselves
        }
    }
}

/// A sheet over the launcher as macOS opens it: the window dims and the sheet comes down from the title bar.
struct GallerySheetPresentation: View {
    let background: AnyView
    let sheet: () -> AnyView
    @State private var shown = false
    @Environment(\.dsMotionSpeed) private var speed
    var body: some View {
        ZStack(alignment: .top) {
            background
            if shown {
                Color.black.opacity(0.35).transition(.opacity)
                sheet()
                    .background(DS.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                    .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
                    .padding(.top, 28)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .clipped()
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + GalleryMotion.lead) {
                withAnimation(DS.Motion.animation(.easeOut(duration: 0.35), speed: speed)) { shown = true }
            }
        }
    }
}
