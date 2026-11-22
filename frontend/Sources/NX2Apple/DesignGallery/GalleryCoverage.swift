import Foundation
import NXCore
import NXModel

/// What the state gallery shows (LNPANDY/NX2Apple#1459): for every View type of the launcher (NX2Apple and NXLauncher), every
/// sheet, popover and alert it presents, every notice and every case of the state enums the views switch on, the scenes that show
/// it, or a short reason why none can. `GalleryCoverageTests` reads the sources and fails for anything without either, and writes
/// COVERAGE.md (next to this file) from these tables. A new view, sheet or state gets a scene here, or a reason.
enum GalleryCoverage {
    /// The state enums the views switch on: the file, the enum's name with its containers, and the name the tables use.
    static let stateEnums: [(file: String, path: String)] = [
        ("NX2Apple/LauncherPage.swift", "LauncherPage"), ("NX2Apple/SettingsCategory.swift", "SettingsCategory"),
        ("NX2Apple/LauncherPage.swift", "LibraryFilter"), ("NX2Apple/LauncherPage.swift", "LibrarySort"),
        ("NX2Apple/Library.swift", "LibraryGame.Primary"), ("NX2Apple/LibraryArtworkState.swift", "LibraryArtworkState.Attention"),
        ("NXCore/GameUpdateCatalog.swift", "HeroRefreshState"), ("NX2Apple/ArtworkSlots.swift", "ArtworkSlot"),
        ("NX2Apple/ArtworkEditor.swift", "ArtworkEditor.LoadState"), ("NX2Apple/ArtworkEditor.swift", "ArtworkEditor.Notice"),
        ("NXCore/BuildProgress.swift", "StepState"), ("NXModel/BuildStore+Completion.swift", "BuildCompletionStatus"),
        ("NXCore/BuildFailureKind.swift", "BuildFailureKind"), ("NXModel/BuildStore+Send.swift", "DataSend"),
        ("NXCore/BuildQueue.swift", "QueueEntry.Status"), ("NXCore/TransferQueue.swift", "TransferEntry.Status"),
        ("NXCore/ActiveOperation.swift", "ActiveOperation.Kind"), ("NXLauncher/SendSelectedSheet.swift", "SendSelectedSheet.Mode"),
        ("NXModel/AppUpdateStore.swift", "AppUpdateStore.Phase"), ("NXCore/EngineUpdater.swift", "EngineChannel"),
        ("NXModel/BuildStore+Nxkit.swift", "NxkitUpdateState"), ("NXCore/NxkitUpdate.swift", "NxkitUpdate.Rejection"),
        ("NXCore/NxkitBuilder.swift", "NxkitBuilder.Availability"), ("NXModel/BuildStore+Nxkit.swift", "NxkitFeedbackPrompt.Moment"),
        ("NX2Apple/CloudSaveGate.swift", "CloudSaveStep"), ("NX2Apple/SaveDiscovery.swift", "SavesModel.DeviceState"),
        ("NX2Apple/FreeSpace.swift", "FreeSpaceError"), ("NX2Apple/GameDeletion.swift", "GameDeletion.Item.Kind"),
        ("NX2Apple/OnboardingState.swift", "OnboardingStep"), ("NX2Apple/OnboardingState.swift", "OnboardingState.Welcome"),
        ("NX2Apple/OnboardingState.swift", "OnboardingState.Platform"), ("NX2Apple/OnboardingState.swift", "OnboardingState.Xcode"),
        ("NX2Apple/OnboardingState.swift", "OnboardingState.Keys"), ("NX2Apple/OnboardingState.swift", "OnboardingState.Games"),
        ("NX2Apple/OnboardingState.swift", "OnboardingState.Done"), ("NX2Apple/OnboardingState.swift", "OnboardingTaskState"),
        ("NX2Apple/MockOnboardingDriver.swift", "MockOnboardingDriver.Scenario"),
        ("NX2Apple/ConsoleState.swift", "ConsoleSheet"), ("NX2Apple/ConsoleState.swift", "ConsoleGame.Status"),
        ("NX2Apple/ConsoleState.swift", "ConsoleStarting"), ("NX2Apple/ConsoleState.swift", "ConsoleController.Kind"),
        ("NX2Apple/ConsoleState+Pages.swift", "ConsoleGameTab"), ("NX2Apple/ConsoleState+Pages.swift", "ConsoleLibraryFilter"),
        ("NX2Apple/ConsoleState+Pages.swift", "ConsoleBuilds.ArtworkOutcome"), ("NX2Apple/ConsoleCloudSaves.swift", "ConsoleSaveStatus"),
        ("NX2Apple/ConsoleExtras.swift", "ConsoleAppUpdate"), ("NX2Apple/ControlPresets.swift", "PadMode"),
        ("NX2Apple/MockConsoleDriver.swift", "MockConsoleDriver.Scenario"),
    ]

    private typealias D = GalleryDesktopScene
    private typealias C = GalleryConsoleScene
    private typealias O = OnboardingGalleryState

    /// Every view type of NX2Apple and NXLauncher (the gallery's own excepted) and the scenes that show it.
    static let views: [String: [GalleryScene]] = [
        // the launcher's window, the library and its hero
        "LauncherView": [.libraryGames], "CardPages": [.buildsIdle, .settings], "LauncherGlassGroup": [.libraryGames],
        "LauncherIconButton": [.libraryGames], "LauncherTopBarRule": [.libraryGames], "PlayerPicker": [.libraryGames],
        "LauncherDropdownLayer": [.libraryGames], "LibraryCardKeyboardActions": [.libraryGames], "LauncherActionButton": [.libraryGames],
        "LauncherHeroActionLabel": [.libraryGames, .desktop(D.heroPlay)], "ArtworkFill": [.libraryGames, .consoleHome],
        "LibraryGameCard": [.libraryGames, .cardStates], "DSCardButton": [.cardStates], "DSCard": [.cardStates],
        "LibraryArtworkChip": [.desktop(D.cardEveryState)], "ArtworkStatusChip": [.desktop(D.cardEveryState)],
        "LibraryProfileChip": [.desktop(D.heroUnverified)], "LibraryCarouselPlaceholder": [.libraryEmpty, .desktop(D.noArtwork)],
        "LibraryFallbackArtwork": [.desktop(D.noArtwork)], "LauncherNoticeStack": [.libraryEngineUpdate, .libraryNoticeWarning],
        "LauncherNotice": [.buildsSetupHint], "DSSpinner": [.libraryEngineSyncing], "EngineSyncBanner": [.libraryNoticeError, .settingsEngineError],
        "ManageMenuPanel": [.desktop(D.manageMenu), .desktop(D.manageMenuPad)], "ArtworkPanel": [.desktop(D.artworkHero), .desktop(D.artworkThumbnail)],
        "SkeletonTile": [.desktop(D.artworkLoading)], "ConsoleConnectionPrompt": [.desktop(D.consolePrompt)],
        "ConsoleToastView": [.desktop(D.controllerToast), .console(C.homeToast)], "NxkitFeedbackRow": [.nxkitFinished, .nxkitLibrary],
        "BuildActivityFooter": [.buildsRunning, .desktop(D.footerExporting)], "BuildProgressRevealMask": [.buildsRunning, .motion(.iconReveal)],
        "BuildCompletionTimerStroke": [.desktop(D.buildJustFinished), .motion(.buildFinishing)], "LauncherWordmark": [.onboarding(.fresh)],
        // the build page
        "BuildPage": [.buildsIdle, .gamePage], "LauncherPageScroll": [.buildsIdle],
        "EngineSwitcherCard": [.buildsIdle, .nxkitFailed, .desktop(D.mngRecommend), .desktop(D.mngRecommendInstalled)],
        "EngineDropdownPanel": [.desktop(D.engineDropdown)], "LauncherCustomDropdownBox": [.desktop(D.engineDropdown)],
        "EngineExperimentalBadge": [.desktop(D.engineDropdown)], "UpstreamVersionPill": [.buildsIdle, .desktop(D.engineDropdown)],
        "FilesCard": [.addGameFound, .addGamePartial], "FileRow": [.addGameFound], "FileRowDivider": [.addGameFound],
        "LauncherInfoHelp": [.addGameFound], "ActionCard": [.addGameFound], "TargetCard": [.gamePage, .wizardPlatform],
        "InstallCard": [.wizardInstall], "RefreshDevicesButton": [.wizardInstall], "LauncherBrandMark": [.wizardInstall],
        "BuildMetadataHero": [.buildOneStage, .buildMultiStage], "BuildIconReveal": [.buildOneStage, .motion(.iconReveal)],
        "BuildProcessCard": [.buildMultiStage], "BuildProcessRows": [.buildMultiStage], "CardDisclosure": [.buildOneStage],
        "ProgressCard": [.buildsRunning, .nxkitFailed], "LauncherProgressBar": [.buildsRunning], "BuildUpNextSection": [.buildsQueued, .desktop(D.queueRunning)],
        "BuildQueueHero": [.desktop(D.queueRunning)], "QueueArtworkStack": [.desktop(D.queueRunning), .buildsQueued],
        "BuildQueueCard": [.desktop(D.queueEveryState)], "BuildPlatformChip": [.desktop(D.queueEveryState), .sheet(.buildSelected)],
        "ArtworkOutcomeBadge": [.desktop(D.queueEveryState)], "OutcomeCard": [.buildFinishedMac, .buildFinishedIOS],
        "ExportSteps": [.desktop(D.completionExported), .desktop(D.sendSent)], "FinderCopySteps": [.buildFailure(.shellDataIncomplete)],
        "BuildFailureCard": [.buildFailed, .buildFailure(.rosetta)], "FailureTitleRow": [.buildFailure(.severalGames)],
        "SetupHintCard": [.buildsSetupHint], "TransferCard": [.desktop(D.transfersEveryState)], "LogCard": [.desktop(D.logOpen)],
        "BuildLogView": [.desktop(D.logOpen)], "ShellCopyCard": [.desktop(D.sendSending)],
        // Settings
        "SettingsPage": [.settings, .settingsTools], "LauncherStickyPageScroll": [.settings], "CardPageHeading": [.settings],
        "CardGroup": [.settings], "CardRow": [.settings], "CardDivider": [.settings], "LauncherSegmented": [.settings],
        "LauncherSecondaryButton": [.settings], "AppCard": [.settings, .desktop(D.appAvailable)], "SettingsUpdateAction": [.desktop(D.appAvailable)],
        "PersonalDefaultsCard": [.settings], "MissingToolRow": [.desktop(D.missingTool)], "LibraryFoldersCard": [.settingsLibrary, .desktop(D.libraryFolders)],
        "GlobalSavesCard": [.settingsLibrary], "CloudSavesCard": [.settingsLibrary, .gameOptions], "PlayersCard": [.desktop(D.players)],
        "ControlsCard": [.settingsControls], "StickDeadzoneCard": [.settingsControls], "StickVisualizer": [.settingsControls],
        "KeysCard": [.settingsTools], "ToolsCard": [.settingsTools], "ShellCacheRow": [.settingsTools], "CacheFolderRow": [.settingsTools], "BuildCacheRows": [.settingsTools], "DiagnosticsButton": [.settingsTools],
        "BuildFilesCard": [.settingsTools], "DSOverflowMenu": [.settingsTools], "LauncherDropdown": [.settingsTools, .settings],
        "UpstreamPicker": [.nxkitEngine, .desktop(D.mngBlocked)], "UpstreamBuilderRow": [.desktop(D.mngUpdateAvailable), .desktop(D.mngBlocked), .desktop(D.mngDownloadingSettings)],
        "DSRowMessageView": [.nxkitUnavailable, .desktop(D.nxkitUnreachable)],
        "LauncherDropdownList": [.desktop(D.dropdownList), .desktop(D.mngDropdownDisabled), .desktop(D.mngDownloadOffered)], "Hosted": [.settings, .settingsTools],
        // sheets and dialogs
        "LauncherConfirmSheet": [.sheet(.removeGame)], "DSSheet": [.sheet(.removeGame), .sheet(.rename)], "DSSheetConfirmButtons": [.sheet(.removeGame)],
        "DSSheetHeader": [.sheet(.batchRefresh), .sheet(.appUpdate)], "DSSheetButtonRow": [.sheet(.batchRefresh)], "DSSheetPrimaryButton": [.sheet(.rename)],
        "DSScrollingSheet": [.sheet(.saves), .sheet(.controlsSheet)], "DSPathText": [.sheet(.freeSpace)], "DSInlineWarning": [.sheet(.cloudUnreadable)],
        "DSTag": [.sheet(.supportedGames), .sheet(.cheats), .desktop(D.mngLibrary), .desktop(D.mngUpdateAvailable)], "DSTextButton": [.sheet(.buildSteps), .settingsTools],
        "DeleteGameSheet": [.sheet(.deleteGame), .desktop(D.deleteGameIOS)], "RenameGameSheet": [.sheet(.rename)],
        "ConsoleControllersSheet": [.sheet(.controllersSheet)], "ControlsView": [.sheet(.controlsSheet)], "PadModeSection": [.sheet(.controlsSheet)],
        "ControllerMappingStatus": [.sheet(.controlsSheet)], "SteamControllerSection": [.sheet(.controlsSheet)],
        "CloudSaveSheet": [.sheet(.cloudChoose), .sheet(.cloudFetching)], "CloudSyncConflictSheet": [.sheet(.cloudSyncConflict)], "FreeSpaceView": [.sheet(.freeSpace), .desktop(D.freeSpaceRunning)],
        "BuildFilesRemoveSheet": [.sheet(.buildFilesRemove)], "BuildSelectedSheet": [.sheet(.buildSelected)],
        "SupportedGamesSheet": [.sheet(.supportedGames)], "SupportedGameRow": [.sheet(.supportedGames)], "BatchRefreshSheet": [.sheet(.batchRefresh)],
        "MissingImgGuideSheet": [.sheet(.imgGuide)], "SavesView": [.sheet(.saves), .desktop(D.savesReady)], "SaveImportSheet": [.sheet(.saveImport)],
        "SkippedLibraryItemsOverlay": [.sheet(.skippedItems)], "SkippedItemRow": [.sheet(.skippedItems)], "UpdateSheet": [.sheet(.appUpdate)],
        "PlayerNameSheet": [.sheet(.playerName)], "BuildProcessStepsSheet": [.sheet(.buildSteps)],
        "SendSelectedSheet": [.sheet(.sendSelectedDevice), .desktop(D.sendSelectedDrive)], "ShellCopySheet": [.sheet(.shellCopy)], "CheatsView": [.sheet(.cheats)],
        "LaunchOptionsView": [.gameOptions], "ChangedLabel": [.gameOptions], "GameSavesSection": [.gameOptions], "LauncherSlider": [.gameOptions],
        "GameControllerMappingView": [.desktop(D.controllerMapping)], "FrameTimesRecordingView": [.desktop(D.frameTimes)],
        // the first run
        "OnboardingDemoHost": [.onboarding(.fresh)], "OnboardingView": [.onboarding(.fresh)], "DSWizardFooter": [.onboarding(.fresh)],
        "DSContinueLabel": [.onboarding(.fresh)], "LauncherTargetOptionLabel": [.onboardingState(O.platformChosen)],
        "OnboardingStatusRow": [.onboardingState(O.xcodeSettingUp)], "OnboardingStatusIcon": [.onboardingState(O.xcodeSettingUp)],
        "OnboardingRowDivider": [.onboardingState(O.xcodeSettingUp)], "OnboardingKeysContent": [.onboardingState(O.keysFound)],
        "OnboardingKeysHelp": [.onboardingState(O.keysEmpty)], "OnboardingGamesContent": [.onboardingState(O.gamesFound)],
        "OnboardingDropZone": [.onboardingState(O.gamesEmpty)], "OnboardingCheck": [.onboardingState(O.done)],
        // console mode
        "ConsoleView": [.consoleHome], "ConsoleHomeScreen": [.consoleHome], "ConsoleBackdrop": [.consoleHome], "ConsoleClock": [.consoleHome],
        "ConsoleHint": [.consoleHome], "ConsoleGlyphView": [.consoleHome], "ConsoleHeaderButton": [.consoleHome], "ConsoleControllerButton": [.consoleHome],
        "ConsolePlayersChip": [.console(C.controllersMixed), .consoleHome], "ConsoleGameTile": [.consoleHome], "ConsoleArtwork": [.consoleHome],
        "ConsoleBuildIndicator": [.consoleHomeBuilding], "ConsolePrimaryButton": [.console(C.explainNeedsBuild), .console(C.homeStopped)],
        "ConsoleLaunchProgress": [.consoleStarting, .console(C.startingOpening)], "ConsoleCloudSaveView": [.console(C.cloudSaveQuestion)],
        "ConsoleQuestionLayer": [.console(C.confirmExit)], "ConsoleQuestion": [.console(C.confirmExit), .console(C.confirmStopBuild)],
        "ConsoleAllGamesPage": [.consoleAllGames], "ConsoleGridTile": [.consoleAllGames], "ConsoleSearchPage": [.consoleSearch],
        "ConsoleKeyButton": [.consoleSearch], "ConsoleSegmentedControl": [.consoleGamePage, .consoleAllGames],
        "ConsoleGamePage": [.consoleGamePage], "ConsoleStatsCard": [.consoleGamePage], "ConsoleCheatsSection": [.consoleGameCheats],
        "ConsoleSwitchRow": [.consoleGameCheats], "ConsoleManagePanel": [.console(C.manage)], "ConsoleGameOptionsList": [.consoleOptions],
        "ConsoleOptionRow": [.consoleOptions], "ConsoleValueStepper": [.consoleOptions], "ConsoleSwitch": [.consoleOptions, .console(C.mappingStandard)],
        "ConsolePageLayout": [.consoleOptions], "ConsoleArtColumn": [.consoleOptions], "ConsoleHintBar": [.consoleOptions],
        "ConsoleSectionHeading": [.consoleOptions], "ConsoleFocused": [.consoleOptionsStepperFocus], "ConsoleMenuRow": [.console(C.menu)],
        "ConsoleAdvancedList": [.console(C.advanced)], "ConsoleGamePadPage": [.console(C.gamePad)], "ConsoleLibraryList": [.console(C.menuLibrary)],
        "ConsoleSettingsList": [.console(C.menuSettings)], "ConsolePageHeader": [.console(C.supportedGames), .console(C.cloudSaves)],
        "ConsoleSupportedGamesPage": [.console(C.supportedGames)], "ConsoleCloudSavesPage": [.console(C.cloudSaves)],
        "ConsolePadMappingSheet": [.console(C.mappingStandard), .console(C.mappingCustom)], "ConsolePadDiagram": [.console(C.mappingCustom)],
        "ConsolePadGlyph": [.console(C.mappingCustom)], "ChangedDot": [.console(C.mappingCustom)],
        "ConsoleBuildsPage": [.consoleBuilds], "ConsoleProgressBar": [.consoleBuilds], "ConsoleGroupedList": [.consoleBuilds, .consoleGamePage],
        "ConsoleListRow": [.consoleBuilds], "ConsoleRowDivider": [.consoleBuilds], "ConsoleInfoRow": [.consoleGamePage],
        "ConsoleToggleListRow": [.consoleControllers], "ConsoleNoticeCard": [.consoleBuildsEmpty, .consoleGameOverviewEmpty],
        "ConsoleQuickMenu": [.consoleQuickMenu], "ConsoleControllerList": [.consoleControllers], "ConsoleFlatButton": [.consoleControllers],
        "ConsoleBattery": [.console(C.controllersMixed)], "BatteryIcon": [.console(C.controllersMixed)],
    ]

    /// Every sheet, popover and alert, by "<file> <modifier> <the view it presents>", and the scenes that show it.
    static let presentations: [String: [GalleryScene]] = [
        "LauncherView.swift .sheet ConsoleControllersSheet": [.sheet(.controllersSheet)],
        "LauncherView.swift .sheet LauncherConfirmSheet": [.sheet(.removeGame)],
        "LauncherView.swift .sheet LaunchOptionsView": [.gameOptions],
        "LauncherView.swift .sheet ControlsView": [.sheet(.controlsSheet)],
        "LauncherView.swift .sheet FreeSpaceView": [.sheet(.freeSpace)],
        "LauncherView.swift .sheet BuildSelectedSheet": [.sheet(.buildSelected)],
        "LauncherView.swift .sheet SupportedGamesSheet": [.sheet(.supportedGames)],
        "LauncherView.swift .sheet UpdateSheet": [.sheet(.appUpdate)],
        "LauncherView.swift .sheet LauncherConfirmSheet 2": [.sheet(.confirmUninstall)],
        "LauncherView.swift .sheet SavesView": [.sheet(.saves)],
        "BuildFiles.swift .sheet BuildFilesRemoveSheet": [.sheet(.buildFilesRemove)],
        "LaunchOptionsView.swift .sheet LauncherConfirmSheet": [.sheet(.confirmTestedValues)],
        "LaunchOptionsView.swift .sheet GameControllerMappingView": [.desktop(D.controllerMapping)],
        "BuildPage.swift .sheet BuildProcessStepsSheet": [.sheet(.buildSteps)],
        "BuildPage.swift .sheet LauncherConfirmSheet": [.sheet(.confirmCancelDraft)],
        "BuildPage.swift .sheet LauncherConfirmSheet 2": [.sheet(.confirmCancelQueue)],
        "Controls.swift .sheet LauncherConfirmSheet": [.sheet(.controlsDiscard)],
        "FreeSpace.swift .sheet LauncherConfirmSheet": [.sheet(.freeSpaceConfirm)],
        "GameSavesSection.swift .sheet SaveImportSheet": [.sheet(.saveImport)],
        "MissingImgGuideSheet.swift .sheet BatchRefreshSheet": [.sheet(.batchRefresh)],
        "MissingImgGuideSheet.swift .sheet MissingImgGuideSheet": [.sheet(.imgGuide)],
        "BuildFailureCard.swift .sheet LauncherConfirmSheet": [.sheet(.confirmBuildAnyway)],
        "ToolsCard.swift .sheet DSSheet": [.sheet(.invalidXcode)],
        "ToolsCard.swift .sheet LauncherConfirmSheet": [.sheet(.confirmEngineChannel)],
        "StaleFrameworksPrompt.swift .sheet LauncherConfirmSheet": [.sheet(.confirmStaleFrameworks)],
        "InstallCard.swift .sheet SendSelectedSheet": [.sheet(.sendSelectedDevice)],
        "ExportSteps.swift .sheet SendSelectedSheet": [.desktop(D.sendSelectedDrive)],
        "ShellCopySheet.swift .sheet ShellCopySheet": [.sheet(.shellCopy)],
        "PlayersCard.swift .sheet PlayerNameSheet": [.sheet(.playerName)],
        "PlayersCard.swift .sheet LauncherConfirmSheet": [.sheet(.confirmRemovePlayer)],
        "CloudSavesCard.swift .sheet CloudSyncConflictSheet": [.sheet(.cloudSyncConflict)],
    ]

    /// The launcher's notices (LauncherNoticeItem), by id.
    static let notices: [String: [GalleryScene]] = [
        "engine.failure": [.libraryNoticeError, .settingsEngineError], "engine.syncing": [.libraryEngineSyncing],
        "library.skippedBanner": [.libraryNoticeWarning], "hero.signature": [.desktop(D.heroSignature)], "hero.refresh": [.libraryEngineUpdate],
        "hero.switch2": [.librarySwitch2], "hero.gatekeeper": [.libraryGatekeeper], "hero.resign": [.desktop(D.heroResign)],
        "build.setup": [.buildsSetupHint],
    ]

    /// Every case of `stateEnums`, as "<enum>.<case>", and the scenes that show it.
    static var states: [String: [GalleryScene]] {
        var map: [String: [GalleryScene]] = [:]
        func add(_ name: String, _ cases: [String: [GalleryScene]]) { for (key, scenes) in cases { map[name + "." + key] = scenes } }
        add("LauncherPage", ["library": [.libraryGames], "builds": [.buildsIdle], "settings": [.settings]])
        add("SettingsCategory", ["general": [.settings], "library": [.settingsLibrary], "controls": [.settingsControls], "tools": [.settingsTools]])
        add("LibraryFilter", ["owned": [.desktop(D.filterOwned)], "built": [.console(C.menuOnlyBuilt)], "mac": [.desktop(D.filterMac)], "ios": [.desktop(D.filterIOS)]])
        add("LibrarySort", ["recent": [.allGames], "name": [.desktop(D.sortName)]])
        add("LibraryGame.Primary", ["play": [.desktop(D.heroPlay)], "openOnDevice": [.desktop(D.heroOnDevice)], "build": [.libraryGames]])
        add("LibraryArtworkState.Attention", ["none": [.desktop(D.cardEveryState)], "notBuilt": [.desktop(D.cardEveryState)],
                                              "missingData": [.desktop(D.cardEveryState), .libraryGames], "fixFiles": [.desktop(D.cardEveryState)],
                                              "building": [.desktop(D.cardEveryState)]])
        add("HeroRefreshState", ["upToDate": [.desktop(D.heroPlay)], "specificFast": [.desktop(D.heroRefreshFast)],
                                 "specificFull": [.desktop(D.heroRefreshFull)], "generalSync": [.libraryEngineUpdate]])
        add("ArtworkSlot", ["hero": [.desktop(D.artworkHero)], "thumbnail": [.desktop(D.artworkThumbnail)]])
        add("ArtworkEditor.LoadState", ["loading": [.desktop(D.artworkLoading)], "loaded": [.desktop(D.artworkHero)],
                                        "offline": [.desktop(D.artworkOffline)], "none": [.desktop(D.artworkNoScreenshots)]])
        add("ArtworkEditor.Notice", ["warning": [.desktop(D.artworkWarning)], "error": [.desktop(D.artworkError)]])
        add("StepState", ["pending": [.buildMultiStage], "running": [.buildMultiStage], "done": [.buildMultiStage], "failed": [.nxkitFailed]])
        add("BuildCompletionStatus", ["mac": [.buildFinishedMac], "installed": [.buildFinishedIOS], "exported": [.desktop(D.completionExported)],
                                      "needsData": [.desktop(D.completionNeedsData)]])
        for kind in BuildFailureKind.allCases { map["BuildFailureKind." + kind.rawValue] = kind == .diskFull ? [.buildFailed] : [.buildFailure(kind)] }
        add("DataSend", ["idle": [.desktop(D.completionExported)], "sending": [.desktop(D.sendSending)], "sent": [.desktop(D.sendSent)],
                         "appNotFound": [.desktop(D.sendAppNotFound)], "chooseApp": [.desktop(D.sendChooseApp)], "refused": [.desktop(D.sendRefused)],
                         "failed": [.desktop(D.sendFailed)], "copying": [.desktop(D.sendCopying)], "copied": [.desktop(D.sendCopied)]])
        add("QueueEntry.Status", ["queued": [.desktop(D.queueEveryState), .buildsQueued], "running": [.desktop(D.queueRunning)],
                                  "done": [.desktop(D.queueEveryState)], "failed": [.desktop(D.queueEveryState)],
                                  "skipped": [.desktop(D.queueEveryState)], "stopped": [.desktop(D.queueEveryState)]])
        add("TransferEntry.Status", Dictionary(uniqueKeysWithValues: ["queued", "sending", "waiting", "failed", "done", "cancelling"]
            .map { ($0, [GalleryScene.desktop(D.transfersEveryState)]) }))
        add("ActiveOperation.Kind", ["building": [.buildsRunning], "verifyingFirstStart": [.desktop(D.footerVerifying)],
                                     "exportingIPA": [.desktop(D.footerExporting)], "installing": [.desktop(D.footerInstalling)],
                                     "renewingSignature": [.desktop(D.footerRenewing)], "sendingGameData": [.desktop(D.footerSending)]])
        add("SendSelectedSheet.Mode", ["device": [.sheet(.sendSelectedDevice)], "drive": [.desktop(D.sendSelectedDrive)]])
        add("AppUpdateStore.Phase", ["idle": [.settings, .desktop(D.appAvailable)], "checking": [.desktop(D.appChecking)],
                                     "downloading": [.desktop(D.appDownloading)], "preparing": [.desktop(D.appPreparing)]])
        add("EngineChannel", ["stable": [.settingsTools], "experimental": [.desktop(D.engineExperimental)]])
        add("NxkitUpdateState", ["idle": [.desktop(D.nxkitIdle)], "checking": [.desktop(D.nxkitChecking)], "upToDate": [.nxkitEngine],
                                 "waitingForBuild": [.desktop(D.nxkitWaiting)], "rejected": [.nxkitUnsigned], "unreachable": [.desktop(D.nxkitUnreachable)]])
        add("NxkitUpdate.Rejection", ["unsigned": [.nxkitUnsigned], "badSignature": [.desktop(D.nxkitBadSignature)], "checksum": [.desktop(D.nxkitChecksum)],
                                      "incompatible": [.desktop(D.nxkitIncompatible)], "incomplete": [.desktop(D.nxkitIncomplete)],
                                      "download": [.desktop(D.nxkitDownload)], "unpack": [.desktop(D.nxkitUnpack)], "cancelled": [.desktop(D.nxkitCancelled)]])
        add("NxkitBuilder.Availability", ["available": [.nxkitEngine], "needsNewerMacOS": [.nxkitUnavailable], "needsAppleSilicon": [.desktop(D.nxkitAppleSilicon)]])
        add("NxkitFeedbackPrompt.Moment", ["built": [.nxkitFinished], "failed": [.nxkitFailed], "firstLaunch": [.nxkitLibrary]])
        add("CloudSaveStep", ["fetching": [.sheet(.cloudFetching), .sheet(.cloudFetchingLong)], "asking": [.sheet(.cloudChoose), .sheet(.cloudUnreadable)]])
        add("SavesModel.DeviceState", ["noDevices": [.desktop(D.savesNoDevices)], "notConnected": [.desktop(D.savesNotConnected)],
                                       "notInstalled": [.desktop(D.savesNotInstalled)], "reading": [.desktop(D.savesReading)], "ready": [.desktop(D.savesReady)],
                                       "failed": [.desktop(D.savesFailed)], "timedOut": [.desktop(D.savesTimedOut)]])
        add("FreeSpaceError", ["buildRunning": [.desktop(D.freeSpaceRunning)], "notABuildFolder": [.desktop(D.freeSpaceFailed)], "failed": [.desktop(D.freeSpaceFailed)]])
        add("GameDeletion.Item.Kind", ["macApp": [.sheet(.deleteGame)], "ipa": [.sheet(.deleteGame)], "iosApp": [.desktop(D.deleteGameIOS)],
                                       "archive": [.sheet(.deleteGame)], "shellFramework": [.sheet(.deleteGame)], "buildFolder": [.sheet(.deleteGame)],
                                       "log": [.sheet(.deleteGame)], "saves": [.sheet(.deleteGameSaves)]])
        add("OnboardingStep", ["welcome": [.onboarding(.fresh)], "platform": [.onboardingState(O.platformEmpty)], "xcode": [.onboardingState(O.xcodeChecking)],
                               "keys": [.onboardingState(O.keysSearching)], "games": [.onboardingState(O.gamesScanning)], "done": [.onboardingState(O.done)]])
        add("OnboardingState.Welcome", ["requirements": [.onboarding(.fresh), .onboardingState(O.welcomeLowSpace)]])
        add("OnboardingState.Platform", ["empty": [.onboardingState(O.platformEmpty)], "selected": [.onboardingState(O.platformChosen)]])
        add("OnboardingState.Xcode", ["checking": [.onboardingState(O.xcodeChecking)], "missing": [.onboardingState(O.xcodeMissing)],
                                      "disconnected": [.onboardingState(O.xcodeDisconnected)], "downloading": [.onboardingState(O.xcodeDownloading)],
                                      "needsSetup": [.onboardingState(O.xcodeNeedsSetup)], "settingUp": [.onboardingState(O.xcodeSettingUp)],
                                      "ready": [.onboarding(.xcodeReady)], "failed": [.onboarding(.xcodeFailed)]])
        add("OnboardingState.Keys", ["searching": [.onboardingState(O.keysSearching)], "found": [.onboardingState(O.keysFound)],
                                     "validating": [.onboardingState(O.keysValidating)], "valid": [.onboardingState(O.keysValid)],
                                     "invalid": [.onboarding(.keysInvalid)], "empty": [.onboardingState(O.keysEmpty)], "skipped": [.onboardingState(O.keysSkipped)]])
        add("OnboardingState.Games", ["empty": [.onboardingState(O.gamesEmpty)], "scanning": [.onboardingState(O.gamesScanning)],
                                      "found": [.onboardingState(O.gamesFound)], "none": [.onboarding(.noGames)]])
        add("OnboardingState.Done", ["celebrating": [.onboardingState(O.done)], "ready": [.onboardingState(O.doneReady)]])
        add("OnboardingTaskState", ["queued": [.onboardingState(O.xcodeSettingUp)], "running": [.onboardingState(O.xcodeSettingUp)],
                                    "done": [.onboardingState(O.xcodeSettingUp)], "failed": [.onboarding(.xcodeFailed), .onboardingState(O.xcodeSupportFailed)]])
        for scenario in MockOnboardingDriver.Scenario.allCases { map["MockOnboardingDriver.Scenario." + scenario.rawValue] = [.onboarding(scenario)] }
        add("ConsoleSheet", [
            "options": [.consoleOptions], "controllers": [.consoleControllers], "explanation": [.console(C.explainNeedsBuild)],
            "homeButtonHint": [.console(C.homeHint)], "menu": [.console(C.menu)], "mapping": [.console(C.mappingStandard)], "gamePad": [.console(C.gamePad)],
            "library": [.console(C.menuLibrary)], "settings": [.console(C.menuSettings)], "language": [.console(C.menuLanguage)],
            "cloudSaves": [.console(C.cloudSaves)], "confirmExit": [.console(C.confirmExit)], "confirmMapping": [.console(C.confirmMapping)],
            "advanced": [.console(C.advanced)], "confirmReset": [.console(C.confirmReset)], "confirmUpdate": [.console(C.confirmUpdate)],
            "cloudSave": [.console(C.cloudSaveQuestion), .console(C.cloudSaveUnreadable)], "gamePage": [.consoleGamePage], "allGames": [.consoleAllGames],
            "search": [.consoleSearch], "builds": [.consoleBuilds], "quickMenu": [.consoleQuickMenu], "manage": [.console(C.manage)],
            "stopped": [.console(C.homeStopped)], "confirmStopBuild": [.console(C.confirmStopBuild)], "confirmQuitPaused": [.console(C.confirmQuitPaused)],
            "supportedGames": [.console(C.supportedGames)]])
        add("ConsoleGame.Status", ["ready": [.consoleHome], "needsBuild": [.console(C.explainNeedsBuild)], "needsData": [.console(C.explainNeedsData)],
                                   "iphoneOnly": [.console(C.explainIphoneOnly)], "broken": [.console(C.explainBroken)]])
        add("ConsoleStarting", ["preparing": [.console(C.startingPreparing), .motion(.startGame)], "compilingShaders": [.consoleStarting],
                                "opening": [.console(C.startingOpening)], "cloudSave": [.consoleStartingCloud]])
        add("ConsoleController.Kind", ["gamepad": [.consoleControllers], "fullSize": [.console(C.controllersMixed)], "paired": [.console(C.controllersMixed)],
                                       "xbox": [.console(C.controllersMixed)], "keyboard": [.console(C.controllersMixed)]])
        add("ConsoleGameTab", ["overview": [.consoleGamePage], "saves": [.consoleGameSaves], "build": [.consoleGameBuild], "cheats": [.consoleGameCheats]])
        add("ConsoleLibraryFilter", ["all": [.consoleAllGames], "readyOnMac": [.console(C.allReady)], "notBuilt": [.console(C.allNotBuilt)],
                                     "needsData": [.console(C.allNeedsData)]])
        add("ConsoleBuilds.ArtworkOutcome", ["success": [.consoleBuildsFinished], "warning": [.console(C.buildsWarning)], "failure": [.consoleBuildsFailed]])
        add("ConsoleSaveStatus", Dictionary(uniqueKeysWithValues: ["off", "missingFolder", "notPlayed", "synced", "pending", "failed", "noSave", "notSynced"]
            .map { ($0, [GalleryScene.console(C.cloudSaves)]) }))
        add("ConsoleAppUpdate", ["upToDate": [.console(C.updateUpToDate)], "checking": [.console(C.updateChecking)], "available": [.console(C.menuSettings)],
                                 "downloading": [.console(C.updateDownloading)], "ready": [.console(C.updateReady)],
                                 "cannotInstall": [.console(C.updateCannotInstall)], "waitingForBuild": [.console(C.updateWaiting)],
                                 "failed": [.console(C.updateFailed)]])
        add("PadMode", ["auto": [.console(C.mappingAuto)], "standard": [.console(C.mappingStandard)], "byLabel": [.console(C.mappingByLabel)],
                        "custom": [.console(C.mappingCustom), .console(C.mappingGame)]])
        add("MockConsoleDriver.Scenario", ["full": [.consoleHome], "few": [.console(C.homeFew)], "empty": [.consoleEmpty], "controllers": [.consoleControllers],
                                           "controllersMixed": [.console(C.controllersMixed)], "starting": [.consoleStarting], "paused": [.console(C.homePaused)]])
        return map
    }

    /// What no scene shows, and why: kept short. Each reason names the items it covers.
    static let reasons: [(reason: String, items: [String])] = [
        ("Not used by the launcher: no view creates it, only tests host it.",
         ["EngineFootnote", "MacNativeGamesNotice", "build.mngRecommend", "BuildFooterReveal", "ConsoleChoiceRow",
          "ManageButtonLabel"]),
        ("A popover or an alert: AppKit draws it in its own window, which a capture of the scene cannot hold. The scene shows what opens it.",
         ["OnboardingKeysContent.swift .popover VStack", "LibraryArtworkState.swift .popover Text", "LauncherInfoHelp.swift .popover VStack",
          "LauncherDropdown.swift .popover LauncherDropdownList", "EngineSwitcherCard.swift .popover EngineDropdownPanel",
          "LauncherView.swift .alert Text", "Popped"]),
        ("A context menu: macOS draws its items as a menu.", ["LibraryCardContextMenuContent"]),
        ("The app's roots: they choose the onboarding, the launcher or the console demo, whose scenes show what they draw.",
         ["RootView", "ConsoleInLanguage", "ConsoleDemoView"]),
    ]

    /// The reason for `item`, nil when none is given.
    static func reason(for item: String) -> String? { reasons.first { $0.items.contains(item) }?.reason }
}
