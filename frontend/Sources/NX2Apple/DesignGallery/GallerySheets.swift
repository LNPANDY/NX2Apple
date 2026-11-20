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
    case saves, saveImport
    case skippedItems, appUpdate, playerName, playerRename, buildSteps, sendSelectedDevice, shellCopy
    case cheats, invalidXcode

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
        case .saves: return "Saves: Mac and iPhone"
        case .saveImport: return "Import a save"
        case .skippedItems: return "Skipped files"
        case .appUpdate: return "App update"
        case .playerName: return "New player"
        case .playerRename: return "Rename a player"
        case .buildSteps: return "Build steps"
        case .sendSelectedDevice: return "Send game data: no shared app"
        case .shellCopy: return "Copy game data: USB link speed"
        case .cheats: return "Cheats: no files yet"
        case .invalidXcode: return "Chosen app is not Xcode"
        }
    }

    /// nil: the sheet's own size (its width, its content's height). A sheet with a scrolling list has a fixed one.
    var size: CGSize? {
        switch self {
        case .controlsSheet: return CGSize(width: 600, height: 700)
        case .freeSpace, .freeSpaceMeasuring: return CGSize(width: 560, height: 690)
        case .buildSelected, .buildSelectedEmpty: return CGSize(width: 680, height: 720)
        case .supportedGames, .supportedGamesExpanded, .batchRefresh: return CGSize(width: 680, height: 720)
        case .saves: return CGSize(width: 600, height: 560)
        case .buildSteps: return CGSize(width: 600, height: 440)
        case .cheats: return CGSize(width: 600, height: 700)
        case .sendSelectedDevice: return CGSize(width: 680, height: 720)
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
        let t = stores.localizer.t
        func confirm(_ title: String, subtitle: String = "", note: String = "", cancel: String = "saves.cancel",
                     _ action: String, destructive: Bool = true) -> AnyView {
            AnyView(LauncherConfirmSheet(title: title, subtitle: subtitle, note: note, cancelTitle: t(cancel), confirmTitle: action,
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
            return AnyView(DeleteGameSheet(game: game, shellRoot: "", plan: deletionPlan(game), saves: sheet == .deleteGameSaves))
        case .deleteGameNothing:
            return AnyView(DeleteGameSheet(game: game, shellRoot: "", plan: GameDeletion(titleID: game.titleID, items: [], saves: nil, shellRoot: nil)))
        case .deleteGameMeasuring:
            return AnyView(DeleteGameSheet(game: game, shellRoot: "", measures: false))
        case .removeGame:
            return confirm(t("library.removeQuestion"), subtitle: name, note: t("library.removeNote"), t("library.remove"))
        case .controllersSheet:
            return AnyView(ConsoleControllersSheet(driver: MockConsoleDriver(scenario: .controllers, lang: lang, animated: false), lang: lang, close: {}))
        case .controlsSheet:
            return AnyView(ControlsView(layout: controls))
        case .controlsDiscard:
            return confirm(t("controls.discardTitle"), note: t("controls.discardNote"), cancel: "controls.keepEditing", t("controls.discard"))
        case .cloudFetching, .cloudFetchingLong:
            return AnyView(CloudSaveSheet(gate: cloudGate(.fetching(gameName: name, long: sheet == .cloudFetchingLong), titleID: game.titleID)))
        case .cloudChoose, .cloudChosen:
            return AnyView(CloudSaveSheet(gate: cloudGate(.asking(differ), titleID: game.titleID), picked: sheet == .cloudChosen ? .cloud : nil))
        case .cloudUnreadable:
            return AnyView(CloudSaveSheet(gate: cloudGate(.asking(unreadable), titleID: game.titleID)))
        case .freeSpace:
            return AnyView(FreeSpaceView(m: stores.build, game: game, survey: survey(game), chosen: [.extracted, .oldShaders]))
        case .freeSpaceMeasuring:
            return AnyView(FreeSpaceView(m: stores.build, game: game, survey: nil, measures: false))
        case .freeSpaceConfirm:
            return confirm(String(format: t("free.confirm"), FreeSpaceView.bytes(14_200_000_000)), subtitle: name,
                           note: [t("free.confirmNote"), t("free.cost.extracted"), t("free.cost.oldShaders")].joined(separator: "\n"), t("free.confirmButton"))
        case .buildFilesRemove:
            return AnyView(BuildFilesRemoveSheet(entry: BuildFilesStore.Entry(id: game.id, name: name, folder: "/Volumes/Games/\(game.name)/\(game.titleID)_build",
                                                                              bytes: 18_900_000_000), cancel: {}, confirm: {}))
        case .confirmUninstall:
            return confirm(t("uninstall.title"), note: t("uninstall.confirm"), t("uninstall.confirmButton"))
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
            return confirm(t("flow.cancelTitle"), subtitle: name, note: t("flow.cancelNote"), t("flow.cancel"))
        case .rename, .renameCustom:
            var named = game
            if sheet == .renameCustom { named.customName = "Orchard" }
            return AnyView(RenameGameSheet(game: named))
        case .buildSelected, .buildSelectedEmpty:
            let source = sheet == .buildSelectedEmpty ? GameLibrary(file: directory.appendingPathComponent("empty-\(UUID().uuidString).json"), artwork: artworkFolder) : library
            return AnyView(BuildSelectedSheet(library: source, queue: stores.queue, engineID: stores.engineSync.selection.engineID, close: {}))
        case .supportedGames, .supportedGamesExpanded:
            let supported = catalog.enumerated().map { index, entry in
                SupportedGame(titleID: entry.titleID, name: entry.name, edition: .switch1, version: index % 3 == 0 ? nil : "1.\(index).0",
                              notes: index == 0 ? "Runs at full speed. The first start compiles its shaders, which takes a few minutes." : "")
            }
            return AnyView(SupportedGamesSheet(games: supported, owned: { id in library.games.first { $0.titleID.uppercased() == id.uppercased() } },
                                               covers: .saved(in: library.artworkDirectory, maxPixel: SupportedGamesSheet.coverPixels), showInLibrary: { _ in },
                                               // the first two stand in for profiles improved in this release, the first with an older build
                                               olderBuild: { $0 == library.games.first?.id }, appVersion: "1.5.0",
                                               improved: { id in supported.prefix(2).contains { $0.titleID == id } },
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
                                                libraryFolder: library.folder, onResolvedImg: { _ in }, onFallbackFullRebuild: {}, close: {}))
        case .saves:   // no device is asked: a devicectl stand-in that answers nothing and the devices the launcher knows (none)
            return AnyView(SavesView(m: stores.build, library: library, gameID: game.id, devicectl: DeviceControl { _ in (false, "") },
                                     support: directory.appendingPathComponent("support", isDirectory: true), listDevices: { [] }))
        case .saveImport:
            return AnyView(SaveImportSheet(gameName: name, source: "/Users/Shared/Exports/\(game.name) save.zip",
                                           target: "/Volumes/Games/\(game.name)/save/\(game.titleID)", cancel: {}, confirm: {}))
        case .skippedItems:
            let items = [
                SkippedLibraryItem(path: "/Volumes/Games/Update v3.nsp", name: "Update v3.nsp", rootPath: "/Volumes/Games", reason: .orphanSupplement(titleID: "0100000000990800")),
                SkippedLibraryItem(path: "/Volumes/Games/\(game.name).rar", name: "\(game.name).rar", rootPath: "/Volumes/Games", reason: .unextractedArchiveOrSplit),
            ]
            return AnyView(SkippedLibraryItemsOverlay(items: items, openKeysSettings: {}, close: {}, panelOnly: true))
        case .appUpdate:
            stores.appUpdates.update = AppUpdate.Release(tag: "v1.2.0", url: "", digest: nil,
                                                         notes: "## What is new\n\n- Sheets show the game they are about.\n- Return never deletes a game.\n- The Controllers sheet keeps its toasts at the bottom.")
            return AnyView(UpdateSheet(updates: stores.appUpdates, build: stores.build))
        case .playerName, .playerRename:
            let renaming = sheet == .playerRename ? (stores.players.profiles.first ?? stores.players.create(name: "Alex")) : nil
            return AnyView(PlayerNameSheet(players: stores.players, renaming: renaming, close: {}))
        case .buildSteps:
            stores.build.stages = [Stage(id: 1, name: "Extract", state: .done), Stage(id: 2, name: "Romfs", state: .done),
                                   Stage(id: 3, name: "Shaders", state: .running, detail: "31 / 50", percent: 62), Stage(id: 4, name: "Package", state: .pending)]
            return AnyView(BuildProcessStepsSheet(build: stores.build, close: {}))
        case .sendSelectedDevice:
            return AnyView(SendSelectedSheet(mode: .device, build: stores.build, close: {}))
        case .shellCopy:
            let plan = ShellCopyPlan(
                files: 2,
                bytes: 15_000_000_000,
                connection: .wired,
                linkProfile: .usb2(bps: 480_000_000),
                deviceName: "iPhone",
                sizeText: String(format: t("shell.copySize"), "15.0 GB", 2),
                connectionText: String(format: t("shell.copyUSB2"), "480 Mbps", "15.0 GB", 7, 9, "iPhone")
            )
            return AnyView(ShellCopySheet(devices: stores.deviceStore, previewPlan: plan))
        case .cheats:
            return AnyView(CheatsView(m: stores.build, library: library, gameID: game.id))
        case .invalidXcode:   // Settings › Tools, Choose… with an app that is not Xcode (ToolsCard)
            return AnyView(DSSheet(title: t("xcodeChoice.invalid")) { EmptyView() } buttons: { DSSheetPrimaryButton(t("library.ok")) {} })
        case .confirmTestedValues:
            return confirm(t("launch.useTested"), subtitle: name, note: String(format: t("launch.useTestedMany"), 3), t("launch.useTested"), destructive: false)
        }
    }
}
