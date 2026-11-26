import SwiftUI
#if canImport(PhotosUI)
import PhotosUI
#endif

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
    public let activityLog: ActivityLogSnapshot
    public let controllers: [ControllerInfo]
    public let globalPadMap: PadMap
    public let padMerge: Bool
    /// The controller's state while the button test is open, from the host.
    public let padSnapshot: PadSnapshot?
    public let signingWarning: SigningWarning?
    public let sideloadCertificate: SideloadCertificateSummary?
    public let canOpenHomeButtonSettings: Bool
    public let notice: String?
    public let noticeTitle: String
    public let noticeDismissTitle: String
    public var onDismissNotice: () -> Void
    public var onModalPresentedChange: ((Bool) -> Void)?
    public var onDismissSigningWarning: () -> Void
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
    @State var activityLogOpen: Bool
    @State var controllersOpen: Bool
    /// The game whose How to fix or How to update explanation is open.
    @State var helpGameID: String?
    /// The game whose save-backup restore confirmation is open, and its backup timestamp label.
    @State var restoreBackupGameID: String?
    @State var restoreBackupLabel = ""
    /// Staged save import preview awaiting confirmation inside the menu navigation stack.
    @State var saveImportPrompt: SaveImportPrompt?
    @State var saveImportCommitting = false
    @State var saveFeedbackMessage: String?
    /// The game whose Add to Home Screen guide is open.
    @State var homeScreenGameID: String?
    /// The game whose Cheats center sheet is open.
    @State var cheatsGameID: String?
    /// The game currently picking or cropping a custom 16:9 cover.
    @State var coverPickerGameID: String?
    @State var coverPickerPresented = false
    @State var coverPickerInSheetPresented = false
    @State var coverPickerGeneration: UInt64 = 0
    @State var coverCropSession: CoverCropSession?
    @State var coverCropInSheetSession: CoverCropSession?
    #if canImport(PhotosUI)
    @State var selectedCoverPhotoItem: PhotosPickerItem?
    #endif
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
    /// True while a child modal inside the menu sheet (such as the certificate password sheet) is presented.
    @State var childModalPresented = false
    @State var focus: FocusAppearance
    @State var focusRefresh = 0
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
                globalPadMap: PadMap = PadMap(), padMerge: Bool = false, padSnapshot: PadSnapshot? = nil,
                signingWarning: SigningWarning? = nil, onDismissSigningWarning: @escaping () -> Void = {},
                sideloadCertificate: SideloadCertificateSummary? = nil,
                initialPadMapping: String? = nil, initialButtonTestOpen: Bool = false,
                canOpenHomeButtonSettings: Bool = false,
                notice: String? = nil, noticeTitle: String = "NX2Apple", noticeDismissTitle: String = "OK",
                onDismissNotice: @escaping () -> Void = {},
                onModalPresentedChange: ((Bool) -> Void)? = nil,
                activityLog: ActivityLogSnapshot = .empty, initialActivityLogOpen: Bool = false) {
        ShellPalette.configureNativeAppearance()
        self.games = games
        self.activityLog = activityLog
        self.controllers = controllers
        self.globalPadMap = globalPadMap
        self.padMerge = padMerge
        self.padSnapshot = padSnapshot
        self.signingWarning = signingWarning
        self.sideloadCertificate = sideloadCertificate
        self.canOpenHomeButtonSettings = canOpenHomeButtonSettings
        self.notice = notice
        self.noticeTitle = noticeTitle
        self.noticeDismissTitle = noticeDismissTitle
        self.onDismissNotice = onDismissNotice
        self.onModalPresentedChange = onModalPresentedChange
        self.onDismissSigningWarning = onDismissSigningWarning
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
        _activityLogOpen = State(initialValue: initialActivityLogOpen)
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
        .environment(\.shellFocusRefresh, focusRefresh)
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
                    EmptyLibraryView(onOpenSettings: openShellSettings)
                } else if let selected {
                    library(selected, layout: layout, size: geometry.size, insets: insets)
                        .frame(width: width, height: geometry.size.height)
                        .allowsHitTesting(!menuPresented)
                        .accessibilityHidden(menuPresented)
                }
                if !menuPresented, let signingWarning {
                    SigningWarningBanner(warning: signingWarning, onDismiss: onDismissSigningWarning)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .frame(width: width, alignment: .top)
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
                    #if canImport(PhotosUI)
                    .photosPicker(isPresented: $coverPickerInSheetPresented, selection: $selectedCoverPhotoItem, matching: .images, photoLibrary: .shared())
                    #endif
                    #if os(iOS)
                    .fullScreenCover(item: $coverCropInSheetSession) { session in
                        coverCropModal(session)
                    }
                    #else
                    .sheet(item: $coverCropInSheetSession) { session in
                        coverCropModal(session)
                    }
                    #endif
                    .presentationSizing(LauncherMenuSizing(mapping: padMapping != nil))
                    .presentationDetents(horizontalDivision ? [.medium, .large] : [.large])
                    .presentationCompactAdaptation(divisionAxis == nil ? .automatic : .sheet)
                    .presentationDragIndicator(.visible)
                    .presentationBackground(ShellPalette.background)
                    .presentationContentInteraction(touchLayout != nil ? .scrolls : .automatic)
                    .interactiveDismissDisabled(touchLayout != nil)
                    .modifier(MenuPlacement(divided: divisionAxis == .vertical, secondary: controllersOpen || shellSettingsOpen || activityLogOpen))
                    .alert(
                        Text(verbatim: noticeTitle),
                        isPresented: Binding(
                            get: { menuShowsNotice || (saveFeedbackMessage != nil && !childModalPresented) },
                            set: {
                                if !$0 {
                                    if menuShowsNotice { onDismissNotice() }
                                    saveFeedbackMessage = nil
                                }
                            }
                        )
                    ) {
                        Button(noticeDismissTitle) {
                            if menuShowsNotice { onDismissNotice() }
                            saveFeedbackMessage = nil
                        }
                    } message: {
                        Text(menuShowsNotice ? (notice ?? "") : (saveFeedbackMessage ?? ""))
                    }
                    .modifier(ShellKeyboardNavigation(active: touchLayout == nil && padMapping?.row == nil && coverCropInSheetSession == nil && !childModalPresented && !menuShowsNotice && saveFeedbackMessage == nil) { handle($0, from: .keyboard) })
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
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: activityLogOpen)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: helpGameID)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: restoreBackupGameID)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: saveImportPrompt?.token)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: homeScreenGameID)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: cheatsGameID)
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
        .environment(\.shellAskRestoreBackup, { game, label in openRestoreBackup(game.id, label: label) })
        .environment(\.shellAskSaveImport, actions.supportsSaves ? { prompt in openSaveImport(prompt) } : nil)
        .environment(\.shellShowSaveMessage, { message in showSaveFeedback(message) })
        .environment(\.shellAskHomeScreen, actions.supportsHomeScreen ? { game in openHomeScreen(game.id) } : nil)
        .environment(\.shellOpenCheats, actions.supportsCheats ? { game in openCheats(game.id) } : nil)
        .environment(\.shellAskChangeCover, actions.supportsCustomCover ? { game in openCoverPicker(game.id) } : nil)
        .environment(\.shellAskDelete, { game in openDelete(game.id) })
        #if canImport(PhotosUI)
        .photosPicker(isPresented: $coverPickerPresented, selection: $selectedCoverPhotoItem, matching: .images, photoLibrary: .shared())
        .onChange(of: selectedCoverPhotoItem) { _, item in
            guard let item else { return }
            selectedCoverPhotoItem = nil
            handlePickedCoverPhoto(item)
        }
        #endif
        #if os(iOS)
        .fullScreenCover(item: $coverCropSession) { session in
            coverCropModal(session)
        }
        #else
        .sheet(item: $coverCropSession) { session in
            coverCropModal(session)
        }
        #endif
        .environment(\.shellFocus, focus)
        .environment(\.shellFocusRefresh, focusRefresh)
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
        .modifier(ShellKeyboardNavigation(active: !menuPresented && activeCoverCrop == nil && notice == nil) { handle($0, from: .keyboard) })
        .onAppear {
            focusRefresh &+= 1
            onModalPresentedChange?(libraryModalPresented)
        }
        .onChange(of: libraryModalPresented) { _, presented in
            onModalPresentedChange?(presented)
        }
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
        touchLayout != nil || settingsOpen || controllersOpen || shellSettingsOpen || activityLogOpen || cheatsGameID != nil || helpGameID != nil
            || saveImportPrompt != nil || restoreBackupGameID != nil || homeScreenGameID != nil || deleteGameID != nil || choice != nil || padMapping != nil || buttonTestOpen
    }

    var libraryModalPresented: Bool {
        menuPresented || activeCoverCrop != nil
    }

    var activeNoticeHost: ShellNoticeHost {
        ShellNoticeHost.resolve(
            menuSheetPresented: menuPresented,
            coverCropPresented: activeCoverCrop != nil,
            touchEditorPresented: touchLayout != nil,
            hostSheetPresented: false
        )
    }

    var menuShowsNotice: Bool {
        notice != nil && activeNoticeHost == .menuSheet && !childModalPresented
    }

    var coverCropShowsNotice: Bool {
        notice != nil && activeNoticeHost == .coverCrop
    }

    // Host-owned alerts and sheets must wait until the menu presentation finishes closing.
    var menuActions: ShellActions {
        var routed = guardedActions
        routed.onPlay = { id in handOffMenu { actions.onPlay(id) } }
        routed.onShowLog = { id in handOffMenu { actions.onShowLog(id) } }
        routed.onAppUpdate = { handOffMenu { actions.onAppUpdate() } }
        routed.onRestoreSaveBackup = { id in handOffMenu { actions.onRestoreSaveBackup(id) } }
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
        coverPickerInSheetPresented = false
        coverCropInSheetSession = nil
        helpGameID = nil
        if let prompt = saveImportPrompt {
            saveImportPrompt = nil
            saveImportCommitting = false
            actions.onCancelSaveImport?(prompt.gameID, prompt.token)
        }
        restoreBackupGameID = nil
        homeScreenGameID = nil
        cheatsGameID = nil
        deleteGameID = nil
        let leaving: PanelRetention.Panel? = activityLogOpen ? .activityLog : controllersOpen ? .controllers : shellSettingsOpen ? .shellSettings : nil
        activityLogOpen = false
        controllersOpen = false
        shellSettingsOpen = false
        settingsOpen = false
        if let leaving { retention.closed(leaving, sheetStaysOpen: false) }
        focus.id = "lib.tile.\(selected?.id ?? "")"
    }

    @ViewBuilder func library(_ selected: GameDetail, layout: ShellLayout, size: CGSize, insets: EdgeInsets) -> some View {
        let homeScreenAction: ((String) -> Void)? = actions.supportsHomeScreen ? { openHomeScreen($0) } : nil
        let coverPickerAction: ((String) -> Void)? = actions.supportsCustomCover ? { openCoverPicker($0) } : nil
        let resetCoverAction: ((String) -> Void)? = actions.onResetCustomCover != nil ? { resetCustomCover($0) } : nil
        if layout.isCoverFlow {
            CoverFlowView(games: games, selected: selected, controllers: controllers.count, showsHints: !touchMode, obscured: menuPresented, screenInsets: insets,
                          select: select, primary: { primary($0) }, openSettings: openSettings, openControllers: openControllers,
                          openShellSettings: openShellSettings, openHomeScreen: homeScreenAction,
                          openCoverPicker: coverPickerAction, resetCover: resetCoverAction)
                .equatable()
                .transition(.opacity)
        } else {
            PortraitLibrary(games: games, selected: selected, wide: layout == .grid, size: size, topInset: insets.top, bottomInset: insets.bottom, obscured: menuPresented,
                            controllers: controllers.count, select: select, primary: { primary($0) },
                            openSettings: openSettings, openControllers: openControllers, openShellSettings: openShellSettings,
                            openHomeScreen: homeScreenAction, openCoverPicker: coverPickerAction, resetCover: resetCoverAction,
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
                        if id == "set.back" || id == "set.play" { settingsPosition.scrollTo(edge: .top) }
                        else { proxy.scrollTo(GameDetailView.scrollRowID(for: id), anchor: .center) }
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
    @ToolbarContentBuilder var rootLauncherToolbar: some ToolbarContent {
        let items = rootMenuToolbarActions
        ToolbarItemGroup(placement: .cancellationAction) {
            ForEach(items.filter { $0.placement == .close }) { item in
                toolbarButton(ShellStrings.text(item.title), item.symbol, item.id, item.target, item.action)
            }
        }
        ToolbarItemGroup(placement: donePlacement) {
            ForEach(items.filter { $0.placement == .done }) { item in
                toolbarButton(ShellStrings.text(item.title), item.symbol, item.id, item.target, item.action)
                    .disabled(item.id == "touchLayout.done" && touchLayout?.invalidPlacement == true)
                    .buttonStyle(.borderedProminent).tint(ShellPalette.cream).foregroundStyle(.black)
            }
        }
        if settingsOpen, !controllersOpen, !shellSettingsOpen, !activityLogOpen, let selected {
            ToolbarItem(placement: .primaryAction) {
                toolbarButton(selected.game.state.actionTitle, selected.game.state.actionSymbol, "state.action", "set.play") { primary(selected, fromSettings: true) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderedProminent)
                    .tint(ShellPalette.cream)
                    .foregroundStyle(.black)
                    .disabled(selected.game.state.isJoining)
            }
        }
    }

    @ToolbarContentBuilder func secondaryLauncherToolbar(for route: MenuSecondaryRoute) -> some ToolbarContent {
        let items = secondaryToolbarActions(for: route)
        ToolbarItemGroup(placement: .cancellationAction) {
            ForEach(items.filter { $0.placement == .close }) { item in
                toolbarButton(ShellStrings.text(item.title), item.symbol, item.id, item.target, item.action)
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

        if let item = libraryActions.first(where: { $0.id == "activityLog.open" }) {
            ToolbarItem(placement: .primaryAction) {
                toolbarButton(ShellStrings.text(item.title), item.symbol, item.id, item.target, item.action)
                    .disabled(menuPresented).accessibilityHidden(menuPresented)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
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

    var rootMenuToolbarActions: [ToolbarAction] {
        guard hasRootMenu else { return toolbarActions }
        if activityLogOpen { return [.init(title: "Done", symbol: "checkmark", id: "activityLog.close", target: "act.close", placement: .done, action: closeActivityLog)] }
        if controllersOpen { return [.init(title: "Close controllers", symbol: "xmark", id: "controllers.close", target: "ctl.close", placement: .close, action: back)] }
        if shellSettingsOpen { return [.init(title: "Close", symbol: "xmark", id: "shellSettings.close", target: "shs.close", placement: .close, action: closeShellSettings)] }
        if settingsOpen { return [.init(title: "Close", symbol: "xmark", id: "library.back", target: "set.back", placement: .close, action: closeSettings)] }
        return []
    }

    func secondaryToolbarActions(for route: MenuSecondaryRoute) -> [ToolbarAction] {
        switch route {
        case .buttonTest:
            return [.init(title: "Controllers", symbol: "chevron.left", id: "buttonTest.close", target: "test.close", placement: .close, action: closeButtonTest)]
        case .padMapping:
            return [.init(title: "Back", symbol: "chevron.left", id: "padMapping.close", target: "map.close", placement: .close, action: closePadMapping)]
        case .choice:
            return [.init(title: "Close", symbol: "xmark", id: "choice.close", target: "pick.close", placement: .close, action: closeChoice)]
        case .help:
            return [.init(title: settingsOpen ? "Game settings" : "Close", symbol: settingsOpen ? "chevron.left" : "xmark", id: "help.done", target: "help.done", placement: .close, action: closeHelp)]
        case .cheats:
            return [.init(title: settingsOpen ? "Game settings" : "Close", symbol: settingsOpen ? "chevron.left" : "xmark", id: "cheats.close", target: "cht.close", placement: .close, action: closeCheats)]
        case .homeScreen:
            return [.init(title: settingsOpen ? "Game settings" : "Close", symbol: settingsOpen ? "chevron.left" : "xmark", id: "homeScreen.close", target: "hsc.close", placement: .close, action: closeHomeScreen)]
        case .restoreBackup, .delete, .saveImport:
            return []
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
        if saveImportPrompt != nil { return [] }
        if cheatsGameID != nil { return [.init(title: settingsOpen ? "Game settings" : "Close", symbol: settingsOpen ? "chevron.left" : "xmark", id: "cheats.close", target: "cht.close", placement: .close, action: closeCheats)] }
        if homeScreenGameID != nil { return [.init(title: settingsOpen ? "Game settings" : "Close", symbol: settingsOpen ? "chevron.left" : "xmark", id: "homeScreen.close", target: "hsc.close", placement: .close, action: closeHomeScreen)] }
        if restoreBackupGameID != nil { return [] }
        if deleteGameID != nil { return [] }
        if activityLogOpen { return [.init(title: "Done", symbol: "checkmark", id: "activityLog.close", target: "act.close", placement: .done, action: closeActivityLog)] }
        if controllersOpen { return [.init(title: "Close controllers", symbol: "xmark", id: "controllers.close", target: "ctl.close", placement: .close, action: back)] }
        if shellSettingsOpen { return [.init(title: "Close", symbol: "xmark", id: "shellSettings.close", target: "shs.close", placement: .close, action: closeShellSettings)] }
        if settingsOpen { return [.init(title: "Close", symbol: "xmark", id: "library.back", target: "set.back", placement: .close, action: closeSettings)] }
        return libraryActions
    }

    var libraryActions: [ToolbarAction] {
        var items: [ToolbarAction] = []
        items.append(.init(title: "Activity log", symbol: "chart.bar.xaxis", id: "activityLog.open", target: "lib.activityLog", placement: .actions, action: openActivityLog))
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
            // Toolbar content is separately hosted: register its actual geometry with an instance owner so an outgoing
            // transition view disappearing never clears a live toolbar target sharing the same key.
            .modifier(ToolbarFocusRegistration(targets: targets, target: target, action: action))
    }

    var activeTargets: [FocusTarget] {
        let prefix: String
        if activeCoverCrop != nil { prefix = "crp." }
        else if buttonTestOpen { prefix = "test." }
        else if padMapping != nil { prefix = "map." }
        else if choice != nil { prefix = "pick." }
        else if touchLayout != nil { prefix = "lay." }
        else if cheatsGameID != nil { prefix = "cht." }
        else if helpGameID != nil { prefix = "help." }
        else if saveImportPrompt != nil { prefix = "svi." }
        else if restoreBackupGameID != nil { prefix = "rst." }
        else if homeScreenGameID != nil { prefix = "hsc." }
        else if deleteGameID != nil { prefix = "del." }
        else if activityLogOpen { prefix = "act." }
        else if controllersOpen { prefix = "ctl." }
        else if shellSettingsOpen { prefix = "shs." }
        else if settingsOpen { prefix = "set." }
        else { prefix = "lib." }
        return targets.active(prefix: prefix, toolbarIDs: Set(toolbarActions.map(\.target)))
    }
}

private struct ToolbarFocusRegistration: ViewModifier {
    let targets: FocusTargetBuffer
    let target: String
    let action: () -> Void
    @State private var ownerID = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                targets.registerToolbar(FocusTarget(id: target, frame: frame, activate: action), owner: ownerID)
            }
            .onDisappear {
                targets.unregisterToolbar(id: target, owner: ownerID)
            }
    }
}
