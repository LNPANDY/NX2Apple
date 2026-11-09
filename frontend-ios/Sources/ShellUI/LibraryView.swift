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
    @State var inputSeen: Int
    @State var selectedID: String?
    @State var settingsOpen: Bool
    /// The settings pane has finished sliding in: its focus ring shows only then, not ahead of it where it will stop.
    @State var settingsArrived: Bool
    /// Counts the opening and closing of the settings pane, so a wait for one opening does not act on a later one.
    @State var settingsOpenings = 0
    @State var shellSettingsOpen: Bool
    @State var controllersOpen: Bool
    /// The game whose How to fix or How to update explanation is open.
    @State var helpGameID: String?
    /// The game whose Delete question is open, and whether its saves go too.
    @State var deleteGameID: String?
    @State var deleteSaves = false
    /// The choice whose option list is open.
    @State var choice: ChoiceRequest?
    /// The button-mapping card, while open.
    @State var padMapping: PadMappingState?
    @State var buttonTestOpen: Bool
    /// The touch controls' layout editor, while open (over the shell settings).
    @State var touchLayout: TouchLayoutEditorModel?
    @State var focus: FocusAppearance
    @State var targets = FocusTargetBuffer()
    @State var settingsPosition = ScrollPosition()
    @State var settingsHeroVisible = true
    @State var settingsHeroHeight: CGFloat = 0
    @State var libraryPosition = ScrollPosition()
    @State var layout: ShellLayout = .column
    @State var divisionAxis: Axis?
    var horizontalDivision: Bool { divisionAxis == .horizontal }
    @State var pendingMenuAction: (() -> Void)?
    @State var retention = PanelRetention()   // a closed panel stays drawn while the sheet slides out (#664)
    @State var returnFocus: String?
    /// The device that sent the last input, for the glyphs.
    @State var device: InputDevice = .controller(.neutral)
    /// True after a touch: the controller hints and the focus ring step back until the next controller or key press.
    @State var touchMode: Bool
    @State var gate = InputGate()
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.dynamicTypeSize) var typeSize

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
    var selected: GameDetail? { games.first { $0.id == selectedID } ?? games.first }

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

    var content: some View {
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

    func visibleTargets(_ values: [FocusTarget]) -> [FocusTarget] {
        values.filter { $0.frame.width > 1 }
    }

    var menuPresented: Bool {
        touchLayout != nil || settingsOpen || controllersOpen || shellSettingsOpen || helpGameID != nil
            || deleteGameID != nil || choice != nil || padMapping != nil || buttonTestOpen
    }

    // Host-owned alerts and sheets must wait until the menu presentation finishes closing.
    var menuActions: ShellActions {
        var routed = guardedActions
        routed.onPlay = { id in handOffMenu { actions.onPlay(id) } }
        routed.onShowLog = { id in handOffMenu { actions.onShowLog(id) } }
        routed.onAppUpdate = { handOffMenu { actions.onAppUpdate() } }
        return routed
    }

    func handOffMenu(_ action: @escaping () -> Void) {
        pendingMenuAction = action
        dismissMenus()
    }

    func runPendingMenuAction() {
        let action = pendingMenuAction
        pendingMenuAction = nil
        retention.reset()
        action?()
    }

    func dismissMenus() {
        closeTouchLayout()
        if buttonTestOpen { closeButtonTest() }
        choice = nil
        padMapping = nil
        helpGameID = nil
        deleteGameID = nil
        let leaving: PanelRetention.Panel? = controllersOpen ? .controllers : shellSettingsOpen ? .shellSettings : nil
        controllersOpen = false
        shellSettingsOpen = false
        settingsOpen = false
        if let leaving { retention.closed(leaving, sheetStaysOpen: false) }
        focus.id = "lib.tile.\(selected?.id ?? "")"
    }

    var menuSheet: some View {
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

    func editorPage(_ model: TouchLayoutEditorModel) -> some View {
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

    var menuContent: some View {
        GeometryReader { geometry in
            ZStack {
                if settingsOpen, let selected {
                    settingsPane(selected, width: geometry.size.width)
                        .accessibilityHidden(controllersOpen || shellSettingsOpen || choice != nil || padMapping != nil || helpGameID != nil || deleteGameID != nil)
                }
                if retention.draws(.controllers, open: controllersOpen) {
                    ControllersView(controllers: controllers, onBack: back, padMap: globalPadMap)
                        .background(ShellPalette.background)
                        .accessibilityHidden(choice != nil || padMapping != nil || buttonTestOpen || retention.isLeaving(.controllers, open: controllersOpen))
                        .allowsHitTesting(!retention.isLeaving(.controllers, open: controllersOpen))
                }
                if retention.draws(.shellSettings, open: shellSettingsOpen) {
                    ShellSettingsView(actions: menuActions, onClose: closeShellSettings)
                        .background(ShellPalette.background)
                        .accessibilityHidden(choice != nil || retention.isLeaving(.shellSettings, open: shellSettingsOpen))
                        .allowsHitTesting(!retention.isLeaving(.shellSettings, open: shellSettingsOpen))
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

    var tabletopSettings: Bool {
        horizontalDivision && settingsOpen && !controllersOpen && !shellSettingsOpen && choice == nil
            && padMapping == nil && !buttonTestOpen && helpGameID == nil && deleteGameID == nil
    }

    var menuTitle: String {
        guard choice == nil, padMapping == nil, !buttonTestOpen, helpGameID == nil, deleteGameID == nil else { return "" }
        if controllersOpen { return ShellStrings.text("Controllers") }
        if shellSettingsOpen { return ShellStrings.text("Settings") }
        return settingsOpen && (horizontalDivision || !settingsHeroVisible) ? selected?.game.title ?? "" : ""
    }

    @ViewBuilder func library(_ selected: GameDetail, layout: ShellLayout, size: CGSize, insets: EdgeInsets) -> some View {
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
    func settingsPane(_ selected: GameDetail, width: CGFloat) -> some View {
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

    enum BarGroup { case close, done, actions }
    struct ToolbarAction: Identifiable {
        let title: String.LocalizationValue
        let symbol: String
        let id: String
        let target: String
        let placement: BarGroup
        let action: () -> Void
    }

    // The navigation container owns these bars so UIKit can share the Duo rail with system UI.
    @ToolbarContentBuilder var launcherToolbar: some ToolbarContent {
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

    @ToolbarContentBuilder var libraryToolbar: some ToolbarContent {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            libraryToolbarItems.axisBehavior(layout.isCoverFlow || layout == .column ? .horizontalOnly : .automatic)
        } else { libraryToolbarItems }
        #else
        libraryToolbarItems
        #endif
    }

    var libraryTitlePlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }

    var landscapeLibrary: Bool {
        layout.isCoverFlow
    }

    @ToolbarContentBuilder var libraryToolbarItems: some ToolbarContent {
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

    func controllerItem(_ item: ToolbarAction) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            toolbarButton(ShellStrings.text(item.title), item.symbol, item.id, item.target, item.action)
                .disabled(menuPresented).accessibilityHidden(menuPresented)
        }
    }

    var toolbarActions: [ToolbarAction] {
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

    var libraryActions: [ToolbarAction] {
        var items: [ToolbarAction] = []
        items.append(.init(title: "Controllers", symbol: controllers.isEmpty ? "gamecontroller" : "gamecontroller.fill", id: "controllers.open", target: "lib.controllers", placement: .actions, action: openControllers))
        items.append(.init(title: "Settings", symbol: "gearshape", id: "shellSettings.open", target: "lib.shellSettings", placement: .actions, action: openShellSettings))
        return items
    }

    var donePlacement: ToolbarItemPlacement { .confirmationAction }

    func toolbarButton(_ label: String, _ symbol: String, _ identifier: String, _ target: String,
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

    var activeTargets: [FocusTarget] {
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

    func words(title: String) -> some View {
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
