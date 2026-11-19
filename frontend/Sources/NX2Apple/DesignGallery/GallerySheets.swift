import SwiftUI
import AppKit
import NXCore
import NXModel
import NXLauncher

/// The desktop's sheets and dialogs in the state gallery and the design captures (GalleryScene.sheet), each step and state of
/// each one, drawn on the fixture stores. A sheet is drawn at the size it takes (`size` nil): as wide as its frame and as high as
/// its content, exactly as it opens over the launcher. A sheet that scrolls keeps its own fixed size.
enum GallerySheet: String, CaseIterable {
    case deleteGame, deleteGameSaves, deleteGameNothing, deleteGameMeasuring
    case removeGame
    case controllersSheet
    case controlsSheet, controlsDiscard

    var title: String {
        switch self {
        case .deleteGame: return "Delete game"
        case .deleteGameSaves: return "Delete game: with saves"
        case .deleteGameNothing: return "Delete game: nothing on this Mac"
        case .deleteGameMeasuring: return "Delete game: measuring"
        case .removeGame: return "Remove from library"
        case .controllersSheet: return "Controllers"
        case .controlsSheet: return "Keyboard controls"
        case .controlsDiscard: return "Keyboard controls: discard changes"
        }
    }

    /// nil: the sheet's own size (its width, its content's height). A sheet with a scrolling list has a fixed one.
    var size: CGSize? {
        switch self {
        case .controllersSheet: return CGSize(width: 680, height: 720)   // console mode's view (ConsoleControllersView.swift), not this pass
        case .controlsSheet: return CGSize(width: 600, height: 700)
        default: return nil
        }
    }
}

extension GalleryFixtures {
    /// The example of what the Delete sheet lists: every part a built game can have, with sizes, no files.
    private func deletionPlan(_ game: LibraryGame) -> GameDeletion {
        let out = "/Volumes/Games/" + game.name, id = game.titleID
        return GameDeletion(titleID: id, items: [
            .init(kind: .macApp, paths: [out + "/\(game.name).app"], bytes: 14_600_000_000),
            .init(kind: .ipa, paths: [out + "/\(id).ipa"], bytes: 380_000_000),
            .init(kind: .archive, paths: [out + "/games/\(id)"], bytes: 11_200_000_000),
            .init(kind: .shellFramework, paths: [], bytes: 0),
            .init(kind: .buildFolder, paths: [out + "/\(id)_build/extract"], bytes: 18_900_000_000),
            .init(kind: .log, paths: [out + "/log/\(id).log"], bytes: 2_400_000)],
            saves: .init(kind: .saves, paths: [out + "/save/\(id)"], bytes: 1_200_000), shellRoot: "/Volumes/Games/NX2Apple-shell")
    }

    func sheetView(_ sheet: GallerySheet, stores: LauncherStores, library: GameLibrary, controls: ControlLayout) -> AnyView {
        let game = library.games.first ?? LibraryGame(titleID: catalog[0].titleID, name: catalog[0].name)
        let icon = GameLibrary.appIcon(for: game, banners: library.artworkDirectory)
        switch sheet {
        case .deleteGame, .deleteGameSaves:
            return AnyView(DeleteGameSheet(game: game, shellRoot: "", icon: icon, plan: deletionPlan(game), saves: sheet == .deleteGameSaves))
        case .deleteGameNothing:
            return AnyView(DeleteGameSheet(game: game, shellRoot: "", icon: icon, plan: GameDeletion(titleID: game.titleID, items: [], saves: nil, shellRoot: nil)))
        case .deleteGameMeasuring:
            return AnyView(DeleteGameSheet(game: game, shellRoot: "", icon: icon, measures: false))
        case .removeGame:
            return AnyView(LauncherConfirmSheet(subject: .game(icon), title: stores.localizer.t("library.removeQuestion"), subtitle: game.displayName(lang),
                                                note: stores.localizer.t("library.removeNote"), cancelTitle: stores.localizer.t("saves.cancel"),
                                                confirmTitle: stores.localizer.t("library.remove"), destructive: true, scope: "remove", cancel: {}, confirm: {}))
        case .controllersSheet:
            return AnyView(ConsoleControllersSheet(driver: MockConsoleDriver(scenario: .controllers, lang: lang, animated: false), lang: lang, close: {}))
        case .controlsSheet:
            return AnyView(ControlsView(layout: controls))
        case .controlsDiscard:
            return AnyView(LauncherConfirmSheet(title: stores.localizer.t("controls.discardTitle"), subtitle: "", note: stores.localizer.t("controls.discardNote"),
                                                cancelTitle: stores.localizer.t("controls.keepEditing"), confirmTitle: stores.localizer.t("controls.discard"),
                                                destructive: true, scope: "controldiscard", cancel: {}, confirm: {}))
        }
    }
}
