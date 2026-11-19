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
    case cloudFetching, cloudFetchingLong, cloudChoose, cloudChosen, cloudUnreadable
    case freeSpace, freeSpaceMeasuring, freeSpaceConfirm, buildFilesRemove
    case confirmUninstall, confirmEngineChannel, confirmStaleFrameworks, confirmBuildAnyway, confirmRemovePlayer
    case confirmCancelQueue, confirmCancelDraft, confirmTestedValues
    case rename, renameCustom, buildSelected, buildSelectedEmpty, supportedGames, supportedGamesExpanded
    case batchRefresh, batchRefreshEmpty, imgGuide, imgGuideNoPackage

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
        case .cloudFetching: return "Cloud save: fetching"
        case .cloudFetchingLong: return "Cloud save: fetching, long"
        case .cloudChoose: return "Cloud save: choose"
        case .cloudChosen: return "Cloud save: one chosen"
        case .cloudUnreadable: return "Cloud save: unreadable"
        case .freeSpace: return "Free space"
        case .freeSpaceMeasuring: return "Free space: measuring"
        case .freeSpaceConfirm: return "Free space: confirm"
        case .buildFilesRemove: return "Remove build files"
        case .confirmUninstall: return "Uninstall the app"
        case .confirmEngineChannel: return "Switch the engine channel"
        case .confirmStaleFrameworks: return "Build installed games again"
        case .confirmBuildAnyway: return "Build anyway"
        case .confirmRemovePlayer: return "Remove a player"
        case .confirmCancelQueue: return "Cancel the queue"
        case .confirmCancelDraft: return "Cancel a build draft"
        case .confirmTestedValues: return "Use tested values"
        case .rename: return "Rename"
        case .renameCustom: return "Rename: own name set"
        case .buildSelected: return "Build selected games"
        case .buildSelectedEmpty: return "Build selected games: none"
        case .supportedGames: return "Supported games"
        case .supportedGamesExpanded: return "Supported games: notes open"
        case .batchRefresh: return "Refresh games: fast and full"
        case .batchRefreshEmpty: return "Refresh games: nothing to refresh"
        case .imgGuide: return "Game data for iOS missing"
        case .imgGuideNoPackage: return "Game data for iOS missing: no package"
        }
    }

    /// nil: the sheet's own size (its width, its content's height). A sheet with a scrolling list has a fixed one.
    var size: CGSize? {
        switch self {
        case .controllersSheet: return CGSize(width: 680, height: 720)   // console mode's view (ConsoleControllersView.swift), not this pass
        case .controlsSheet: return CGSize(width: 600, height: 700)
        case .freeSpace, .freeSpaceMeasuring: return CGSize(width: 560, height: 690)
        case .buildSelected, .buildSelectedEmpty: return CGSize(width: 680, height: 720)
        case .supportedGames, .supportedGamesExpanded, .batchRefresh: return CGSize(width: 680, height: 720)
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

    /// A build folder as the Free space sheet measures it: example sizes, no files.
    private func survey(_ game: LibraryGame) -> BuildFolderSurvey {
        BuildFolderSurvey(folder: "/Volumes/Games/\(game.name)/\(game.titleID)_build",
                          sizes: [.extracted: 9_800_000_000, .shaders: 5_850_000_000, .oldShaders: 4_400_000_000, .xcode: 2_100_000_000, .caches: 610_000_000],
                          kept: 48_000_000,
                          oldShaders: [OldShaderVersion(name: "b-157e1b96c8da", bytes: 2_100_000_000), OldShaderVersion(name: "b-a78f966a7b38", bytes: 2_300_000_000)])
    }

    private func cloudGate(_ step: CloudSaveStep, titleID: String) -> CloudSaveGate {
        let gate = CloudSaveGate()
        gate.step = step
        gate.qaTitleID = titleID
        return gate
    }

    func sheetView(_ sheet: GallerySheet, stores: LauncherStores, library: GameLibrary, controls: ControlLayout) -> AnyView {
        let game = library.games.first ?? LibraryGame(titleID: catalog[0].titleID, name: catalog[0].name)
        let name = game.displayName(lang)
        let icon = GameLibrary.appIcon(for: game, banners: library.artworkDirectory)
        let t = stores.localizer.t
        func confirm(subject: DSSheetSubject? = nil, _ title: String, subtitle: String = "", note: String = "", cancel: String = "saves.cancel",
                     _ action: String, destructive: Bool = true) -> AnyView {
            AnyView(LauncherConfirmSheet(subject: subject, title: title, subtitle: subtitle, note: note, cancelTitle: t(cancel), confirmTitle: action,
                                         destructive: destructive, scope: "gallery", cancel: {}, confirm: {}))
        }
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let differ = CloudSaveQuestion(gameName: name, outcome: .bothChanged, local: .init(hash: "a", saved: now.addingTimeInterval(-20 * 60)),
                                       cloud: .init(hash: "b", saved: now.addingTimeInterval(-26 * 3600), device: "iPhone17,1"), reason: nil,
                                       backups: directory)
        let unreadable = CloudSaveQuestion(gameName: name, outcome: .unreadable, local: .init(hash: "a", saved: now), cloud: nil,
                                           reason: "The Internet connection appears to be offline.", backups: directory)
        switch sheet {
        case .deleteGame, .deleteGameSaves:
            return AnyView(DeleteGameSheet(game: game, shellRoot: "", icon: icon, plan: deletionPlan(game), saves: sheet == .deleteGameSaves))
        case .deleteGameNothing:
            return AnyView(DeleteGameSheet(game: game, shellRoot: "", icon: icon, plan: GameDeletion(titleID: game.titleID, items: [], saves: nil, shellRoot: nil)))
        case .deleteGameMeasuring:
            return AnyView(DeleteGameSheet(game: game, shellRoot: "", icon: icon, measures: false))
        case .removeGame:
            return confirm(subject: .game(icon), t("library.removeQuestion"), subtitle: name, note: t("library.removeNote"), t("library.remove"))
        case .controllersSheet:
            return AnyView(ConsoleControllersSheet(driver: MockConsoleDriver(scenario: .controllers, lang: lang, animated: false), lang: lang, close: {}))
        case .controlsSheet:
            return AnyView(ControlsView(layout: controls))
        case .controlsDiscard:
            return confirm(t("controls.discardTitle"), note: t("controls.discardNote"), cancel: "controls.keepEditing", t("controls.discard"))
        case .cloudFetching, .cloudFetchingLong:
            return AnyView(CloudSaveSheet(gate: cloudGate(.fetching(gameName: name, long: sheet == .cloudFetchingLong), titleID: game.titleID), icon: { _ in icon }))
        case .cloudChoose, .cloudChosen:
            return AnyView(CloudSaveSheet(gate: cloudGate(.asking(differ), titleID: game.titleID), icon: { _ in icon }, picked: sheet == .cloudChosen ? .cloud : nil))
        case .cloudUnreadable:
            return AnyView(CloudSaveSheet(gate: cloudGate(.asking(unreadable), titleID: game.titleID), icon: { _ in icon }))
        case .freeSpace:
            return AnyView(FreeSpaceView(m: stores.build, game: game, icon: icon, survey: survey(game), chosen: [.extracted, .oldShaders]))
        case .freeSpaceMeasuring:
            return AnyView(FreeSpaceView(m: stores.build, game: game, icon: icon, survey: nil, measures: false))
        case .freeSpaceConfirm:
            return confirm(subject: .game(icon), String(format: t("free.confirm"), FreeSpaceView.bytes(14_200_000_000)), subtitle: name,
                           note: [t("free.confirmNote"), t("free.cost.extracted"), t("free.cost.oldShaders")].joined(separator: "\n"), t("free.confirmButton"))
        case .buildFilesRemove:
            return AnyView(BuildFilesRemoveSheet(entry: BuildFilesStore.Entry(id: game.id, name: name, folder: "/Volumes/Games/\(game.name)/\(game.titleID)_build",
                                                                              bytes: 18_900_000_000), subject: .game(icon), cancel: {}, confirm: {}))
        case .confirmUninstall:
            return confirm(subject: .app, t("uninstall.title"), note: t("uninstall.confirm"), t("uninstall.confirmButton"))
        case .confirmEngineChannel:
            return confirm(t("engine.switch.title"), note: t("engine.switch.toExperimental"), cancel: "engine.switch.cancel",
                           String(format: t("engine.switch.go"), t("engine.channel.experimental")), destructive: false)
        case .confirmStaleFrameworks:
            return confirm(t("stale.title"), note: String(format: t("stale.message"), "Lantern Coast, Paper Comet"), cancel: "stale.stop", t("stale.go"), destructive: false)
        case .confirmBuildAnyway:
            return confirm(t("fail.confirm.title"), note: t("fail.shaderRegression.risk"), cancel: "fail.confirm.cancel", t("fail.confirm.go"), destructive: false)
        case .confirmRemovePlayer:
            return confirm(String(format: t("players.removeAsk"), "Alex"), note: t("players.removeNote"), cancel: "players.cancel", t("players.remove"))
        case .confirmCancelQueue:
            return confirm(String(format: t("queue.cancelConfirm"), 3), cancel: "queue.keep", t("queue.cancel"))
        case .confirmCancelDraft:
            return confirm(subject: .game(icon), t("flow.cancelTitle"), subtitle: name, note: t("flow.cancelNote"), t("flow.cancel"))
        case .rename, .renameCustom:
            var named = game
            if sheet == .renameCustom { named.customName = "Orchard" }
            return AnyView(RenameGameSheet(game: named, icon: icon))
        case .buildSelected, .buildSelectedEmpty:
            let source = sheet == .buildSelectedEmpty ? GameLibrary(file: directory.appendingPathComponent("empty-\(UUID().uuidString).json"), artwork: artworkFolder) : library
            return AnyView(BuildSelectedSheet(library: source, queue: stores.queue, engineID: stores.engineSync.selection.engineID, close: {}))
        case .supportedGames, .supportedGamesExpanded:
            let supported = catalog.enumerated().map { index, entry in
                SupportedGame(titleID: entry.titleID, name: entry.name, edition: .switch1, version: index % 3 == 0 ? nil : "1.\(index).0",
                              notes: index == 0 ? "Runs at full speed. The first start compiles its shaders, which takes a few minutes." : "", fullScreen: index % 4 == 1)
            }
            return AnyView(SupportedGamesSheet(games: supported, owned: { id in library.games.first { $0.titleID.uppercased() == id.uppercased() } },
                                               covers: .saved(in: library.artworkDirectory, maxPixel: SupportedGamesSheet.coverPixels), showInLibrary: { _ in },
                                               expanded: sheet == .supportedGamesExpanded ? supported.first?.titleID : nil))
        case .batchRefresh, .batchRefreshEmpty:
            var assessments: [UUID: GameRefreshAssessment] = [:]
            if sheet == .batchRefresh {
                for (index, entry) in library.games.prefix(5).enumerated() {
                    assessments[entry.id] = GameRefreshAssessment(heroState: .generalSync(fast: index < 2), hasSpecificUpdate: index == 2, versionLabel: "1.2.0",
                                                                  canFastRefreshMac: index < 2, canFastRefreshIOS: index == 0, needsMissingImgGuideIOS: index == 3,
                                                                  missingOriginalPackage: index == 4, hasUsableSeed: index < 2)
                }
            }
            return AnyView(BatchRefreshSheet(library: library, toolsAge: ToolsAge(assessments: assessments), stores: stores, onConfirmed: {}, close: {}))
        case .imgGuide, .imgGuideNoPackage:
            let assessment = GameRefreshAssessment(heroState: .generalSync(fast: false), hasSpecificUpdate: false, versionLabel: "1.2.0",
                                                   canFastRefreshMac: false, canFastRefreshIOS: false, needsMissingImgGuideIOS: true,
                                                   missingOriginalPackage: sheet == .imgGuideNoPackage)
            return AnyView(MissingImgGuideSheet(context: MissingImgGuideContext(game: game, assessment: assessment), stores: stores, devices: stores.deviceStore,
                                                libraryFolder: library.folder, onResolvedImg: { _ in }, onFallbackFullRebuild: {}, close: {}, icon: icon))
        case .confirmTestedValues:
            return confirm(subject: .game(icon), t("launch.useTested"), subtitle: name, note: String(format: t("launch.useTestedMany"), 3), t("launch.useTested"), destructive: false)
        }
    }
}
