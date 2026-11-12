import SwiftUI
import NXCore
import NXLauncher
import NXModel

// The Settings page: a selector for General, Library, Controls and Tools, then the cards of the one chosen. The page owns what only the app can give the cards: the switches kept in the app's
// defaults (the console prompt, build notifications, return after play, the check of a new app's first start), the library and the Copy diagnostics report.

struct SettingsPage: View {
    let build: BuildStore   // whether a build runs turns off the update and pull buttons
    let updates: AppUpdateStore
    let repo: RepoStore
    let engine: EngineSyncStore
    let dependencies: DependencyStore
    @ObservedObject var library: GameLibrary
    var players: PlayerProfileStore? = nil
    var sticks: StickDeadzoneStore? = nil   // Controls: StickDeadzoneCard
    var saveSettings: SaveSettingsStore? = nil   // the cloud saves and save folder for every game (GlobalSavesCard)
    var diagnostics: (LibraryGame?, @escaping (String) -> Void) -> Void = { _, _ in }   // the report of Copy diagnostics (LauncherStores)
    var onChooseLibraryFolder: () -> Void = {}
    var onOpenControls: () -> Void = {}
    var onOpenControllers: () -> Void = {}   // the Controllers sheet (the console mode's list, with the player-mode setting)
    var onRunSetup: (() -> Void)?   // the guided first-run setup, again (nil where there is none)
    var controlChanges = 0
    var padMerge: Binding<Bool> = .constant(false)   // "All controllers are player 1" (ControlLayout.padMerge)
    var buildFiles: BuildFilesStore? = nil   // Tools: BuildFilesCard (#232)
    var buildingID: UUID? = nil   // the game a build runs for: its build files cannot be removed
    var onBuildFileDetails: (UUID) -> Void = { _ in }   // Details…: the game's Free space sheet, part by part
    @Binding var category: SettingsCategory
    @AppStorage(ConsolePrompt.defaultsKey) private var consolePromptOn = true   // ConsoleCoordinator.swift
    @AppStorage(ConsolePrompt.startKey) private var startInConsole = false   // ConsoleCoordinator.swift (#336)
    @AppStorage(BuildNotice.defaultsKey) private var notifyBuilds = true   // BuildNotifications.swift
    @AppStorage(ReturnAfterPlay.defaultsKey) private var returnAfterPlay = true   // ReturnAfterPlay.swift
    @AppStorage(MacPreflight.defaultsKey) private var preflightAfterBuild = true   // MacPreflight.swift (#1005)
    @State private var pendingScrollID: String?
    @EnvironmentObject var loc: Localizer

    var body: some View {
        LauncherStickyPageScroll(memoryKey: "settings." + category.rawValue, scrollRequest: $pendingScrollID) {
            CardPageHeading(loc.t("settings.heading"), note: loc.t("settings.note"))
        } bar: {
            LauncherSegmented(options: SettingsCategory.allCases.map { ($0.rawValue, loc.t($0.labelKey)) }, selection: category.rawValue) {
                category = SettingsCategory(rawValue: $0) ?? .general
            }
            .accessibilityElement(children: .contain).accessibilityLabel(loc.t("settings.heading"))
            .padTarget("set.category", scope: "main", radius: 17, activate: { move(1) }, adjust: { move($0) })
        } content: {
            switch category {
            case .general: general
            case .library: libraryCategory
            case .controls: controls
            case .tools: tools
            }
        }
    }

    private func move(_ by: Int) {
        let all = SettingsCategory.allCases
        let at = all.firstIndex(of: category) ?? 0
        category = all[(at + by + all.count) % all.count]
    }

    /// The row for a missing tool opens Tools with the dependency list open and scrolled to.
    private func showTools() {
        category = .tools
        if !dependencies.open { dependencies.toggle() }
        pendingScrollID = "set.deps"
    }

    private func appCard(_ part: AppCard.Part) -> AppCard {
        AppCard(updates: updates, buildRunning: build.running, notify: $notifyBuilds, notifyAvailable: BuildNotice.hasBundleID,
                returnAfterPlay: $returnAfterPlay, preflightAfterBuild: $preflightAfterBuild, onRunSetup: onRunSetup, uninstallPlan: uninstallPlan, part: part)
    }

    @ViewBuilder private var general: some View {
        MissingToolRow(dependencies: dependencies, showTools: showTools)
        appCard(.general)
        PersonalDefaultsCard()
        appCard(.updates)
    }

    @ViewBuilder private var libraryCategory: some View {
        LibraryFoldersCard(library: library, onAddFolder: onChooseLibraryFolder)
        if let saveSettings { GlobalSavesCard(settings: saveSettings) }
        if let players { PlayersCard(players: players) }
    }

    @ViewBuilder private var controls: some View {
        ControlsCard(controlChanges: controlChanges, padMerge: padMerge, consolePrompt: $consolePromptOn,
                     startInConsole: $startInConsole, onOpenControls: onOpenControls, onOpenControllers: onOpenControllers,
                     onOpenHomeSettings: HomeButtonSettings.available ? { HomeButtonSettings.open() } : nil)   // HomeButtonSettings.swift (#336)
        if let sticks { StickDeadzoneCard(store: sticks) }
    }

    @ViewBuilder private var tools: some View {
        KeysCard(build: build)
        ToolsCard(repo: repo, engine: engine, dependencies: dependencies, buildRunning: build.running,
                  shellCache: { ShellCacheRow(build: build) }, builder: { if ExperimentalBuilder.featureEnabled { ExperimentalBuilderRow(build: build) } }) {
            DiagnosticsButton(report: diagnostics, game: library.selected)
        }
        .id("set.deps")
        if let buildFiles {
            BuildFilesCard(store: buildFiles, buildingID: buildingID, details: onBuildFileDetails)
                .onAppear { buildFiles.refresh(BuildFiles.games(library.games, lang: loc.lang)) }
        }
        appCard(.maintenance)
    }

    private func uninstallPlan() -> Uninstall.Plan {
        Uninstall.plan(home: NSHomeDirectory(), gamesFolder: library.folder, outputFolder: build.outDir,
                       checkouts: [repo.path], defaultsDomain: Bundle.main.bundleIdentifier)
    }
}

/// Settings, Library, "Games folders": one row for each folder the launcher looks for games in, with whether it is connected, and Add
/// folder below. A folder on a drive that is not connected is shown as missing and its games stay in the library. It stays in the app
/// target because it observes `GameLibrary`.
struct LibraryFoldersCard: View {
    @ObservedObject var library: GameLibrary
    let onAddFolder: () -> Void
    @EnvironmentObject var loc: Localizer

    private func stateText(_ state: LibraryRoots.State) -> String {
        switch state {
        case .connected: return loc.t("library.root.connected")
        case .disconnected: return loc.t("library.root.disconnected")
        case .missing: return loc.t("library.root.missing")
        case .covered(let parent): return String(format: loc.t("library.root.covered"), RepoLayout.shortPath(parent))
        }
    }

    private func dot(_ state: LibraryRoots.State) -> Color {
        switch state {
        case .connected: return LauncherPalette.ready
        case .covered: return LauncherPalette.unbuilt
        case .disconnected, .missing: return LauncherPalette.building
        }
    }

    var body: some View {
        CardGroup(loc.t("library.folders"), footnote: loc.t("library.folderHint")) {
            if library.folders.isEmpty {
                CardRow(loc.t("library.folderTitle"), detail: loc.t("library.folderUnset"), dot: LauncherPalette.unbuilt) { EmptyView() }
                CardDivider()
            }
            ForEach(Array(library.folders.enumerated()), id: \.element) { index, root in
                let state = library.rootState(root)
                let name = (root as NSString).lastPathComponent
                // The path in the middle-truncating mono line, then the state in words
                CardRow(name.isEmpty ? root : name, detail: stateText(state), detail2: RepoLayout.shortPath(root), dot: dot(state), help: root) {
                    if library.scanning { ProgressView().controlSize(.small) }
                    Button(loc.t("library.rescan")) { library.rescan() }
                        .disabled(library.scanning || state != .connected)
                        .accessibilityLabel(String(format: loc.t("library.rescanFolder"), name))
                        .padTarget("set.rescan.\(index)", scope: "main") { if !library.scanning, state == .connected { library.rescan() } }
                    Button(loc.t("library.removeFolder")) { library.removeFolder(root) }
                        .accessibilityLabel(String(format: loc.t("library.removeFolderNamed"), name))
                        .padTarget("set.removeFolder.\(index)", scope: "main") { library.removeFolder(root) }
                }
                CardDivider()
            }
            CardRow(loc.t("library.addFolder")) {
                Button(loc.t("library.addFolderBtn"), action: onAddFolder)
                    .padTarget("set.folder", scope: "main") { onAddFolder() }
            }
        }
    }
}
