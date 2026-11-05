import SwiftUI
import NXCore
import NXLauncher
import NXModel

// The Settings page: one card per area, in order. The page owns what only the app can give the cards: the switches kept in the app's
// defaults (the console prompt, build notifications, return after play), the library and the Copy diagnostics report.

struct SettingsPage: View {
    let build: BuildStore   // whether a build runs turns off the update and pull buttons
    let updates: AppUpdateStore
    let repo: RepoStore
    let engine: EngineSyncStore
    let dependencies: DependencyStore
    @ObservedObject var library: GameLibrary
    var diagnostics: (LibraryGame?, @escaping (String) -> Void) -> Void = { _, _ in }   // the report of Copy diagnostics (LauncherStores)
    var onChooseLibraryFolder: () -> Void = {}
    var onOpenControls: () -> Void = {}
    var onOpenControllers: () -> Void = {}   // the Controllers sheet (the console mode's list, with the player-mode setting)
    var onRunSetup: (() -> Void)?   // the guided first-run setup, again (nil where there is none)
    var controlChanges = 0
    var padMerge: Binding<Bool> = .constant(false)   // "All controllers are player 1" (ControlLayout.padMerge)
    @AppStorage(ConsolePrompt.defaultsKey) private var consolePromptOn = true   // ConsoleCoordinator.swift
    @AppStorage(ConsolePrompt.startKey) private var startInConsole = false   // ConsoleCoordinator.swift (#336)
    @AppStorage(BuildNotice.defaultsKey) private var notifyBuilds = true   // BuildNotifications.swift
    @AppStorage(ReturnAfterPlay.defaultsKey) private var returnAfterPlay = true   // ReturnAfterPlay.swift
    @EnvironmentObject var loc: Localizer

    var body: some View {
        CardPageHeading(loc.t("settings.heading"), note: loc.t("settings.note"))
        LibraryCard(library: library, onChooseFolder: onChooseLibraryFolder)
        ControlsCard(controlChanges: controlChanges, padMerge: padMerge, consolePrompt: $consolePromptOn,
                     startInConsole: $startInConsole, onOpenControls: onOpenControls, onOpenControllers: onOpenControllers,
                     onOpenHomeSettings: HomeButtonSettings.available ? { HomeButtonSettings.open() } : nil)   // HomeButtonSettings.swift (#336)
        ToolsCard(repo: repo, engine: engine, dependencies: dependencies, buildRunning: build.running,
                  shellCache: { ShellCacheRow(build: build) }, builder: { ExperimentalBuilderRow(build: build) }) {
            DiagnosticsButton(report: diagnostics, game: library.selected)
        }
        AppCard(updates: updates, buildRunning: build.running, notify: $notifyBuilds, notifyAvailable: BuildNotice.hasBundleID,
                returnAfterPlay: $returnAfterPlay, onRunSetup: onRunSetup, uninstallPlan: uninstallPlan)
    }

    private func uninstallPlan() -> Uninstall.Plan {
        Uninstall.plan(home: NSHomeDirectory(), gamesFolder: library.folder, outputFolder: build.outDir,
                       checkouts: [repo.path], defaultsDomain: Bundle.main.bundleIdentifier)
    }
}

/// Settings, "Library": the folder the launcher looks for games in. It stays in the app target because it observes `GameLibrary`.
struct LibraryCard: View {
    @ObservedObject var library: GameLibrary
    let onChooseFolder: () -> Void
    @EnvironmentObject var loc: Localizer

    var body: some View {
        CardGroup(loc.t("section.library"), footnote: loc.t("library.folderHint")) {
            CardRow(loc.t("library.folderTitle"), detail: library.folder.isEmpty ? loc.t("library.folderUnset") : RepoLayout.shortPath(library.folder),
                dot: library.folder.isEmpty ? LauncherPalette.unbuilt : LauncherPalette.ready, help: library.folder) {
                if library.scanning { ProgressView().controlSize(.small) }
                if !library.folder.isEmpty {
                    Button(loc.t("library.rescan")) { library.discover() }.disabled(library.scanning)
                        .padTarget("set.rescan", scope: "main") { if !library.scanning { library.discover() } }
                }
                Button(loc.t("library.chooseFolder"), action: onChooseFolder)
                    .padTarget("set.folder", scope: "main") { onChooseFolder() }
            }
        }
    }
}
