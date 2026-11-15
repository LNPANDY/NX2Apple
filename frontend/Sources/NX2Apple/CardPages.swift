import SwiftUI
import NXCore
import NXLauncher
import NXModel

// The Builds and Settings pages share one scrolling column, so the scroll position, the open log and the open extra rows stay when
// someone goes from one to the other. This is that column and nothing else: it holds those three things and puts the cards of one
// page or the other in it. The cards observe the stores they show (NXLauncher, and `FilesCard`, `LibraryFoldersCard` in this target).
// A game file dropped on the Builds page goes to the build store (DropFiles.swift).

struct CardPages: View {
    let settings: Bool
    @ObservedObject var build: BuildStore   // for the drop target (off while a build runs) and the two cards that need to know
    let updates: AppUpdateStore
    let repo: RepoStore
    let engine: EngineSyncStore
    let dependencies: DependencyStore
    let devices: DeviceStore
    let queue: BuildQueueStore
    let transfers: TransferQueueStore
    var onSelectGames: () -> Void = {}
    var sticks: StickDeadzoneStore? = nil
    var saveSettings: SaveSettingsStore? = nil
    var players: PlayerProfileStore? = nil   // Settings > Library > Players (PlayersCard)
    @ObservedObject var library: GameLibrary
    var diagnostics: (LibraryGame?, @escaping (String) -> Void) -> Void = { _, _ in }   // the report of Copy diagnostics (LauncherStores)
    var onViewGame: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onChooseLibraryFolder: () -> Void = {}
    var onOpenControls: () -> Void = {}
    var onOpenControllers: () -> Void = {}   // the Controllers sheet (the console mode's list, with the player-mode setting)
    var onRunSetup: (() -> Void)?   // the guided first-run setup, again (nil where there is none)
    var controlChanges = 0
    var padMerge: Binding<Bool> = .constant(false)   // "All controllers are player 1" (ControlLayout.padMerge)
    var buildFiles: BuildFilesStore? = nil   // Settings > Tools > Build files (#232)
    var buildingID: UUID? = nil   // the game a build runs for
    var onBuildFileDetails: (UUID) -> Void = { _ in }   // the game's Free space sheet
    @Binding var settingsCategory: SettingsCategory   // the part of Settings shown (kept by the launcher, so a test opens any of them)
    @State private var extrasOpen = false
    @State private var logOpen = false
    @EnvironmentObject var loc: Localizer

    var body: some View {
        Group {
            if settings {
                SettingsPage(build: build, updates: updates, repo: repo, engine: engine, dependencies: dependencies, library: library, players: players, sticks: sticks, saveSettings: saveSettings,
                             diagnostics: diagnostics, onChooseLibraryFolder: onChooseLibraryFolder, onOpenControls: onOpenControls,
                             onOpenControllers: onOpenControllers, onRunSetup: onRunSetup, controlChanges: controlChanges, padMerge: padMerge, buildFiles: buildFiles, buildingID: buildingID, onBuildFileDetails: onBuildFileDetails, category: $settingsCategory)
            } else {
                LauncherPageScroll(memoryKey: "builds") {
                    BuildPage(build: build, running: build.running, repo: repo, dependencies: dependencies, devices: devices, queue: queue, transfers: transfers, onSelectGames: onSelectGames, extrasOpen: $extrasOpen, logOpen: $logOpen,
                              onViewGame: onViewGame, onOpenSettings: onOpenSettings)
                }
            }
        }
        .modifier(GameFilesDrop(enabled: !settings && !build.running, label: loc.t("drop.hint")) { build.take(dropped: $0) })   // DropFiles.swift
    }
}
