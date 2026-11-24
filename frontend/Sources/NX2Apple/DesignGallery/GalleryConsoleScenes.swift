import SwiftUI
import AppKit
import NXCore
import NXLauncher

/// Console mode's pages, questions and states beyond the home screen's scenes (GalleryScene.consoleScenes): every ConsoleSheet, each
/// game status's explanation, each step of a start, each state of the app's update, the button mapping's layouts, the filters of
/// All games and the controllers of every kind. Each one is the preview driver (MockConsoleDriver) in that state, on the gallery's games.
enum GalleryConsoleScene: String, CaseIterable {
    // a game that cannot start: what it needs, by its status
    case explainNeedsBuild, explainNeedsData, explainIphoneOnly, explainBroken
    // the start
    case startingPreparing, startingOpening
    // the home screen
    case homeFew, homePaused, homeToast, homeHint, homeStopped
    // the menu and its pages
    case menu, menuLibrary, menuOnlyBuilt, menuSettings, menuLanguage, supportedGames, cloudSaves, confirmExit
    case updateUpToDate, updateChecking, updateDownloading, updateReady, updateCannotInstall, updateWaiting, updateFailed, confirmUpdate
    // the button mapping
    case mappingStandard, mappingByLabel, mappingAuto, mappingCustom, mappingButton, mappingGame, confirmMapping
    // a game's options and pages over them
    case gamePad, advanced, confirmReset, manage, cloudSaveQuestion, cloudSaveUnreadable, mngMigration
    // All games and the search
    case allReady, allNotBuilt, allNeedsData, allByName, searchNoResults
    // the builds
    case confirmStopBuild, buildsStopping, buildsWarning, confirmQuitPaused
    // the controllers
    case controllersMixed

    var title: String {
        switch self {
        case .explainNeedsBuild: return "Explanation: not built"
        case .explainNeedsData: return "Explanation: game data missing"
        case .explainIphoneOnly: return "Explanation: iPhone only"
        case .explainBroken: return "Explanation: cannot start"
        case .startingPreparing: return "Starting: preparing"
        case .startingOpening: return "Starting: opening"
        case .homeFew: return "Home, two games"
        case .homePaused: return "Home, a game paused"
        case .homeToast: return "Home, a controller toast"
        case .homeHint: return "Home button hint"
        case .homeStopped: return "Stopped unexpectedly"
        case .menu: return "Menu"
        case .menuLibrary: return "Menu: Library"
        case .menuOnlyBuilt: return "Menu: Library, only built games"
        case .menuSettings: return "Menu: General, update available"
        case .menuLanguage: return "Menu: display language"
        case .supportedGames: return "Supported games"
        case .cloudSaves: return "Cloud saves: every state"
        case .confirmExit: return "Leave console mode?"
        case .updateUpToDate: return "Update: up to date"
        case .updateChecking: return "Update: checking"
        case .updateDownloading: return "Update: downloading"
        case .updateReady: return "Update: ready to restart"
        case .updateCannotInstall: return "Update: cannot install here"
        case .updateWaiting: return "Update: waits for a build"
        case .updateFailed: return "Update: failed"
        case .confirmUpdate: return "Install the update?"
        case .mappingStandard: return "Button mapping: Standard"
        case .mappingByLabel: return "Button mapping: By label"
        case .mappingAuto: return "Button mapping: Auto"
        case .mappingCustom: return "Button mapping: Custom"
        case .mappingButton: return "Button mapping: a button's choices"
        case .mappingGame: return "Button mapping: one game"
        case .confirmMapping: return "Button mapping: save changes?"
        case .gamePad: return "A game's controller settings"
        case .advanced: return "Advanced options"
        case .confirmReset: return "Reset this game's options?"
        case .manage: return "Manage a game"
        case .cloudSaveQuestion: return "Cloud save: both changed"
        case .cloudSaveUnreadable: return "Cloud save: cannot be read"
        case .mngMigration: return "MNG shared save: migration"
        case .allReady: return "All games: Ready on Mac"
        case .allNotBuilt: return "All games: Not built"
        case .allNeedsData: return "All games: Needs game data"
        case .allByName: return "All games: by name"
        case .searchNoResults: return "Search: no results"
        case .confirmStopBuild: return "Stop the build?"
        case .buildsStopping: return "Builds: stopping"
        case .buildsWarning: return "Builds: finished with an artwork warning"
        case .confirmQuitPaused: return "Quit the paused game?"
        case .controllersMixed: return "Controllers: every kind and battery"
        }
    }

    /// Where the sidebar lists it: the console's questions and pages, or its states.
    var group: GalleryScene.Group { self.rawValue.hasPrefix("update") || self == .confirmUpdate || rawValue.hasPrefix("mapping") || self == .confirmMapping ? .consolePages : .console }
}

extension GalleryFixtures {
    func consoleView(_ scene: GalleryConsoleScene) -> AnyView {
        let scenario: MockConsoleDriver.Scenario = {
            switch scene {
            case .homeFew: return .few
            case .homePaused, .confirmQuitPaused: return .paused
            case .controllersMixed: return .controllersMixed
            default: return .full
            }
        }()
        let driver = consoleDriver(scenario)
        let played = "demo.2"
        func t(_ key: String) -> String { L10n.string(key, lang) }
        func update(_ value: ConsoleAppUpdate, status: String = "") {
            driver.state.prefs.update = value
            driver.state.prefs.updateStatus = status
            driver.openMenu()
            driver.openSettings()
        }
        func explain(_ id: String) { driver.focus(id); driver.play(id) }
        let now = driver.state.time
        let name = driver.state.games.first { $0.id == played }?.title ?? ""
        switch scene {
        case .explainNeedsBuild: explain("demo.3")
        case .explainNeedsData: explain("demo.5")
        case .explainBroken: explain("demo.7")
        case .explainIphoneOnly: explain("demo.9")
        case .startingPreparing, .startingOpening:
            driver.state.play("demo.0")
            driver.state.starting = scene == .startingPreparing ? .preparing : .opening
        case .homeFew: break
        case .homePaused: break
        case .homeToast:
            driver.state.toast = ConsoleToast(message: String(format: t("console.connected"), t("console.demoController2"), 2))
        case .homeHint: driver.state.showHomeButtonHint()
        case .homeStopped: driver.state.showStopped(played, lastSave: now.addingTimeInterval(-540))
        case .menu: driver.openMenu()
        case .menuLibrary: driver.openMenu(); driver.openLibrary()
        case .menuOnlyBuilt: driver.setPref(.onlyBuilt, on: true); driver.openMenu(); driver.openLibrary()
        case .menuSettings: driver.openMenu(); driver.openSettings()
        case .menuLanguage: driver.openMenu(); driver.openSettings(); driver.openLanguage()
        case .supportedGames: driver.openMenu(); driver.openLibrary(); driver.openSupportedGames()
        case .cloudSaves: driver.openMenu(); driver.openLibrary(); driver.openCloudSaves()
        case .confirmExit: driver.confirmExit()
        case .updateUpToDate: update(.upToDate)
        case .updateChecking: update(.checking)
        case .updateDownloading: update(.downloading(42), status: "42 %")
        case .updateReady: update(.ready)
        case .updateCannotInstall: update(.cannotInstall("1.2.4"))
        case .updateWaiting: update(.waitingForBuild)
        case .updateFailed: update(.failed(tag: "v1.2.4", reason: "The Internet connection appears to be offline."))
        case .confirmUpdate: update(.available("1.2.4")); driver.appUpdateAction()
        case .mappingStandard, .mappingByLabel, .mappingAuto, .mappingCustom, .mappingButton, .confirmMapping:
            driver.openMenu()
            driver.openMapping()
            switch scene {
            case .mappingByLabel: driver.setPadMode(.byLabel)
            case .mappingAuto: driver.setPadMode(.auto)
            case .mappingCustom: driver.setPadSends(button: "A", to: "B"); driver.setPadSends(button: "B", to: "A")
            case .mappingButton: driver.openMappingRow("ZL")
            case .confirmMapping: driver.setPadSends(button: "X", to: "Y"); driver.state.push(.confirmMapping)
            default: break
            }
        case .mappingGame: driver.openOptions(played); driver.openGamePad(played); driver.openGameMapping(played)
        case .gamePad: driver.openOptions(played); driver.openGamePad(played)
        case .advanced: driver.openOptions(played); driver.openAdvanced(played)
        case .confirmReset:
            driver.setOption(gameID: played, setting: "DM_FPS_TARGET", value: "30")
            driver.openOptions(played)
            driver.askResetOptions(played)
        case .manage: driver.openGamePage(played); driver.openManage(played)
        case .cloudSaveQuestion, .cloudSaveUnreadable:
            let backups = directory
            let question = scene == .cloudSaveQuestion
                ? CloudSaveQuestion(gameName: name, outcome: .bothChanged, local: .init(hash: "a", saved: now.addingTimeInterval(-20 * 60)),
                                    cloud: .init(hash: "b", saved: now.addingTimeInterval(-26 * 3600), device: "iPhone17,1"), reason: nil, backups: backups)
                : CloudSaveQuestion(gameName: name, outcome: .unreadable, local: .init(hash: "a", saved: now), cloud: nil,
                                    reason: "The Internet connection appears to be offline.", backups: backups)
            driver.state.askCloudSave(question)
        case .mngMigration:
            let mngSource = directory.appendingPathComponent("MacNativeGames/TOTK/profile/save/53574e415449564578626c0000000001")
            let nxTarget = directory.appendingPathComponent("Saves/0100F2C0115B6000")
            driver.state.askMngMigration(
                MngMigrationQuestion(
                    titleID: GalleryFixtures.mngTitleID,
                    gameName: name,
                    appPath: directory.appendingPathComponent("\(name).app").path,
                    assessment: .bothHaveSaves(
                        mngSource: mngSource,
                        nxTarget: nxTarget,
                        nxExisting: nxTarget,
                        mngFiles: 12,
                        mngNewest: now.addingTimeInterval(-3600),
                        nxFiles: 8,
                        nxNewest: now.addingTimeInterval(-120)
                    )
                )
            )
        case .allReady, .allNotBuilt, .allNeedsData, .allByName:
            driver.openAllGames()
            driver.state.libraryFilter = [GalleryConsoleScene.allReady: ConsoleLibraryFilter.readyOnMac, .allNotBuilt: .notBuilt, .allNeedsData: .needsData][scene] ?? .all
            if scene == .allByName { driver.toggleLibrarySort() }
        case .searchNoResults: driver.openSearch(); driver.typeSearch("Zebra")
        case .confirmStopBuild: driver.state.builds = builds(driver, "running"); driver.openBuilds(); driver.askStopBuild()
        case .buildsStopping: driver.state.builds = builds(driver, "running"); driver.openBuilds(); driver.state.builds.stopping = true
        case .buildsWarning:
            driver.state.builds = ConsoleBuilds(queue: [queueRow(driver, 3, status: "queue.status.done", outcome: .warning),
                                                        queueRow(driver, 5, status: "queue.status.done", outcome: .success)])
            driver.openBuilds()
        case .confirmQuitPaused: driver.state.askQuitPaused(then: .play("demo.0"))
        case .controllersMixed: break
        }
        return console(driver)
    }
}
