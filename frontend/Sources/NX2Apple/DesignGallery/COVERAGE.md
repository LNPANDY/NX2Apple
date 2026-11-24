# State gallery coverage

Written by `GalleryCoverageTests` from `GalleryCoverage.swift`: every View type of NX2Apple and NXLauncher, every sheet,
popover and alert, every notice and every case of the state enums the views switch on, with the gallery's scenes
(`GalleryScene.id`) that show it, or the reason none can. After a change:
`NX_WRITE_COVERAGE=1 swift test --package-path frontend --filter GalleryCoverageTests`. The gallery has
342 scenes.

## Views: 234 of 244 in a scene

| View | Scenes |
|---|---|
| `ActionCard` | `addGameFound` |
| `ActivityLogSheet` | `activityLog`, `activityLogEmpty` |
| `AppCard` | `settings`, `desktop-appAvailable` |
| `ArtworkFill` | `libraryGames`, `consoleHome` |
| `ArtworkOutcomeBadge` | `desktop-queueEveryState` |
| `ArtworkPanel` | `desktop-artworkHero`, `desktop-artworkThumbnail` |
| `ArtworkStatusChip` | `desktop-cardEveryState` |
| `BatchRefreshSheet` | `batchRefresh` |
| `BatteryIcon` | `console-controllersMixed` |
| `BuildActivityFooter` | `buildsRunning`, `desktop-footerExporting` |
| `BuildCacheRows` | `settingsTools` |
| `BuildCompletionTimerStroke` | `desktop-buildJustFinished`, `motion-buildFinishing` |
| `BuildFailureCard` | `buildFailed`, `buildFailure-rosetta` |
| `BuildFilesCard` | `settingsTools` |
| `BuildFilesRemoveSheet` | `buildFilesRemove` |
| `BuildFooterReveal` | Reason: Not used by the launcher: no view creates it, only tests host it. |
| `BuildIconReveal` | `buildOneStage`, `motion-iconReveal` |
| `BuildLogView` | `desktop-logOpen` |
| `BuildMetadataHero` | `buildOneStage`, `buildMultiStage` |
| `BuildPage` | `buildsIdle`, `gamePage` |
| `BuildPlatformChip` | `desktop-queueEveryState`, `buildSelected` |
| `BuildProcessCard` | `buildMultiStage` |
| `BuildProcessRows` | `buildMultiStage` |
| `BuildProcessStepsSheet` | `buildSteps` |
| `BuildProgressRevealMask` | `buildsRunning`, `motion-iconReveal` |
| `BuildQueueCard` | `desktop-queueEveryState` |
| `BuildQueueHero` | `desktop-queueRunning` |
| `BuildSelectedSheet` | `buildSelected` |
| `CacheFolderRow` | `settingsTools` |
| `CardDisclosure` | `buildOneStage` |
| `CardDivider` | `settings` |
| `CardGroup` | `settings` |
| `CardPageHeading` | `settings` |
| `CardPages` | `buildsIdle`, `settings` |
| `CardRow` | `settings` |
| `ChangedDot` | `console-mappingCustom` |
| `ChangedLabel` | `gameOptions` |
| `CheatCapabilityTag` | `cheats` |
| `CheatTriggerKeyPill` | `cheats` |
| `CheatsCountPill` | `cheats` |
| `CheatsOverviewCard` | `cheats` |
| `CheatsView` | `cheats` |
| `CloudSaveSheet` | `cloudChoose`, `cloudFetching` |
| `CloudSavesCard` | `settingsLibrary`, `gameOptions` |
| `CloudSyncConflictSheet` | `cloudSyncConflict` |
| `ConsoleAdvancedList` | `console-advanced` |
| `ConsoleAllGamesPage` | `consoleAllGames` |
| `ConsoleArtColumn` | `consoleOptions` |
| `ConsoleArtwork` | `consoleHome` |
| `ConsoleBackdrop` | `consoleHome` |
| `ConsoleBattery` | `console-controllersMixed` |
| `ConsoleBuildIndicator` | `consoleHomeBuilding` |
| `ConsoleBuildsPage` | `consoleBuilds` |
| `ConsoleCheatsSection` | `consoleGameCheats` |
| `ConsoleChoiceRow` | Reason: Not used by the launcher: no view creates it, only tests host it. |
| `ConsoleClock` | `consoleHome` |
| `ConsoleCloudSaveView` | `console-cloudSaveQuestion` |
| `ConsoleCloudSavesPage` | `console-cloudSaves` |
| `ConsoleConnectionPrompt` | `desktop-consolePrompt` |
| `ConsoleControllerButton` | `consoleHome` |
| `ConsoleControllerList` | `consoleControllers` |
| `ConsoleControllersSheet` | `controllersSheet` |
| `ConsoleDemoView` | Reason: The app's roots: they choose the onboarding, the launcher or the console demo, whose scenes show what they draw. |
| `ConsoleFlatButton` | `consoleControllers` |
| `ConsoleFocused` | `consoleOptionsStepperFocus` |
| `ConsoleGameOptionsList` | `consoleOptions` |
| `ConsoleGamePadPage` | `console-gamePad` |
| `ConsoleGamePage` | `consoleGamePage` |
| `ConsoleGameTile` | `consoleHome` |
| `ConsoleGlyphView` | `consoleHome` |
| `ConsoleGridTile` | `consoleAllGames` |
| `ConsoleGroupedList` | `consoleBuilds`, `consoleGamePage` |
| `ConsoleHeaderButton` | `consoleHome` |
| `ConsoleHint` | `consoleHome` |
| `ConsoleHintBar` | `consoleOptions` |
| `ConsoleHomeScreen` | `consoleHome` |
| `ConsoleInLanguage` | Reason: The app's roots: they choose the onboarding, the launcher or the console demo, whose scenes show what they draw. |
| `ConsoleInfoRow` | `consoleGamePage` |
| `ConsoleKeyButton` | `consoleSearch` |
| `ConsoleLaunchProgress` | `consoleStarting`, `console-startingOpening` |
| `ConsoleLibraryList` | `console-menuLibrary` |
| `ConsoleListRow` | `consoleBuilds` |
| `ConsoleManagePanel` | `console-manage` |
| `ConsoleMenuRow` | `console-menu` |
| `ConsoleMngMigrationView` | `console-mngMigration` |
| `ConsoleNoticeCard` | `consoleBuildsEmpty`, `consoleGameOverviewEmpty` |
| `ConsoleOptionRow` | `consoleOptions` |
| `ConsolePadDiagram` | `console-mappingCustom` |
| `ConsolePadGlyph` | `console-mappingCustom` |
| `ConsolePadMappingSheet` | `console-mappingStandard`, `console-mappingCustom` |
| `ConsolePageHeader` | `console-supportedGames`, `console-cloudSaves` |
| `ConsolePageLayout` | `consoleOptions` |
| `ConsolePlayersChip` | `console-controllersMixed`, `consoleHome` |
| `ConsolePrimaryButton` | `console-explainNeedsBuild`, `console-homeStopped` |
| `ConsoleProgressBar` | `consoleBuilds` |
| `ConsoleQuestion` | `console-confirmExit`, `console-confirmStopBuild` |
| `ConsoleQuestionLayer` | `console-confirmExit` |
| `ConsoleQuickMenu` | `consoleQuickMenu` |
| `ConsoleRowDivider` | `consoleBuilds` |
| `ConsoleSearchPage` | `consoleSearch` |
| `ConsoleSectionHeading` | `consoleOptions` |
| `ConsoleSegmentedControl` | `consoleGamePage`, `consoleAllGames` |
| `ConsoleSettingsList` | `console-menuSettings` |
| `ConsoleStatsCard` | `consoleGamePage` |
| `ConsoleSupportedGamesPage` | `console-supportedGames` |
| `ConsoleSwitch` | `consoleOptions`, `console-mappingStandard` |
| `ConsoleSwitchRow` | `consoleGameCheats` |
| `ConsoleTag` | `consoleOptions`, `console-supportedGames` |
| `ConsoleToastView` | `desktop-controllerToast`, `console-homeToast` |
| `ConsoleToggleListRow` | `consoleControllers` |
| `ConsoleValueStepper` | `consoleOptions` |
| `ConsoleView` | `consoleHome` |
| `ControllerMappingStatus` | `controlsSheet` |
| `ControlsCard` | `settingsControls` |
| `ControlsView` | `controlsSheet` |
| `DSCard` | `cardStates` |
| `DSCardButton` | `cardStates` |
| `DSContinueLabel` | `onboarding-fresh` |
| `DSInlineWarning` | `cloudUnreadable` |
| `DSOverflowMenu` | `settingsTools` |
| `DSPathText` | `freeSpace` |
| `DSRowMessageView` | `nxkitUnavailable`, `desktop-nxkitUnreachable` |
| `DSScrollingSheet` | `saves`, `controlsSheet` |
| `DSSheet` | `removeGame`, `rename` |
| `DSSheetButtonRow` | `batchRefresh` |
| `DSSheetConfirmButtons` | `removeGame` |
| `DSSheetHeader` | `batchRefresh`, `appUpdate` |
| `DSSheetPrimaryButton` | `rename` |
| `DSSpinner` | `libraryEngineSyncing` |
| `DSTag` | `supportedGames`, `cheats`, `desktop-mngLibrary`, `desktop-mngUpdateAvailable` |
| `DSTextButton` | `buildSteps`, `settingsTools` |
| `DSWizardFooter` | `onboarding-fresh` |
| `DeleteGameSheet` | `deleteGame`, `desktop-deleteGameIOS` |
| `DiagnosticsButton` | `settingsTools` |
| `EngineDropdownPanel` | `desktop-engineDropdown` |
| `EngineExperimentalBadge` | `desktop-engineDropdown` |
| `EngineFootnote` | Reason: Not used by the launcher: no view creates it, only tests host it. |
| `EnginePlatformBadge` | `desktop-engineDropdown` |
| `EngineSwitcherCard` | `buildsIdle`, `nxkitFailed`, `desktop-mngRecommend`, `desktop-mngRecommendInstalled` |
| `EngineSyncBanner` | `libraryNoticeError`, `settingsEngineError` |
| `ExportSteps` | `desktop-completionExported`, `desktop-sendSent` |
| `FailureTitleRow` | `buildFailure-severalGames` |
| `FileRow` | `addGameFound` |
| `FileRowDivider` | `addGameFound` |
| `FilesCard` | `addGameFound`, `addGamePartial` |
| `FinderCopySteps` | `buildFailure-shellDataIncomplete` |
| `FrameTimesRecordingView` | `desktop-frameTimes` |
| `FreeSpaceView` | `freeSpace`, `desktop-freeSpaceRunning` |
| `GameControllerMappingView` | `desktop-controllerMapping` |
| `GameSavesSection` | `gameOptions` |
| `GlobalSavesCard` | `settingsLibrary` |
| `Hosted` | `settings`, `settingsTools` |
| `InstallCard` | `wizardInstall` |
| `KeysCard` | `settingsTools` |
| `LaunchOptionsView` | `gameOptions` |
| `LauncherActionButton` | `libraryGames` |
| `LauncherBrandMark` | `wizardInstall` |
| `LauncherConfirmSheet` | `removeGame` |
| `LauncherCustomDropdownBox` | `desktop-engineDropdown` |
| `LauncherDropdown` | `settingsTools`, `settings` |
| `LauncherDropdownLayer` | `libraryGames` |
| `LauncherDropdownList` | `desktop-dropdownList`, `desktop-mngDropdownDisabled`, `desktop-mngDownloadOffered` |
| `LauncherGlassGroup` | `libraryGames` |
| `LauncherHeroActionLabel` | `libraryGames`, `desktop-heroPlay` |
| `LauncherIconButton` | `libraryGames` |
| `LauncherInfoHelp` | `addGameFound` |
| `LauncherNotice` | `buildsSetupHint` |
| `LauncherNoticeStack` | `libraryEngineUpdate`, `libraryNoticeWarning` |
| `LauncherPageScroll` | `buildsIdle` |
| `LauncherProgressBar` | `buildsRunning` |
| `LauncherSecondaryButton` | `settings` |
| `LauncherSegmented` | `settings` |
| `LauncherSlider` | `gameOptions` |
| `LauncherStickyPageScroll` | `settings` |
| `LauncherTargetOptionLabel` | `onboarding-platformChosen` |
| `LauncherTopBarRule` | `libraryGames` |
| `LauncherView` | `libraryGames` |
| `LauncherWordmark` | `onboarding-fresh` |
| `LibraryArtworkChip` | `desktop-cardEveryState` |
| `LibraryCardContextMenuContent` | Reason: A context menu: macOS draws its items as a menu. |
| `LibraryCardKeyboardActions` | `libraryGames` |
| `LibraryCarouselPlaceholder` | `libraryEmpty`, `desktop-noArtwork` |
| `LibraryFallbackArtwork` | `desktop-noArtwork` |
| `LibraryFoldersCard` | `settingsLibrary`, `desktop-libraryFolders` |
| `LibraryGameCard` | `libraryGames`, `cardStates` |
| `LibraryProfileChip` | `desktop-heroUnverified` |
| `LogCard` | `desktop-logOpen` |
| `MacNativeGamesNotice` | Reason: Not used by the launcher: no view creates it, only tests host it. |
| `ManageButtonLabel` | Reason: Not used by the launcher: no view creates it, only tests host it. |
| `ManageMenuPanel` | `desktop-manageMenu`, `desktop-manageMenuPad` |
| `MissingImgGuideSheet` | `imgGuide` |
| `MissingToolRow` | `desktop-missingTool` |
| `MngSaveMigrationSheet` | `mngSaveMigration` |
| `NxkitFeedbackRow` | `nxkitFinished`, `nxkitLibrary` |
| `NxkitGenericBuildRow` | `nxkitGeneric` |
| `OnboardingCheck` | `onboarding-done` |
| `OnboardingDemoHost` | `onboarding-fresh` |
| `OnboardingDropZone` | `onboarding-gamesEmpty` |
| `OnboardingGamesContent` | `onboarding-gamesFound` |
| `OnboardingKeysContent` | `onboarding-keysFound` |
| `OnboardingKeysHelp` | `onboarding-keysEmpty` |
| `OnboardingRowDivider` | `onboarding-xcodeSettingUp` |
| `OnboardingStatusIcon` | `onboarding-xcodeSettingUp` |
| `OnboardingStatusRow` | `onboarding-xcodeSettingUp` |
| `OnboardingView` | `onboarding-fresh` |
| `OutcomeCard` | `buildFinishedMac`, `buildFinishedIOS` |
| `PadModeSection` | `controlsSheet` |
| `PersonalDefaultsCard` | `settings` |
| `PlayerNameSheet` | `playerName` |
| `PlayerPicker` | `libraryGames` |
| `PlayersCard` | `desktop-players` |
| `Popped` | Reason: A popover or an alert: AppKit draws it in its own window, which a capture of the scene cannot hold. The scene shows what opens it. |
| `ProgressCard` | `buildsRunning`, `nxkitFailed` |
| `QueueArtworkStack` | `desktop-queueRunning`, `buildsQueued` |
| `RefreshCompletionSheet` | `refreshCompletion` |
| `RefreshDevicesButton` | `wizardInstall` |
| `RenameGameSheet` | `rename` |
| `RootView` | Reason: The app's roots: they choose the onboarding, the launcher or the console demo, whose scenes show what they draw. |
| `SaveImportSheet` | `saveImport` |
| `SavesView` | `saves`, `desktop-savesReady` |
| `SeedCompressionSettingsRow` | `settingsTools`, `desktop-seedCompressionStorage` |
| `SeedCompressionSheet` | `seedCompressionPrompt`, `seedCompressionProgress`, `seedCompressionDone` |
| `SendSelectedSheet` | `sendSelectedDevice`, `desktop-sendSelectedDrive` |
| `SettingsPage` | `settings`, `settingsTools` |
| `SettingsUpdateAction` | `desktop-appAvailable` |
| `SetupHintCard` | `buildsSetupHint` |
| `ShellCacheRow` | `settingsTools` |
| `ShellCopyCard` | `desktop-sendSending` |
| `ShellCopySheet` | `shellCopy` |
| `SkeletonTile` | `desktop-artworkLoading` |
| `SkippedItemRow` | `skippedItems` |
| `SkippedLibraryItemsOverlay` | `skippedItems` |
| `SteamControllerSection` | `controlsSheet` |
| `StickDeadzoneCard` | `settingsControls` |
| `StickVisualizer` | `settingsControls` |
| `SupportedGameRow` | `supportedGames` |
| `SupportedGamesSheet` | `supportedGames` |
| `TargetCard` | `gamePage`, `wizardPlatform` |
| `ToolsCard` | `settingsTools` |
| `TransferCard` | `desktop-transfersEveryState` |
| `UpdateSheet` | `appUpdate` |
| `UpstreamBuilderRow` | `desktop-mngUpdateAvailable`, `desktop-mngBlocked`, `desktop-mngDownloadingSettings` |
| `UpstreamPicker` | `nxkitEngine`, `desktop-mngBlocked` |
| `UpstreamVersionPill` | `buildsIdle`, `desktop-engineDropdown` |

## Presentations: 33 of 39 in a scene

| Presentation | Scenes |
|---|---|
| `BuildFailureCard.swift .sheet LauncherConfirmSheet` | `confirmBuildAnyway` |
| `BuildFiles.swift .sheet BuildFilesRemoveSheet` | `buildFilesRemove` |
| `BuildPage.swift .sheet BuildProcessStepsSheet` | `buildSteps` |
| `BuildPage.swift .sheet LauncherConfirmSheet` | `confirmCancelDraft` |
| `BuildPage.swift .sheet LauncherConfirmSheet 2` | `confirmCancelQueue` |
| `CloudSavesCard.swift .sheet CloudSyncConflictSheet` | `cloudSyncConflict` |
| `Controls.swift .sheet LauncherConfirmSheet` | `controlsDiscard` |
| `EngineSwitcherCard.swift .popover EngineDropdownPanel` | Reason: A popover or an alert: AppKit draws it in its own window, which a capture of the scene cannot hold. The scene shows what opens it. |
| `ExportSteps.swift .sheet SendSelectedSheet` | `desktop-sendSelectedDrive` |
| `FreeSpace.swift .sheet LauncherConfirmSheet` | `freeSpaceConfirm` |
| `GameSavesSection.swift .sheet SaveImportSheet` | `saveImport` |
| `InstallCard.swift .sheet SendSelectedSheet` | `sendSelectedDevice` |
| `LaunchOptionsView.swift .sheet LauncherConfirmSheet` | `confirmTestedValues` |
| `LaunchOptionsView.swift .sheet GameControllerMappingView` | `desktop-controllerMapping` |
| `LauncherDropdown.swift .popover LauncherDropdownList` | Reason: A popover or an alert: AppKit draws it in its own window, which a capture of the scene cannot hold. The scene shows what opens it. |
| `LauncherInfoHelp.swift .popover VStack` | Reason: A popover or an alert: AppKit draws it in its own window, which a capture of the scene cannot hold. The scene shows what opens it. |
| `LauncherView+SeedCompression.swift .sheet SeedCompressionSheet` | `seedCompressionPrompt` |
| `LauncherView.swift .sheet ConsoleControllersSheet` | `controllersSheet` |
| `LauncherView.swift .alert Text` | Reason: A popover or an alert: AppKit draws it in its own window, which a capture of the scene cannot hold. The scene shows what opens it. |
| `LauncherView.swift .sheet LauncherConfirmSheet` | `removeGame` |
| `LauncherView.swift .sheet LaunchOptionsView` | `gameOptions` |
| `LauncherView.swift .sheet ControlsView` | `controlsSheet` |
| `LauncherView.swift .sheet FreeSpaceView` | `freeSpace` |
| `LauncherView.swift .sheet BuildSelectedSheet` | `buildSelected` |
| `LauncherView.swift .sheet SupportedGamesSheet` | `supportedGames` |
| `LauncherView.swift .sheet UpdateSheet` | `appUpdate` |
| `LauncherView.swift .sheet LauncherConfirmSheet 2` | `confirmUninstall` |
| `LauncherView.swift .sheet SavesView` | `saves` |
| `LibraryArtworkState.swift .popover Text` | Reason: A popover or an alert: AppKit draws it in its own window, which a capture of the scene cannot hold. The scene shows what opens it. |
| `MissingImgGuideSheet.swift .sheet BatchRefreshSheet` | `batchRefresh` |
| `MissingImgGuideSheet.swift .sheet MissingImgGuideSheet` | `imgGuide` |
| `MissingImgGuideSheet.swift .sheet RefreshCompletionSheet` | `refreshCompletion` |
| `OnboardingKeysContent.swift .popover VStack` | Reason: A popover or an alert: AppKit draws it in its own window, which a capture of the scene cannot hold. The scene shows what opens it. |
| `PlayersCard.swift .sheet PlayerNameSheet` | `playerName` |
| `PlayersCard.swift .sheet LauncherConfirmSheet` | `confirmRemovePlayer` |
| `ShellCopySheet.swift .sheet ShellCopySheet` | `shellCopy` |
| `StaleFrameworksPrompt.swift .sheet LauncherConfirmSheet` | `confirmStaleFrameworks` |
| `ToolsCard.swift .sheet DSSheet` | `invalidXcode` |
| `ToolsCard.swift .sheet LauncherConfirmSheet` | `confirmEngineChannel` |

## Notices: 9 of 10 in a scene

| Notice | Scenes |
|---|---|
| `build.mngRecommend` | Reason: Not used by the launcher: no view creates it, only tests host it. |
| `build.setup` | `buildsSetupHint` |
| `engine.failure` | `libraryNoticeError`, `settingsEngineError` |
| `engine.syncing` | `libraryEngineSyncing` |
| `hero.gatekeeper` | `libraryGatekeeper` |
| `hero.refresh` | `libraryEngineUpdate` |
| `hero.resign` | `desktop-heroResign` |
| `hero.signature` | `desktop-heroSignature` |
| `hero.switch2` | `librarySwitch2` |
| `library.skippedBanner` | `libraryNoticeWarning` |

## States: 285 of 285 in a scene

| State | Scenes |
|---|---|
| `LauncherPage.library` | `libraryGames` |
| `LauncherPage.builds` | `buildsIdle` |
| `LauncherPage.settings` | `settings` |
| `SettingsCategory.general` | `settings` |
| `SettingsCategory.library` | `settingsLibrary` |
| `SettingsCategory.controls` | `settingsControls` |
| `SettingsCategory.tools` | `settingsTools` |
| `LibraryFilter.owned` | `desktop-filterOwned` |
| `LibraryFilter.built` | `console-menuOnlyBuilt` |
| `LibraryFilter.mac` | `desktop-filterMac` |
| `LibraryFilter.ios` | `desktop-filterIOS` |
| `LibrarySort.recent` | `allGames` |
| `LibrarySort.name` | `desktop-sortName` |
| `LibraryGame.Primary.play` | `desktop-heroPlay` |
| `LibraryGame.Primary.openOnDevice` | `desktop-heroOnDevice` |
| `LibraryGame.Primary.build` | `libraryGames` |
| `LibraryArtworkState.Attention.none` | `desktop-cardEveryState` |
| `LibraryArtworkState.Attention.notBuilt` | `desktop-cardEveryState` |
| `LibraryArtworkState.Attention.missingData` | `desktop-cardEveryState`, `libraryGames` |
| `LibraryArtworkState.Attention.fixFiles` | `desktop-cardEveryState` |
| `LibraryArtworkState.Attention.building` | `desktop-cardEveryState` |
| `LibraryArtworkState.Attention.queued` | `desktop-cardEveryState` |
| `HeroRefreshState.upToDate` | `desktop-heroPlay` |
| `HeroRefreshState.specificFast` | `desktop-heroRefreshFast` |
| `HeroRefreshState.specificFull` | `desktop-heroRefreshFull` |
| `HeroRefreshState.generalSync` | `libraryEngineUpdate` |
| `ArtworkSlot.hero` | `desktop-artworkHero` |
| `ArtworkSlot.thumbnail` | `desktop-artworkThumbnail` |
| `ArtworkEditor.LoadState.loading` | `desktop-artworkLoading` |
| `ArtworkEditor.LoadState.loaded` | `desktop-artworkHero` |
| `ArtworkEditor.LoadState.offline` | `desktop-artworkOffline` |
| `ArtworkEditor.LoadState.none` | `desktop-artworkNoScreenshots` |
| `ArtworkEditor.Notice.warning` | `desktop-artworkWarning` |
| `ArtworkEditor.Notice.error` | `desktop-artworkError` |
| `StepState.pending` | `buildMultiStage` |
| `StepState.running` | `buildMultiStage` |
| `StepState.done` | `buildMultiStage` |
| `StepState.failed` | `nxkitFailed` |
| `BuildCompletionStatus.mac` | `buildFinishedMac` |
| `BuildCompletionStatus.installed` | `buildFinishedIOS` |
| `BuildCompletionStatus.exported` | `desktop-completionExported` |
| `BuildCompletionStatus.needsData` | `desktop-completionNeedsData` |
| `BuildFailureKind.rosetta` | `buildFailure-rosetta` |
| `BuildFailureKind.translator` | `buildFailure-translator` |
| `BuildFailureKind.zbic` | `buildFailure-zbic` |
| `BuildFailureKind.iosSDK` | `buildFailure-iosSDK` |
| `BuildFailureKind.cltSelected` | `buildFailure-cltSelected` |
| `BuildFailureKind.metalToolchain` | `buildFailure-metalToolchain` |
| `BuildFailureKind.otherMetal` | `buildFailure-otherMetal` |
| `BuildFailureKind.shaderRegression` | `buildFailure-shaderRegression` |
| `BuildFailureKind.damagedNSP` | `buildFailure-damagedNSP` |
| `BuildFailureKind.a32Program` | `buildFailure-a32Program` |
| `BuildFailureKind.keys` | `buildFailure-keys` |
| `BuildFailureKind.severalGames` | `buildFailure-severalGames` |
| `BuildFailureKind.noTitleID` | `buildFailure-noTitleID` |
| `BuildFailureKind.driveMissing` | `buildFailure-driveMissing` |
| `BuildFailureKind.keysOld` | `buildFailure-keysOld` |
| `BuildFailureKind.staleProfile` | `buildFailure-staleProfile` |
| `BuildFailureKind.updateMismatch` | `buildFailure-updateMismatch` |
| `BuildFailureKind.mngSharedFonts` | `buildFailure-mngSharedFonts` |
| `BuildFailureKind.psoDiskFull` | `buildFailure-psoDiskFull` |
| `BuildFailureKind.diskFull` | `buildFailed` |
| `BuildFailureKind.teamTaken` | `buildFailure-teamTaken` |
| `BuildFailureKind.noSigningAccount` | `buildFailure-noSigningAccount` |
| `BuildFailureKind.freeAccountLimit` | `buildFailure-freeAccountLimit` |
| `BuildFailureKind.appIDLimit` | `buildFailure-appIDLimit` |
| `BuildFailureKind.deviceTransfer` | `buildFailure-deviceTransfer` |
| `BuildFailureKind.cloudFolder` | `buildFailure-cloudFolder` |
| `BuildFailureKind.volumeFormat` | `buildFailure-volumeFormat` |
| `BuildFailureKind.devicePairing` | `buildFailure-devicePairing` |
| `BuildFailureKind.developerMode` | `buildFailure-developerMode` |
| `BuildFailureKind.shellDataIncomplete` | `buildFailure-shellDataIncomplete` |
| `BuildFailureKind.engineOffline` | `buildFailure-engineOffline` |
| `BuildFailureKind.engineSync` | `buildFailure-engineSync` |
| `BuildFailureKind.nxkit` | `buildFailure-nxkit` |
| `BuildFailureKind.unknown` | `buildFailure-unknown` |
| `DataSend.idle` | `desktop-completionExported` |
| `DataSend.sending` | `desktop-sendSending` |
| `DataSend.sent` | `desktop-sendSent` |
| `DataSend.appNotFound` | `desktop-sendAppNotFound` |
| `DataSend.chooseApp` | `desktop-sendChooseApp` |
| `DataSend.refused` | `desktop-sendRefused` |
| `DataSend.failed` | `desktop-sendFailed` |
| `DataSend.copying` | `desktop-sendCopying` |
| `DataSend.copied` | `desktop-sendCopied` |
| `QueueEntry.Status.queued` | `desktop-queueEveryState`, `buildsQueued` |
| `QueueEntry.Status.running` | `desktop-queueRunning` |
| `QueueEntry.Status.done` | `desktop-queueEveryState` |
| `QueueEntry.Status.failed` | `desktop-queueEveryState` |
| `QueueEntry.Status.skipped` | `desktop-queueEveryState` |
| `QueueEntry.Status.stopped` | `desktop-queueEveryState` |
| `TransferEntry.Status.queued` | `desktop-transfersEveryState` |
| `TransferEntry.Status.sending` | `desktop-transfersEveryState` |
| `TransferEntry.Status.waiting` | `desktop-transfersEveryState` |
| `TransferEntry.Status.failed` | `desktop-transfersEveryState` |
| `TransferEntry.Status.done` | `desktop-transfersEveryState` |
| `TransferEntry.Status.cancelling` | `desktop-transfersEveryState` |
| `ActiveOperation.Kind.building` | `buildsRunning` |
| `ActiveOperation.Kind.verifyingFirstStart` | `desktop-footerVerifying` |
| `ActiveOperation.Kind.exportingIPA` | `desktop-footerExporting` |
| `ActiveOperation.Kind.installing` | `desktop-footerInstalling` |
| `ActiveOperation.Kind.renewingSignature` | `desktop-footerRenewing` |
| `ActiveOperation.Kind.sendingGameData` | `desktop-footerSending` |
| `SendSelectedSheet.Mode.device` | `sendSelectedDevice` |
| `SendSelectedSheet.Mode.drive` | `desktop-sendSelectedDrive` |
| `AppUpdateStore.Phase.idle` | `settings`, `desktop-appAvailable` |
| `AppUpdateStore.Phase.checking` | `desktop-appChecking` |
| `AppUpdateStore.Phase.downloading` | `desktop-appDownloading` |
| `AppUpdateStore.Phase.preparing` | `desktop-appPreparing` |
| `EngineChannel.stable` | `settingsTools` |
| `EngineChannel.experimental` | `desktop-engineExperimental` |
| `SeedCompressionStore.Phase.prompt` | `seedCompressionPrompt` |
| `SeedCompressionStore.Phase.running` | `seedCompressionProgress` |
| `SeedCompressionStore.Phase.done` | `seedCompressionDone` |
| `SeedCompressionStore.ItemStatus.waiting` | `seedCompressionProgress` |
| `SeedCompressionStore.ItemStatus.compressing` | `seedCompressionProgress` |
| `SeedCompressionStore.ItemStatus.done` | `seedCompressionProgress` |
| `SeedCompressionStore.ItemStatus.failed` | `seedCompressionProgress` |
| `SeedCompressionStore.ScanState.idle` | `settingsTools` |
| `SeedCompressionStore.ScanState.scanning` | `settingsTools` |
| `SeedCompressionStore.ScanState.ready` | `desktop-seedCompressionStorage` |
| `SeedCompressionStore.ScanState.failed` | `settingsTools` |
| `SeedCompressSummary.Status.completed` | `seedCompressionDone` |
| `SeedCompressSummary.Status.partial` | `seedCompressionDonePartial` |
| `SeedCompressSummary.Status.stopped` | `seedCompressionDoneStopped` |
| `NxkitUpdateState.idle` | `desktop-nxkitIdle` |
| `NxkitUpdateState.checking` | `desktop-nxkitChecking` |
| `NxkitUpdateState.upToDate` | `nxkitEngine` |
| `NxkitUpdateState.waitingForBuild` | `desktop-nxkitWaiting` |
| `NxkitUpdateState.rejected` | `nxkitUnsigned` |
| `NxkitUpdateState.unreachable` | `desktop-nxkitUnreachable` |
| `NxkitUpdate.Rejection.unsigned` | `nxkitUnsigned` |
| `NxkitUpdate.Rejection.badSignature` | `desktop-nxkitBadSignature` |
| `NxkitUpdate.Rejection.checksum` | `desktop-nxkitChecksum` |
| `NxkitUpdate.Rejection.incompatible` | `desktop-nxkitIncompatible` |
| `NxkitUpdate.Rejection.incomplete` | `desktop-nxkitIncomplete` |
| `NxkitUpdate.Rejection.download` | `desktop-nxkitDownload` |
| `NxkitUpdate.Rejection.unpack` | `desktop-nxkitUnpack` |
| `NxkitUpdate.Rejection.cancelled` | `desktop-nxkitCancelled` |
| `NxkitBuilder.Availability.available` | `nxkitEngine` |
| `NxkitBuilder.Availability.needsNewerMacOS` | `nxkitUnavailable` |
| `NxkitBuilder.Availability.needsAppleSilicon` | `desktop-nxkitAppleSilicon` |
| `NxkitFeedbackPrompt.Moment.built` | `nxkitFinished` |
| `NxkitFeedbackPrompt.Moment.failed` | `nxkitFailed` |
| `NxkitFeedbackPrompt.Moment.firstLaunch` | `nxkitLibrary` |
| `CloudSaveStep.fetching` | `cloudFetching`, `cloudFetchingLong` |
| `CloudSaveStep.asking` | `cloudChoose`, `cloudUnreadable` |
| `SavesModel.DeviceState.noDevices` | `desktop-savesNoDevices` |
| `SavesModel.DeviceState.notConnected` | `desktop-savesNotConnected` |
| `SavesModel.DeviceState.notInstalled` | `desktop-savesNotInstalled` |
| `SavesModel.DeviceState.reading` | `desktop-savesReading` |
| `SavesModel.DeviceState.ready` | `desktop-savesReady` |
| `SavesModel.DeviceState.failed` | `desktop-savesFailed` |
| `SavesModel.DeviceState.timedOut` | `desktop-savesTimedOut` |
| `FreeSpaceError.buildRunning` | `desktop-freeSpaceRunning` |
| `FreeSpaceError.notABuildFolder` | `desktop-freeSpaceFailed` |
| `FreeSpaceError.failed` | `desktop-freeSpaceFailed` |
| `GameDeletion.Item.Kind.macApp` | `deleteGame` |
| `GameDeletion.Item.Kind.ipa` | `deleteGame` |
| `GameDeletion.Item.Kind.iosApp` | `desktop-deleteGameIOS` |
| `GameDeletion.Item.Kind.archive` | `deleteGame` |
| `GameDeletion.Item.Kind.shellFramework` | `deleteGame` |
| `GameDeletion.Item.Kind.buildFolder` | `deleteGame` |
| `GameDeletion.Item.Kind.log` | `deleteGame` |
| `GameDeletion.Item.Kind.saves` | `deleteGameSaves` |
| `OnboardingStep.welcome` | `onboarding-fresh` |
| `OnboardingStep.platform` | `onboarding-platformEmpty` |
| `OnboardingStep.xcode` | `onboarding-xcodeChecking` |
| `OnboardingStep.keys` | `onboarding-keysSearching` |
| `OnboardingStep.games` | `onboarding-gamesScanning` |
| `OnboardingStep.done` | `onboarding-done` |
| `OnboardingState.Welcome.requirements` | `onboarding-fresh`, `onboarding-welcomeLowSpace` |
| `OnboardingState.Platform.empty` | `onboarding-platformEmpty` |
| `OnboardingState.Platform.selected` | `onboarding-platformChosen` |
| `OnboardingState.Xcode.checking` | `onboarding-xcodeChecking` |
| `OnboardingState.Xcode.missing` | `onboarding-xcodeMissing` |
| `OnboardingState.Xcode.disconnected` | `onboarding-xcodeDisconnected` |
| `OnboardingState.Xcode.downloading` | `onboarding-xcodeDownloading` |
| `OnboardingState.Xcode.needsSetup` | `onboarding-xcodeNeedsSetup` |
| `OnboardingState.Xcode.settingUp` | `onboarding-xcodeSettingUp` |
| `OnboardingState.Xcode.ready` | `onboarding-xcodeReady` |
| `OnboardingState.Xcode.failed` | `onboarding-xcodeFailed` |
| `OnboardingState.Keys.searching` | `onboarding-keysSearching` |
| `OnboardingState.Keys.found` | `onboarding-keysFound` |
| `OnboardingState.Keys.validating` | `onboarding-keysValidating` |
| `OnboardingState.Keys.valid` | `onboarding-keysValid` |
| `OnboardingState.Keys.invalid` | `onboarding-keysInvalid` |
| `OnboardingState.Keys.empty` | `onboarding-keysEmpty` |
| `OnboardingState.Keys.skipped` | `onboarding-keysSkipped` |
| `OnboardingState.Games.empty` | `onboarding-gamesEmpty` |
| `OnboardingState.Games.scanning` | `onboarding-gamesScanning` |
| `OnboardingState.Games.found` | `onboarding-gamesFound` |
| `OnboardingState.Games.none` | `onboarding-noGames` |
| `OnboardingState.Done.celebrating` | `onboarding-done` |
| `OnboardingState.Done.ready` | `onboarding-doneReady` |
| `OnboardingTaskState.queued` | `onboarding-xcodeSettingUp` |
| `OnboardingTaskState.running` | `onboarding-xcodeSettingUp` |
| `OnboardingTaskState.done` | `onboarding-xcodeSettingUp` |
| `OnboardingTaskState.failed` | `onboarding-xcodeFailed`, `onboarding-xcodeSupportFailed` |
| `MockOnboardingDriver.Scenario.fresh` | `onboarding-fresh` |
| `MockOnboardingDriver.Scenario.xcodeReady` | `onboarding-xcodeReady` |
| `MockOnboardingDriver.Scenario.keysInvalid` | `onboarding-keysInvalid` |
| `MockOnboardingDriver.Scenario.xcodeFailed` | `onboarding-xcodeFailed` |
| `MockOnboardingDriver.Scenario.noGames` | `onboarding-noGames` |
| `MockOnboardingDriver.Scenario.oldMac` | `onboarding-oldMac` |
| `ConsoleSheet.options` | `consoleOptions` |
| `ConsoleSheet.controllers` | `consoleControllers` |
| `ConsoleSheet.explanation` | `console-explainNeedsBuild` |
| `ConsoleSheet.homeButtonHint` | `console-homeHint` |
| `ConsoleSheet.menu` | `console-menu` |
| `ConsoleSheet.mapping` | `console-mappingStandard` |
| `ConsoleSheet.gamePad` | `console-gamePad` |
| `ConsoleSheet.library` | `console-menuLibrary` |
| `ConsoleSheet.settings` | `console-menuSettings` |
| `ConsoleSheet.language` | `console-menuLanguage` |
| `ConsoleSheet.cloudSaves` | `console-cloudSaves` |
| `ConsoleSheet.confirmExit` | `console-confirmExit` |
| `ConsoleSheet.confirmMapping` | `console-confirmMapping` |
| `ConsoleSheet.advanced` | `console-advanced` |
| `ConsoleSheet.confirmReset` | `console-confirmReset` |
| `ConsoleSheet.confirmUpdate` | `console-confirmUpdate` |
| `ConsoleSheet.cloudSave` | `console-cloudSaveQuestion`, `console-cloudSaveUnreadable` |
| `ConsoleSheet.mngMigration` | `console-mngMigration` |
| `ConsoleSheet.gamePage` | `consoleGamePage` |
| `ConsoleSheet.allGames` | `consoleAllGames` |
| `ConsoleSheet.search` | `consoleSearch` |
| `ConsoleSheet.builds` | `consoleBuilds` |
| `ConsoleSheet.quickMenu` | `consoleQuickMenu` |
| `ConsoleSheet.manage` | `console-manage` |
| `ConsoleSheet.stopped` | `console-homeStopped` |
| `ConsoleSheet.confirmStopBuild` | `console-confirmStopBuild` |
| `ConsoleSheet.confirmQuitPaused` | `console-confirmQuitPaused` |
| `ConsoleSheet.supportedGames` | `console-supportedGames` |
| `ConsoleGame.Status.ready` | `consoleHome` |
| `ConsoleGame.Status.needsBuild` | `console-explainNeedsBuild` |
| `ConsoleGame.Status.needsData` | `console-explainNeedsData` |
| `ConsoleGame.Status.iphoneOnly` | `console-explainIphoneOnly` |
| `ConsoleGame.Status.broken` | `console-explainBroken` |
| `ConsoleStarting.preparing` | `console-startingPreparing`, `motion-startGame` |
| `ConsoleStarting.compilingShaders` | `consoleStarting` |
| `ConsoleStarting.opening` | `console-startingOpening` |
| `ConsoleStarting.cloudSave` | `consoleStartingCloud` |
| `ConsoleController.Kind.gamepad` | `consoleControllers` |
| `ConsoleController.Kind.fullSize` | `console-controllersMixed` |
| `ConsoleController.Kind.paired` | `console-controllersMixed` |
| `ConsoleController.Kind.xbox` | `console-controllersMixed` |
| `ConsoleController.Kind.keyboard` | `console-controllersMixed` |
| `ConsoleGameTab.overview` | `consoleGamePage` |
| `ConsoleGameTab.saves` | `consoleGameSaves` |
| `ConsoleGameTab.build` | `consoleGameBuild` |
| `ConsoleGameTab.cheats` | `consoleGameCheats` |
| `ConsoleLibraryFilter.all` | `consoleAllGames` |
| `ConsoleLibraryFilter.readyOnMac` | `console-allReady` |
| `ConsoleLibraryFilter.notBuilt` | `console-allNotBuilt` |
| `ConsoleLibraryFilter.needsData` | `console-allNeedsData` |
| `ConsoleBuilds.ArtworkOutcome.success` | `consoleBuildsFinished` |
| `ConsoleBuilds.ArtworkOutcome.warning` | `console-buildsWarning` |
| `ConsoleBuilds.ArtworkOutcome.failure` | `consoleBuildsFailed` |
| `ConsoleSaveStatus.off` | `console-cloudSaves` |
| `ConsoleSaveStatus.missingFolder` | `console-cloudSaves` |
| `ConsoleSaveStatus.notPlayed` | `console-cloudSaves` |
| `ConsoleSaveStatus.synced` | `console-cloudSaves` |
| `ConsoleSaveStatus.pending` | `console-cloudSaves` |
| `ConsoleSaveStatus.failed` | `console-cloudSaves` |
| `ConsoleSaveStatus.noSave` | `console-cloudSaves` |
| `ConsoleSaveStatus.notSynced` | `console-cloudSaves` |
| `ConsoleAppUpdate.upToDate` | `console-updateUpToDate` |
| `ConsoleAppUpdate.checking` | `console-updateChecking` |
| `ConsoleAppUpdate.available` | `console-menuSettings` |
| `ConsoleAppUpdate.downloading` | `console-updateDownloading` |
| `ConsoleAppUpdate.ready` | `console-updateReady` |
| `ConsoleAppUpdate.cannotInstall` | `console-updateCannotInstall` |
| `ConsoleAppUpdate.waitingForBuild` | `console-updateWaiting` |
| `ConsoleAppUpdate.failed` | `console-updateFailed` |
| `PadMode.auto` | `console-mappingAuto` |
| `PadMode.standard` | `console-mappingStandard` |
| `PadMode.byLabel` | `console-mappingByLabel` |
| `PadMode.custom` | `console-mappingCustom`, `console-mappingGame` |
| `MockConsoleDriver.Scenario.full` | `consoleHome` |
| `MockConsoleDriver.Scenario.few` | `console-homeFew` |
| `MockConsoleDriver.Scenario.empty` | `consoleEmpty` |
| `MockConsoleDriver.Scenario.controllers` | `consoleControllers` |
| `MockConsoleDriver.Scenario.controllersMixed` | `console-controllersMixed` |
| `MockConsoleDriver.Scenario.starting` | `consoleStarting` |
| `MockConsoleDriver.Scenario.paused` | `console-homePaused` |

## Reasons

- Not used by the launcher: no view creates it, only tests host it. `EngineFootnote`, `MacNativeGamesNotice`, `build.mngRecommend`, `BuildFooterReveal`, `ConsoleChoiceRow`, `ManageButtonLabel`
- A popover or an alert: AppKit draws it in its own window, which a capture of the scene cannot hold. The scene shows what opens it. `OnboardingKeysContent.swift .popover VStack`, `LibraryArtworkState.swift .popover Text`, `LauncherInfoHelp.swift .popover VStack`, `LauncherDropdown.swift .popover LauncherDropdownList`, `EngineSwitcherCard.swift .popover EngineDropdownPanel`, `LauncherView.swift .alert Text`, `Popped`
- A context menu: macOS draws its items as a menu. `LibraryCardContextMenuContent`
- The app's roots: they choose the onboarding, the launcher or the console demo, whose scenes show what they draw. `RootView`, `ConsoleInLanguage`, `ConsoleDemoView`
