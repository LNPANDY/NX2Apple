import SwiftUI
import NXCore
import NXLauncher

/// The question on top, in the middle of the screen over what it was asked from (ConsoleQuestion): leaving console mode, saving the
/// button mapping's changes, resetting a game's options, the app's update, stopping a build, quitting a paused game (#952) and the
/// screen after a crash (#816). The focus starts on the safe answer (ConsoleView.resetFocus).
@MainActor struct ConsoleQuestionLayer<Driver: ConsoleDriver>: View {
    @ObservedObject var driver: Driver
    let lang: Lang
    let compact: Bool
    @EnvironmentObject private var pad: PadFocus
    private var state: ConsoleState { driver.state }
    private func t(_ key: String) -> String { L10n.string(key, lang) }

    var body: some View {
        switch state.presentedSheet {
        case let .confirmReset(id)?:
            ConsoleQuestion(compact: compact, symbol: "arrow.counterclockwise", title: t("console.reset.ask"), message: t("console.reset.askBody"),
                            scope: "console.confirmReset",
                            other: (t("console.exit.cancel"), "console.confirmReset.cancel", { driver.back() }),
                            main: (t("console.reset.confirm"), "console.confirmReset.reset", { driver.resetOptions(id) }))
                .padScope("console.confirmReset", pad)
        case .confirmUpdate?:
            let ready = state.prefs.update == .ready
            let tag: String = {
                switch state.prefs.update { case let .available(tag), let .failed(tag, _): return tag; default: return "" }
            }()
            ConsoleQuestion(compact: compact, symbol: "arrow.down.app", title: ready ? t("console.update.restartAsk") : String(format: t("console.update.ask"), tag),
                            message: t(ready ? "console.update.restartBody" : "console.update.askBody"), scope: "console.confirmUpdate",
                            other: (t("console.exit.cancel"), "console.confirmUpdate.cancel", { driver.back() }),
                            main: (t(ready ? "app.restartNow" : "console.update.install"), "console.confirmUpdate.go", { driver.confirmAppUpdate() }))
                .padScope("console.confirmUpdate", pad)
        case .confirmMapping?:
            ConsoleQuestion(compact: compact, symbol: "arrow.left.arrow.right", title: t("console.mapping.saveTitle"), message: t("console.mapping.saveBody"),
                            scope: "console.confirmMapping",
                            other: (t("console.mapping.discard"), "console.confirmMapping.discard", { driver.finishMapping(save: false) }),
                            main: (t("console.mapping.save"), "console.confirmMapping.save", { driver.finishMapping(save: true) }))
                .padScope("console.confirmMapping", pad)
        case .confirmStopBuild?:
            ConsoleQuestion(compact: compact, symbol: "stop.circle", title: t("console.builds.stopAsk"), message: t("console.builds.stopBody"),
                            scope: "console.confirmStop",
                            other: (t("console.exit.cancel"), "console.confirmStop.cancel", { driver.back() }),
                            main: (t("btn.stop"), "console.confirmStop.stop", { driver.stopBuild() }))
                .padScope("console.confirmStop", pad)
        case .confirmQuitPaused?:
            let name = state.pausedGame?.title ?? ""
            ConsoleQuestion(compact: compact, symbol: "xmark.circle", title: String(format: t("homeQuit.title"), name),
                            message: state.quittingPaused ? t("console.quitting") : t("homeQuit.note"),
                            scope: "console.confirmQuitPaused",
                            other: (t("console.exit.cancel"), "console.confirmQuitPaused.cancel", { driver.back() }),
                            main: (t("homeQuit.quit"), "console.confirmQuitPaused.quit", { driver.quitPausedGame() }))
                .padScope("console.confirmQuitPaused", pad)
        case .stopped?:
            let game = state.stopped.flatMap { stopped in state.games.first { $0.id == stopped.gameID } }
            let saved = state.stopped?.lastSave.map { String(format: t("console.stopped.lastSave"), ConsoleTimes.absolute($0, lang: lang)) }
            ConsoleQuestion(compact: compact, symbol: "exclamationmark.triangle", title: String(format: t("console.stopped.title"), game?.title ?? ""),
                            message: saved ?? t("console.stopped.noSave"), scope: "console.stopped",
                            other: (t("console.stopped.back"), "console.stopped.back", { driver.back() }),
                            main: (t("console.stopped.again"), "console.stopped.again", { if let id = game?.id { driver.play(id) } }))
                .padScope("console.stopped", pad)
        default:
            ConsoleQuestion(compact: compact, symbol: "rectangle.portrait.and.arrow.right", title: t("console.exit.title"), message: t("console.exit.body"),
                            scope: "console.confirmExit",
                            other: (t("console.exit.cancel"), "console.confirmExit.cancel", { driver.back() }),
                            main: (t("console.exit.confirm"), "console.confirmExit.leave", { driver.exitToDesktop() }))
                .padScope("console.confirmExit", pad)
        }
    }
}
