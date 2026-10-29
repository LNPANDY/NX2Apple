import SwiftUI
import UniformTypeIdentifiers

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

enum LauncherPalette {
    static let background = Color(red: 0.055, green: 0.055, blue: 0.06)
    static let surface = Color(red: 0.10, green: 0.10, blue: 0.11)
    static let cream = Color(red: 1, green: 0.94, blue: 0.84)
    static let ready = Color(red: 0.25, green: 0.84, blue: 0.47)
    static let building = Color(red: 1, green: 0.78, blue: 0.24)
    static let unbuilt = Color(red: 0.57, green: 0.58, blue: 0.61)
}

struct ContentView: View {
    @StateObject private var m: BuildModel
    @StateObject private var library: GameLibrary
    @State private var page: LauncherPage = .library
    @State private var search = ""
    @State private var searching = false
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
    @State private var manageOpenFor: UUID?   // the game whose Manage menu is open (ManageMenu.swift)
    @StateObject private var controls = ControlLayout()
    @StateObject private var gamepad = LauncherGamepad()
    @StateObject private var padFocus = PadFocus()
    @StateObject private var row = RowScroller()
    @StateObject private var toolsAge: ToolsAge
    @State private var buildCommit = ""   // the checkout's commit when the running build started (ToolsAge)
    @State private var signatureExpiry: [UUID: Date] = [:]   // installed apps' provisioning-profile expiry, per game
    @State private var resignNote: String?   // the last re-sign's outcome, shown under the hero's expiry line
    private var performStartupChecks: Bool
    private let onRunSetup: (() -> Void)?   // Settings' "Run setup again"; the root view supplies it
    private let qaManage: (open: Bool, ring: Bool)   // visual QA: the Manage menu open at launch, with the controller's focus ring or without
    @Environment(\.scenePhase) private var scenePhase

    init(model: BuildModel? = nil, library: GameLibrary? = nil, initialPage: LauncherPage = .library,
         activeBuildID: UUID? = nil, performStartupChecks: Bool = true, search: String? = nil, olderTools: Set<UUID> = [],
         manageOpen: Bool = false, padRing: Bool = false, onRunSetup: (() -> Void)? = nil) {
        self.onRunSetup = onRunSetup
        qaManage = (manageOpen, padRing)
        if let search { _search = State(initialValue: search); _searching = State(initialValue: true) }   // visual QA: the bar with its field open
        _toolsAge = StateObject(wrappedValue: ToolsAge(older: olderTools))   // visual QA: games marked without a checkout to compare
        _m = StateObject(wrappedValue: model ?? BuildModel())
        _library = StateObject(wrappedValue: library ?? GameLibrary())
        _page = State(initialValue: initialPage)
        _activeBuildID = State(initialValue: activeBuildID)
        self.performStartupChecks = performStartupChecks
    }

    private var filteredGames: [LibraryGame] {
        library.games.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().opacity(0.3)
            if page == .library {
                libraryPage
            } else {
                BuilderView(m: m, library: library, settings: page == .settings, onViewGame: { page = .library },
                            onOpenSettings: { page = .settings }, onChooseLibraryFolder: chooseLibraryFolder,
                            onOpenControls: { controlsOpen = true }, onRunSetup: onRunSetup, controlChanges: controls.changeCount)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if m.running || page == .library { activityBar }
        }
        .padScope("main", padFocus)
        .environmentObject(padFocus)
        .manageMenuOverlay(items: manageOpenFor.flatMap { id in library.games.first { $0.id == id } }.map(manageItems),
                           label: m.t("library.manage"), pad: padFocus) { manageOpenFor = nil }
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
            if performStartupChecks { library.migrateLaunchOptions() }
            if qaManage.open {
                if qaManage.ring { padFocus.show(default: nil) }
                manageOpenFor = library.selected?.id
            }
            refreshArtwork()
            readSignatures()
            if performStartupChecks { library.discover(); fetchArtwork(); m.refreshDevices(); checkTools() }
            if performStartupChecks {
                m.checkDeps()
                if m.repoOK && m.repoIsGit { m.checkRepoUpdates(silent: true) } else { m.adoptAtLaunch() }
                m.checkAppUpdate(silent: true)
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
        .onChange(of: m.repoPath) { _ in refreshArtwork(); if performStartupChecks { checkTools() } }
        // A clone, pull or update check has finished (the automatic pull at launch among them): the checkout may have moved
        .onReceive(m.$repoBusy.removeDuplicates().dropFirst()) { busy in if !busy && performStartupChecks { checkTools() } }
        .onChange(of: library.selectedID) { _ in resignNote = nil }   // the last re-sign's note belongs to its game
        .onReceive(m.$running.removeDuplicates()) { running in
            if running && activeBuildID == nil { activeBuildID = library.rememberInputs(m) }
            if running && activeBuildID != nil {   // the tools this build runs: a pull waits for the build (pullRepo, autoPull)
                buildCommit = ""
                let repo = m.repoPath
                DispatchQueue.global(qos: .utility).async {
                    let commit = ToolsAge.head(repo: repo) ?? ""
                    DispatchQueue.main.async { buildCommit = commit }
                }
            }
            if !running {
                DispatchQueue.main.async {
                    if m.done { recordBuild() }
                    activeBuildID = nil
                }
            }
        }
        .onReceive(m.$done.removeDuplicates()) { done in
            if done { DispatchQueue.main.async { recordBuild() } }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { library.objectWillChange.send() }
        }
        .alert(m.t("library.error"), isPresented: Binding(
            get: { launchError != nil || library.error != nil },
            set: { if !$0 { launchError = nil; library.error = nil } }
        )) {
            Button(m.t("library.ok")) { launchError = nil; library.error = nil }
        } message: { Text(launchError ?? library.error ?? "") }
        .confirmationDialog(m.t("library.removeQuestion"), isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible) {
            Button(m.t("library.remove"), role: .destructive) {
                if let game = removing { library.remove(game.id) }
                removing = nil
            }
        } message: { Text(m.t("library.removeNote")) }
        .sheet(isPresented: Binding(get: { optionsFor != nil }, set: { if !$0 { optionsFor = nil } })) {
            if let id = optionsFor { LaunchOptionsView(m: m, library: library, gameID: id).environmentObject(padFocus) }
        }
        .sheet(isPresented: $controlsOpen) { ControlsView(m: m, layout: controls).environmentObject(padFocus) }
        .sheet(isPresented: Binding(get: { freeSpaceFor != nil }, set: { if !$0 { freeSpaceFor = nil } })) {
            if let game = library.games.first(where: { $0.id == freeSpaceFor }) { FreeSpaceView(m: m, game: game).environmentObject(padFocus) }
        }
        .onChange(of: freeSpaceFor) { id in padFocus.scope = id != nil ? "free" : currentPadScope }
        .sheet(isPresented: $m.showUpdateSheet) { UpdateSheet(m: m) }
        .sheet(isPresented: Binding(get: { savesFor != nil }, set: { if !$0 { savesFor = nil } })) {
            if let id = savesFor { SavesView(m: m, library: library, gameID: id).environmentObject(padFocus) }
        }
        .onChange(of: savesFor) { id in padFocus.scope = id != nil ? "saves" : currentPadScope }
        .onChange(of: optionsFor) { id in padFocus.scope = id != nil ? "launch" : (controlsOpen ? "controls" : "main") }
        .onChange(of: controlsOpen) { open in padFocus.scope = open ? "controls" : (optionsFor != nil ? "launch" : "main") }
        .onChange(of: page) { _ in padFocus.focused = nil }
        .onChange(of: padFocus.focused) { id in   // a controller moving onto a game's card selects it, as a click does
            if let id, id.hasPrefix("card."), let uuid = UUID(uuidString: String(id.dropFirst(5))) { library.selectedID = uuid }
        }
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
            .padding(.trailing, 34)
            ForEach(LauncherPage.allCases, id: \.self) { destination in
                Button { page = destination } label: {
                    Label(m.t("nav." + destination.rawValue), systemImage: destination.symbol)
                        .font(.manrope(15, page == destination ? .bold : .medium))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(page == destination ? Color.white.opacity(0.10) : .clear,
                                    in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(RoundedRectangle(cornerRadius: 9))   // the whole pill takes the click, not only its text
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(page == destination ? .isSelected : [])
                .padTarget("tab." + destination.rawValue, scope: "main") { page = destination }
            }
            Spacer(minLength: 8)
            searchField
            Button { newBuild() } label: {
                Label(m.t("library.newBuild"), systemImage: "plus")
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.1)))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain).disabled(m.running)
            .padTarget("top.build", scope: "main", radius: 8) { if !m.running { newBuild() } }
            .padding(.leading, 12)
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
            .buttonStyle(.plain).help(m.t("library.search")).accessibilityLabel(m.t("library.search"))
            if searching {
                TextField(m.t("library.search"), text: $search)
                    .textFieldStyle(.plain).font(.manrope(14))
                    .focused($searchFocused)
                    .onSubmit { if search.isEmpty { closeSearch() } }
                    .onExitCommand { closeSearch() }
                    .frame(width: 210)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                Button { closeSearch() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).help(m.t("library.clearSearch")).accessibilityLabel(m.t("library.clearSearch"))
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
                        if let game = library.selected {
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
            Text(m.t("library.welcome")).font(.manrope(54, .bold)).tracking(-1.8)
            Text(m.t("library.welcomeNote")).font(.manrope(17)).foregroundStyle(.secondary)
                .frame(maxWidth: 490, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            Button { newBuild() } label: {
                Label(m.t("library.firstBuild"), systemImage: "plus")
                    .font(.manrope(16, .semibold))
                    .padding(.horizontal, 24).padding(.vertical, 15)
                    .foregroundStyle(.black).background(LauncherPalette.cream, in: Capsule())
            }
            .buttonStyle(.plain).padding(.top, 8)
            Button(action: chooseLibraryFolder) {
                Label(m.t("library.chooseFolder"), systemImage: "folder")
                    .font(.manrope(14)).foregroundStyle(.secondary)
            }.buttonStyle(.plain)
            Spacer()
            Text(m.t("library.localNote")).font(.manrope(12)).foregroundStyle(.secondary)
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
                            Label(m.t("library.rebuildShort"), systemImage: "arrow.clockwise")
                                .font(.manrope(12, .semibold)).foregroundStyle(LauncherPalette.cream)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .overlay(Capsule().strokeBorder(LauncherPalette.cream.opacity(0.35)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain).disabled(m.running || game.inputs["base", default: []].isEmpty)
                        .help(m.t("library.olderToolsHelp"))
                        .padTarget("hero.rebuild", scope: "main", radius: 12) { if !m.running { configureBuild(game) } }
                    }
                }
                Text(game.name).font(.manrope(min(68, width * 0.052), .heavy))
                    .tracking(-1.6).lineLimit(2).shadow(color: .black.opacity(0.25), radius: 12)
                HStack(spacing: 18) {
                    Button { primaryAction(game) } label: {
                        Label(game.primary == .play ? m.t("library.play")
                                : (game.primary == .openOnDevice ? String(format: m.t("dev.open"), m.deviceName(game.installedDevice))
                                   : m.t("library.newBuild")),
                              systemImage: game.primary == .play ? "play.fill" : (game.primary == .openOnDevice ? "iphone" : "hammer.fill"))
                            .font(.manrope(18, .bold))
                            .foregroundStyle(.black).padding(.horizontal, 30).padding(.vertical, 14)
                            .frame(minWidth: 164)
                            .background(LauncherPalette.cream, in: Capsule())
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
                        .buttonStyle(.plain).help(m.t("launch.title")).accessibilityLabel(m.t("launch.title"))
                        .padTarget("hero.options", scope: "main", radius: 24) { optionsFor = game.id }
                    }
                    Button { manageOpenFor = manageOpenFor == nil ? game.id : nil } label: { ManageButtonLabel(title: m.t("library.manage")) }
                        .buttonStyle(.plain).accessibilityLabel(m.t("library.manage"))
                        .anchorPreference(key: ManageAnchorKey.self, value: .bounds) { $0 }
                        .padTarget("hero.manage", scope: "main", radius: 12) { manageOpenFor = game.id }
                }
                // A free Apple ID's provisioning profile lasts 7 days. Say when this app's runs out, and offer the
                // re-sign at any time: renewing early (before a trip, say) is as valid as renewing just in time.
                if game.onDevice {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.seal").font(.system(size: 12))
                            .foregroundStyle(LauncherPalette.cream.opacity(0.7))
                        Text(signatureExpiry[game.id].map { AppSignature.describe($0, m.t) } ?? m.t("dev.expiryUnknown"))
                            .font(.manrope(12.5))
                            .foregroundStyle(signatureExpiry[game.id].map { AppSignature.isUrgent($0) } == true
                                             ? LauncherPalette.building : .secondary)
                        Button { resign(game) } label: {
                            Text(m.t("dev.resign")).font(.manrope(12, .semibold))
                                .foregroundStyle(LauncherPalette.cream)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .overlay(Capsule().strokeBorder(LauncherPalette.cream.opacity(0.35)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain).disabled(m.running)
                        .help(m.t("dev.resignHelp"))
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
        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(m.t("library.collection")).font(.manrope(28, .bold)).tracking(-0.6)
                Spacer()
                Text(String(format: m.t("library.gameCount"), library.games.count))
                    .font(.manrope(12)).foregroundStyle(.secondary)
            }
            if filteredGames.isEmpty {
                Text(m.t("library.noResults")).foregroundStyle(.secondary).padding(.vertical, 28)
            } else {
                ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(filteredGames) { game in
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
                                            game.id == library.selectedID ? LauncherPalette.cream : .clear, lineWidth: 2))
                                        Text(game.name).font(.manrope(16, .semibold)).lineLimit(1)
                                        status(game)
                                        Capsule().fill(game.id == library.selectedID ? LauncherPalette.cream : .clear)
                                            .frame(height: 3).padding(.top, 4)
                                    }
                                    .frame(width: cardWidth, alignment: .leading).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(game.id == library.selectedID ? .isSelected : [])
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
        .accessibilityLabel(m.t(symbol == "chevron.left" ? "library.scrollBack" : "library.scrollForward"))
        .transition(.opacity)
    }

    private func status(_ game: LibraryGame, prominent: Bool = false) -> some View {
        let building = m.running && activeBuildID == game.id
        let color = building ? LauncherPalette.building : ((game.isReady || game.hasIOSBuild) ? LauncherPalette.ready : LauncherPalette.unbuilt)
        let key = building ? "library.building" : (game.isReady ? "library.ready" : (game.hasIOSBuild ? "library.readyIOS" : "library.notBuilt"))
        return HStack(spacing: 7) {
            Circle().fill(color).frame(width: prominent ? 9 : 7, height: prominent ? 9 : 7)
            Text(prominent ? m.t(key).uppercased() : m.t(key))
                .font(prominent ? .manrope(12, .bold) : .manrope(13, .medium))
                .tracking(prominent ? 1.3 : 0)   // the eyebrow: the same face, in tracked capitals
                .foregroundStyle(color)
            if !building && toolsAge.older.contains(game.id) {   // a quiet note beside the status, not a warning
                Text("· " + m.t(prominent ? "library.olderTools" : "library.olderToolsShort"))
                    .font(.manrope(prominent ? 13 : 12)).foregroundStyle(.secondary).lineLimit(1)
                    .help(m.t("library.olderToolsHelp"))
            }
            // A free Apple ID's profile lasts 7 days: the card says when it runs out, the hero offers to renew it.
            if !building, let expiry = signatureExpiry[game.id] {
                Text("· " + AppSignature.short(expiry, m.t))
                    .font(.manrope(prominent ? 13 : 12))
                    .foregroundStyle(AppSignature.isUrgent(expiry) ? LauncherPalette.building : .secondary)
                    .lineLimit(1)
                    .help(AppSignature.describe(expiry, m.t))
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
                        Text(m.t(m.target == "mac-app" ? "activity.mac" : "activity.ios")).font(.manrope(15, .bold))
                        TimelineView(.periodic(from: Date(), by: 1)) { context in   // the clock ticks while a count may stand still
                            Text(m.stages.last(where: { $0.state == .running })
                                    .map { [$0.name, $0.detail, $0.clock(at: context.date, left: m.t("prog.eta"))].filter { !$0.isEmpty }.joined(separator: " · ") }
                                 ?? m.t("library.preparing"))
                                .font(.manrope(13)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .frame(minWidth: 180, alignment: .leading)
                    LauncherProgressBar(value: buildProgress).frame(maxWidth: 480)
                    Text(buildProgress.map { "\(Int($0 * 100))%" } ?? "")
                        .font(.manrope(14, .semibold)).monospacedDigit().foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                    Spacer(minLength: 8)
                    Button(m.t("library.viewBuild")) { page = .builds }.buttonStyle(LauncherSecondaryButtonStyle())
                    Button(m.t(m.stopping ? "library.stopping" : "btn.stop")) { m.stop() }
                        .buttonStyle(LauncherSecondaryButtonStyle(accent: LauncherPalette.building)).disabled(m.stopping)
                } else {
                    Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                    Text(m.t("library.localNote")).font(.manrope(13)).foregroundStyle(.secondary)
                    if let n = m.autoPulled, n > 0 {
                        // The automatic update when the app opened (BuildModel.autoPull): the build tools are the current ones
                        Circle().fill(LauncherPalette.ready).frame(width: 6, height: 6).padding(.leading, 10)
                        Text(String(format: m.t("library.toolsUpdated"), n)).font(.manrope(13)).foregroundStyle(.secondary)
                    }
                    if m.autoAdopted {
                        // A ZIP copy connected to git and updated when the app opened (BuildModel.adoptAtLaunch)
                        Circle().fill(LauncherPalette.ready).frame(width: 6, height: 6).padding(.leading, 10)
                        Text(m.t("library.toolsAdopted")).font(.manrope(13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let staged = m.appStaged {
                        // A downloaded, verified update (BuildModel.stageAppUpdate): it goes in when the app quits, or now.
                        // This branch only shows with no build running, and restartToUpdate checks again.
                        HStack(spacing: 10) {
                            Circle().fill(LauncherPalette.ready).frame(width: 6, height: 6)
                            Text(String(format: m.t("library.appReady"), staged.release.tag)).font(.manrope(13)).foregroundStyle(.secondary)
                        }
                        Button(m.t("app.restartNow")) { m.restartToUpdate() }.buttonStyle(LauncherSecondaryButtonStyle())
                    }
                    if gamepad.connected {
                        // The buttons a controller has here, named as the game names them (A on the right)
                        HStack(spacing: 18) {
                            padHint("A", m.t("pad.play")); padHint("X", m.t("pad.options")); padHint("B", m.t("pad.back"))
                            padHint("Y", m.t("pad.manage"))
                            Image(systemName: "gamecontroller").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 30).frame(height: 84)
        }
    }

    private func padHint(_ button: String, _ label: String) -> some View {
        HStack(spacing: 7) {
            Text(button).font(.manrope(11, .bold)).foregroundStyle(.black)
                .frame(width: 20, height: 20).background(LauncherPalette.cream.opacity(0.9), in: Circle())
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
        m.gameDir = ""; m.done = false; m.doneNote = ""; m.macAppPath = ""; m.ipaPath = ""; m.stages = []
        if m.outDir.isEmpty && !library.folder.isEmpty { m.outDir = library.folder }
        page = .builds
    }

    private func configureBuild(_ game: LibraryGame) {
        guard !m.running else { page = .builds; return }
        for index in m.slots.indices {
            m.slots[index].paths = game.inputs[m.slots[index].id] ?? []
            m.slots[index].problem = ""
        }
        m.gameDir = (m.basePath as NSString).deletingLastPathComponent
        m.outDir = game.outputDirectory
        m.done = false; m.doneNote = ""; m.stages = []
        m.target = game.lastTarget
        page = .builds
    }

    /// A controller's button (LauncherGamepad): the first press shows the focus (on the selected game's card in the library),
    /// then the D-pad moves it (PadFocus), A activates, B closes a sheet or goes back to the library, X opens the selected
    /// game's launch options, L and R switch the pages.
    private func padAction(_ action: LauncherGamepad.Action) {
        let sheetOpen = optionsFor != nil || controlsOpen || savesFor != nil || freeSpaceFor != nil
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
        if action == .b, savesFor != nil { savesFor = nil; return }
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
        case .y:   // the Manage menu: ManagePad.route opened it above
            return
        case .b:
            return
        }
    }

    /// The Manage menu's rows for a game, wired to the launcher's sheets and actions (ManageItem.list).
    private func manageItems(_ game: LibraryGame) -> [ManageItem] {
        ManageItem.list(game: game, labels: m.t, running: m.running, olderTools: toolsAge.older.contains(game.id), activeBuildID: activeBuildID,
                        hasBuildFolder: BuildFolder.location(for: game) != nil,
                        hasLog: GameLog.latest(titleID: game.titleID, appPath: game.appPath) != nil,
                        actions: ManageActions(
                            rebuild: { configureBuild(game) }, options: { optionsFor = game.id }, saves: { savesFor = game.id },
                            changeArtwork: { chooseArtwork(game) }, resetArtwork: { library.setArtwork("", for: game.id) },
                            reveal: { if let path = game.revealTarget { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } },
                            showLog: { if let log = GameLog.latest(titleID: game.titleID, appPath: game.appPath) { GameLog.show(log) } },
                            freeSpace: { freeSpaceFor = game.id }, remove: { removing = game }))
    }

    private func manageItems(for game: LibraryGame?) -> [ManageItem] { game.map(manageItems) ?? [] }

    /// The scope a controller acts in when no menu is open: the innermost sheet, else the window.
    private var currentPadScope: String {
        savesFor != nil ? "saves" : freeSpaceFor != nil ? "free" : optionsFor != nil ? "launch" : controlsOpen ? "controls" : "main"
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
            library.migrateLaunchOptions()
            let settings = LaunchSetting.forMac(app: game.appPath, titleID: game.titleID, repo: m.repoPath, labels: m.t) ?? []
            let mods = GameMod.list(in: GameMod.folder(for: game, library: library.folder), titleID: game.titleID)
            let environment = game.startEnvironment(controls: controls.environment, settings: settings, mods: mods,
                                                  store: SavedChoices(app: game.appPath, titleID: game.titleID),
                                                  appReadsStore: SavedChoices.appReadsStore(app: game.appPath))
            if !environment.isEmpty { configuration.environment = environment }
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: game.appPath), configuration: configuration) { _, error in
                DispatchQueue.main.async {
                    launching = false
                    if let error { launchError = error.localizedDescription }
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
            for (id, path) in apps { if let date = AppSignature.expiration(ofApp: path) { found[id] = date } }
            DispatchQueue.main.async { signatureExpiry = found }
        }
    }

    /// Sign the installed app again for another 7 days (a free Apple ID's profile), then install it: the game's code
    /// is not rebuilt, and its Documents stay.
    private func resign(_ game: LibraryGame) {
        resignNote = nil
        m.resignOnDevice(app: game.iosAppPath, device: game.installedDevice) {
            resignNote = m.doneNote
            signatureExpiry[game.id] = AppSignature.expiration(ofApp: game.iosAppPath)
        }
    }

    private func recordBuild() {
        guard m.done, let id = activeBuildID else { return }
        if m.target == "mac-app" { library.recordCompletedApp(path: m.macAppPath, commit: buildCommit, for: id) }
        else { library.recordCompletedIOS(ipa: m.ipaPath, archive: m.archivePath, app: m.installedAppPath, device: m.installedOn, commit: buildCommit, for: id) }
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
        panel.message = m.t("library.artworkHint")
        if panel.runModal() == .OK, let url = panel.url, NSImage(contentsOf: url) != nil {
            library.setArtwork(url.path, for: game.id)
        }
    }

    private func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = m.t("library.folderHint")
        if !library.folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: library.folder) }
        if panel.runModal() == .OK, let url = panel.url {
            library.setFolder(url)
            if !m.running { m.outDir = url.path }
        }
    }
}

/// The collection row's scroll state, read from its NSScrollView: SwiftUI's horizontal ScrollView does not
/// report its offset on macOS 13, so the pager chevrons follow the clip view's bounds instead.
final class RowScroller: ObservableObject {
    @Published private(set) var canBack = false
    @Published private(set) var canForward = false
    private weak var scrollView: NSScrollView?
    private var observers: [NSObjectProtocol] = []

    func attach(_ view: NSScrollView) {
        guard view !== scrollView else { return update() }
        observers.forEach(NotificationCenter.default.removeObserver)
        scrollView = view
        let clip = view.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        view.documentView?.postsFrameChangedNotifications = true
        observers = [(NSView.boundsDidChangeNotification, clip), (NSView.frameDidChangeNotification, clip),
                     (NSView.frameDidChangeNotification, view.documentView as Any)].map { name, object in
            NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in self?.update() }
        }
        update()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func update() {
        guard let view = scrollView, let document = view.documentView else { return }
        let x = view.contentView.bounds.minX, end = document.frame.width - view.contentView.bounds.width
        if canBack != (x > 1) { canBack = x > 1 }
        if canForward != (x < end - 1) { canForward = x < end - 1 }
    }

    /// Scroll by the whole cards that fit in the row.
    func page(_ direction: CGFloat, step: CGFloat) {
        guard let view = scrollView, let document = view.documentView else { return }
        let clip = view.contentView
        let distance = max(step, (clip.bounds.width / step).rounded(.down) * step)
        let target = min(max(0, clip.bounds.minX + direction * distance), max(0, document.frame.width - clip.bounds.width))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clip.animator().setBoundsOrigin(NSPoint(x: target, y: clip.bounds.minY))
        }
        view.reflectScrolledClipView(clip)
    }
}

/// Hands the NSScrollView around this background view to the row's scroller once it is in a window.
private struct EnclosingScrollView: NSViewRepresentable {
    let row: RowScroller
    final class Probe: NSView {
        var row: RowScroller?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                if let view = self?.enclosingScrollView { self?.row?.attach(view) }
            }
        }
    }
    func makeNSView(context: Context) -> Probe { let probe = Probe(); probe.row = row; return probe }
    func updateNSView(_ probe: Probe, context: Context) {
        probe.row = row
        DispatchQueue.main.async { if let view = probe.enclosingScrollView { row.attach(view) } }
    }
}

/// The library's collection row reports its height, so the hero above it fills exactly what is left.
private struct CollectionHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
