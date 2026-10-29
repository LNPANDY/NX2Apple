import SwiftUI

/// How the library arranges itself. Only the available size decides, never the device model or orientation,
/// so a Stage Manager window, Split View and a foldable opening while the app runs all follow the same rules.
enum ShellLayout: Equatable {
    /// Compact and taller than wide: one column, settings pushed over the library.
    case column
    /// Regular width and height, not wide: the library beside the settings pane.
    case split
    /// Wider than tall: Cover Flow. Settings open as a panel on the right (regular) or over the library (compact).
    case coverFlow(regular: Bool)

    static func resolve(_ size: CGSize, accessibilityText: Bool) -> ShellLayout {
        let regular = size.width >= 600 && size.height >= 500
        if size.width > size.height * 1.2 { return .coverFlow(regular: regular) }
        return regular && !accessibilityText ? .split : .column
    }

    /// The settings pane's width: the whole width where it covers the library.
    func paneWidth(_ width: CGFloat) -> CGFloat {
        switch self {
        case .column, .coverFlow(regular: false): width
        case .split: min(460, max(320, width * 0.46))
        case .coverFlow(regular: true): min(520, max(380, width * 0.42))
        }
    }
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
            let paneShown = layout == .split || settingsOpen
            // Where the pane is as wide as the screen, the library underneath steps out of the way.
            let paneCovers = settingsOpen && pane >= width
            let panelOverLibrary = settingsOpen && layout == .coverFlow(regular: true)
            ZStack(alignment: .topLeading) {
                if layout.isCoverFlow, let selected { CoverFlowBackdrop(game: selected.game) } else { ShellPalette.background.ignoresSafeArea() }
                if games.isEmpty {
                    EmptyLibraryView()
                        .overlay(alignment: .topTrailing) {
                            ControllerChip(count: controllers.count, action: openControllers).padding(.top, 6).padding(.trailing, 16)
                        }
                } else if let selected {
                    library(selected, layout: layout,
                            size: CGSize(width: layout == .split ? width - pane : width, height: geometry.size.height),
                            topInset: insets.top)
                        .frame(width: layout == .split ? width - pane : width, height: geometry.size.height)
                        .opacity(paneCovers ? 0 : 1)
                        .allowsHitTesting(!paneCovers && !panelOverLibrary)
                        .accessibilityHidden(paneCovers || panelOverLibrary)
                        .transformPreference(FocusTargets.self) { if paneCovers || panelOverLibrary { $0.removeAll() } }
                    if panelOverLibrary {
                        Color.black.opacity(0.45).ignoresSafeArea()
                            .onTapGesture { closeSettings() }
                            .accessibilityHidden(true)
                            .transition(.opacity)
                    }
                    // One settings pane in one place for every layout, so its scroll position and focus survive
                    // a fold, a rotation or a Stage Manager resize.
                    settingsPane(selected, layout: layout)
                        .frame(width: pane, height: geometry.size.height)
                        .background {
                            (paneCovers ? ShellPalette.background : Color(red: 0.075, green: 0.075, blue: 0.082))
                                .ignoresSafeArea()
                                .overlay(alignment: .leading) {
                                    if !paneCovers { Rectangle().fill(ShellPalette.hairline).frame(width: 1).ignoresSafeArea() }
                                }
                        }
                        .offset(x: paneShown ? 0 : pane + 24)
                        .opacity(paneShown ? 1 : 0)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .allowsHitTesting(paneShown)
                        .accessibilityHidden(!paneShown)
                        .transformPreference(FocusTargets.self) { if !paneShown { $0.removeAll() } }
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
            PortraitLibrary(games: games, selected: selected, twoPanes: layout == .split, size: size, topInset: topInset,
                            controllers: controllers.count, select: select, primary: primary,
                            openSettings: openSettings, openControllers: openControllers, position: $libraryPosition)
                .transition(.opacity)
        }
    }

    private func settingsPane(_ selected: GameDetail, layout: ShellLayout) -> some View {
        let closable = layout != .split
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                if closable {
                    Button(action: closeSettings) {
                        if typeSize.isAccessibilitySize { Image(systemName: "chevron.left").frame(minWidth: 24) }
                        else { Label(ShellStrings.text("Library"), systemImage: "chevron.left") }
                    }
                    .buttonStyle(ShellButtonStyle())
                    .accessibilityLabel(ShellStrings.text("Library"))
                    .accessibilityIdentifier("library.back")
                    .shellTarget("set.back", action: closeSettings)
                }
                SectionHeading(title: ShellStrings.text("Game settings"))
                    .padding(.leading, closable ? 4 : 0)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 4).frame(minHeight: 56)
            ScrollViewReader { proxy in
                ScrollView {
                    GameDetailView(detail: selected, actions: actions, showsPrimaryAction: layout != .split, showsHeader: layout != .split)
                        .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 32)
                        // A phone on its side: a readable column, not rows stretched across the whole width.
                        .frame(maxWidth: 640, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollPosition($settingsPosition)
                .scrollIndicators(.hidden)
                .onChange(of: focus.id) { _, id in
                    guard let id, id.hasPrefix("set."), id != "set.back" else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .center) }
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
        if layout == .split {
            // The pane is already there: move into it.
            focus.id = targets.values.first { $0.id.hasPrefix("set.row.") }?.id ?? focus.id
            return
        }
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
        else if settingsOpen && layout != .split { closeSettings() }
        else if let id = focus.id, id.hasPrefix("set.") { focus.id = selected.map { "lib.tile.\($0.id)" } }
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
        if settingsOpen && layout != .split { return "set.back" }
        return selected.map { "lib.tile.\($0.id)" } ?? "lib.controllers"
    }
}
