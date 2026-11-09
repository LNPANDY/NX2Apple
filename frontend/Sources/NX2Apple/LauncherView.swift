import SwiftUI
import UniformTypeIdentifiers
import NXCore
import NXModel
import NXLauncher

struct LauncherView: View {
    let stores: LauncherStores   // the wiring: the stores below are its, the views take what they show
    @StateObject var m: BuildStore   // the build: the stages, the failure, the inputs
    @ObservedObject var devices: DeviceStore   // the copy card and the activity line while the data goes over
    @ObservedObject var loc: Localizer   // the strings: handed on to every view below through the environment
    @ObservedObject private var updates: AppUpdateStore   // the app's self-update: the update icon, the sheet, the uninstall dialog
    @ObservedObject private var repo: RepoStore   // the repository: the activity line, and the checks that follow a change of it
    @ObservedObject private var engine: EngineSyncStore   // the engine: the sync banner, and the checks that follow a sync
    @StateObject var library: GameLibrary
    @State var page: LauncherPage = .library
    @State var settingsCategory: SettingsCategory = .general   // the part of Settings shown
    @State private var search = ""
    @State private var searching = false
    @State private var consolePrompt = false
    private let enterConsole: (() -> Void)?   // nil until the console mode is wired: no entry button, no prompt
    private let injectedDriver: Bool
    @StateObject private var consoleDriver: AnyConsoleDriver
    @State private var controllerSheet = false
    @FocusState private var searchFocused: Bool
    @State var artwork: [UUID: NSImage] = [:]   // card size
    @State var heroArtwork: (id: UUID, image: NSImage)?   // the hero game's, at the size the hero needs
    @StateObject private var recorder: BuildRecorder   // writes the builds into the library: the session's, so a build that ends in console mode is recorded too
    var activeBuildID: UUID? { recorder.activeBuildID }
    @State var launching = false
    @StateObject private var cloudGate = CloudSaveGate()   // the check of the cloud's save before a start (CloudSaveGate.swift, #957)
    @State private var launchError: String?
    @State private var removing: LibraryGame?
    @State private var selectingGames = false   // the Build selected games sheet (BuildSelectedSheet.swift)
    @State private var deleting: LibraryGame?   // the game whose Delete sheet is open (DeleteGameSheet.swift)
    @State var supportedGames: [SupportedGame]?   // the Supported games sheet is open when this is set (SupportedGamesSheet.swift)
    @State private var renaming: LibraryGame?   // the game whose Rename sheet is open (RenameGameSheet.swift)
    @State var optionsFor: UUID?
    @State private var controllerMappingOpen = false
    @State private var freeSpaceFor: UUID?   // the game whose Free space sheet is open
    @State private var controlsOpen = false
    @State private var controlsCancelRequest = 0   // the controller's B in the Controls sheet: asks to leave like Cancel
    @State private var savesFor: UUID?   // the game whose Saves sheet is open (SaveTransfer.swift)
    @State private var cheatsFor: UUID?  // the game whose Cheats sheet is open (CheatsView.swift)
    @State var manageOpenFor: UUID?   // the game whose Manage menu is open (ManageMenu.swift)
    @State var artworkEditor: ArtworkEditor?   // the game whose artwork panel is open (ArtworkPanel.swift, LauncherView+Artwork.swift)
    @State var artworkSlot: ArtworkSlot?   // its tab: the part of the library not being edited dims
    @State var artworkPreview: GameArtwork?   // its draft, which the hero and the selected card draw instead of the saved artwork
    @State var previewGeneration = 0   // the latest preview decode: an older one that finishes late is dropped
    @State var artworkHeroAspect = ArtworkEditor.heroBandAspect   // the hero's proportions now, the band the panel frames for
    let artworkStore: ArtworkStore
    @StateObject private var controls: ControlLayout
    @StateObject private var gamepad: LauncherGamepad
    @StateObject var padFocus: PadFocus
    @StateObject var row = RowScroller()
    @StateObject var toolsAge: ToolsAge
    @State var signatureExpiry: [UUID: Date] = [:]   // installed apps' provisioning-profile expiry, per game
    @State var resignNote: String?   // the last re-sign's outcome, shown under the hero's expiry line
    private var performStartupChecks: Bool
    private let onRunSetup: (() -> Void)?   // Settings' "Run setup again"; the root view supplies it
    private let qaManage: (open: Bool, ring: Bool)   // visual QA: the Manage menu open at launch, with the controller's focus ring or without
    private let qaArtwork: ArtworkSlot?   // visual QA: the artwork panel open at launch, on this tab
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    init(stores: LauncherStores? = nil, library: GameLibrary? = nil, initialPage: LauncherPage = .library, settingsCategory: SettingsCategory = .general,
         activeBuildID: UUID? = nil, performStartupChecks: Bool = true, search: String? = nil, olderTools: Set<UUID> = [],
         manageOpen: Bool = false, padRing: Bool = false, onRunSetup: (() -> Void)? = nil,
         enterConsole: (() -> Void)? = nil, controllerDriver: AnyConsoleDriver? = nil, controls sharedControls: ControlLayout? = nil, recorder: BuildRecorder? = nil, qaPrompt: Bool = false,
         gamepad: LauncherGamepad? = nil, padFocus: PadFocus? = nil, artworkOpen: ArtworkSlot? = nil, artworkEditor: ArtworkEditor? = nil, artworkStore: ArtworkStore = .shared) {
        _padFocus = StateObject(wrappedValue: padFocus ?? PadFocus())
        _consolePrompt = State(initialValue: qaPrompt)   // visual QA: the connect prompt open at launch
        self.onRunSetup = onRunSetup
        let layout = sharedControls ?? ControlLayout()
        _controls = StateObject(wrappedValue: layout)
        _consoleDriver = StateObject(wrappedValue: controllerDriver ?? AnyConsoleDriver(LauncherControllerDriver(layout: layout)))
        injectedDriver = controllerDriver != nil
        self.enterConsole = enterConsole
        qaManage = (manageOpen, padRing)
        qaArtwork = artworkOpen
        self.artworkStore = artworkStore
        _artworkEditor = State(initialValue: artworkEditor)   // tests hand in one with its own environment
        _artworkPreview = State(initialValue: artworkEditor?.draft)   // and the library draws its draft from the first frame
        _artworkSlot = State(initialValue: artworkEditor?.slot)
        if let search { _search = State(initialValue: search); _searching = State(initialValue: true) }   // visual QA: the bar with its field open
        _toolsAge = StateObject(wrappedValue: ToolsAge(older: olderTools))   // visual QA: games marked without a checkout to compare
        _gamepad = StateObject(wrappedValue: gamepad ?? LauncherGamepad())   // LauncherPerformanceTests presses its buttons
        let stores = stores ?? LauncherStores(); self.stores = stores
        _m = StateObject(wrappedValue: stores.build); _loc = ObservedObject(wrappedValue: stores.localizer)
        _updates = ObservedObject(wrappedValue: stores.appUpdates); _devices = ObservedObject(wrappedValue: stores.deviceStore)
        _repo = ObservedObject(wrappedValue: stores.repo); _engine = ObservedObject(wrappedValue: stores.engineSync)
        let library = library ?? GameLibrary()
        _library = StateObject(wrappedValue: library)
        _recorder = StateObject(wrappedValue: recorder ?? BuildRecorder(stores: stores, library: library, activeBuildID: activeBuildID))
        _page = State(initialValue: initialPage)
        _settingsCategory = State(initialValue: settingsCategory)
        self.performStartupChecks = performStartupChecks
    }

    /// "All controllers are player 1": saved here, passed to games as DM_PAD_MERGE, shown in the Controllers sheet too.
    private func setPadMerge(_ on: Bool) {
        controls.padMerge = on
        if injectedDriver { consoleDriver.setPadMerge(on) }
    }

    @State var libraryFilter: LibraryFilter = LibraryFilter.load()
    @State var librarySort: LibrarySort = LibrarySort.load()

    /// Order of the collection. The selection stays whatever it was: the order only moves cards.
    func setLibrarySort(_ sort: LibrarySort) {
        guard sort != librarySort else { return }
        librarySort = sort
        sort.save()
    }

    func setLibraryFilter(_ filter: LibraryFilter) {
        guard filter != libraryFilter else { return }
        withAnimation(.easeInOut(duration: 0.2)) { libraryFilter = filter }
        filter.save()
        let after = filter.reconcile(games: library.games, selectedID: library.selectedID, focused: padFocus.focused, sort: librarySort)
        if after.selectedID != library.selectedID { library.selectedID = after.selectedID }
        if after.focused != padFocus.focused { padFocus.focused = after.focused }
    }

    var filteredGames: [LibraryGame] {
        libraryFilter.visibleGames(library.games, matching: search, lang: loc.lang, sort: librarySort)
    }

    /// The hero's game: the selection, unless the filter hides it, then the first game the filter shows.
    var heroGame: LibraryGame? {
        guard libraryFilter != .owned else { return library.selected }
        if let selected = library.selected, libraryFilter.includes(selected) { return selected }
        return libraryFilter.visibleGames(library.games, lang: loc.lang, sort: librarySort).first
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
        .onChange(of: consoleDriver.state.joyconSplit) { split in if injectedDriver { controls.joyconSplit = split } }
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
                .background(LauncherPalette.background)   // opaque: a scrolled page passes under it, never through it
                .zIndex(1)
            LauncherTopBarRule()
            EngineSyncBanner(engine: engine, m: m)
            if page == .library {
                HStack(spacing: 0) {
                    // The activity bar stays under the library, so the panel runs to the window's bottom edge with its buttons
                    VStack(spacing: 0) {
                        libraryPage
                            .allowsHitTesting(artworkEditor == nil)   // the library stays visible as the live preview, and takes no click or Return
                            .transaction { if reduceMotion { $0.animation = nil } }   // under Reduce Motion the panel fades in, nothing moves
                        activityBar
                    }
                    if let editor = artworkEditor {
                        Divider().opacity(0.3)
                        ArtworkPanel(editor: editor, labels: loc.t, save: { closeArtwork(save: true) }, cancel: { closeArtwork(save: false) })
                            .onReceive(editor.$draft) { refreshPreview($0) }
                            .onReceive(editor.$slot) { artworkSlot = $0 }
                            .onChange(of: artworkHeroAspect) { editor.heroAspect = $0 }
                            .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                    }
                }
            } else {
                CardPages(settings: page == .settings, build: m, updates: updates, repo: repo, engine: engine, dependencies: stores.dependencies, devices: devices, queue: stores.queue, transfers: stores.transfers, onSelectGames: { selectingGames = true },
                          sticks: stores.sticks, saveSettings: stores.saveSettings, players: stores.players,
                          library: library, diagnostics: stores.diagnostics, onViewGame: { page = .library }, onOpenSettings: { page = .settings },
                          onChooseLibraryFolder: chooseLibraryFolder, onOpenControls: { controlsOpen = true }, onOpenControllers: { controllerSheet = true }, onRunSetup: onRunSetup, controlChanges: controls.changeCount,
                          padMerge: Binding(get: { controls.padMerge }, set: { setPadMerge($0) }), buildFiles: stores.buildFiles, buildingID: m.running ? activeBuildID : nil, onBuildFileDetails: { freeSpaceFor = $0 }, settingsCategory: $settingsCategory)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if m.running && page == .settings { activityBar }
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
        .launcherAppearance()
        .tint(LauncherPalette.accent)
        .font(.manrope(13))   // the default for text without a font of its own
        .frame(minWidth: 900, idealWidth: 1280, minHeight: 680, idealHeight: 900)
        .onDisappear { gamepad.deactivate() }
        .onAppear {
            gamepad.perform = padAction
            gamepad.capture = { [consoleDriver] id, action in consoleDriver.consumePress(controllerID: id, isBack: action == .b) }
            if performStartupChecks {
                library.migrateLaunchOptions(); library.migrateArtwork(); CloudSavesMigration.run()
                library.syncSharedApp(root: m.shellCachePath)
            }
            if let slot = qaArtwork, artworkEditor == nil, let game = library.selected { openArtwork(game, slot: slot) }
            if qaManage.open {
                if qaManage.ring { padFocus.show(default: nil) }
                manageOpenFor = library.selected?.id
            }
            refreshArtwork()
            readSignatures()
            m.sharedAppDataSources = { [library] in   // the games with packed data, for Send all game data (#1036)
                library.games.filter { !$0.archivePath.isEmpty && FileManager.default.fileExists(atPath: $0.archivePath) }
                    .map { TransferSource(titleID: $0.titleID, name: $0.name, archive: $0.archivePath) }
            }
            m.macBuildEnvironment = { [library] titleID in   // the engine takes it only for a game without an icon of its own (#784)
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NX2Apple/fallback-icons", isDirectory: true)
                return FallbackIcon.environment(titleID: titleID, banners: library.artworkDirectory, folder: support)
            }
            library.keysFile = { [m] in m.savedKeys }   // the scan reads renamed packages' title IDs with them (#1012)
            if performStartupChecks { library.discover(); fetchArtwork(); library.fillMissingTitleNames(engineRoot: EngineLayout.root(repo.path)); _ = stores.deviceStore.refresh(); checkTools() }
            if performStartupChecks {
                _ = stores.dependencies.check()
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
        .onChange(of: loc.lang) { _ in if performStartupChecks { fetchArtwork() } }   // the banners in the new language
        .onChange(of: library.games) { _ in
            if performStartupChecks { library.syncSharedApp(root: m.shellCachePath) }
            refreshArtwork()
            readSignatures()
            if performStartupChecks { fetchArtwork(); library.fillMissingTitleNames(engineRoot: EngineLayout.root(repo.path)) }
        }
        .onChange(of: m.savedKeys) { _ in if performStartupChecks { library.discover() } }   // other keys may name other packages (#1012)
        .onReceive(library.$scanning.removeDuplicates().dropFirst()) { scanning in if !scanning && performStartupChecks { checkTools() } }
        .onChange(of: m.shellCachePath) { root in
            if performStartupChecks { library.syncSharedApp(root: root); readSignatures() }
        }
        .onChange(of: repo.path) { _ in refreshArtwork(); if performStartupChecks { checkTools(); library.fillMissingTitleNames(engineRoot: EngineLayout.root(repo.path)) } }
        // A clone, pull or update check has finished (the automatic pull at launch among them): the checkout may have moved
        .onReceive(repo.$busy.removeDuplicates().dropFirst()) { busy in if !busy && performStartupChecks { checkTools() } }
        .onReceive(engine.$syncing.removeDuplicates().dropFirst()) { syncing in if !syncing && performStartupChecks { checkTools() } }   // a sync made or moved the engine (its HEAD is what ToolsAge compares)
        .onChange(of: library.selectedID) { _ in resignNote = nil }   // the last re-sign's note belongs to its game
        .onChange(of: heroGame?.id) { _ in refreshHeroArtwork() }
        .onReceive(recorder.recorded) {   // a build was written into the library (BuildRecorder); a window opened since reads it in onAppear
            refreshArtwork()
            if m.runningTarget != BuildTarget.mac { readSignatures() }
            if performStartupChecks { checkTools() }
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
            if let id = optionsFor { LaunchOptionsView(m: m, library: library, gameID: id, globalControls: controls, controllerMappingPresentation: $controllerMappingOpen,
                              onBuild: { game in DispatchQueue.main.async { configureBuild(game) } },
                              openCheats: { id in optionsFor = nil; DispatchQueue.main.async { cheatsFor = id } },
                              openSaves: { id in optionsFor = nil; DispatchQueue.main.async { savesFor = id } }).environmentObject(padFocus).environmentObject(stores.saveSettings).environmentObject(stores.players).launcherDropdownHost() }
        }
        .sheet(isPresented: $controlsOpen) { ControlsView(layout: controls, cancelRequest: controlsCancelRequest).environmentObject(padFocus).launcherDropdownHost() }
        .sheet(isPresented: Binding(get: { freeSpaceFor != nil }, set: { if !$0 { freeSpaceFor = nil } })) {
            if let game = library.games.first(where: { $0.id == freeSpaceFor }) { FreeSpaceView(m: m, game: game).environmentObject(padFocus) }
        }
        .onChange(of: freeSpaceFor) { id in
            padFocus.scope = id != nil ? "free" : currentPadScope
            if id == nil { stores.buildFiles.refresh(BuildFiles.games(library.games, lang: loc.lang)) }   // Details… may have freed some
        }
        .buildFilesWiring(stores.buildFiles, library: library, recorded: recorder.recorded, buildingID: m.running ? activeBuildID : nil, pad: padFocus, scope: { currentPadScope })
        .cloudSaveSheet(cloudGate, pad: padFocus, scope: { currentPadScope })
        .syncControllerLayouts(library: library, controls: controls)
        .deleteGameSheet($deleting, shellRoot: m.shellCachePath, library: library, loc: loc, pad: padFocus, scope: { currentPadScope })
        .sheet(isPresented: $selectingGames) {
            BuildSelectedSheet(library: library, queue: stores.queue, engineID: engine.selection.engineID, exportsIPA: devices.exportIPA) { selectingGames = false }
                .environmentObject(loc)
        }
        .sheet(isPresented: Binding(get: { supportedGames != nil }, set: { if !$0 { supportedGames = nil } })) {
            SupportedGamesSheet(games: supportedGames ?? [], owned: { id in library.games.first { $0.titleID.uppercased() == id } },
                                cover: { id in ArtworkStore.cachedBanner(id, in: library.artworkDirectory).flatMap { ArtworkImages.shared.image(at: $0, maxPixel: 128) } },
                                showInLibrary: showInLibrary)
                .environmentObject(padFocus)
        }
        .onChange(of: supportedGames == nil) { closed in padFocus.scope = closed ? currentPadScope : "supported" }
        .renameGameSheet($renaming, library: library, pad: padFocus, scope: { currentPadScope })
        .sheet(isPresented: $updates.showUpdateSheet) { UpdateSheet(updates: updates, build: m) }
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
        .onChange(of: optionsFor) { id in
            if id == nil { controllerMappingOpen = false }
            padFocus.scope = currentPadScope
        }
        .onChange(of: controllerMappingOpen) { _ in padFocus.scope = currentPadScope }
        .onChange(of: controlsOpen) { open in padFocus.scope = open ? "controls" : (optionsFor != nil ? "launch" : "main") }
        .onChange(of: page) { page in
            padFocus.focused = nil
            if page != .library { closeArtwork(save: false) }
        }
        .onChange(of: artworkEditor?.gameID) { id in
            padFocus.scope = id != nil ? "artwork" : currentPadScope
            if id != nil, padFocus.visible {   // opened by the controller: its focus lands on the chosen tile once the panel is drawn
                DispatchQueue.main.async { padFocus.show(default: artworkPadFocus) }
            }
        }
        .onChange(of: padFocus.focused) { id in   // a controller moving onto a game's card selects it, as a click does
            if let id, id.hasPrefix("card."), let uuid = UUID(uuidString: String(id.dropFirst(5))) { library.selectedID = uuid }
        }
    }

    @ViewBuilder private func navLabel(_ destination: LauncherPage, compact: Bool) -> some View {
        if compact { Image(systemName: destination.symbol).accessibilityLabel(loc.t("nav." + destination.rawValue)) }
        else { Label(loc.t("nav." + destination.rawValue), systemImage: destination.symbol) }
    }

    private func navigationTabs(compact: Bool = false, tabInset: CGFloat, brandGap: CGFloat) -> some View {
        HStack(spacing: 6) {
            ForEach(LauncherPage.allCases, id: \.self) { destination in
                Button { page = destination } label: {
                    // The selected tab is bold. The bold text also sizes the (hidden) slot, so a tab never changes width as the selection moves.
                    ZStack {
                        navLabel(destination, compact: compact).font(.manrope(15, .bold)).hidden()
                        navLabel(destination, compact: compact).font(.manrope(15, page == destination ? .bold : .medium))
                    }
                        .padding(.horizontal, tabInset).padding(.vertical, 10)
                        .background(page == destination ? LauncherPalette.ink(0.10) : .clear,
                                    in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(RoundedRectangle(cornerRadius: 9))   // the whole pill takes the click, not only its text
                }
                .buttonStyle(.plain).launcherHover().help(loc.t("nav." + destination.rawValue))
                .accessibilityAddTraits(page == destination ? .isSelected : [])
                .padTarget("tab." + destination.rawValue, scope: "main") { page = destination }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.leading, brandGap)
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            // The project is NX2Apple (the user's call: what this fork produces is NX2Apple);
            // "by nxnative" credits the engine it stands on, which the sketch kept.
            VStack(alignment: .leading, spacing: -2) {
                Text("NX2Apple").font(.manrope(27, .bold)).tracking(-0.8)
                Text("— by nxnative").font(.manrope(10.5, .medium))
                    .foregroundStyle(LauncherPalette.unbuilt).tracking(0.2)
            }
            .fixedSize(horizontal: true, vertical: false)
            ViewThatFits(in: .horizontal) {
                navigationTabs(tabInset: 18, brandGap: 34)
                navigationTabs(tabInset: 8, brandGap: 16)
                navigationTabs(compact: true, tabInset: 14, brandGap: 16)
            }
            Spacer(minLength: 8)
            PlayerPicker(players: stores.players)   // whose saves Play uses (PlayerPicker.swift)
            searchField
            Button { newBuild() } label: {
                ViewThatFits(in: .horizontal) {
                    Label(loc.t("library.newBuild"), systemImage: "plus")
                        .fixedSize()
                    Image(systemName: "plus")
                }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(LauncherPalette.menuFill, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LauncherPalette.secondaryBorder))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain).launcherHover().disabled(m.running).help(loc.t("library.newBuild")).accessibilityLabel(loc.t("library.newBuild"))
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
                .buttonStyle(.plain).launcherHover()
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
            .keyboardShortcut("f", modifiers: .command)
            .buttonStyle(.plain).launcherHover().help(loc.t("library.search")).accessibilityLabel(loc.t("library.search"))
            if searching {
                TextField(loc.t("library.search"), text: $search)
                    .textFieldStyle(.plain).font(.manrope(14))
                    .focused($searchFocused)
                    .onAppear { searchFocused = true }
                    .onSubmit { if search.isEmpty { closeSearch() } }
                    .onExitCommand { closeSearch() }
                    .frame(minWidth: 140, idealWidth: 210, maxWidth: 210)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                Button { closeSearch() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(LauncherPalette.secondaryText)
                }
                .buttonStyle(.plain).launcherHover().help(loc.t("library.clearSearch")).accessibilityLabel(loc.t("library.clearSearch"))
            }
        }
        .padding(.horizontal, searching ? 12 : 0)
        .frame(height: 36)
        .background(searching ? LauncherPalette.ink(0.07) : .clear, in: Capsule())
        .overlay(Capsule().strokeBorder(searching ? LauncherPalette.ink(searchFocused ? 0.22 : 0.10) : .clear))
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
    @State var collectionHeight: CGFloat = 274
    /// The hero's height with the panel closed, kept while it is open so the scaled-down hero keeps its proportions.
    @State var closedHeroHeight: CGFloat = 498

    private var activityBar: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.3)
            HStack(spacing: 22) {
                if m.running {
                    let stage = m.stages.last { $0.state == .running }
                    Image(systemName: "wrench.and.screwdriver").font(.system(size: 22, weight: .light)).foregroundStyle(LauncherPalette.secondaryText)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(m.operationTitle ?? loc.t(devices.shellCopy != nil || devices.shellWaiting || m.stages.contains { $0.id == 1003 && $0.state == .running }
                                 ? "activity.transfer" : (m.runningTarget == BuildTarget.mac ? "activity.mac" : "activity.ios"))).font(.manrope(15, .bold))
                            .lineLimit(2)
                        TimelineView(.periodic(from: Date(), by: 1)) { context in   // the clock ticks while a count may stand still
                            Text(stage
                                    .map { [$0.name, $0.detail, $0.clock(at: context.date, left: loc.t("prog.etaEstimate"))].filter { !$0.isEmpty }.joined(separator: " · ") }
                                 ?? loc.t("library.preparing"))
                                .font(.manrope(13)).monospacedDigit().foregroundStyle(LauncherPalette.secondaryText).lineLimit(1).truncationMode(.middle)
                        }
                        if stage?.isScanningLastShaderFiles == true {
                            Text(loc.t("prog.lastShaderFiles")).font(.manrope(13)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(minWidth: 180, alignment: .leading)
                    LauncherProgressBar(value: buildProgress).frame(maxWidth: 480)
                        .accessibilityLabel(loc.t("prog.stageProgress"))
                    Text(buildProgress.map { "\(Int($0 * 100))%" } ?? "")
                        .font(.manrope(14, .semibold)).monospacedDigit().foregroundStyle(LauncherPalette.secondaryText).frame(width: 46, alignment: .leading)
                    Spacer(minLength: 8)
                    Button(loc.t("library.viewBuild")) { page = .builds }.buttonStyle(LauncherSecondaryButtonStyle())
                    Button(loc.t(m.stopping ? "library.stopping" : "btn.stop")) { m.stop() }
                        .buttonStyle(LauncherSecondaryButtonStyle(accent: LauncherPalette.building)).disabled(m.stopping)
                } else {
                    Image(systemName: "desktopcomputer").foregroundStyle(LauncherPalette.secondaryText)
                    Text(loc.t("library.localNote")).font(.manrope(13)).foregroundStyle(LauncherPalette.secondaryText)
                    if let n = repo.autoPulled, n > 0 {   // the automatic update when the app opened (RepoStore.autoPull): the tools are current
                        Circle().fill(LauncherPalette.ready).frame(width: 6, height: 6).padding(.leading, 10)
                        Text(String(format: loc.t("library.toolsUpdated"), n)).font(.manrope(13)).foregroundStyle(LauncherPalette.secondaryText)
                    }
                    if repo.autoAdopted {   // a ZIP copy connected and updated when the app opened (RepoStore.adoptAtLaunch)
                        Circle().fill(LauncherPalette.ready).frame(width: 6, height: 6).padding(.leading, 10)
                        Text(loc.t("library.toolsAdopted")).font(.manrope(13)).foregroundStyle(LauncherPalette.secondaryText)
                    }
                    Spacer()
                    if let staged = updates.staged {
                        // A downloaded, verified update (AppUpdateStore.stage): it goes in when the app quits, or now.
                        // This branch only shows with no build running, and restartNow checks again.
                        HStack(spacing: 10) {
                            Circle().fill(LauncherPalette.ready).frame(width: 6, height: 6)
                            Text(String(format: loc.t("library.appReady"), staged.release.tag)).font(.manrope(13)).foregroundStyle(LauncherPalette.secondaryText)
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
            .padding(.horizontal, 30).frame(minHeight: 84)
        }
    }

    /// A pad hint shows the glyph of the controller connected (the same ConsoleGlyphs the console mode uses), so it names the button
    /// that really performs the action on a DualSense, an Xbox or a Nintendo-layout controller.
    private func padHint(_ role: ConsoleGlyphs.Role, _ label: String) -> some View {
        HStack(spacing: 7) {
            ConsoleGlyphView(glyph: ConsoleGlyphs.current().glyph(for: role), size: 18).foregroundStyle(LauncherPalette.accent)
            Text(label).font(.manrope(13)).foregroundStyle(LauncherPalette.secondaryText)
        }
    }

    private var buildProgress: Double? {
        // The script reports a percentage for the current step, not for all remaining work.
        guard let percent = m.stages.last(where: { $0.state == .running })?.percent else { return nil }
        return percent / 100
    }

    /// Reads the engine's profiles and opens the Supported games sheet. The profiles are small files, read off the main thread.
    func openSupportedGames() {
        let root = EngineLayout.root(repo.path)
        DispatchQueue.global(qos: .userInitiated).async {
            let list = SupportedGames.list(engineRoot: root)
            DispatchQueue.main.async { supportedGames = list }
        }
    }

    /// Supported games > Show in library: the page, the filter and the selection go to that game.
    func showInLibrary(_ id: UUID) {
        page = .library
        if let game = library.games.first(where: { $0.id == id }), !libraryFilter.includes(game) { setLibraryFilter(.owned) }
        library.selectedID = id
    }

    func newBuild() {
        guard !m.running else { page = .builds; return }
        m.leaveGameFolder()
        for index in m.slots.indices { m.slots[index].paths = []; m.slots[index].problem = "" }
        m.gameDir = ""; m.done = false; m.doneNote = ""; m.macAppPath = ""; m.stages = []
        if m.outDir.isEmpty && !library.folder.isEmpty { m.outDir = library.folder }
        page = .builds
    }

    func configureBuild(_ game: LibraryGame) {
        guard !m.running else { page = .builds; return }
        if let folder = game.inputs[GameLibrary.folderInput]?.first {
            m.scan(folder: folder)   // a game folder is read again: its updates and DLC may have changed since
        } else {
            m.leaveGameFolder()
            for index in m.slots.indices {
                m.slots[index].paths = game.inputs[m.slots[index].id] ?? []
                m.slots[index].problem = ""
            }
            // The folder the game's files were found in (a base package may sit one level down in its own folder) — from the
            // scan, or from the last build. Falling back to the base's folder would put the update and DLC out of reach.
            m.gameDir = game.sourceFolder.isEmpty ? (m.basePath as NSString).deletingLastPathComponent : game.sourceFolder
        }
        m.macAppPath = game.appPath
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
        let sheetOpen = controllerSheet || supportedGames != nil || optionsFor != nil || controlsOpen || savesFor != nil || cheatsFor != nil || freeSpaceFor != nil || stores.buildFiles.confirming != nil || deleting != nil || renaming != nil || artworkEditor != nil || cloudGate.isActive
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
        if cloudGate.isActive && [.b, .x, .l, .r].contains(action) { if action == .b { cloudGate.cancel() }; return }
        if action == .b, controllerMappingOpen { controllerMappingOpen = false; return }
        if action == .b, controllerSheet { controllerSheet = false; return }
        if action == .b, artworkEditor != nil { closeArtwork(save: false); return }
        if action == .b, savesFor != nil { savesFor = nil; return }
        if action == .b, cheatsFor != nil { cheatsFor = nil; return }
        // The Free space sheet: B closes it, the D-pad and A work in it, X, L and R do nothing behind it
        if freeSpaceFor != nil && [.b, .x, .l, .r].contains(action) { if action == .b { freeSpaceFor = nil }; return }
        if deleting != nil && [.b, .x, .l, .r].contains(action) { if action == .b { deleting = nil }; return }
        if supportedGames != nil && [.b, .x, .l, .r].contains(action) { if action == .b { supportedGames = nil }; return }
        if renaming != nil && [.b, .x, .l, .r].contains(action) { if action == .b { renaming = nil }; return }
        if action == .b {
            if optionsFor != nil { optionsFor = nil } else if controlsOpen { controlsCancelRequest += 1 }
            else if searching { searching = false; search = "" } else if page != .library { page = .library }
            return
        }
        if removing != nil { return }   // the remove dialog is AppKit's; it takes the mouse or the keyboard
        if !padFocus.visible {
            padFocus.show(default: manageOpenFor != nil ? ManagePad.firstFocus(manageItems(for: library.selected))
                          : artworkEditor != nil ? artworkPadFocus : !sheetOpen && page == .library ? library.selectedID.map { "card." + $0.uuidString } : nil)
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
                        buildFilesTitle: BuildFiles.menuTitle(stores.buildFiles, game: game.id, t: loc.t),
                        hasLog: GameLog.latest(titleID: game.titleID, appPath: game.appPath) != nil,
                        deviceName: devices.deviceName(game.installedDevice), launching: launching,
                        actions: ManageActions(
                            rebuild: { configureBuild(game) }, openOnDevice: { openOnDevice(game) }, options: { optionsFor = game.id }, saves: { savesFor = game.id }, cheats: { cheatsFor = game.id },
                            changeArtwork: { openArtwork(game) }, rename: { renaming = game }, supportedGames: openSupportedGames,
                            reveal: { if let path = game.revealTarget { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } },
                            showLog: { if let log = GameLog.latest(titleID: game.titleID, appPath: game.appPath) { GameLog.show(log) } },
                            removeBuildFiles: { stores.buildFiles.ask(game.id, building: m.running && activeBuildID == game.id) }, remove: { removing = game }, delete: { deleting = game }))
    }

    private func manageItems(for game: LibraryGame?) -> [ManageItem] { game.map(manageItems) ?? [] }

    /// The scope a controller acts in when no menu is open: the innermost sheet, else the window.
    private var currentPadScope: String {
        cloudGate.isActive ? "cloudsave" : controllerSheet ? "console.controllers" : controllerMappingOpen ? "controls" : artworkEditor != nil ? "artwork" : savesFor != nil ? "saves" : cheatsFor != nil ? "cheats" : freeSpaceFor != nil ? "free" : stores.buildFiles.confirming != nil ? "buildfiles" : deleting != nil ? "delete" : supportedGames != nil ? "supported" : renaming != nil ? "rename" : optionsFor != nil ? "launch" : controlsOpen ? "controls" : "main"
    }

    /// The space the collection row keeps around its cards for the focus ring (PadFocus draws it 4 pt outside a target).
    static let ringRoom: CGFloat = 6

    private func openOnDevice(_ game: LibraryGame) {
        guard !launching else { return }
        launching = true
        m.openOnDevice(udid: game.installedDevice, app: game.iosAppPath) { error in
            launching = false
            if let error { launchError = error }
        }
    }

    func primaryAction(_ game: LibraryGame) {
        if game.primary == .openOnDevice { openOnDevice(game); return }
        guard game.isReady else { configureBuild(game); return }
        do {
            _ = try MacGameBundle.read(URL(fileURLWithPath: game.appPath))
            launching = true
            cloudGate.begin(game, proceed: { start(game, cloudChoice: $0) }, ended: { launching = false })   // the cloud's save first, then the start
        } catch { launchError = error.localizedDescription }
    }

    private func start(_ game: LibraryGame, cloudChoice: [String: String]) {
        let configuration = NSWorkspace.OpenConfiguration()
        // The launch options; the app's launcher (dm/mac/launcher.c) keeps a variable that is already set.
        // The keyboard and controller layout (Settings → Controls) goes to every game; a build whose host does not read it plays with the default keys.
        let environment = GameStart.environment(for: game, library: library, controls: controls, repo: stores.repo.path, labels: loc.t, lang: loc.lang, player: stores.players.active,
                                                 saves: (stores.saveSettings.global, stores.saveSettings.game(game.titleID)), sticks: stores.sticks.settings)   // GameStart.swift: the console mode starts games with the same
        let withRecording = environment.merging(FrameTimes.recordingEnvironment(for: game, library: library.folder)) { $1 }.merging(cloudChoice) { $1 }   // FrameTimes.swift, as console mode does
        if !withRecording.isEmpty { configuration.environment = withRecording }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: game.appPath), configuration: configuration) { app, error in
            let pid = app?.processIdentifier
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    launching = false
                    if let error { launchError = error.localizedDescription }
                    else { library.recordPlayed(game.id); if let pid { GameReturnWatcher.shared.didStart(pid: pid) } }   // ReturnAfterPlay.swift, and the Recently played order
                }
            }
        }
    }

    /// The installed apps' profile expiries, read in the background: `security cms` per unique app path, so not in a view body.
    private func readSignatures() {
        let apps = library.games.filter(\.onDevice).map { ($0.id, $0.iosAppPath) }
        guard !apps.isEmpty else { signatureExpiry = [:]; return }
        let runner = stores.runner
        DispatchQueue.global(qos: .utility).async {
            let found = AppSignature.expirations(ofApps: apps, runner: runner)
            DispatchQueue.main.async { signatureExpiry = found }
        }
    }

    /// Sign the installed app again for another 7 days (a free Apple ID's profile), then install it: the game's code
    /// is not rebuilt, and its Documents stay.
    func resign(_ game: LibraryGame) {
        resignNote = nil
        m.resignOnDevice(app: game.iosAppPath, device: game.installedDevice) {
            resignNote = m.doneNote
            if !m.installedOn.isEmpty { library.recordSharedAppInstalled(app: m.installedAppPath, device: m.installedOn) }
            readSignatures()
        }
    }

    private func checkTools() { toolsAge.check(games: library.games, repo: stores.repo.path) }

    func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = loc.t("library.folderHint")
        if !library.folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: library.folder) }
        if panel.runModal() == .OK, let url = panel.url {
            let first = library.folders.isEmpty
            library.addFolder(url)   // several folders are allowed (#992)
            if first, !m.running { m.outDir = url.path }   // where a build goes stays the player's explicit choice
        }
    }
}
