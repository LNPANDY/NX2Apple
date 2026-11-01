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

    /// The width of the overlay Settings and Controllers share: a panel from the trailing edge over the dimmed library.
    static let overlayWidth: CGFloat = 520
    /// Settings drop in as that overlay wherever the library stays in view beside it (at least 120 points of it), and
    /// take the whole screen where it would not: a phone held upright, a folded foldable, a narrow window.
    func settingsFloat(_ width: CGFloat) -> Bool { self != .column && width >= Self.overlayWidth + 120 }
    /// The settings' width: the overlay, or the whole width.
    func paneWidth(_ width: CGFloat) -> CGFloat { settingsFloat(width) ? min(width, Self.overlayWidth) : width }
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
    @State private var shellSettingsOpen = false
    @State private var controllersOpen: Bool
    /// The game whose How to fix or How to update explanation is open.
    @State private var helpGameID: String?
    /// The choice whose option list is open.
    @State private var choice: ChoiceRequest?
    @State private var focus: FocusAppearance
    @State private var targets = FocusTargetBuffer()
    @State private var settingsPosition = ScrollPosition()
    /// How far the left-edge swipe has dragged the open settings or Controllers to the right.
    @State private var edgeDrag: CGFloat = 0
    @State private var libraryPosition = ScrollPosition()
    @State private var layout: ShellLayout = .column
    @State private var returnFocus: String?
    /// The device that sent the last input, for the glyphs.
    @State private var device: InputDevice = .controller(.neutral)
    /// True after a touch: the controller hints and the focus ring step back until the next controller or key press.
    @State private var touchMode: Bool
    @State private var gate = InputGate()
    @FocusState private var keyboardFocus: Bool
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
        _touchMode = State(initialValue: !initialFocusVisible)
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
            let floating = layout.settingsFloat(width)
            let paneCovers = settingsOpen && !floating
            let panelOverLibrary = settingsOpen && floating
            ZStack(alignment: .topLeading) {
                if layout.isCoverFlow, let selected { CoverFlowBackdrop(game: selected.game) } else { ShellPalette.background.ignoresSafeArea() }
                if games.isEmpty {
                    EmptyLibraryView()
                        .overlay(alignment: .topTrailing) {
                            HStack(spacing: 10) {
                                Button { shellSettingsOpen = true } label: {
                                    Image(systemName: "gearshape")
                                }.buttonStyle(ChipButtonStyle()).accessibilityLabel(ShellStrings.text("Settings"))
                                ControllerChip(count: controllers.count, action: openControllers)
                            }.padding(.top, 6).padding(.trailing, 16)
                        }
                } else if let selected {
                    library(selected, layout: layout, size: geometry.size, insets: insets)
                        .frame(width: width, height: geometry.size.height)
                        .opacity(paneCovers && edgeDrag == 0 ? 0 : 1)
                        .allowsHitTesting(!settingsOpen)
                        .accessibilityHidden(settingsOpen || helpGameID != nil)
                        .transformPreference(FocusTargets.self) { if settingsOpen { $0.removeAll() } }
                    if panelOverLibrary {
                        // The same dimming and dismissal as the Controllers overlay.
                        Color.black.opacity(0.55 * (settingsOpen && !controllersOpen ? 1 - min(1, edgeDrag / pane) : 1)).ignoresSafeArea()
                            .onTapGesture { closeSettings() }
                            .accessibilityHidden(true)
                            .transition(.opacity)
                    }
                    // One settings view in one place for every layout, so its state, scroll position and focus survive
                    // a fold, a rotation or a Stage Manager resize.
                    settingsPane(selected, floating: floating, width: pane,
                                 insets: floating ? EdgeInsets(top: insets.top, leading: 0, bottom: insets.bottom, trailing: insets.trailing)
                                                  : insets)
                        .frame(width: pane)
                        .frame(maxHeight: .infinity)
                        // Presented like Controllers: the page colour edge to edge, a hairline toward the library.
                        .background { ShellPalette.background.ignoresSafeArea() }
                        .overlay(alignment: .leading) {
                            if floating { Rectangle().fill(ShellPalette.hairline).frame(width: 1).ignoresSafeArea() }
                        }
                        .offset(x: settingsOpen ? (controllersOpen ? 0 : edgeDrag) : pane + 40)
                        .opacity(settingsOpen ? 1 : 0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .allowsHitTesting(settingsOpen)
                        .accessibilityHidden(!settingsOpen || choice != nil)
                        .accessibilityAddTraits(settingsOpen ? .isModal : [])
                        .transformPreference(FocusTargets.self) { if !settingsOpen { $0.removeAll() } }
                }
                if let id = helpGameID, let game = games.first(where: { $0.id == id })?.game {
                    Color.black.opacity(0.55).ignoresSafeArea().accessibilityHidden(true)
                        .onTapGesture { closeHelp() }
                        .transition(.opacity)
                    StateHelpView(game: game, actions: actions, onClose: closeHelp)
                        .frame(maxWidth: 460)
                        .background(Color(red: 0.075, green: 0.075, blue: 0.082), in: RoundedRectangle(cornerRadius: 26))
                        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.10)))
                        .shadow(color: .black.opacity(0.5), radius: 40)
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityAddTraits(.isModal)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
                if let choice {
                    Color.black.opacity(0.55).ignoresSafeArea().accessibilityHidden(true)
                        .onTapGesture { closeChoice() }
                        .transition(.opacity)
                    ChoicePickerView(request: choice, pick: pickChoice, close: closeChoice)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
                if controllersOpen {
                    Color.black.opacity(0.55 * (1 - min(1, edgeDrag / min(width, 520)))).ignoresSafeArea().accessibilityHidden(true)
                        .onTapGesture { back() }
                    ControllersView(controllers: controllers, onBack: back)
                        .frame(width: min(width, 520))
                        .frame(maxHeight: .infinity)
                        .background { ShellPalette.background.ignoresSafeArea() }
                        .overlay(alignment: .leading) { Rectangle().fill(ShellPalette.hairline).frame(width: 1).ignoresSafeArea() }
                        .offset(x: edgeDrag)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityAddTraits(.isModal)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .transformPreference(FocusTargets.self) { values in
                values = values.filter { target in
                    if controllersOpen { return target.id.hasPrefix("ctl.") }
                    if helpGameID != nil { return target.id.hasPrefix("help.") }
                    if choice != nil { return target.id.hasPrefix("pick.") }
                    return !target.id.hasPrefix("ctl.") && !target.id.hasPrefix("help.") && !target.id.hasPrefix("pick.")
                }
            }
            .coordinateSpace(name: "shell")
            .background {
                EdgeSwipeBack(enabled: (settingsOpen || controllersOpen) && choice == nil && helpGameID == nil,
                              changed: { edgeDrag = $0 },
                              ended: { finishEdgeSwipe(travel: $0, velocity: $1, span: controllersOpen ? min(width, 520) : pane) },
                              cancelled: cancelEdgeSwipe)
            }
            .onPreferenceChange(FocusTargets.self) { all in targets.values = all.filter { $0.frame.width > 1 } }
            .onAppear { self.layout = layout }
            .onChange(of: layout) { _, new in self.layout = new }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: layout)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: settingsOpen)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: controllersOpen)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: helpGameID)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: choice)
        .environment(\.shellPickChoice, { request in openChoice(request) })
        .environment(\.shellShowHelp, { game in openHelp(game.id) })
        .environment(\.shellFocus, focus)
        .environment(\.shellInputDevice, device)
        .foregroundStyle(.white)
        .font(ShellFonts.font(15)).tint(ShellPalette.cream).preferredColorScheme(.dark)
        .onChange(of: input) { _, event in if let event { handle(event.action, from: event.device) } }
        // A hardware keyboard, as on the Mac: arrows move, Return activates, Escape goes back, O opens game settings,
        // Y opens controllers.
        .focusable().focused($keyboardFocus).focusEffectDisabled()
        .onAppear { keyboardFocus = true }
        .onKeyPress(.leftArrow) { handle(.left, from: .keyboard); return .handled }
        .onKeyPress(.rightArrow) { handle(.right, from: .keyboard); return .handled }
        .onKeyPress(.upArrow) { handle(.up, from: .keyboard); return .handled }
        .onKeyPress(.downArrow) { handle(.down, from: .keyboard); return .handled }
        .onKeyPress(.return) { handle(.activate, from: .keyboard); return .handled }
        .onKeyPress(.escape) { handle(.back, from: .keyboard); return .handled }
        .onKeyPress("o") { handle(.settings, from: .keyboard); return .handled }
        .onKeyPress("y") { handle(.controllers, from: .keyboard); return .handled }
        .onDisappear { targets.values.removeAll() }
        .onChange(of: games.map(\.id)) { _, ids in
            if !ids.contains(selectedID ?? "") { selectedID = ids.first; settingsOpen = false }
        }
        .sheet(isPresented: $shellSettingsOpen) {
            ShellSettingsView(store: ShellSettingsStore()) { key in
                if key == "data" { actions.onPickShellData() } else { actions.onPickShellCloud() }
            }
        }
    }

    @ViewBuilder private func library(_ selected: GameDetail, layout: ShellLayout, size: CGSize, insets: EdgeInsets) -> some View {
        if layout.isCoverFlow {
            CoverFlowView(games: games, selected: selected, controllers: controllers.count, showsHints: !touchMode, screenInsets: insets,
                          select: select, primary: primary, openSettings: openSettings, openControllers: openControllers)
                .equatable()
                .transition(.opacity)
        } else {
            PortraitLibrary(games: games, selected: selected, wide: layout == .grid, size: size, topInset: insets.top, bottomInset: insets.bottom,
                            controllers: controllers.count, select: select, primary: primary,
                            openSettings: openSettings, openControllers: openControllers, position: $libraryPosition)
                .equatable()
                .transition(.opacity)
        }
    }

    /// The settings for the selected game: its banner as the header, with the title over it and Back on top, then
    /// the primary action and the setting groups. A panel or the whole screen, the same view.
    /// The settings for the selected game: its banner as the header, with the title below it and Back on top, then
    /// the primary action and the setting groups. A panel or the whole screen, the same view. The banner runs edge to
    /// edge under the status bar and the settings scroll under the home indicator, while Back, the words and the
    /// settings keep their insets.
    private func settingsPane(_ selected: GameDetail, floating: Bool, width: CGFloat, insets: EdgeInsets) -> some View {
        return ZStack(alignment: .top) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        PaneBanner(game: selected.game, width: width + insets.leading + insets.trailing,
                                   leading: insets.leading, trailing: insets.trailing, topInset: insets.top).id("set.top")
                        GameDetailView(detail: selected, actions: actions, showsPrimaryAction: true, showsHeader: false)
                            .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 32 + insets.bottom)
                            // A phone on its side: a readable column, not rows stretched across the whole width.
                            .frame(maxWidth: 640, alignment: .leading)
                            .padding(.leading, insets.leading).padding(.trailing, insets.trailing)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollPosition($settingsPosition)
                .scrollIndicators(.hidden)
                .ignoresSafeArea(edges: .all)
                .onChange(of: focus.id) { _, id in
                    guard let id, id.hasPrefix("set.") else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                        proxy.scrollTo(id, anchor: id == "set.back" ? .top : .center)
                    }
                }
            }
            HStack(spacing: 0) {
                Button(action: closeSettings) {
                    if typeSize.isAccessibilitySize { Image(systemName: "chevron.left").frame(minWidth: 24) }
                    else { Label(ShellStrings.text("Library"), systemImage: "chevron.left") }
                }
                .buttonStyle(ChipButtonStyle())
                .accessibilityLabel(ShellStrings.text("Library"))
                .accessibilityIdentifier("library.back")
                .shellTarget("set.back", radius: 22, action: closeSettings)
                Spacer(minLength: 0)
            }
            .padding(.leading, 16 + insets.leading).padding(.trailing, 16 + insets.trailing)
            .padding(.top, 6)
            .accessibilityElement(children: .contain)
        }
    }

    // MARK: Actions and focus

    /// An action that did not come from a controller or key came from touch: hints and focus ring step back.
    private func noteTouch() {
        guard !gate.handling else { return }
        if !touchMode { touchMode = true }
        if focus.visible { focus.visible = false }
    }
    private func primary(_ detail: GameDetail) {
        noteTouch()
        if detail.game.state.needsHelp { openHelp(detail.id); return }
        switch detail.game.state {
        case .playable: actions.onPlay(detail.id)
        case .needsGameData: actions.onPickGameData(detail.id)
        case .needsAppUpdate: actions.onAppUpdate()
        case .broken: actions.onShowLog(detail.id)
        }
    }
    private func select(_ id: String) {
        noteTouch()
        guard id != selectedID else { return }
        selectedID = id
        actions.onSelect(id)
        settingsPosition.scrollTo(edge: .top)
    }
    /// The swipe lets go: past a third of the panel or flung to the right, it finishes the slide out from where the
    /// finger is and then closes without a second animation. Otherwise the panel springs back.
    private func finishEdgeSwipe(travel: CGFloat, velocity: CGFloat, span: CGFloat) {
        guard travel > span / 3 || velocity > 600 else { cancelEdgeSwipe(); return }
        let close = {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { back(); edgeDrag = 0 }
        }
        if reduceMotion { close(); return }
        withAnimation(.smooth(duration: 0.25), completionCriteria: .logicallyComplete) { edgeDrag = span + 40 } completion: { close() }
    }
    private func cancelEdgeSwipe() {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { edgeDrag = 0 }
    }
    private func openSettings() {
        noteTouch()
        settingsOpen = true
        focus.id = "set.back"
    }
    private func closeSettings() {
        settingsOpen = false
        focus.id = "lib.settings"
    }
    private func openControllers() { noteTouch(); controllersOpen = true; focus.id = "ctl.close" }
    private func openHelp(_ id: String) { returnFocus = focus.id; helpGameID = id; focus.id = "help.done" }
    private func closeHelp() { helpGameID = nil; focus.id = returnFocus }
    private func openChoice(_ request: ChoiceRequest) {
        noteTouch()
        returnFocus = focus.id
        choice = request
        focus.id = "pick.\(request.row.value)"
    }
    private func closeChoice() {
        guard let request = choice else { return }
        choice = nil
        focus.id = "set.row.\(request.row.id)"
    }
    private func pickChoice(_ value: String) {
        noteTouch()
        guard let request = choice else { return }
        if value != request.row.value { actions.onChange(request.gameID, request.row.id, value) }
        closeChoice()
    }
    private func back() {
        if choice != nil { closeChoice() }
        else if helpGameID != nil { closeHelp() }
        else if controllersOpen { controllersOpen = false; focus.id = "lib.controllers" }
        else if settingsOpen { closeSettings() }
        else { actions.onBack() }
    }
    private func handle(_ action: ShellInput.Action, from source: InputDevice) {
        gate.handling = true
        defer { gate.handling = false }
        if device != source { device = source }
        if touchMode { touchMode = false }
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
        if let choice { return "pick.\(choice.row.value)" }
        if helpGameID != nil { return "help.done" }
        if controllersOpen { return "ctl.close" }
        if settingsOpen { return "set.back" }
        return selected.map { "lib.tile.\($0.id)" } ?? "lib.controllers"
    }
}

/// The top of the settings: the game's banner, whole and fading into the panel, then its state and title below it,
/// so the banner's own logo and the title never overlap. Capped in height for a phone on its side.
private struct PaneBanner: View {
    let game: GameTile
    /// The full width, edge to edge under the side safe areas.
    let width: CGFloat
    /// The side safe areas: the words keep them, the banner does not.
    var leading: CGFloat = 0
    var trailing: CGFloat = 0
    /// The status bar's height where the banner runs under it.
    var topInset: CGFloat = 0
    var body: some View {
        let hasBanner = game.banner != nil
        // A banner gets its full width and 16:9 height. Square or portrait art is never cropped into a tile: it shows
        // whole as a rounded cover above the words, on a heavily blurred fill of itself.
        let bannerHeight = hasBanner ? min(width * 9 / 16, 220) + topInset : topInset + 64
        // On a wide screen the cover sits beside the words, on a narrow one above them, aligned to the same edge.
        let layout = width >= 560 ? AnyLayout(HStackLayout(alignment: .bottom, spacing: 22))
                                  : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
        layout {
            if !hasBanner { CoverThumbnail(game: game).frame(width: 96, height: 96) }
            // The words are bottom-aligned in a block that always reserves two lines of title, as in the library
            // hero: a short title shows more banner above it instead of leaving a hole.
            ZStack(alignment: .bottomLeading) {
                words(title: "M\nM").hidden().accessibilityHidden(true)
                words(title: game.title)
            }
        }
        .padding(.leading, leading + 24).padding(.trailing, trailing + 24)
        .padding(.top, bannerHeight - (hasBanner ? 22 : 0))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .top) {
            // The art runs on past the header and fades into the page over a long distance, so there is no line where
            // the header ends and the settings begin.
            GeometryReader { geometry in
                let tall = geometry.size.height + 160
                Group {
                    if hasBanner {
                        // The banner fills the header edge to edge, cropped as needed, darker under the words.
                        ArtView(game: game, lettering: false)
                            .overlay {
                                LinearGradient(stops: [.init(color: .clear, location: 0.3), .init(color: .black.opacity(0.4), location: 0.6),
                                                       .init(color: .black.opacity(0.55), location: 1)], startPoint: .top, endPoint: .bottom)
                            }
                    } else {
                        ArtView(game: game, backdrop: true)
                            .scaleEffect(1.4)
                            .blur(radius: 40, opaque: true)
                            .saturation(1.2)
                            .overlay(Color.black.opacity(0.38))
                    }
                }
                .frame(width: width, height: tall)
                .clipped()
                .overlay(alignment: .top) {
                    // Darker under the status bar, so the time and battery stay legible on any art.
                    if topInset > 0 {
                        LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: topInset + 50)
                    }
                }
                .mask {
                    LinearGradient(stops: [.init(color: .black, location: 0),
                                           .init(color: .black, location: 0.45),
                                           .init(color: .black.opacity(0.55), location: 0.68),
                                           .init(color: .black.opacity(0.18), location: 0.85),
                                           .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
                }
            }
            .accessibilityHidden(true)
        }
    }

    private func words(title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            StatusLabel(state: game.state, prominent: true)
            Text(title).shellType(ShellType.pageTitle).lineLimit(2)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("detail.title")
            HStack(spacing: 8) {
                SectionHeading(title: ShellStrings.text("Game settings"))
                if !game.subtitle.isEmpty {
                    Text(game.subtitle).shellType(ShellType.note).foregroundStyle(.white.opacity(0.5))
                }
            }.padding(.top, 2)
        }
    }
}

/// A game's square art shown whole: the icon, or the placeholder cover when there is none.
private struct CoverThumbnail: View {
    let game: GameTile
    var body: some View {
        Group {
            if let icon = game.icon {
                Image(decorative: icon.image, scale: 1).resizable().interpolation(.high).scaledToFill()
            } else if let banner = game.banner {
                Image(decorative: banner.image, scale: 1).resizable().interpolation(.high).scaledToFill()
            } else {
                PlaceholderArt(title: game.title, seed: game.id)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
        .accessibilityHidden(true)
    }
}

/// Marks the actions a controller or key press causes, so they are not taken for touch. Not observed.
@MainActor final class InputGate {
    var handling = false
}
