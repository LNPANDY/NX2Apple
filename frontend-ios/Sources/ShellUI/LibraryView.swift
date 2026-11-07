import SwiftUI

/// How the library arranges itself. Only the available size decides, never the device model or orientation,
/// so a Stage Manager window, Split View and a foldable opening while the app runs all follow the same rules.
enum ShellLayout: Equatable {
    /// Compact and taller than wide: one library column.
    case column
    /// Regular width and height, not wide: a grid of cards.
    case grid
    /// Wider than tall: Cover Flow.
    case coverFlow(regular: Bool)

    static func resolve(_ size: CGSize, accessibilityText: Bool) -> ShellLayout {
        let regular = size.width >= 600 && size.height >= 500
        if size.width > size.height * 1.2 { return .coverFlow(regular: regular) }
        return regular && !accessibilityText ? .grid : .column
    }

    var isCoverFlow: Bool { if case .coverFlow = self { true } else { false } }

    static func divisionAxis(_ division: CGRect?, in size: CGSize) -> Axis? {
        guard let division, division.intersects(CGRect(origin: .zero, size: size)), !division.isEmpty else { return nil }
        return division.width > division.height ? .horizontal : .vertical
    }

    static func collapseProgress(expanded: CGFloat, minimum: CGFloat, travel: CGFloat) -> CGFloat {
        let distance = expanded - minimum
        return distance > 0 ? min(1, max(0, travel / distance)) : 1
    }

}

/// A presentation-only shell. Selection, focus, navigation and scroll positions are local UI state.
/// All game effects are supplied by the host through actions.
public struct LibraryView: View {
    public let games: [GameDetail]
    public let controllers: [ControllerInfo]
    public let globalPadMap: PadMap
    /// The controller's state while the button test is open, from the host.
    public let padSnapshot: PadSnapshot?
    public var actions: ShellActions
    public var input: ShellInputLog
    /// The sequence of the last input event acted on.
    @State private var inputSeen: Int
    @State private var selectedID: String?
    @State private var settingsOpen: Bool
    /// The settings pane has finished sliding in: its focus ring shows only then, not ahead of it where it will stop.
    @State private var settingsArrived: Bool
    /// Counts the opening and closing of the settings pane, so a wait for one opening does not act on a later one.
    @State private var settingsOpenings = 0
    @State private var shellSettingsOpen: Bool
    @State private var controllersOpen: Bool
    /// The game whose How to fix or How to update explanation is open.
    @State private var helpGameID: String?
    /// The game whose Delete question is open, and whether its saves go too.
    @State private var deleteGameID: String?
    @State private var deleteSaves = false
    /// The choice whose option list is open.
    @State private var choice: ChoiceRequest?
    /// The button-mapping card, while open.
    @State private var padMapping: PadMappingState?
    @State private var buttonTestOpen: Bool
    /// The touch controls' layout editor, while open (over the shell settings).
    @State private var touchLayout: TouchLayoutEditorModel?
    @State private var focus: FocusAppearance
    @State private var targets = FocusTargetBuffer()
    @State private var settingsPosition = ScrollPosition()
    @State private var settingsHeroVisible = true
    @State private var settingsHeroHeight: CGFloat = 0
    @State private var libraryPosition = ScrollPosition()
    @State private var layout: ShellLayout = .column
    @State private var divisionAxis: Axis?
    private var horizontalDivision: Bool { divisionAxis == .horizontal }
    @State private var pendingMenuAction: (() -> Void)?
    @State private var returnFocus: String?
    /// The device that sent the last input, for the glyphs.
    @State private var device: InputDevice = .controller(.neutral)
    /// True after a touch: the controller hints and the focus ring step back until the next controller or key press.
    @State private var touchMode: Bool
    @State private var gate = InputGate()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(games: [GameDetail], controllers: [ControllerInfo] = [], actions: ShellActions = ShellActions(),
                input: ShellInputLog = ShellInputLog(), initialSelection: String? = nil, initialDetailOpen: Bool = false,
                initialControllersOpen: Bool = false, initialShellSettingsOpen: Bool = false, initialFocusVisible: Bool = false,
                globalPadMap: PadMap = PadMap(), padSnapshot: PadSnapshot? = nil,
                initialPadMapping: String? = nil, initialButtonTestOpen: Bool = false) {
        ShellPalette.configureNativeAppearance()
        self.games = games
        self.controllers = controllers
        self.globalPadMap = globalPadMap
        self.padSnapshot = padSnapshot
        _padMapping = State(initialValue: initialPadMapping.map { PadMappingState(gameID: $0) })
        _buttonTestOpen = State(initialValue: initialButtonTestOpen)
        self.actions = actions
        self.input = input
        _inputSeen = State(initialValue: input.last)
        let first = initialSelection ?? games.first?.id
        _selectedID = State(initialValue: first)
        _settingsOpen = State(initialValue: initialDetailOpen)
        _settingsArrived = State(initialValue: initialDetailOpen)
        _controllersOpen = State(initialValue: initialControllersOpen)
        _shellSettingsOpen = State(initialValue: initialShellSettingsOpen)
        _focus = State(initialValue: FocusAppearance(id: initialFocusVisible ? "lib.tile.\(first ?? "")" : nil, visible: initialFocusVisible))
        _touchMode = State(initialValue: !initialFocusVisible)
    }
    private var selected: GameDetail? { games.first { $0.id == selectedID } ?? games.first }

    public var body: some View {
        NavigationStack {
            Group {
                #if os(iOS)
                if #available(iOS 27.1, *) {
                    content.toolbarMinimizationBehavior(.never, for: .navigationBar)
                        .toolbarVerticalBehavior(landscapeLibrary ? .disabled : .automatic)
                } else if #available(iOS 27.0, *) {
                    // Keep library actions available when rotation replaces the vertical scroll view with Cover Flow.
                    content.toolbarMinimizationBehavior(.never, for: .navigationBar)
                } else { content }
                #else
                content
                #endif
            }
            .toolbar { libraryToolbar }
        }
        .environment(\.shellNativeBars, true)
        .environment(\.shellFocus, focus)
        .coordinateSpace(name: "shell")
        .tint(ShellPalette.cream).preferredColorScheme(.dark)
    }

    private var content: some View {
        GeometryReader { geometry in
            let insets = geometry.safeAreaInsets
            let whole = CGSize(width: geometry.size.width + insets.leading + insets.trailing,
                               height: geometry.size.height + insets.top + insets.bottom)
            let layout = ShellLayout.resolve(whole, accessibilityText: typeSize.isAccessibilitySize)
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                if layout.isCoverFlow, let selected { CoverFlowBackdrop(game: selected.game) } else { ShellPalette.background.ignoresSafeArea() }
                if games.isEmpty {
                    EmptyLibraryView()
                } else if let selected {
                    library(selected, layout: layout, size: geometry.size, insets: insets)
                        .frame(width: width, height: geometry.size.height)
                        .allowsHitTesting(!menuPresented)
                        .accessibilityHidden(menuPresented)
                }

            }
            .coordinateSpace(name: "shell")
            .sheet(isPresented: Binding(get: { menuPresented }, set: { if !$0 { dismissMenus() } }), onDismiss: runPendingMenuAction) {
                menuSheet
                    #if os(iOS)
                    .background(TouchEditorPresentation(content: touchLayout.map { AnyView(editorPage($0)) }))
                    #else
                    .sheet(isPresented: Binding(get: { touchLayout != nil }, set: { if !$0 { closeTouchLayout() } })) {
                        if let touchLayout { editorPage(touchLayout) }
                    }
                    #endif
                    .presentationSizing(LauncherMenuSizing(mapping: padMapping != nil))
                    // shortcut: cap tabletop sheets until the runtime keeps large detents clear of the fold.
                    .presentationDetents(horizontalDivision ? [.medium] : [.large])
                    .presentationCompactAdaptation(divisionAxis == nil ? .automatic : .sheet)
                    .presentationDragIndicator(.visible)
                    .presentationBackground(ShellPalette.background)
                    .presentationContentInteraction(touchLayout != nil ? .scrolls : .automatic)
                    .interactiveDismissDisabled(touchLayout != nil)
                    .modifier(MenuPlacement(divided: divisionAxis == .vertical, secondary: controllersOpen || shellSettingsOpen))
                    .modifier(ShellKeyboardNavigation(active: touchLayout == nil && padMapping?.row == nil) { handle($0, from: .keyboard) })
            }

            .environment(\.shellOpenTouchLayout, { openTouchLayout(whole, insets) })
            .onPreferenceChange(FocusTargets.self) { all in
                targets.libraryValues = all.filter { $0.frame.width > 1 }
            }
            .onGeometryChange(for: Axis?.self) { geometry in
                if #available(iOS 27.1, macOS 27.1, *) {
                    return ShellLayout.divisionAxis(geometry.reservedRegions(kind: .division).first?.frame, in: geometry.size)
                }
                return nil
            } action: { divisionAxis = $0 }
            .onAppear { self.layout = layout }
            .onChange(of: layout) { _, new in self.layout = new }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: layout)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: settingsOpen)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: controllersOpen)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: shellSettingsOpen)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: helpGameID)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: deleteGameID)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: choice)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: padMapping)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: buttonTestOpen)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: touchLayout != nil)
        .environment(\.shellPickChoice, { request in openChoice(request) })
        .environment(\.shellOpenPadMapping, { id in openPadMapping(id) })
        .environment(\.shellOpenButtonTest, { openButtonTest() })
        .environment(\.shellIgnoresPress, { [gate] in gate.isSystemEcho })
        .environment(\.shellShowHelp, { game in openHelp(game.id) })
        .environment(\.shellAskDelete, { game in openDelete(game.id) })
        .environment(\.shellFocus, focus)
        .environment(\.shellInputDevice, device)
        .foregroundStyle(.white)
        .font(ShellFonts.font(15)).tint(ShellPalette.cream).preferredColorScheme(.dark)
        .onChange(of: input) { _, log in
            // Every event since the last update, in order: several can come between two updates.
            for event in log.since(inputSeen) {
                // A button let go only restarts the window for the system's echo, which comes as the button comes up.
                if event.released { if case .controller = event.device { gate.controllerUp(event.action) }; continue }
                handle(event.action, from: event.device)
            }
            inputSeen = log.last
        }
        .onAnyTouch { gate.touch() }
        .modifier(ShellKeyboardNavigation(active: !menuPresented) { handle($0, from: .keyboard) })
        .onDisappear { targets.values.removeAll(); targets.libraryValues.removeAll() }
        .onChange(of: settingsOpen) { _, open in
            settingsArrived = false
            settingsOpenings += 1
            guard open else { return }
            // The pane slides in over 0.3 s (the animation on settingsOpen). Only for this opening: closed and opened
            // again within the 0.3 s, the first opening's wait would show the ring while the pane still slides.
            let opening = settingsOpenings
            DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : 0.3)) {
                if settingsOpen && settingsOpenings == opening { settingsArrived = true }
            }
        }
        .onChange(of: games.map(\.id)) { _, ids in
            if !ids.contains(selectedID ?? "") { selectedID = ids.first; settingsOpen = false }
        }
    }

    private func visibleTargets(_ values: [FocusTarget]) -> [FocusTarget] {
        values.filter { $0.frame.width > 1 }
    }

    private var menuPresented: Bool {
        touchLayout != nil || settingsOpen || controllersOpen || shellSettingsOpen || helpGameID != nil
            || deleteGameID != nil || choice != nil || padMapping != nil || buttonTestOpen
    }

    // Host-owned alerts and sheets must wait until the menu presentation finishes closing.
    private var menuActions: ShellActions {
        var routed = guardedActions
        routed.onPlay = { id in handOffMenu { actions.onPlay(id) } }
        routed.onShowLog = { id in handOffMenu { actions.onShowLog(id) } }
        routed.onAppUpdate = { handOffMenu { actions.onAppUpdate() } }
        return routed
    }

    private func handOffMenu(_ action: @escaping () -> Void) {
        pendingMenuAction = action
        dismissMenus()
    }

    private func runPendingMenuAction() {
        let action = pendingMenuAction
        pendingMenuAction = nil
        action?()
    }

    private func dismissMenus() {
        closeTouchLayout()
        if buttonTestOpen { closeButtonTest() }
        choice = nil
        padMapping = nil
        helpGameID = nil
        deleteGameID = nil
        controllersOpen = false
        shellSettingsOpen = false
        settingsOpen = false
        focus.id = "lib.tile.\(selected?.id ?? "")"
    }

    private var menuSheet: some View {
        NavigationStack {
            menuContent.toolbar { if touchLayout == nil { launcherToolbar } }
                .accessibilityHidden(touchLayout != nil)
                .navigationDestination(isPresented: Binding(get: { padMapping != nil }, set: { if !$0 { closePadMapping() } })) {
                    if let mapping = padMapping {
                        PadMappingCard(title: padMappingTitle(mapping.gameID), rows: padMappingRows(mapping.gameID),
                                       inherited: mapping.gameID == ControllersView.mappingID ? nil : globalPadMap, openRow: mapping.row,
                                       open: openPadRow, pick: pickPadValue, backToList: closePadRow, reset: resetPadMapping, close: closePadMapping,
                                       onChoiceTargets: { targets.values = visibleTargets($0) },
                                       onChoiceInput: { handle($0, from: .keyboard) })
                            .navigationTitle(ShellStrings.text("Button mapping"))
                            #if os(iOS)
                            .navigationBarTitleDisplayMode(.inline)
                            #endif
                            .navigationBarBackButtonHidden()
                            .toolbar { launcherToolbar }
                            .onPreferenceChange(FocusTargets.self) { if padMapping?.row == nil { targets.values = visibleTargets($0) } }
                    }
                }
                .navigationDestination(isPresented: Binding(get: { buttonTestOpen }, set: { if !$0 { closeButtonTest() } })) {
                    ButtonTestView(snapshot: padSnapshot, close: closeButtonTest)
                        .navigationTitle(ShellStrings.text("Button test"))
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                        .navigationBarBackButtonHidden()
                        .toolbar { launcherToolbar }
                        .onPreferenceChange(FocusTargets.self) { targets.values = visibleTargets($0) }
                }
        }
        .background {
            if settingsOpen, let selected { CoverFlowBackdrop(game: selected.game) }
        }
        #if os(iOS)
        .toolbarBackground(settingsOpen ? .hidden : .automatic, for: .navigationBar)
        #endif
    }

    private func editorPage(_ model: TouchLayoutEditorModel) -> some View {
        TouchLayoutEditorView(model: model, close: confirmTouchLayout, cancel: closeTouchLayout)
            .ignoresSafeArea(.container)
            #if os(iOS)
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
            #endif
            .coordinateSpace(name: "shell")
            .environment(\.shellNativeBars, true)
            .environment(\.shellFocus, focus)
            .environment(\.shellIgnoresPress, { [gate] in gate.isSystemEcho })
            .onPreferenceChange(FocusTargets.self) { targets.values = visibleTargets($0) }
            .tint(ShellPalette.cream)
            .preferredColorScheme(.dark)
            .interactiveDismissDisabled()
            .modifier(ShellKeyboardNavigation(active: true) { handle($0, from: .keyboard) })
    }

    private var menuContent: some View {
        GeometryReader { geometry in
            ZStack {
                if settingsOpen, let selected {
                    settingsPane(selected, width: geometry.size.width)
                        .accessibilityHidden(controllersOpen || shellSettingsOpen || choice != nil || padMapping != nil || helpGameID != nil || deleteGameID != nil)
                }
                if controllersOpen {
                    ControllersView(controllers: controllers, onBack: back, padMap: globalPadMap)
                        .background(ShellPalette.background)
                        .accessibilityHidden(choice != nil || padMapping != nil || buttonTestOpen)
                }
                if shellSettingsOpen {
                    ShellSettingsView(actions: menuActions, onClose: closeShellSettings)
                        .background(ShellPalette.background)
                        .accessibilityHidden(choice != nil)
                }
                if let id = helpGameID, let game = games.first(where: { $0.id == id })?.game {
                    ScrollView { StateHelpView(game: game, actions: menuActions, onClose: closeHelp).padding(24) }
                        .background(ShellPalette.background)
                }
                if let id = deleteGameID, let game = games.first(where: { $0.id == id })?.game {
                    ScrollView { DeleteGameView(game: game, saves: $deleteSaves, delete: { confirmDelete(id) }, cancel: closeDelete) }
                        .background(ShellPalette.background)
                }
                if let choice {
                    ChoicePickerView(request: choice, pick: pickChoice, close: closeChoice)
                        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(ShellPalette.background)
                }

            }
            .onPreferenceChange(FocusTargets.self) { all in
                if touchLayout == nil { targets.values = visibleTargets(all).filter { $0.frame.width > 1 } }
            }

        }
        .navigationTitle(menuTitle)
        .navigationSubtitle(tabletopSettings ? ShellStrings.text("Game settings").uppercased() : "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var tabletopSettings: Bool {
        horizontalDivision && settingsOpen && !controllersOpen && !shellSettingsOpen && choice == nil
            && padMapping == nil && !buttonTestOpen && helpGameID == nil && deleteGameID == nil
    }

    private var menuTitle: String {
        guard choice == nil, padMapping == nil, !buttonTestOpen, helpGameID == nil, deleteGameID == nil else { return "" }
        if controllersOpen { return ShellStrings.text("Controllers") }
        if shellSettingsOpen { return ShellStrings.text("Settings") }
        return settingsOpen && (horizontalDivision || !settingsHeroVisible) ? selected?.game.title ?? "" : ""
    }

    @ViewBuilder private func library(_ selected: GameDetail, layout: ShellLayout, size: CGSize, insets: EdgeInsets) -> some View {
        if layout.isCoverFlow {
            CoverFlowView(games: games, selected: selected, controllers: controllers.count, showsHints: !touchMode, obscured: menuPresented, screenInsets: insets,
                          select: select, primary: { primary($0) }, openSettings: openSettings, openControllers: openControllers,
                          openShellSettings: openShellSettings)
                .equatable()
                .transition(.opacity)
        } else {
            PortraitLibrary(games: games, selected: selected, wide: layout == .grid, size: size, topInset: insets.top, bottomInset: insets.bottom, obscured: menuPresented,
                            controllers: controllers.count, select: select, primary: { primary($0) },
                            openSettings: openSettings, openControllers: openControllers, openShellSettings: openShellSettings,
                            position: $libraryPosition)
                .equatable()
                .transition(.opacity)
        }
    }

    /// Game settings keep their content column inside the system sheet's safe area.
    private func settingsPane(_ selected: GameDetail, width: CGFloat) -> some View {
        return ZStack(alignment: .top) {
            ScrollViewReader { proxy in
                Form {
                    if !horizontalDivision {
                        Section {
                            PaneBanner(game: selected.game, width: width)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { settingsHeroHeight = $0 }
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                        .id("set.top")
                    }
                    GameDetailView(detail: selected, actions: menuActions,
                                   showsPrimaryAction: false,
                                   showsHeader: false, nativeSections: true)
                }
                .formStyle(.grouped)
                .contentMargins(.top, 0, for: .scrollContent)
                .scrollContentBackground(.hidden)
                .onScrollGeometryChange(for: Bool.self) {
                    settingsHeroHeight == 0 || $0.contentOffset.y + $0.contentInsets.top < settingsHeroHeight
                } action: { _, visible in settingsHeroVisible = visible }
                .scrollPosition($settingsPosition)
                .accessibilityIdentifier("settings.scroll")
                .scrollIndicators(.hidden)
                .onChange(of: focus.id) { _, id in
                    guard let id, id.hasPrefix("set.") else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                        if id == "set.back" { settingsPosition.scrollTo(edge: .top) }
                        else { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
    }

    private enum BarGroup { case close, done, actions }
    private struct ToolbarAction: Identifiable {
        let title: String.LocalizationValue
        let symbol: String
        let id: String
        let target: String
        let placement: BarGroup
        let action: () -> Void
    }

    // The navigation container owns these bars so UIKit can share the Duo rail with system UI.
    @ToolbarContentBuilder private var launcherToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .cancellationAction) {
            ForEach(toolbarActions.filter { $0.placement == .close }) { item in
                toolbarButton(ShellStrings.text(item.title), item.symbol, item.id, item.target, item.action)
            }
        }
        ToolbarItemGroup(placement: donePlacement) {
            ForEach(toolbarActions.filter { $0.placement == .done }) { item in
                toolbarButton(ShellStrings.text(item.title), item.symbol, item.id, item.target, item.action)
                    .disabled(item.id == "touchLayout.done" && touchLayout?.invalidPlacement == true)
                    .buttonStyle(.borderedProminent).tint(ShellPalette.cream).foregroundStyle(.black)
            }
        }
        if settingsOpen, helpGameID == nil, deleteGameID == nil, choice == nil, padMapping == nil,
           !controllersOpen, !shellSettingsOpen, let selected {
            ToolbarItem(placement: .primaryAction) {
                toolbarButton(selected.game.state.actionTitle, selected.game.state.actionSymbol, "state.action", "set.play") { primary(selected, fromSettings: true) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderedProminent)
                    .tint(ShellPalette.cream)
                    .foregroundStyle(.black)
            }
        }
    }

    @ToolbarContentBuilder private var libraryToolbar: some ToolbarContent {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            libraryToolbarItems.axisBehavior(layout.isCoverFlow || layout == .column ? .horizontalOnly : .automatic)
        } else { libraryToolbarItems }
        #else
        libraryToolbarItems
        #endif
    }

    private var libraryTitlePlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }

    private var landscapeLibrary: Bool {
        layout.isCoverFlow
    }

    @ToolbarContentBuilder private var libraryToolbarItems: some ToolbarContent {
        if landscapeLibrary, let selected {
            ToolbarItem(placement: libraryTitlePlacement) {
                HStack(spacing: 8) {
                    Text(ShellStrings.text("Your games")).textCase(.uppercase).font(.caption).tracking(1.8)
                    Text(ShellStrings.text("\((games.firstIndex { $0.id == selected.id } ?? 0) + 1) of \(games.count)"))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .fixedSize().layoutPriority(1)
                }
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("library.position")
            }
            .sharedBackgroundVisibility(.hidden)
        }

        if let item = libraryActions.first(where: { $0.id == "controllers.open" }) {
            controllerItem(item)
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        if let item = libraryActions.first(where: { $0.id == "shellSettings.open" }) {
            ToolbarItem(placement: .primaryAction) {
                toolbarButton(ShellStrings.text(item.title), item.symbol, item.id, item.target, item.action)
                    .disabled(menuPresented).accessibilityHidden(menuPresented)
            }
        }
    }

    private func controllerItem(_ item: ToolbarAction) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            toolbarButton(ShellStrings.text(item.title), item.symbol, item.id, item.target, item.action)
                .disabled(menuPresented).accessibilityHidden(menuPresented)
        }
    }

    private var toolbarActions: [ToolbarAction] {
        if buttonTestOpen { return [.init(title: "Controllers", symbol: "chevron.left", id: "buttonTest.close", target: "test.close", placement: .close, action: closeButtonTest)] }
        if padMapping != nil {
            return [.init(title: "Back", symbol: "chevron.left", id: "padMapping.close", target: "map.close", placement: .close, action: closePadMapping)]
        }
        if choice != nil { return [.init(title: "Close", symbol: "xmark", id: "choice.close", target: "pick.close", placement: .close, action: closeChoice)] }
        if touchLayout != nil {
            return [.init(title: "Cancel", symbol: "xmark", id: "touchLayout.back", target: "lay.back", placement: .close, action: closeTouchLayout),
                    .init(title: "Done", symbol: "checkmark", id: "touchLayout.done", target: "lay.done", placement: .done, action: confirmTouchLayout)]
        }
        if helpGameID != nil { return [.init(title: settingsOpen ? "Game settings" : "Close", symbol: settingsOpen ? "chevron.left" : "xmark", id: "help.done", target: "help.done", placement: .close, action: closeHelp)] }
        if deleteGameID != nil { return [] }
        if controllersOpen { return [.init(title: "Close controllers", symbol: "xmark", id: "controllers.close", target: "ctl.close", placement: .close, action: back)] }
        if shellSettingsOpen { return [.init(title: "Close", symbol: "xmark", id: "shellSettings.close", target: "shs.close", placement: .close, action: closeShellSettings)] }
        if settingsOpen { return [.init(title: "Close", symbol: "xmark", id: "library.back", target: "set.back", placement: .close, action: closeSettings)] }
        return libraryActions
    }

    private var libraryActions: [ToolbarAction] {
        var items: [ToolbarAction] = []
        items.append(.init(title: "Controllers", symbol: controllers.isEmpty ? "gamecontroller" : "gamecontroller.fill", id: "controllers.open", target: "lib.controllers", placement: .actions, action: openControllers))
        items.append(.init(title: "Settings", symbol: "gearshape", id: "shellSettings.open", target: "lib.shellSettings", placement: .actions, action: openShellSettings))
        return items
    }

    private var donePlacement: ToolbarItemPlacement { .confirmationAction }

    private func toolbarButton(_ label: String, _ symbol: String, _ identifier: String, _ target: String,
                               _ action: @escaping () -> Void) -> some View {
        let accessibilityLabel = identifier == "controllers.open" ? label + ", \(controllers.count)" : label
        return Button { if !fromSystemEcho { action() } } label: {
            if identifier == "controllers.open" {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: symbol).foregroundStyle(.white).frame(width: 32, height: 32)
                        if !controllers.isEmpty {
                            Text(controllers.count, format: .number)
                                .font(.caption2.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4).frame(minWidth: 18, minHeight: 18)
                                .background(.black, in: Capsule())
                                .fixedSize().offset(x: 4, y: -4)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
            } else { Label(label, systemImage: symbol) }
        }
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier(identifier)
            .shellTarget(target, radius: 22, action: action)
            // Toolbar content is separately hosted: register its actual geometry without relying on preferences crossing hosts.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                targets.toolbarValues[target] = FocusTarget(id: target, frame: frame, activate: action)
            }
            .onDisappear { targets.toolbarValues.removeValue(forKey: target) }
    }

    private var activeTargets: [FocusTarget] {
        let prefix: String
        if buttonTestOpen { prefix = "test." }
        else if padMapping != nil { prefix = "map." }
        else if choice != nil { prefix = "pick." }
        else if touchLayout != nil { prefix = "lay." }
        else if helpGameID != nil { prefix = "help." }
        else if deleteGameID != nil { prefix = "del." }
        else if controllersOpen { prefix = "ctl." }
        else if shellSettingsOpen { prefix = "shs." }
        else if settingsOpen { prefix = "set." }
        else { prefix = "lib." }
        return targets.active(prefix: prefix, toolbarIDs: Set(toolbarActions.map(\.target)))
    }

    // MARK: Actions and focus

    /// The system's echo of a controller button (see `SystemEchoWindow`), for the actions that close or go back: they
    /// do not change the touch mode, but the echo must not close the panel the button just opened.
    private var fromSystemEcho: Bool { gate.isSystemEcho }
    /// `actions` for the views that change settings or data themselves (a switch, a row, a button in the settings): the
    /// system's echo of a controller button changes nothing through them.
    private var guardedActions: ShellActions {
        let gate = gate
        func echo() -> Bool { gate.isSystemEcho }
        var a = actions
        let o = actions
        a.onSelect = { if !echo() { o.onSelect($0) } }
        a.onPlay = { if !echo() { o.onPlay($0) } }
        a.onChange = { if !echo() { o.onChange($0, $1, $2) } }
        a.onPickGameData = { if !echo() { o.onPickGameData($0) } }
        a.onUseAppData = { if !echo() { o.onUseAppData($0) } }
        a.onPickCloudSaves = { if !echo() { o.onPickCloudSaves($0) } }
        a.onDisableCloudSaves = { if !echo() { o.onDisableCloudSaves($0) } }
        a.onResetDefaults = { if !echo() { o.onResetDefaults($0) } }
        a.onShowLog = { if !echo() { o.onShowLog($0) } }
        a.onAppUpdate = { if !echo() { o.onAppUpdate() } }
        a.onPickShellData = { if !echo() { o.onPickShellData() } }
        a.onPickShellCloud = { if !echo() { o.onPickShellCloud() } }
        a.onUseShellCloud = { if !echo() { o.onUseShellCloud($0) } }
        a.onClearShellData = { if !echo() { o.onClearShellData() } }
        a.onClearShellCloud = { if !echo() { o.onClearShellCloud() } }
        a.onGlobalPadMapChange = { if !echo() { o.onGlobalPadMapChange($0, $1) } }
        a.onGlobalPadMapReset = { if !echo() { o.onGlobalPadMapReset() } }
        a.onDeleteGame = { if !echo() { o.onDeleteGame($0, $1) } }
        return a
    }
    /// An action that did not come from a controller or key came from touch: hints and focus ring step back. False when
    /// it came from neither but is the system's echo of a controller button (see `SystemEchoWindow`): the shell's own
    /// focus already took that button, so the press is not acted on.
    private func noteTouch() -> Bool {
        guard !gate.handling else { return true }
        if gate.isSystemEcho { return false }
        if !touchMode { touchMode = true }
        if focus.visible { focus.visible = false }
        return true
    }
    /// A press on the library's own buttons that the shell may act on: from `handle`, or with nothing over the library.
    /// Under a dialog or a panel no finger reaches the library (it takes no hits there), so a press on its buttons is the
    /// system's echo of a controller button, whatever the window says: a finger that came down elsewhere just before the
    /// echo (a tap in the settings pane right after A) ends the window, and Play behind the pane started the game.
    private var libraryPressAllowed: Bool { FocusLayer.libraryTakesPress(fromShell: gate.handling, under: topLayer) }
    private func primary(_ detail: GameDetail, fromSettings: Bool = false) {
        guard (fromSettings && topLayer == .settings) || libraryPressAllowed, noteTouch() else { return }
        if detail.game.state.needsHelp { openHelp(detail.id); return }
        let targetActions = settingsOpen ? menuActions : actions
        switch detail.game.state {
        case .playable: targetActions.onPlay(detail.id)
        case .needsGameData: targetActions.onPickGameData(detail.id)
        case .needsAppUpdate: targetActions.onAppUpdate()
        case .broken: targetActions.onShowLog(detail.id)
        }
    }
    private func select(_ id: String) {
        guard libraryPressAllowed, noteTouch() else { return }
        guard id != selectedID else { return }
        selectedID = id
        actions.onSelect(id)
        settingsHeroVisible = true
        settingsPosition.scrollTo(edge: .top)
    }
    private func openSettings() {
        guard !shellSettingsOpen else { return }
        guard noteTouch() else { return }
        controllersOpen = false
        settingsOpen = true
        focus.id = "set.back"
    }
    private func closeSettings() {
        guard !fromSystemEcho else { return }
        settingsOpen = false
        focus.id = "lib.settings"
    }
    private func openControllers() { guard !shellSettingsOpen else { return }; guard noteTouch() else { return }; controllersOpen = true; focus.id = "ctl.close" }
    private func openShellSettings() { guard noteTouch() else { return }; shellSettingsOpen = true; focus.id = "shs.close" }
    private func closeShellSettings() { guard !fromSystemEcho else { return }; shellSettingsOpen = false; focus.id = "lib.shellSettings" }
    private func openTouchLayout(_ window: CGSize, _ insets: EdgeInsets) {
        guard noteTouch() else { return }
        touchLayout = TouchLayoutEditorModel.forDevice(window: window, insets: insets)
        focus.id = "lay.options"
    }
    private func closeTouchLayout() { guard !fromSystemEcho else { return }; touchLayout = nil; focus.id = "shs.arrange" }
    private func confirmTouchLayout() {
        guard !fromSystemEcho, let touchLayout, !touchLayout.invalidPlacement else { return }
        touchLayout.commit()
        closeTouchLayout()
    }
    private func openHelp(_ id: String) { guard !fromSystemEcho else { return }; returnFocus = focus.id; helpGameID = id; focus.id = "help.done" }
    private func closeHelp() { guard !fromSystemEcho else { return }; helpGameID = nil; focus.id = returnFocus }
    /// The question starts on Cancel, with the saves kept.
    private func openDelete(_ id: String) { guard noteTouch() else { return }; returnFocus = focus.id; deleteSaves = false; deleteGameID = id; focus.id = "del.cancel" }
    private func closeDelete() { guard !fromSystemEcho else { return }; deleteGameID = nil; focus.id = returnFocus }
    private func confirmDelete(_ id: String) {
        guard !fromSystemEcho else { return }
        let saves = deleteSaves
        deleteGameID = nil
        settingsOpen = false
        focus.id = nil
        actions.onDeleteGame(id, saves)
    }
    private func openChoice(_ request: ChoiceRequest) {
        guard noteTouch() else { return }
        returnFocus = focus.id
        choice = request
        focus.id = "pick." + request.row.value
    }
    private func closeChoice() {
        guard !fromSystemEcho else { return }
        guard let request = choice else { return }
        choice = nil
        let prefix = request.gameID == ShellSettingsRows.gameID ? ShellSettingsRows.targetPrefix : request.gameID == TouchLayoutEditorView.gameID ? "lay.row." : "set.row."
        focus.id = prefix + request.row.id
    }
    private func pickChoice(_ value: String) {
        guard noteTouch() else { return }
        guard let request = choice else { return }
        if value != request.row.value {
            if request.gameID == TouchLayoutEditorView.gameID { touchLayout?.apply(row: request.row.id, value: value) }
            else if request.gameID == ShellSettingsRows.gameID { ShellSettingsRows.apply(request.row.id, value: value, to: .current) }
            else { actions.onChange(request.gameID, request.row.id, value) }
        }
        closeChoice()
    }
    // The mapping card: the shell's map or a game's, a row's options in place of the rows once one is picked.
    private func padMappingRows(_ id: String) -> [SettingRow] {
        if id == ControllersView.mappingID { return PadMappingRows.global(globalPadMap) }
        return games.first { $0.id == id }.map(PadMappingRows.game) ?? []
    }
    private func padMappingTitle(_ id: String) -> String {
        if id == ControllersView.mappingID { return ShellStrings.text("All games") }
        return games.first { $0.id == id }?.game.title ?? ""
    }
    private func openPadMapping(_ id: String) {
        guard noteTouch() else { return }
        returnFocus = focus.id
        padMapping = PadMappingState(gameID: id)
        focus.id = "map.close"
    }
    private func closePadMapping() { guard !fromSystemEcho else { return }; padMapping = nil; focus.id = returnFocus }
    private func openPadRow(_ row: String) {
        guard noteTouch() else { return }
        padMapping?.row = row
        focus.id = "map.opt." + (padMappingRows(padMapping?.gameID ?? "").first { $0.id == row }?.value ?? "")
    }
    private func closePadRow() {
        guard !fromSystemEcho else { return }
        guard let row = padMapping?.row else { return }
        padMapping?.row = nil
        focus.id = "map.row." + row
    }
    private func pickPadValue(_ row: String, _ value: String) {
        guard noteTouch() else { return }
        guard let id = padMapping?.gameID else { return }
        if id == ControllersView.mappingID { actions.onGlobalPadMapChange(row, value) } else { actions.onChange(id, row, value) }
        closePadRow()
    }
    private func resetPadMapping() {
        guard noteTouch() else { return }
        guard let id = padMapping?.gameID else { return }
        let global = id == ControllersView.mappingID
        if global { actions.onGlobalPadMapReset() } else { actions.onChange(id, PadMappingRows.resetID, "") }
        // Reset is disabled now: the focus goes to the swap, which is back at its default.
        focus.id = "map.swap.toggle"
    }
    private func openButtonTest() { guard noteTouch() else { return }; buttonTestOpen = true; focus.id = "test.close"; actions.onButtonTest(true) }
    private func closeButtonTest() {
        guard buttonTestOpen else { return }
        buttonTestOpen = false
        actions.onButtonTest(false)
        focus.id = "ctl.test"
    }
    private func back() {
        guard !fromSystemEcho else { return }
        if buttonTestOpen { closeButtonTest() }
        else if padMapping?.row != nil { closePadRow() }
        else if padMapping != nil { closePadMapping() }
        else if choice != nil { closeChoice() }
        else if let touchLayout {
            if touchLayout.held { touchLayout.putDown() } else if touchLayout.confirmingExit { touchLayout.confirmingExit = false } else if touchLayout.requestExit() { closeTouchLayout() }
        }
        else if helpGameID != nil { closeHelp() }
        else if deleteGameID != nil { closeDelete() }
        else if controllersOpen { controllersOpen = false; focus.id = settingsOpen ? "set.back" : "lib.controllers" }
        else if shellSettingsOpen { closeShellSettings() }
        else if settingsOpen { closeSettings() }
        else { actions.onBack() }
    }
    private func handle(_ action: ShellInput.Action, from source: InputDevice) {
        gate.handling = true
        defer { gate.handling = false }
        if case .controller = source { gate.controller(action) }
        // Every controller button belongs to the button test while it is open: it closes on B held, touch or Escape.
        if buttonTestOpen, case .controller = source { return }
        if device != source { device = source }
        if touchMode { touchMode = false }
        focus.visible = true
        // A control the editor holds: the D-pad (or the arrow keys) moves it, A or B puts it down.
        if let touchLayout, touchLayout.held, choice == nil {
            switch action {
            case .left, .right, .up, .down: touchLayout.nudge(action); return
            case .activate, .back: touchLayout.putDown(); return
            default: break
            }
        }
        if focus.id == nil || !activeTargets.contains(where: { $0.id == focus.id }) {
            focus.id = defaultFocus
            if action != .activate && action != .back && action != .settings && action != .controllers { return }
        }
        switch action {
        case .activate: activeTargets.first { $0.id == focus.id }?.activate()
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
    /// The dialog or panel on top, in the order of `FocusLayer`.
    private var topLayer: FocusLayer? {
        if buttonTestOpen { return .buttonTest }
        if padMapping != nil { return .padMapping }
        if choice != nil { return .choice }
        if touchLayout != nil { return .touchLayout }
        if controllersOpen { return .controllers }
        if shellSettingsOpen { return .shellSettings }
        if helpGameID != nil { return .help }
        if deleteGameID != nil { return .delete }
        if settingsOpen { return .settings }
        return nil
    }
    private func move(_ action: ShellInput.Action) {
        let candidates = layout.isCoverFlow
            ? activeTargets.filter { !$0.id.hasPrefix("lib.tile.") || $0.id == "lib.tile.\(selected?.id ?? "")" }
            : activeTargets
        focus.id = FocusNavigation.next(from: focus.id, action: action, targets: candidates)
        if let id = focus.id, id.hasPrefix("lib.tile.") { select(String(id.dropFirst("lib.tile.".count))) }
    }
    private var defaultFocus: String? {
        if buttonTestOpen { return "test.close" }
        if let padMapping { return padMapping.row == nil ? "map.close" : "map.back" }
        if let choice { return "pick." + choice.row.value }
        if touchLayout != nil { return activeTargets.contains { $0.id == "lay.done" } ? "lay.done" : "lay.options" }
        if helpGameID != nil { return "help.done" }
        if deleteGameID != nil { return "del.cancel" }
        if controllersOpen { return "ctl.close" }
        if shellSettingsOpen { return "shs.close" }
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
        let hasBanner = game.banner != nil && game.icon == nil
        let bannerHeight = hasBanner ? min(width * 9 / 16, 220) : 0
        // Centred on the artwork like the title in the game detail header, not sitting on its lower edge.
        HStack(alignment: .center, spacing: 22) {
            if !hasBanner { CoverThumbnail(game: game, showsShadow: false).frame(width: 96, height: 96) }
            words(title: game.title).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, max(0, bannerHeight - (hasBanner ? 22 : 0)))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func words(title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {

            Text(title).shellType(ShellType.pageTitle).lineLimit(2)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("detail.title")
            AlertStateChip(state: game.state)
        }
    }
}

/// A square app icon beside metadata, or an uncropped banner when no icon is available.
struct CoverThumbnail: View {
    let game: GameTile
    var showsShadow = true
    var cornerRadius: CGFloat = 18
    var body: some View {
        Group {
            if let icon = game.icon {
                Image(decorative: icon.image, scale: 1).resizable().interpolation(.high).scaledToFit()
            } else if let banner = game.banner {
                Image(decorative: banner.image, scale: 1).resizable().interpolation(.high).scaledToFit()
            } else {
                PlaceholderArt(title: game.title, seed: game.id)
            }
        }
        .saturation(game.state == .playable ? 1 : 0)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.white.opacity(0.14)))
        .shadow(color: showsShadow ? .black.opacity(0.4) : .clear, radius: 16, y: 6)
        .accessibilityHidden(true)
    }
}
/// Request a native side only when the system reports a vertical division; flat iPhone/iPad sheets stay adaptive.
private struct MenuPlacement: ViewModifier {
    var divided: Bool
    var secondary: Bool
    @ViewBuilder func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 27.0, *), divided {
            content.presentationPlacement(secondary ? .trailing : .leading)
        } else { content }
        #else
        content
        #endif
    }
}

private struct LauncherMenuSizing: PresentationSizing {
    var mapping: Bool
    func proposedSize(for root: PresentationSizingRoot, context: PresentationSizingContext) -> ProposedViewSize {
        if mapping { return PagePresentationSizing.page.proposedSize(for: root, context: context) }
        return FormPresentationSizing.form.proposedSize(for: root, context: context)
    }
}
