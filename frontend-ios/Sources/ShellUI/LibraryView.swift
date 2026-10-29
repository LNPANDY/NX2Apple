import SwiftUI

/// How the library arranges itself. Only the available size decides, never the device model or orientation,
/// so a Stage Manager window, Split View and a foldable opening while the app runs all follow the same rules.
enum ShellLayout: Equatable {
    /// Compact and taller than wide: one column, settings over the whole library when asked for.
    case column
    /// Regular width and height, not wide: the library alone with a grid of cards, settings as a panel when asked for.
    case grid
    /// Wider than tall: Cover Flow. Settings as a panel on the right (regular) or over the whole library (compact).
    case coverFlow(regular: Bool)

    static func resolve(_ size: CGSize, accessibilityText: Bool) -> ShellLayout {
        let regular = size.width >= 600 && size.height >= 500
        if size.width > size.height * 1.2 { return .coverFlow(regular: regular) }
        return regular && !accessibilityText ? .grid : .column
    }

    /// The settings panel's width: the whole width where it covers the library, else a panel that leaves the
    /// library in view beside it.
    func paneWidth(_ width: CGFloat) -> CGFloat {
        switch self {
        case .column, .coverFlow(regular: false): width
        case .grid, .coverFlow(regular: true): min(500, max(380, width * 0.5))
        }
    }
    /// Whether the settings float as a panel over a dimmed library, rather than replacing it.
    var settingsFloat: Bool { self == .grid || self == .coverFlow(regular: true) }
    var isCoverFlow: Bool { if case .coverFlow = self { true } else { false } }
}

/// A presentation-only shell. Selection, focus, navigation and scroll positions are local UI state.
/// All game effects are supplied by the host through actions.
public struct LibraryView: View {
    public let games: [GameDetail]
    public let controllers: [ControllerInfo]
    public var actions: ShellActions
    public var input: ShellInput?
    @State private var selectedID: String?
    @State private var settingsOpen: Bool
    @State private var controllersOpen: Bool
    @State private var focus: FocusAppearance
    @State private var targets = FocusTargetBuffer()
    @State private var settingsPosition = ScrollPosition()
    @State private var libraryPosition = ScrollPosition()
    @State private var layout: ShellLayout = .column
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(games: [GameDetail], controllers: [ControllerInfo] = [], actions: ShellActions = ShellActions(),
                input: ShellInput? = nil, initialSelection: String? = nil, initialDetailOpen: Bool = false,
                initialControllersOpen: Bool = false, initialFocusVisible: Bool = false) {
        self.games = games
        self.controllers = controllers
        self.actions = actions
        self.input = input
        let first = initialSelection ?? games.first?.id
        _selectedID = State(initialValue: first)
        _settingsOpen = State(initialValue: initialDetailOpen)
        _controllersOpen = State(initialValue: initialControllersOpen)
        _focus = State(initialValue: FocusAppearance(id: initialFocusVisible ? "lib.tile.\(first ?? "")" : nil, visible: initialFocusVisible))
    }
    private var selected: GameDetail? { games.first { $0.id == selectedID } ?? games.first }

    public var body: some View {
        GeometryReader { geometry in
            let insets = geometry.safeAreaInsets
            let whole = CGSize(width: geometry.size.width + insets.leading + insets.trailing,
                               height: geometry.size.height + insets.top + insets.bottom)
            let layout = ShellLayout.resolve(whole, accessibilityText: typeSize.isAccessibilitySize)
            let width = geometry.size.width
            let pane = layout.paneWidth(width)
            // Settings only when asked for. A panel floats over the dimmed library where there is room, otherwise the
            // settings take the whole screen and the library steps out of the way.
            let floating = layout.settingsFloat
            let paneCovers = settingsOpen && !floating
            let panelOverLibrary = settingsOpen && floating
            ZStack(alignment: .topLeading) {
                if layout.isCoverFlow, let selected { CoverFlowBackdrop(game: selected.game) } else { ShellPalette.background.ignoresSafeArea() }
                if games.isEmpty {
                    EmptyLibraryView()
                        .overlay(alignment: .topTrailing) {
                            ControllerChip(count: controllers.count, action: openControllers).padding(.top, 6).padding(.trailing, 16)
                        }
                } else if let selected {
                    library(selected, layout: layout, size: geometry.size, topInset: insets.top)
                        .frame(width: width, height: geometry.size.height)
                        .opacity(paneCovers ? 0 : 1)
                        .allowsHitTesting(!settingsOpen)
                        .accessibilityHidden(settingsOpen)
                        .transformPreference(FocusTargets.self) { if settingsOpen { $0.removeAll() } }
                    if panelOverLibrary {
                        Color.black.opacity(0.5).ignoresSafeArea()
                            .onTapGesture { closeSettings() }
                            .accessibilityHidden(true)
                            .transition(.opacity)
                    }
                    // One settings view in one place for every layout, so its state, scroll position and focus survive
                    // a fold, a rotation or a Stage Manager resize.
                    settingsPane(selected, floating: floating, width: pane - (floating ? 24 : 0))
                        .frame(width: pane - (floating ? 24 : 0))
                        .frame(maxHeight: .infinity)
                        .background {
                            if floating {
                                RoundedRectangle(cornerRadius: 26).fill(Color(red: 0.075, green: 0.075, blue: 0.082))
                                    .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.10)))
                            } else {
                                ShellPalette.background.ignoresSafeArea()
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: floating ? 26 : 0))
                        .shadow(color: .black.opacity(floating ? 0.5 : 0), radius: 40, x: -8)
                        .padding(floating ? 12 : 0)
                        .offset(x: settingsOpen ? 0 : pane + 40)
                        .opacity(settingsOpen ? 1 : 0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .allowsHitTesting(settingsOpen)
                        .accessibilityHidden(!settingsOpen)
                        .accessibilityAddTraits(settingsOpen ? .isModal : [])
                        .transformPreference(FocusTargets.self) { if !settingsOpen { $0.removeAll() } }
                }
                if controllersOpen {
                    Color.black.opacity(0.55).ignoresSafeArea().accessibilityHidden(true)
                        .onTapGesture { back() }
                    ControllersView(controllers: controllers, onBack: back)
                        .frame(width: min(width, 520))
                        .frame(maxHeight: .infinity)
                        .background { ShellPalette.background.ignoresSafeArea() }
                        .overlay(alignment: .leading) { Rectangle().fill(ShellPalette.hairline).frame(width: 1).ignoresSafeArea() }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityAddTraits(.isModal)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .transformPreference(FocusTargets.self) { values in
                values = values.filter { controllersOpen ? $0.id.hasPrefix("ctl.") : !$0.id.hasPrefix("ctl.") }
            }
            .coordinateSpace(name: "shell")
            .onPreferenceChange(FocusTargets.self) { all in targets.values = all.filter { $0.frame.width > 1 } }
            .onAppear { self.layout = layout }
            .onChange(of: layout) { _, new in self.layout = new }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: layout)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: settingsOpen)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: controllersOpen)
        .environment(\.shellFocus, focus)
        .foregroundStyle(.white)
        .font(ShellFonts.font(15)).tint(ShellPalette.cream).preferredColorScheme(.dark)
        .onChange(of: input) { _, event in if let event { handle(event.action) } }
        .focusable().focusEffectDisabled()
        .onKeyPress(.leftArrow) { handle(.left); return .handled }
        .onKeyPress(.rightArrow) { handle(.right); return .handled }
        .onKeyPress(.upArrow) { handle(.up); return .handled }
        .onKeyPress(.downArrow) { handle(.down); return .handled }
        .onKeyPress(.return) { handle(.activate); return .handled }
        .onKeyPress(.escape) { handle(.back); return .handled }
        .onDisappear { targets.values.removeAll() }
        .onChange(of: games.map(\.id)) { _, ids in
            if !ids.contains(selectedID ?? "") { selectedID = ids.first; settingsOpen = false }
        }
    }

    @ViewBuilder private func library(_ selected: GameDetail, layout: ShellLayout, size: CGSize, topInset: CGFloat) -> some View {
        if layout.isCoverFlow {
            CoverFlowView(games: games, selected: selected, controllers: controllers.count, showsHints: !controllers.isEmpty,
                          select: select, primary: primary, openSettings: openSettings, openControllers: openControllers)
                .transition(.opacity)
        } else {
            PortraitLibrary(games: games, selected: selected, wide: layout == .grid, size: size, topInset: topInset,
                            controllers: controllers.count, select: select, primary: primary,
                            openSettings: openSettings, openControllers: openControllers, position: $libraryPosition)
                .transition(.opacity)
        }
    }

    /// The settings for the selected game: its banner as the header, with the title over it and Back on top, then
    /// the primary action and the setting groups. A panel or the whole screen, the same view.
    private func settingsPane(_ selected: GameDetail, floating: Bool, width: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PaneBanner(game: selected.game, width: width).id("set.top")
                    GameDetailView(detail: selected, actions: actions, showsPrimaryAction: true, showsHeader: false)
                        .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 32)
                        // A phone on its side: a readable column, not rows stretched across the whole width.
                        .frame(maxWidth: 640, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollPosition($settingsPosition)
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: floating ? [] : .top)
            .overlay(alignment: .topLeading) {
                Button(action: closeSettings) {
                    if typeSize.isAccessibilitySize { Image(systemName: "chevron.left").frame(minWidth: 24) }
                    else { Label(ShellStrings.text("Library"), systemImage: "chevron.left") }
                }
                .buttonStyle(ChipButtonStyle())
                .accessibilityLabel(ShellStrings.text("Library"))
                .accessibilityIdentifier("library.back")
                .shellTarget("set.back", radius: 22, action: closeSettings)
                .padding(.leading, 16).padding(.top, floating ? 14 : 6)
            }
            .onChange(of: focus.id) { _, id in
                guard let id, id.hasPrefix("set.") else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    proxy.scrollTo(id == "set.back" ? "set.top" : id, anchor: id == "set.back" ? .top : .center)
                }
            }
        }
    }

    // MARK: Actions and focus

    private func primary(_ detail: GameDetail) {
        switch detail.game.state {
        case .playable: actions.onPlay(detail.id)
        case .needsGameData: actions.onPickGameData(detail.id)
        case .needsAppUpdate: actions.onAppUpdate()
        case .broken: actions.onShowLog(detail.id)
        }
    }
    private func select(_ id: String) {
        guard id != selectedID else { return }
        selectedID = id
        actions.onSelect(id)
        settingsPosition.scrollTo(edge: .top)
    }
    private func openSettings() {
        settingsOpen = true
        focus.id = "set.back"
    }
    private func closeSettings() {
        settingsOpen = false
        focus.id = "lib.settings"
    }
    private func openControllers() { controllersOpen = true; focus.id = "ctl.close" }
    private func back() {
        if controllersOpen { controllersOpen = false; focus.id = "lib.controllers" }
        else if settingsOpen { closeSettings() }
        else { actions.onBack() }
    }
    private func handle(_ action: ShellInput.Action) {
        focus.visible = true
        if focus.id == nil || !targets.values.contains(where: { $0.id == focus.id }) {
            focus.id = defaultFocus
            if action != .activate && action != .back && action != .settings && action != .controllers { return }
        }
        switch action {
        case .activate: targets.values.first { $0.id == focus.id }?.activate()
        case .back: back()
        case .settings: openSettings()
        case .controllers: openControllers()
        case .left, .right:
            // In Cover Flow the focused cover is always the middle one: left and right move the carousel by one.
            if layout.isCoverFlow, let id = focus.id, id.hasPrefix("lib.tile."), let index = games.firstIndex(where: { $0.id == selected?.id }) {
                let next = min(games.count - 1, max(0, index + (action == .left ? -1 : 1)))
                select(games[next].id)
                focus.id = "lib.tile.\(games[next].id)"
                return
            }
            move(action)
        default: move(action)
        }
    }
    private func move(_ action: ShellInput.Action) {
        let candidates = layout.isCoverFlow
            ? targets.values.filter { !$0.id.hasPrefix("lib.tile.") || $0.id == "lib.tile.\(selected?.id ?? "")" }
            : targets.values
        focus.id = FocusNavigation.next(from: focus.id, action: action, targets: candidates)
        if let id = focus.id, id.hasPrefix("lib.tile.") { select(String(id.dropFirst("lib.tile.".count))) }
    }
    private var defaultFocus: String? {
        if controllersOpen { return "ctl.close" }
        if settingsOpen { return "set.back" }
        return selected.map { "lib.tile.\($0.id)" } ?? "lib.controllers"
    }
}

/// The top of the settings: the game's banner, whole and fading into the panel, then its state and title below it,
/// so the banner's own logo and the title never overlap. Capped in height for a phone on its side.
private struct PaneBanner: View {
    let game: GameTile
    let width: CGFloat
    var body: some View {
        let bannerHeight = min(width * 9 / 16, 220)
        VStack(alignment: .leading, spacing: 8) {
            StatusLabel(state: game.state, prominent: true)
            Text(game.title).shellText(26, .heavy, relativeTo: .title).tracking(-0.7)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("detail.title")
            HStack(spacing: 8) {
                SectionHeading(title: ShellStrings.text("Game settings"))
                if !game.subtitle.isEmpty {
                    Text(game.subtitle).shellText(12.5).foregroundStyle(.white.opacity(0.5))
                }
            }.padding(.top, 2)
        }
        .padding(.horizontal, 24)
        .padding(.top, bannerHeight - 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .top) {
            ArtView(game: game, lettering: false)
                .frame(width: width, height: bannerHeight)
                .mask {
                    LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.55),
                                           .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
                }
                .accessibilityHidden(true)
        }
    }
}
