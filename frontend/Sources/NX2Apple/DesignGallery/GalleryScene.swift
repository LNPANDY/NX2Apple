import Foundation
import NXCore

/// Every view and state of the launcher the state gallery (LNPANDY/NX2Apple#1459) and the design captures show. GalleryFixtures builds
/// each one with fixture data. The titles are English only: the gallery is a developer window that ships to no player.
enum GalleryScene: Hashable, Identifiable, CaseIterable {
    // Library
    case libraryGames, libraryFew, libraryEmpty, libraryNarrow, libraryWidescreen
    case libraryEngineSyncing, libraryEngineUpdate, libraryNoticeWarning, libraryNoticeError, librarySwitch2, libraryGatekeeper
    // All games
    case allGames, allGamesSearch, allGamesNoResults
    // A game's launch options
    case gameOptions
    // Builds and the build wizard
    case addGame, gamePage, wizardPlatform, wizardInstall, buildsIdle, buildsRunning, buildsQueued, buildsSetupHint, buildFailed
    case addGameFound, addGamePartial, buildOneStage, buildMultiStage, buildFinishedMac, buildFinishedIOS
    case buildFailure(BuildFailureKind)
    // Settings
    case settings, settingsLibrary, settingsControls, settingsTools, settingsEngineError
    // Sheets
    case sheet(GallerySheet)
    // The first run
    case onboarding(MockOnboardingDriver.Scenario), onboardingState(OnboardingGalleryState)
    // Console mode
    case consoleHome, consoleHomeTV, consoleHomeBuilding, consoleEmpty
    case consoleGamePage, consoleGameOverviewEmpty, consoleGameSaves, consoleGameSavesEmpty, consoleGameBuild, consoleGameBuildEmpty, consoleGameCheats, consoleGameCheatsEmpty
    case consoleOptions, consoleOptionsMin, consoleOptionsMax, consoleOptionsStepperFocus, consoleOptionsNavFocus, consoleOptionsSingleLanguage
    case consoleBuilds, consoleBuildsQueued, consoleBuildsFinished, consoleBuildsFailed, consoleBuildsEmpty
    case consoleControllers, consoleControllersAssigned, consoleSearch, consoleQuickMenu, consoleStarting, consoleStartingCloud

    // The design system's own check scenes
    case cardStates

    /// Console mode's scenes, in the gallery's order, with their titles.
    static let consoleScenes: [(scene: GalleryScene, title: String)] = [
        (.consoleHome, "Home"), (.consoleHomeTV, "Home at 1600 x 1000"), (.consoleHomeBuilding, "Home, a build running"), (.consoleEmpty, "Empty"),
        (.consoleGamePage, "Game page: Overview"), (.consoleGameOverviewEmpty, "Game page: Overview, not built"),
        (.consoleGameSaves, "Game page: Saves"), (.consoleGameSavesEmpty, "Game page: Saves, none yet"),
        (.consoleGameBuild, "Game page: Build"), (.consoleGameBuildEmpty, "Game page: Build, not built"),
        (.consoleGameCheats, "Game page: Cheats"), (.consoleGameCheatsEmpty, "Game page: Cheats, none"),
        (.consoleOptions, "Options panel"), (.consoleOptionsMin, "Options: values at the minimum"), (.consoleOptionsMax, "Options: values at the maximum"),
        (.consoleOptionsStepperFocus, "Options: focus on a stepper"), (.consoleOptionsNavFocus, "Options: focus on a link row"),
        (.consoleOptionsSingleLanguage, "Options: one language"),
        (.consoleBuilds, "Builds: running"), (.consoleBuildsQueued, "Builds: several queued"), (.consoleBuildsFinished, "Builds: finished"),
        (.consoleBuildsFailed, "Builds: failed"), (.consoleBuildsEmpty, "Builds: empty"),
        (.consoleControllers, "Controllers: waiting for a button"), (.consoleControllersAssigned, "Controllers: player assigned"),
        (.consoleSearch, "Search"), (.consoleQuickMenu, "Quick menu"), (.consoleStarting, "Starting a game"), (.consoleStartingCloud, "Starting: cloud save"),
    ]

    enum Group: String, CaseIterable, Identifiable {
        case library = "Library", allGames = "All games", gameOptions = "Game options", builds = "Builds", failures = "Build failures"
        case settings = "Settings", sheets = "Sheets", onboarding = "Onboarding", console = "Console mode", design = "Design system"
        var id: String { rawValue }
    }

    static var allCases: [GalleryScene] {
        [.libraryGames, .libraryFew, .libraryEmpty, .libraryNarrow, .libraryWidescreen,
         .libraryEngineSyncing, .libraryEngineUpdate, .libraryNoticeWarning, .libraryNoticeError, .librarySwitch2, .libraryGatekeeper,
         .allGames, .allGamesSearch, .allGamesNoResults, .gameOptions,
         .addGame, .addGameFound, .addGamePartial, .gamePage, .wizardPlatform, .wizardInstall, .buildsIdle, .buildsRunning,
         .buildOneStage, .buildMultiStage, .buildsQueued, .buildFinishedMac, .buildFinishedIOS, .buildsSetupHint, .buildFailed]
        + BuildFailureKind.allCases.filter { $0 != .diskFull }.map(GalleryScene.buildFailure)
        + [.settings, .settingsLibrary, .settingsControls, .settingsTools, .settingsEngineError]
        + GallerySheet.allCases.map(GalleryScene.sheet)
        + onboardingScenes
        + consoleScenes.map(\.scene)
        + [.cardStates]
    }

    /// A stable name: the file name of its capture and the gallery's selection.
    var id: String {
        switch self {
        case .buildFailure(let kind): return "buildFailure-" + kind.rawValue
        case .onboarding(let scenario): return "onboarding-" + scenario.rawValue
        case .sheet(let sheet): return sheet.rawValue
        case .onboardingState(let state): return "onboarding-" + state.rawValue
        default: return String(describing: self)
        }
    }

    var group: Group {
        switch self {
        case .libraryGames, .libraryFew, .libraryEmpty, .libraryNarrow, .libraryWidescreen, .libraryEngineSyncing, .libraryEngineUpdate,
             .libraryNoticeWarning, .libraryNoticeError, .librarySwitch2, .libraryGatekeeper: return .library
        case .allGames, .allGamesSearch, .allGamesNoResults: return .allGames
        case .gameOptions: return .gameOptions
        case .addGame, .gamePage, .wizardPlatform, .wizardInstall, .buildsIdle, .buildsRunning, .buildsQueued, .buildsSetupHint,
             .addGameFound, .addGamePartial, .buildOneStage, .buildMultiStage, .buildFinishedMac, .buildFinishedIOS: return .builds
        case .buildFailed, .buildFailure: return .failures
        case .settings, .settingsLibrary, .settingsControls, .settingsTools, .settingsEngineError: return .settings
        case .sheet: return .sheets
        case .onboarding, .onboardingState: return .onboarding
        case .cardStates: return .design
        default: return .console   // consoleScenes
        }
    }

    var title: String {
        switch self {
        case .libraryGames: return "Recently played, Show all"
        case .libraryFew: return "Few games, no Show all"
        case .libraryEmpty: return "Empty library"
        case .libraryNarrow: return "Narrowest window"
        case .libraryWidescreen: return "Widescreen game"
        case .libraryEngineSyncing: return "Notice: engine syncing"
        case .libraryEngineUpdate: return "Notice: engine update"
        case .libraryNoticeWarning: return "Notice: skipped files"
        case .libraryNoticeError: return "Notice: engine failed"
        case .librarySwitch2: return "Notice: Switch 2 content"
        case .libraryGatekeeper: return "Notice: first launch check"
        case .allGames: return "Grid"
        case .allGamesSearch: return "Search results"
        case .allGamesNoResults: return "No results"
        case .gameOptions: return "Launch options"
        case .addGame: return "Add game: nothing chosen"
        case .addGameFound: return "Add game: folder, all found"
        case .addGamePartial: return "Add game: keys missing"
        case .buildOneStage: return "Building: one stage"
        case .buildMultiStage: return "Building: several stages"
        case .buildFinishedMac: return "Finished: Mac"
        case .buildFinishedIOS: return "Finished: iPhone"
        case .gamePage: return "Wizard: game files"
        case .wizardPlatform: return "Wizard: platform"
        case .wizardInstall: return "Wizard: install"
        case .buildsIdle: return "Builds"
        case .buildsRunning: return "Build running, footer"
        case .buildsQueued: return "Several queued"
        case .buildsSetupHint: return "Setup missing"
        case .buildFailed: return "diskFull"
        case .buildFailure(let kind): return kind.rawValue
        case .settings: return "General"
        case .settingsLibrary: return "Library"
        case .settingsControls: return "Controls"
        case .settingsTools: return "Tools"
        case .settingsEngineError: return "Engine failed"
        case .sheet(let sheet): return sheet.title
        case .onboarding(let scenario): return scenario.galleryTitle
        case .onboardingState(let state): return state.title
        case .cardStates: return "Card and row states"
        default: return Self.consoleScenes.first { $0.scene == self }?.title ?? id
        }
    }

    /// The launcher's ideal width at a common laptop height.
    static let size = CGSize(width: 1280, height: 800)
    /// The scene's own size: a sheet keeps the sheet's, the narrow scene the smallest window.
    var size: CGSize {
        switch self {
        case .libraryNarrow: return CGSize(width: 900, height: 680)
        case .consoleHomeTV: return CGSize(width: 1600, height: 1000)
        case .gameOptions: return CGSize(width: 680, height: 720)
        case .sheet(let sheet): return sheet.size ?? CGSize(width: 680, height: 720)
        default: return Self.size
        }
    }
    /// Whether the gallery's size presets apply (a sheet keeps its size).
    var resizable: Bool {
        if case .sheet = self { return false }
        return ![.gameOptions, .libraryNarrow].contains(self)
    }
    /// A sheet: drawn without the window's title bar, as it opens over the launcher.
    var isSheet: Bool { if case .sheet = self { return true } else { return false } }
    /// A sheet drawn at the size it takes: as wide as its frame, as high as its content (GallerySheet.size nil).
    var fitsContent: Bool {
        if case .sheet(let sheet) = self { return sheet.size == nil }
        return false
    }

    /// How many of the fixture games the scene's library holds.
    var gameCount: Int {
        switch self {
        case .libraryEmpty: return 0
        case .libraryFew: return 6
        default: return GalleryFixtures.games.count
        }
    }
}
