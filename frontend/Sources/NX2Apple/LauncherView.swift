import SwiftUI
import UniformTypeIdentifiers
import NXCore
import NXModel
import NXLauncher

enum LauncherPage: String, CaseIterable {
    case library, builds, settings
    var symbol: String {
        switch self {
        case .library: return "gamecontroller"
        case .builds: return "shippingbox"
        case .settings: return "slider.horizontal.3"
        }
    }
}

/// The library's filter: every game in the games folder, or only those with a build. Remembered between launches.
enum LibraryFilter: String, CaseIterable, Identifiable {
    case owned, built
    var id: String { rawValue }
    var labelKey: String { "filter." + rawValue }

    /// Owned shows every game without reading its build, so the default filter costs nothing per card.
    func includes(_ game: LibraryGame) -> Bool { self == .owned || game.isReady || game.hasIOSBuild }

    static func load(_ defaults: UserDefaults = .standard) -> LibraryFilter {
        LibraryFilter(rawValue: defaults.string(forKey: "libraryFilter") ?? "") ?? .owned
    }
    func save(_ defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: "libraryFilter") }

    /// The selection and the controller's focus after a switch to this filter. A selected game the filter hides gives way to the
    /// first one it shows, and a focus on a hidden card is dropped, so neither the hero nor the A button reaches a game that is not
    /// on screen.
    func reconcile(games: [LibraryGame], selectedID: UUID?, focused: String?) -> (selectedID: UUID?, focused: String?) {
        let shown = games.filter(includes)
        let selection = shown.contains { $0.id == selectedID } ? selectedID : shown.first?.id
        guard let focused, focused.hasPrefix("card.") else { return (selection, focused) }
        return (selection, shown.contains { "card." + $0.id.uuidString == focused } ? focused : nil)
    }
}

struct ContentView: View {
    @StateObject private var m: BuildModel
    @ObservedObject private var loc: Localizer   // the strings: handed on to every view below through the environment
    @ObservedObject private var updates: AppUpdateStore   // the app's self-update: the update icon, the sheet, the uninstall dialog
    @ObservedObject private var repo: RepoStore   // the repository: the activity line, and the checks that follow a change of it
    @ObservedObject private var engine: EngineSyncStore   // the engine: the sync banner, and the checks that follow a sync
    @StateObject private var library: GameLibrary
    @State private var page: LauncherPage = .library
    @State private var search = ""
    @State private var searching = false
    @State private var consolePrompt = false
    private let enterConsole: (() -> Void)?   // nil until the console mode is wired: no entry button, no prompt
    private let injectedDriver: Bool
    @StateObject private var consoleDriver: AnyConsoleDriver
    @State private var controllerSheet = false
    @FocusState private var searchFocused: Bool
    @State private var artwork: [UUID: NSImage] = [:]
    @State private var activeBuildID: UUID?
    @State private var launching = false
    @State private var launchError: String?
    @State private var removing: LibraryGame?
    @State private var optionsFor: UUID?
    @State private var freeSpaceFor: UUID?   // the game whose Free space sheet is open
    @State private var controlsOpen = false
    @State private var savesFor: UUID?   // the game whose Saves sheet is open (SaveTransfer.swift)
    @State private var cheatsFor: UUID?  // the game whose Cheats sheet is open (CheatsView.swift)
    @State private var manageOpenFor: UUID?   // the game whose Manage menu is open (ManageMenu.swift)
    @StateObject private var controls: ControlLayout
    @StateObject private var gamepad: LauncherGamepad
    @StateObject private var padFocus = PadFocus()
    @StateObject private var row = RowScroller()
    @StateObject private var toolsAge: ToolsAge
    @State private var buildCommit = ""   // the engine's commit when the running build started (ToolsAge)
    @State private var signatureExpiry: [UUID: Date] = [:]   // installed apps' provisioning-profile expiry, per game
    @State private var resignNote: String?   // the last re-sign's outcome, shown under the hero's expiry line
    private var performStartupChecks: Bool
    private let onRunSetup: (() -> Void)?   // Settings' "Run setup again"; the root view supplies it
    private let qaManage: (open: Bool, ring: Bool)   // visual QA: the Manage menu open at launch, with the controller's focus ring or without
    @Environment(\.scenePhase) private var scenePhase

    init(model: BuildModel? = nil, library: GameLibrary? = nil, initialPage: LauncherPage = .library,
         activeBuildID: UUID? = nil, performStartupChecks: Bool = true, search: String? = nil, olderTools: Set<UUID> = [],
         manageOpen: Bool = false, padRing: Bool = false, onRunSetup: (() -> Void)? = nil,
         enterConsole: (() -> Void)? = nil, controllerDriver: AnyConsoleDriver? = nil, controls sharedControls: ControlLayout? = nil, qaPrompt: Bool = false,
         gamepad: LauncherGamepad? = nil) {
        _consolePrompt = State(initialValue: qaPrompt)   // visual QA: the connect prompt open at launch
        self.onRunSetup = onRunSetup
        let layout = sharedControls ?? ControlLayout()
        _controls = StateObject(wrappedValue: layout)
        _consoleDriver = StateObject(wrappedValue: controllerDriver ?? AnyConsoleDriver(LauncherControllerDriver(layout: layout)))
        injectedDriver = controllerDriver != nil
        self.enterConsole = enterConsole
        qaManage = (manageOpen, padRing)
        if let search { _search = State(initialValue: search); _searching = State(initialValue: true) }   // visual QA: the bar with its field open
        _toolsAge = StateObject(wrappedValue: ToolsAge(older: olderTools))   // visual QA: games marked without a checkout to compare
        _gamepad = StateObject(wrappedValue: gamepad ?? LauncherGamepad())   // LauncherPerformanceTests presses its buttons
        let model = model ?? BuildModel()
        _m = StateObject(wrappedValue: model)
        _loc = ObservedObject(wrappedValue: model.localizer)
        _updates = ObservedObject(wrappedValue: model.appUpdates)
        _repo = ObservedObject(wrappedValue: model.repo); _engine = ObservedObject(wrappedValue: model.engineSync)
        _library = StateObject(wrappedValue: library ?? GameLibrary())
        _page = State(initialValue: initialPage)
        _activeBuildID = State(initialValue: activeBuildID)
        self.performStartupChecks = performStartupChecks
    }

    /// "All controllers are player 1": saved here, passed to games as DM_PAD_MERGE, shown in the Controllers sheet too.
    private func setPadMerge(_ on: Bool) {
        controls.padMerge = on
        if injectedDriver { consoleDriver.setPadMerge(on) }
    }

    @State private var libraryFilter: LibraryFilter = LibraryFilter.load()

    private func setLibraryFilter(_ filter: LibraryFilter) {
        guard filter != libraryFilter else { return }
        withAnimation(.easeInOut(duration: 0.2)) { libraryFilter = filter }
        filter.save()
        let after = filter.reconcile(games: library.games, selectedID: library.selectedID, focused: padFocus.focused)
        if after.selectedID != library.selectedID { library.selectedID = after.selectedID }
        if after.focused != padFocus.focused { padFocus.focused = after.focused }
    }

    private var filteredGames: [LibraryGame] {
        library.games.filter { (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) && libraryFilter.includes($0) }
    }

    /// The hero's game: the selection, unless the filter hides it, then the first game the filter shows.
    private var heroGame: LibraryGame? {
        guard libraryFilter != .owned else { return library.selected }
        if let selected = library.selected, libraryFilter.includes(selected) { return selected }
        return library.games.first(where: libraryFilter.includes)
    }

    var body: some View {
        launcherBody
        .overlay(alignment: .top) {
            if !controllerSheet, let toast = consoleDriver.state.toast { ConsoleToastView(toast: toast) }
        }
        .sheet(isPresented: $controllerSheet) {
            ConsoleControllersSheet(driver: consoleDriver, lang: loc.lang, close: { controllerSheet = false; consoleDriver.back() })
                .environmentObject(padFocus)
        }
        .onChange(of: controllerSheet) { open in
            padFocus.scope = open ? "console.controllers" : currentPadScope
            if open { consoleDriver.openControllers(); padFocus.focused = "console.controller.merge" }
            else if consoleDriver.state.presentedSheet == .controllers { consoleDriver.back() }
        }
        .overlay {
            if consolePrompt, let enterConsole {
                ConsoleConnectionPrompt(lang: loc.lang, enterConsole: { consolePrompt = false; enterConsole() }, dismissPrompt: { consolePrompt = false })
            }
        }
        .onChange(of: gamepad.connected) { connected in
            if connected, enterConsole != nil, ConsolePrompt.shouldShow(enabled: ConsolePrompt.enabled, shown: ConsolePrompt.shownThisSession) {
                ConsolePrompt.didShow()
                consolePrompt = true
            }
        }
        .onChange(of: consoleDriver.state.padMerge) { merged in if injectedDriver { controls.padMerge = merged } }
        .onChange(of: consolePrompt) { open in
            padFocus.scope = open ? "console.entry" : currentPadScope
            if open { padFocus.focused = "console.entry.enter" }
        }
        .environmentObject(padFocus)
        .environmentObject(loc)
    }

    private var launcherBody: some View {
        VStack(spacing: 0) {
            topBar
            Divider().opacity(0.3)
            EngineSyncBanner(engine: engine, m: m)
            if page == .library {
                libraryPage
            } else {
                BuilderView(m: m, updates: updates, repo: repo, engine: engine, dependencies: m.dependencies, devices: m.deviceStore, library: library, settings: page == .settings, onViewGame: { page = .library },
                            onOpenSettings: { page = .settings }, onChooseLibraryFolder: chooseLibraryFolder,
                            onOpenControls: { controlsOpen = true }, onOpenControllers: { controllerSheet = true }, onRunSetup: onRunSetup, controlChanges: controls.changeCount,
                            padMerge: Binding(get: { controls.padMerge }, set: { setPadMerge($0) }))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if m.running || page == .library { activityBar }
        }
        .padScope("main", padFocus)
        .environmentObject(padFocus)
        .manageMenuOverlay(items: manageOpenFor.flatMap { id in library.games.first { $0.id == id } }.map(manageItems),
                           label: loc.t("library.manage"), pad: padFocus) { manageOpenFor = nil }
        .launcherDropdownHost()
        .onChange(of: manageOpenFor) { id in
            padFocus.scope = id != nil ? "manage" : currentPadScope
            if id != nil, padFocus.visible {   // opened by the controller: its focus lands on the first usable row
                DispatchQueue.main.async { padFocus.show(default: ManagePad.firstFocus(manageItems(for: library.selected))) }
            }
        }
        .background(LauncherPalette.background)
        .background(LauncherWindowChrome())
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
        .tint(LauncherPalette.cream)
        .font(.manrope(13))   // the default for text without a font of its own
        .frame(minWidth: 900, idealWidth: 1280, minHeight: 680, idealHeight: 900)
        .onAppear {
            gamepad.perform = padAction
            gamepad.capture = { [consoleDriver] id, action in consoleDriver.consumePress(controllerID: id, isBack: action == .b) }
            if performStartupChecks { library.migrateLaunchOptions(); CloudSavesMigration.run() }
            if qaManage.open {
                if qaManage.ring { padFocus.show(default: nil) }
                manageOpenFor = library.selected?.id
            }
            refreshArtwork()
            readSignatures()
            if performStartupChecks { library.discover(); fetchArtwork(); _ = m.deviceStore.refresh(); checkTools() }
            if performStartupChecks {
                _ = m.dependencies.check()
                if engine.usesEngineStore { engine.prepareEngine() }   // the release app: its engine store, never git
                else { engine.syncEngine() }   // a checkout whose engine/ is missing or older than its pin (#214)
                if repo.isRepo && repo.isGit { repo.checkForUpdates(silent: true) } else { repo.adoptAtLaunch() }
                updates.checkForUpdate(silent: true)
                BuildNotifier.shared.watch(m, library: library)   // BuildNotifications.swift
            }
        }
        .onReceive(BuildNotifier.shared.$route) { route in   // a clicked build notification
            guard let route else { return }
            page = route.page
            if let id = route.game { library.selectedID = id }
            DispatchQueue.main.async { BuildNotifier.shared.route = nil }
        }
        .onChange(of: library.games) { _ in
            refreshArtwork()
            readSignatures()
            if performStartupChecks { fetchArtwork() }
        }
        .onChange(of: repo.path) { _ in refreshArtwork(); if performStartupChecks { checkTools() } }
        // A clone, pull or update check has finished (the automatic pull at launch among them): the checkout may have moved
        .onReceive(repo.$busy.removeDuplicates().dropFirst()) { busy in if !busy && performStartupChecks { checkTools() } }
        .onReceive(engine.$syncing.removeDuplicates().dropFirst()) { syncing in if !syncing && performStartupChecks { checkTools() } }   // a sync made or moved the engine (its HEAD is what ToolsAge compares)
        .onChange(of: library.selectedID) { _ in resignNote = nil }   // the last re-sign's note belongs to its game
        .onChange(of: buildProgress) { progress in if m.running { DockProgress.update(progress) } }
        .onReceive(m.$running.removeDuplicates()) { running in
            if !running { DockProgress.update(nil) }
            if running && activeBuildID == nil { activeBuildID = library.rememberInputs(m) }
            if running && activeBuildID != nil {   // the tools this build runs: a pull waits for the build (RepoStore.pull, autoPull)
                buildCommit = ""
                let dir = repo.path
                DispatchQueue.global(qos: .utility).async {
                    let commit = ToolsAge.head(repo: dir) ?? ""
                    DispatchQueue.main.async { buildCommit = commit }
                }
            }
            if !running {
                DispatchQueue.main.async {
                    if m.done { recordBuild() }
                    activeBuildID = nil
                    engine.applyPendingEngine()   // an engine installed during the build takes over once it is recorded
                }
            }
        }
        .onReceive(m.$done.removeDuplicates()) { done in
            if done { DispatchQueue.main.async { recordBuild() } }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { library.objectWillChange.send() }
        }
        .alert(loc.t("library.error"), isPresented: Binding(
            get: { launchError != nil || library.error != nil },
            set: { if !$0 { launchError = nil; library.error = nil } }
        )) {
            Button(loc.t("library.ok")) { launchError = nil; library.error = nil }
        } message: { Text(launchError ?? library.error ?? "") }
        .confirmationDialog(loc.t("library.removeQuestion"), isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible) {
            Button(loc.t("library.remove"), role: .destructive) {
                if let game = removing { library.remove(game.id) }
                removing = nil
            }
        } message: { Text(loc.t("library.removeNote")) }
        .sheet(isPresented: Binding(get: { optionsFor != nil }, set: { if !$0 { optionsFor = nil } })) {
            if let id = optionsFor { LaunchOptionsView(m: m, library: library, gameID: id).environmentObject(padFocus).launcherDropdownHost() }
        }
        .sheet(isPresented: $controlsOpen) { ControlsView(layout: controls).environmentObject(padFocus).launcherDropdownHost() }
        .sheet(isPresented: Binding(get: { freeSpaceFor != nil }, set: { if !$0 { freeSpaceFor = nil } })) {
            if let game = library.games.first(where: { $0.id == freeSpaceFor }) { FreeSpaceView(m: m, game: game).environmentObject(padFocus) }
        }
        .onChange(of: freeSpaceFor) { id in padFocus.scope = id != nil ? "free" : currentPadScope }
        .sheet(isPresented: $updates.showUpdateSheet) { UpdateSheet(updates: updates) }
        .confirmationDialog(loc.t("uninstall.title"), isPresented: Binding(
            get: { updates.uninstallPlan != nil }, set: { if !$0 { updates.uninstallPlan = nil } }
        ), titleVisibility: .visible) {
            Button(loc.t("uninstall.confirmButton"), role: .destructive) {
                updates.confirmUninstall()
            }
        } message: { Text(loc.t("uninstall.confirm")) }
        .sheet(isPresented: Binding(get: { savesFor != nil }, set: { if !$0 { savesFor = nil } })) {
            if let id = savesFor { SavesView(m: m, library: library, gameID: id).environmentObject(padFocus).launcherDropdownHost() }
        }
        .onChange(of: savesFor) { id in padFocus.scope = id != nil ? "saves" : currentPadScope }
        .cheatsSheet(for: $cheatsFor, m: m, library: library, pad: padFocus) { currentPadScope }
        .onChange(of: optionsFor) { id in padFocus.scope = id != nil ? "launch" : (controlsOpen ? "controls" : "main") }
        .onChange(of: controlsOpen) { open in padFocus.scope = open ? "controls" : (optionsFor != nil ? "launch" : "main") }
        .onChange(of: page) { _ in padFocus.focused = nil }
        .onChange(of: padFocus.focused) { id in   // a controller moving onto a game's card selects it, as a click does
            if let id, id.hasPrefix("card."), let uuid = UUID(uuidString: String(id.dropFirst(5))) { library.selectedID = uuid }
        }
    }

    @ViewBuilder private func navLabel(_ destination: LauncherPage, compact: Bool) -> some View {
        if compact { Image(systemName: destination.symbol).accessibilityLabel(loc.t("nav." + destination.rawValue)) }
        else { Label(loc.t("nav." + destination.rawValue), systemImage: destination.symbol) }
    }

    private var topBar: some View {
        GeometryReader { geometry in
            let compact = false   // the bar holds the tabs, search and Build game only, as before the console mode
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    // The project is NX2Apple (the user's call: what this fork produces is NX2Apple);
                    // "by nxnative" credits the engine it stands on, which the sketch kept.
                    VStack(alignment: .leading, spacing: -2) {
                        Text("NX2Apple").font(.manrope(27, .bold)).tracking(-0.8)
                        Text("— by nxnative").font(.manrope(10.5, .medium))
                            .foregroundStyle(LauncherPalette.unbuilt).tracking(0.2)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.trailing, compact ? 16 : 34)
                    ForEach(LauncherPage.allCases, id: \.self) { destination in
                        Button { page = destination } label: {
                            // The selected tab is bold. The bold text also sizes the (hidden) slot, so a tab never changes width as the selection moves.
                            ZStack {
                                navLabel(destination, compact: compact).font(.manrope(15, .bold)).hidden()
                                navLabel(destination, compact: compact).font(.manrope(15, page == destination ? .bold : .medium))
                            }
                                .padding(.horizontal, compact ? 14 : 18).padding(.vertical, 10)
                                .background(page == destination ? Color.white.opacity(0.10) : .clear,
                                            in: RoundedRectangle(cornerRadius: 9))
                                .contentShape(RoundedRectangle(cornerRadius: 9))   // the whole pill takes the click, not only its text
                        }
                        .buttonStyle(.plain).help(loc.t("nav." + destination.rawValue))
                        .accessibilityAddTraits(page == destination ? .isSelected : [])
                        .padTarget("tab." + destination.rawValue, scope: "main") { page = destination }
                    }
                    Spacer(minLength: 8)
                    searchField
                    Button { newBuild() } label: {
                        Group {
                            if compact { Image(systemName: "plus").accessibilityLabel(loc.t("library.newBuild")) }
                            else { Label(loc.t("library.newBuild"), systemImage: "plus") }
                        }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.1)))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain).disabled(m.running).help(loc.t("library.newBuild")).accessibilityLabel(loc.t("library.newBuild"))
                    .padTarget("top.build", scope: "main", radius: 8) { if !m.running { newBuild() } }
                    .padding(.leading, 12)
                    // A newer release is out: a small icon, last in the bar, opens the update sheet. Without one the bar
                    // stays as it is.
                    if let update = updates.update {
                        let readOnly = updates.installability == .readOnly
                        Button { updates.showUpdateSheet = true } label: {
                            Image(systemName: readOnly ? "exclamationmark.arrow.circlepath" : "arrow.down.circle")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(readOnly ? LauncherPalette.building : LauncherPalette.ready)
                                .frame(width: 34, height: 34).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padTarget("top.update", scope: "main", radius: 17) { updates.showUpdateSheet = true }
                        .padding(.leading, 16.5).padding(.trailing, -7.5)
                        .help(String(format: loc.t("update.pill"), update.tag) + "\n" + loc.t(readOnly ? "update.readOnlyHint" : "update.pillHelp"))
                        .accessibilityLabel(String(format: loc.t("update.pill"), update.tag))
                    }
                }
                .padding(.leading, 90).padding(.trailing, 24)
                .frame(height: 64)
                .background(TitlebarDoubleClick())   // an empty part of the bar acts as the title bar does
            }
        }
        .frame(height: 64)
    }


    /// The magnifier opens into a search field in the bar itself; Esc, or leaving it empty, closes it again.
    private var searchField: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { searching = true; page = .library }
                searchFocused = true
            } label: {
                Image(systemName: "magnifyingglass").font(.system(size: searching ? 13 : 16, weight: .medium))
                    .foregroundStyle(searching ? Color.secondary : Color.primary)
                    .frame(width: searching ? 16 : 40, height: searching ? 16 : 40).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(loc.t("library.search")).accessibilityLabel(loc.t("library.search"))
            if searching {
                TextField(loc.t("library.search"), text: $search)
                    .textFieldStyle(.plain).font(.manrope(14))
                    .focused($searchFocused)
                    .onSubmit { if search.isEmpty { closeSearch() } }
                    .onExitCommand { closeSearch() }
                    .frame(width: 210)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                Button { closeSearch() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).help(loc.t("library.clearSearch")).accessibilityLabel(loc.t("library.clearSearch"))
            }
        }
        .padding(.horizontal, searching ? 12 : 0)
        .frame(height: 36)
        .background(searching ? Color.white.opacity(0.07) : .clear, in: Capsule())
        .overlay(Capsule().strokeBorder(searching ? Color.white.opacity(searchFocused ? 0.22 : 0.10) : .clear))
        .onChange(of: searchFocused) { focused in
            if !focused && search.isEmpty { closeSearch() }
        }
    }

    private func closeSearch() {
        search = ""
        searchFocused = false
        withAnimation(.easeOut(duration: 0.2)) { searching = false }
    }

    /// The collection row's measured height (CollectionHeightKey); the hero above it takes the rest of the page.
    @State private var collectionHeight: CGFloat = 274

    private var libraryPage: some View {
        GeometryReader { geometry in
            if library.games.isEmpty {
                emptyLibrary
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let game = heroGame {
                            hero(game, width: geometry.size.width, height: max(240, geometry.size.height - collectionHeight))
                        }
                        // The hero takes what the collection leaves: the row's height grows with the window's width (its cards
                        // do, up to 300 pt), so a fixed share left a fullscreen window's cards cut off at the bottom
                        collection(width: geometry.size.width)
                            .background(GeometryReader { g in Color.clear.preference(key: CollectionHeightKey.self, value: g.size.height) })
                    }
                }
                .onPreferenceChange(CollectionHeightKey.self) { h in if h > 0, abs(h - collectionHeight) > 0.5 { collectionHeight = h } }
            }
        }
    }

    private var emptyLibrary: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer()
            Image(systemName: "gamecontroller").font(.system(size: 44, weight: .light))
                .foregroundStyle(LauncherPalette.cream)
            Text(loc.t("library.welcome")).font(.manrope(54, .bold)).tracking(-1.8)
            Text(loc.t("library.welcomeNote")).font(.manrope(17)).foregroundStyle(.secondary)
                .frame(maxWidth: 490, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            Button { newBuild() } label: {
                Label(loc.t("library.firstBuild"), systemImage: "plus")
                    .font(.manrope(16, .semibold))
                    .padding(.horizontal, 24).padding(.vertical, 15)
                    .foregroundStyle(.black).background(LauncherPalette.cream, in: Capsule())
            }
            .buttonStyle(.plain).padding(.top, 8)
            Button(action: chooseLibraryFolder) {
                Label(loc.t("library.chooseFolder"), systemImage: "folder")
                    .font(.manrope(14)).foregroundStyle(.secondary)
            }.buttonStyle(.plain)
            Spacer()
            Text(loc.t("library.localNote")).font(.manrope(12)).foregroundStyle(.secondary)
        }
        .padding(48).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func hero(_ game: LibraryGame, width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let image = artwork[game.id] {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: width, height: height).clipped()
            } else {
                LauncherPalette.surface
                Image(systemName: "gamecontroller").font(.system(size: 160, weight: .ultraLight))
                    .foregroundStyle(Color.white.opacity(0.05))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(60)
            }
            LinearGradient(stops: [.init(color: .clear, location: 0.25),
                                   .init(color: .black.opacity(0.25), location: 0.45),
                                   .init(color: LauncherPalette.background, location: 1)],
                           startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [.black.opacity(0.24), .clear], startPoint: .leading, endPoint: .trailing)
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    status(game, prominent: true)
                    if toolsAge.older.contains(game.id) && !(m.running && activeBuildID == game.id) {
                        Button { configureBuild(game) } label: {
                            Label(loc.t("library.rebuildShort"), systemImage: "arrow.clockwise")
                                .font(.manrope(12, .semibold)).foregroundStyle(LauncherPalette.cream)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .overlay(Capsule().strokeBorder(LauncherPalette.cream.opacity(0.35)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain).disabled(m.running || game.inputs["base", default: []].isEmpty)
                        .help(loc.t("library.olderToolsHelp"))
                        .padTarget("hero.rebuild", scope: "main", radius: 12) { if !m.running { configureBuild(game) } }
                    }
                }
                Text(game.name).font(.manrope(min(68, width * 0.052), .heavy))
                    .tracking(-1.6).lineLimit(2).shadow(color: .black.opacity(0.25), radius: 12)
                HStack(spacing: 18) {
                    Button { primaryAction(game) } label: {
                        LauncherHeroActionLabel(
                            title: game.primary == .play ? loc.t("library.play")
                                : (game.primary == .openOnDevice ? String(format: loc.t("dev.open"), m.deviceName(game.installedDevice))
                                   : loc.t("library.newBuild")),
                            symbol: game.primary == .play ? "play.fill" : (game.primary == .openOnDevice ? "iphone" : "hammer.fill"))
                    }
                    .buttonStyle(.plain).disabled(launching || (m.running && !game.isReady))
                    .keyboardShortcut(.return, modifiers: [])
                    .padTarget("hero.play", scope: "main", radius: 30) { if !launching { primaryAction(game) } }
                    if game.isReady {
                        Button { optionsFor = game.id } label: {
                            Image(systemName: "slider.horizontal.3").font(.system(size: 17))
                                .frame(width: 48, height: 48)
                                .background(Color.white.opacity(0.10), in: Circle())
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.14)))
                        }
                        .buttonStyle(.plain).help(loc.t("launch.title")).accessibilityLabel(loc.t("launch.title"))
                        .padTarget("hero.options", scope: "main", radius: 24) { optionsFor = game.id }
                    }
                    Button { manageOpenFor = manageOpenFor == nil ? game.id : nil } label: { ManageButtonLabel(title: loc.t("library.manage")) }
                        .buttonStyle(.plain).accessibilityLabel(loc.t("library.manage"))
                        .anchorPreference(key: ManageAnchorKey.self, value: .bounds) { $0 }
                        .padTarget("hero.manage", scope: "main", radius: 12) { manageOpenFor = game.id }
                }
                // A free Apple ID's provisioning profile lasts 7 days. Say when this app's runs out, and offer the
                // re-sign at any time: renewing early (before a trip, say) is as valid as renewing just in time.
                if game.onDevice && !game.isOlderIOSBuild {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.seal").font(.system(size: 12))
                            .foregroundStyle(LauncherPalette.cream.opacity(0.7))
                        Text(signatureExpiry[game.id].map { AppSignature.describe($0, loc.t) } ?? loc.t("dev.expiryUnknown"))
                            .font(.manrope(12.5))
                            .foregroundStyle(signatureExpiry[game.id].map { AppSignature.isUrgent($0) } == true
                                             ? LauncherPalette.building : .secondary)
                        Button { resign(game) } label: {
                            Text(loc.t("dev.resign")).font(.manrope(12, .semibold))
                                .foregroundStyle(LauncherPalette.cream)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .overlay(Capsule().strokeBorder(LauncherPalette.cream.opacity(0.35)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain).disabled(m.running)
                        .help(loc.t("dev.resignHelp"))
                        .padTarget("hero.resign", scope: "main", radius: 12) { if !m.running { resign(game) } }
                    }
                }
                if let resignNote {
                    Text(resignNote).font(.manrope(12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 34).padding(.bottom, 34)
        }
        .frame(width: width, height: height).clipped()
    }

    private func collection(width: CGFloat) -> some View {
        let cardWidth = min(300, max(190, (width - 124) / 5))
        let step = cardWidth + 14
        let games = filteredGames
        let heroID = heroGame?.id
        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                Text(loc.t("library.collection")).font(.manrope(28, .bold)).tracking(-0.6)
                Spacer()
                LauncherSegmented(options: LibraryFilter.allCases.map { ($0.rawValue, loc.t($0.labelKey)) },
                                  selection: libraryFilter.rawValue) { setLibraryFilter(LibraryFilter(rawValue: $0) ?? .owned) }
                    .frame(width: LauncherControl.width)
                    .padTarget("library.filter", scope: "main", radius: 17,
                               activate: { setLibraryFilter(libraryFilter == .owned ? .built : .owned) },
                               adjust: { setLibraryFilter($0 > 0 ? .built : .owned) })
                Text(String(format: loc.t("library.gameCount"), libraryFilter == .owned ? library.games.count : library.games.filter(libraryFilter.includes).count))
                    .font(.manrope(12)).foregroundStyle(.secondary)
            }
            if games.isEmpty {
                Text(loc.t("library.noResults")).foregroundStyle(.secondary).padding(.vertical, 28)
            } else {
                ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(games) { game in
                                let _ = LauncherWork.count(.card)
                                Button { library.selectedID = game.id } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ZStack {
                                            if let image = artwork[game.id] {
                                                Image(nsImage: image).resizable().scaledToFill()
                                            } else {
                                                LauncherPalette.surface
                                                Image(systemName: "gamecontroller").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                                            }
                                        }
                                        .frame(width: cardWidth, height: cardWidth / 1.8).clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(
                                            game.id == heroID ? LauncherPalette.cream : .clear, lineWidth: 2))
                                        Text(game.name).font(.manrope(16, .semibold)).lineLimit(1)
                                        status(game)
                                        Capsule().fill(game.id == heroID ? LauncherPalette.cream : .clear)
                                            .frame(height: 3).padding(.top, 4)
                                    }
                                    .frame(width: cardWidth, alignment: .leading).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(game.id == heroID ? .isSelected : [])
                                .padTarget("card." + game.id.uuidString, scope: "main", radius: 7) { if !launching { primaryAction(game) } }
                            }
                        }
                        // Room for the controller's focus ring, which sits 4 pt outside a card: the row clips at its edges, so it
                        // gets the room inside and gives it back outside (the cards stay where they were)
                        .padding(.horizontal, Self.ringRoom).padding(.top, Self.ringRoom).padding(.bottom, 5 + Self.ringRoom)
                        .background(EnclosingScrollView(row: row))
                    }
                    .padding(.horizontal, -Self.ringRoom).padding(.vertical, -Self.ringRoom)
                    .onChange(of: padFocus.focused) { id in   // the focused card scrolls into the row's view
                        guard let id, id.hasPrefix("card.") else { return }
                        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                    .overlay(alignment: .topLeading) {
                        if row.canBack {
                            pager("chevron.left", height: cardWidth / 1.8) { row.page(-1, step: step) }.offset(x: -22)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if row.canForward {
                            pager("chevron.right", height: cardWidth / 1.8) { row.page(1, step: step) }.offset(x: 22)
                        }
                    }
            }
        }
        .padding(.horizontal, 34).padding(.top, 8).padding(.bottom, 22)
    }

    /// A round button floating over the row's edge, centred on the artwork, shown while the row scrolls that way.
    private func pager(_ symbol: String, height: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.black.opacity(0.72), in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.16)))
                .shadow(color: .black.opacity(0.4), radius: 10)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(height: height)
        .accessibilityLabel(loc.t(symbol == "chevron.left" ? "library.scrollBack" : "library.scrollForward"))
        .transition(.opacity)
    }

    private func status(_ game: LibraryGame, prominent: Bool = false) -> some View {
        let building = m.running && activeBuildID == game.id
        let color = building ? LauncherPalette.building : ((game.isReady || game.hasIOSBuild) ? LauncherPalette.ready : LauncherPalette.unbuilt)
        let key = building ? "library.building" : (game.isReady ? "library.ready" : (game.hasIOSBuild ? (game.isOlderIOSBuild ? "library.olderIOS" : "library.readyIOS") : "library.notBuilt"))
        return HStack(spacing: 7) {
            Circle().fill(color).frame(width: prominent ? 9 : 7, height: prominent ? 9 : 7)
            Text(prominent ? loc.t(key).uppercased() : loc.t(key))
                .font(prominent ? .manrope(12, .bold) : .manrope(13, .medium))
                .tracking(prominent ? 1.3 : 0)   // the eyebrow: the same face, in tracked capitals
                .foregroundStyle(color)
            if !building && toolsAge.older.contains(game.id) {   // a quiet note beside the status, not a warning
                Text("· " + loc.t(prominent ? "library.olderTools" : "library.olderToolsShort"))
                    .font(.manrope(prominent ? 13 : 12)).foregroundStyle(.secondary).lineLimit(1)
                    .help(loc.t("library.olderToolsHelp"))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var activityBar: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.3)
            HStack(spacing: 22) {
                if m.running {
                    Image(systemName: "wrench.and.screwdriver").font(.system(size: 22, weight: .light)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(loc.t(m.deviceStore.shellCopy != nil || m.deviceStore.shellWaiting || m.stages.contains { $0.id == 1003 && $0.state == .running }
                                 ? "activity.transfer" : (m.target == BuildTarget.mac ? "activity.mac" : "activity.ios"))).font(.manrope(15, .bold))
                        TimelineView(.periodic(from: Date(), by: 1)) { context in   // the clock ticks while a count may stand still
                            Text(m.stages.last(where: { $0.state == .running })
                                    .map { [$0.name, $0.detail, $0.clock(at: context.date, left: loc.t("prog.eta"))].filter { !$0.isEmpty }.joined(separator: " · ") }
                                 ?? loc.t("library.preparing"))
                                .font(.manrope(13)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .frame(minWidth: 180, alignment: .leading)
                    LauncherProgressBar(value: buildProgress).frame(maxWidth: 480)
                    Text(buildProgress.map { "\(Int($0 * 100))%" } ?? "")
                        .font(.manrope(14, .semibold)).monospacedDigit().foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                    Spacer(minLength: 8)
                    Button(loc.t("library.viewBuild")) { page = .builds }.buttonStyle(LauncherSecondaryButtonStyle())
                    Button(loc.t(m.stopping ? "library.stopping" : "btn.stop")) { m.stop() }
                        .buttonStyle(LauncherSecondaryButtonStyle(accent: LauncherPalette.building)).disabled(m.stopping)
                } else {
                    Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                    Text(loc.t("library.localNote")).font(.manrope(13)).foregroundStyle(.secondary)
                    if let n = repo.autoPulled, n > 0 {   // the automatic update when the app opened (RepoStore.autoPull): the tools are current
                        Circle().fill(LauncherPalette.ready).frame(width: 6, height: 6).padding(.leading, 10)
                        Text(String(format: loc.t("library.toolsUpdated"), n)).font(.manrope(13)).foregroundStyle(.secondary)
                    }
                    if repo.autoAdopted {   // a ZIP copy connected and updated when the app opened (RepoStore.adoptAtLaunch)
                        Circle().fill(LauncherPalette.ready).frame(width: 6, height: 6).padding(.leading, 10)
                        Text(loc.t("library.toolsAdopted")).font(.manrope(13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let staged = updates.staged {
                        // A downloaded, verified update (AppUpdateStore.stage): it goes in when the app quits, or now.
                        // This branch only shows with no build running, and restartNow checks again.
                        HStack(spacing: 10) {
                            Circle().fill(LauncherPalette.ready).frame(width: 6, height: 6)
                            Text(String(format: loc.t("library.appReady"), staged.release.tag)).font(.manrope(13)).foregroundStyle(.secondary)
                        }
                        Button(loc.t("app.restartNow")) { updates.restartNow() }.buttonStyle(LauncherSecondaryButtonStyle())
                    }
                    if gamepad.connected {
                        // The buttons a controller has here, named as the game names them (A on the right)
                        HStack(spacing: 18) {
                            padHint(.activate, loc.t("pad.play")); padHint(.launchOptions, loc.t("pad.options")); padHint(.back, loc.t("pad.back"))
                            padHint(.manage, loc.t("pad.manage"))
                            if enterConsole != nil { padHint(.select, loc.t("console.entry")) }
                        }
                    }
                }
            }
            .padding(.horizontal, 30).frame(height: 84)
        }
    }

    /// A pad hint shows the glyph of the controller connected (the same ConsoleGlyphs the console mode uses), so it names the button
    /// that really performs the action on a DualSense, an Xbox or a Nintendo-layout controller.
    private func padHint(_ role: ConsoleGlyphs.Role, _ label: String) -> some View {
        HStack(spacing: 7) {
            ConsoleGlyphView(glyph: ConsoleGlyphs.current().glyph(for: role), size: 18).foregroundStyle(LauncherPalette.cream)
            Text(label).font(.manrope(13)).foregroundStyle(.secondary)
        }
    }

    private var buildProgress: Double? {
        // The script reports a percentage for the current step, not for all remaining work.
        guard let percent = m.stages.last(where: { $0.state == .running })?.percent else { return nil }
        return percent / 100
    }

    private func newBuild() {
        guard !m.running else { page = .builds; return }
        for index in m.slots.indices { m.slots[index].paths = []; m.slots[index].problem = "" }
        m.gameDir = ""; m.done = false; m.doneNote = ""; m.macAppPath = ""; m.stages = []
        if m.outDir.isEmpty && !library.folder.isEmpty { m.outDir = library.folder }
        page = .builds
    }

    private func configureBuild(_ game: LibraryGame) {
        guard !m.running else { page = .builds; return }
        for index in m.slots.indices {
            m.slots[index].paths = game.inputs[m.slots[index].id] ?? []
            m.slots[index].problem = ""
        }
        // The folder the game's files were found in (a base package may sit one level down in its own folder) — from the
        // scan, or from the last build. Falling back to the base's folder would put the update and DLC out of reach.
        m.gameDir = game.sourceFolder.isEmpty ? (m.basePath as NSString).deletingLastPathComponent : game.sourceFolder
        m.outDir = game.outputDirectory
        m.done = false; m.doneNote = ""; m.stages = []
        m.target = game.lastTarget
        page = .builds
    }

    /// A controller's button (LauncherGamepad): the first press shows the focus (on the selected game's card in the library),
    /// then the D-pad moves it (PadFocus), A activates, B closes a sheet or goes back to the library, X opens the selected
    /// game's launch options, L and R switch the pages.
    private func padAction(_ action: LauncherGamepad.Action) {
        if action == .select {   // the controller's Select-type button opens console mode
            if let enterConsole { consolePrompt = false; enterConsole() }
            return
        }
        if consolePrompt {
            switch action {
            case .b: consolePrompt = false
            case .a: padFocus.activate()
            case .left: padFocus.horizontal(-1)
            case .right: padFocus.horizontal(1)
            case .up: padFocus.move(dx: 0, dy: -1)
            case .down: padFocus.move(dx: 0, dy: 1)
            default: break
            }
            return
        }
        let sheetOpen = controllerSheet || optionsFor != nil || controlsOpen || savesFor != nil || cheatsFor != nil || freeSpaceFor != nil
        switch ManagePad.route(action, menuOpen: manageOpenFor != nil, sheetOpen: sheetOpen, hasGame: library.selected != nil && page == .library) {
        case .close: manageOpenFor = nil; return
        case .swallow: return
        case .open:
            guard let game = library.selected else { return }
            padFocus.show(default: nil)   // the ring shows: the menu's own focus follows once it is drawn
            manageOpenFor = game.id
            return
        case .pass: break
        }
        if action == .b, controllerSheet { controllerSheet = false; return }
        if action == .b, savesFor != nil { savesFor = nil; return }
        if action == .b, cheatsFor != nil { cheatsFor = nil; return }
        // The Free space sheet: B closes it, the D-pad and A work in it, X, L and R do nothing behind it
        if freeSpaceFor != nil && [.b, .x, .l, .r].contains(action) { if action == .b { freeSpaceFor = nil }; return }
        if action == .b {
            if optionsFor != nil { optionsFor = nil } else if controlsOpen { controlsOpen = false }
            else if searching { searching = false; search = "" } else if page != .library { page = .library }
            return
        }
        if removing != nil { return }   // the remove dialog is AppKit's; it takes the mouse or the keyboard
        if !padFocus.visible {
            padFocus.show(default: manageOpenFor != nil ? ManagePad.firstFocus(manageItems(for: library.selected))
                          : !sheetOpen && page == .library ? library.selectedID.map { "card." + $0.uuidString } : nil)
            if [.up, .down, .left, .right].contains(action) { return }   // the first press only shows where the focus is
        }
        switch action {
        case .up: padFocus.move(dx: 0, dy: -1)
        case .down: padFocus.move(dx: 0, dy: 1)
        case .left: padFocus.horizontal(-1)
        case .right: padFocus.horizontal(1)
        case .a: padFocus.activate()
        case .x:
            if !sheetOpen, let game = library.selected, game.isReady { optionsFor = game.id }
        case .l, .r:
            guard !sheetOpen, let at = LauncherPage.allCases.firstIndex(of: page) else { return }
            let pages = LauncherPage.allCases
            page = pages[(at + (action == .l ? pages.count - 1 : 1)) % pages.count]
        case .y, .plus, .select:   // Y is the Manage menu: ManagePad.route opened it above
            return
        case .b:
            return
        }
    }

    /// The Manage menu's rows for a game, wired to the launcher's sheets and actions (ManageItem.list).
    private func manageItems(_ game: LibraryGame) -> [ManageItem] {
        ManageItem.list(game: game, labels: loc.t, running: m.running, olderTools: toolsAge.older.contains(game.id), activeBuildID: activeBuildID,
                        hasBuildFolder: BuildFolder.location(for: game) != nil,
                        hasLog: GameLog.latest(titleID: game.titleID, appPath: game.appPath) != nil,
                        actions: ManageActions(
                            rebuild: { configureBuild(game) }, options: { optionsFor = game.id }, saves: { savesFor = game.id }, cheats: { cheatsFor = game.id },
                            changeArtwork: { chooseArtwork(game) }, resetArtwork: { library.setArtwork("", for: game.id) },
                            reveal: { if let path = game.revealTarget { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } },
                            showLog: { if let log = GameLog.latest(titleID: game.titleID, appPath: game.appPath) { GameLog.show(log) } },
                            freeSpace: { freeSpaceFor = game.id }, remove: { removing = game }))
    }

    private func manageItems(for game: LibraryGame?) -> [ManageItem] { game.map(manageItems) ?? [] }

    /// The scope a controller acts in when no menu is open: the innermost sheet, else the window.
    private var currentPadScope: String {
        controllerSheet ? "console.controllers" : savesFor != nil ? "saves" : cheatsFor != nil ? "cheats" : freeSpaceFor != nil ? "free" : optionsFor != nil ? "launch" : controlsOpen ? "controls" : "main"
    }

    /// The space the collection row keeps around its cards for the focus ring (PadFocus draws it 4 pt outside a target).
    static let ringRoom: CGFloat = 6

    private func primaryAction(_ game: LibraryGame) {
        if !game.isReady && game.onDevice {   // installed on a device: start it there
            launching = true
            m.openOnDevice(udid: game.installedDevice, app: game.iosAppPath) { error in
                launching = false
                if let error { launchError = error }
            }
            return
        }
        guard game.isReady else { configureBuild(game); return }
        do {
            _ = try MacGameBundle.read(URL(fileURLWithPath: game.appPath))
            launching = true
            let configuration = NSWorkspace.OpenConfiguration()
            // The launch options; the app's launcher (dm/mac/launcher.c) keeps a variable that is already set.
            // The keyboard and controller layout (Settings → Controls) goes to every game; a build whose host does not read it plays with the default keys.
            // They stay launch overrides (the environment) for now: DM_KEYMAP and DM_PAD_MAP become saved choices only when seedds/nxnative#386 merges.
            let environment = GameStart.environment(for: game, library: library, controls: controls, repo: m.repoPath, labels: loc.t)   // GameStart.swift: the console mode starts games with the same
            let withRecording = environment.merging(FrameTimes.recordingEnvironment(for: game, library: library.folder)) { $1 }   // FrameTimes.swift, as console mode does
            if !withRecording.isEmpty { configuration.environment = withRecording }
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: game.appPath), configuration: configuration) { app, error in
                let pid = app?.processIdentifier
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        launching = false
                        if let error { launchError = error.localizedDescription }
                        else if let pid { GameReturnWatcher.shared.didStart(pid: pid) }   // ReturnAfterPlay.swift
                    }
                }
            }
        } catch { launchError = error.localizedDescription }
    }

    /// The installed apps' profile expiries, read in the background: `security cms` per app, so not in a view body.
    private func readSignatures() {
        let apps = library.games.filter(\.onDevice).map { ($0.id, $0.iosAppPath) }
        guard !apps.isEmpty else { signatureExpiry = [:]; return }
        DispatchQueue.global(qos: .utility).async {
            var found: [UUID: Date] = [:]
            for (id, path) in apps { if let date = AppSignature.expiration(ofApp: path, runner: m.runner) { found[id] = date } }
            DispatchQueue.main.async { signatureExpiry = found }
        }
    }

    /// Sign the installed app again for another 7 days (a free Apple ID's profile), then install it: the game's code
    /// is not rebuilt, and its Documents stay.
    private func resign(_ game: LibraryGame) {
        resignNote = nil
        m.resignOnDevice(app: game.iosAppPath, device: game.installedDevice) {
            resignNote = m.doneNote
            signatureExpiry[game.id] = AppSignature.expiration(ofApp: game.iosAppPath, runner: m.runner)
        }
    }

    private func recordBuild() {
        guard m.done, let id = activeBuildID else { return }
        if m.target == BuildTarget.mac { library.recordCompletedApp(path: m.macAppPath, commit: buildCommit, for: id) }
        else { library.recordCompletedIOS(archive: m.archivePath, app: m.installedAppPath, device: m.installedOn, commit: buildCommit, for: id) }
        refreshArtwork()
        if performStartupChecks { checkTools() }
    }

    private func checkTools() { toolsAge.check(games: library.games, repo: m.repoPath) }

    private func refreshArtwork() {
        artwork = Dictionary(uniqueKeysWithValues: library.games.compactMap { game in
            GameLibrary.artwork(for: game, repo: m.repoPath).map { (game.id, $0) }
        })
    }

    /// The eShop key art of the games that have none yet; the cards and the hero redraw as it arrives.
    private func fetchArtwork() {
        let ids = library.games.map(\.titleID)
        Task {
            let added = await ArtworkStore.shared.fetchMissing(ids)
            if !added.isEmpty { await MainActor.run { refreshArtwork() } }
        }
    }

    private func chooseArtwork(_ game: LibraryGame) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        panel.message = loc.t("library.artworkHint")
        if panel.runModal() == .OK, let url = panel.url, NSImage(contentsOf: url) != nil {
            library.setArtwork(url.path, for: game.id)
        }
    }

    private func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = loc.t("library.folderHint")
        if !library.folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: library.folder) }
        if panel.runModal() == .OK, let url = panel.url {
            library.setFolder(url)
            if !m.running { m.outDir = url.path }
        }
    }
}
