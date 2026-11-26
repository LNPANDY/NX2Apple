import SwiftUI

extension LibraryView {
    enum MenuSecondaryRoute: Hashable {
        case padMapping(String)
        case buttonTest
        case choice(String)
        case help(String)
        case saveImport(String)
        case cheats(String)
        case restoreBackup(String)
        case homeScreen(String)
        case delete(String)
    }

    var hasRootMenu: Bool {
        settingsOpen || controllersOpen || shellSettingsOpen || activityLogOpen
    }

    var secondaryMenuRoute: MenuSecondaryRoute? {
        guard touchLayout == nil else { return nil }
        if let mapping = padMapping { return .padMapping(mapping.gameID) }
        if buttonTestOpen { return .buttonTest }
        guard hasRootMenu else { return nil }
        if let choice { return .choice("\(choice.gameID):\(choice.row.id)") }
        if let id = helpGameID { return .help(id) }
        if let prompt = saveImportPrompt { return .saveImport(prompt.token) }
        if let id = cheatsGameID { return .cheats(id) }
        if let id = restoreBackupGameID { return .restoreBackup(id) }
        if let id = homeScreenGameID { return .homeScreen(id) }
        if let id = deleteGameID { return .delete(id) }
        return nil
    }

    var secondaryMenuRouteBinding: Binding<MenuSecondaryRoute?> {
        Binding(
            get: { secondaryMenuRoute },
            set: { next in
                if next == nil {
                    clearSecondaryMenuRouteFromNavigationPop()
                }
            }
        )
    }

    var menuSheet: some View {
        NavigationStack {
            menuContent.toolbar { if touchLayout == nil { rootLauncherToolbar } }
                .accessibilityHidden(touchLayout != nil)
                .navigationDestination(item: secondaryMenuRouteBinding) { route in
                    secondaryDestinationView(for: route)
                }
        }
        .background {
            if settingsOpen, let selected { CoverFlowBackdrop(game: selected.game) }
        }
        #if os(iOS)
        .toolbarBackground(settingsOpen ? .hidden : .automatic, for: .navigationBar)
        #endif
    }

    @ViewBuilder func secondaryDestinationView(for route: MenuSecondaryRoute) -> some View {
        switch route {
        case .padMapping:
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
                    .toolbar { secondaryLauncherToolbar(for: route) }
                    .modifier(SecondaryEdgeSwipeBackModifier {
                        if padMapping?.row != nil { closePadRow() } else { clearSecondaryMenuRouteFromNavigationPop() }
                    })
                    .onPreferenceChange(FocusTargets.self) { if padMapping?.row == nil { targets.values = visibleTargets($0) } }
            }
        case .buttonTest:
            ButtonTestView(snapshot: padSnapshot, close: closeButtonTest)
                .navigationTitle(ShellStrings.text("Button test"))
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .navigationBarBackButtonHidden()
                .toolbar { secondaryLauncherToolbar(for: route) }
                .modifier(SecondaryEdgeSwipeBackModifier { clearSecondaryMenuRouteFromNavigationPop() })
                .onPreferenceChange(FocusTargets.self) { targets.values = visibleTargets($0) }
        case .choice:
            if let choice {
                ChoicePickerView(request: choice, pick: pickChoice, close: closeChoice)
                    .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ShellPalette.background)
                    .navigationTitle("")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .navigationBarBackButtonHidden()
                    .toolbar { secondaryLauncherToolbar(for: route) }
                    .modifier(SecondaryEdgeSwipeBackModifier { clearSecondaryMenuRouteFromNavigationPop() })
                    .onPreferenceChange(FocusTargets.self) { targets.values = visibleTargets($0) }
            }
        case .help(let id):
            if let game = games.first(where: { $0.id == id })?.game {
                ScrollView { StateHelpView(game: game, actions: menuActions, onClose: closeHelp).padding(24) }
                    .background(ShellPalette.background)
                    .navigationTitle("")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .navigationBarBackButtonHidden()
                    .toolbar { secondaryLauncherToolbar(for: route) }
                    .modifier(SecondaryEdgeSwipeBackModifier { clearSecondaryMenuRouteFromNavigationPop() })
                    .onPreferenceChange(FocusTargets.self) { targets.values = visibleTargets($0) }
            }
        case .saveImport:
            if let prompt = saveImportPrompt {
                ScrollView {
                    SaveImportConfirmView(
                        prompt: prompt,
                        committing: saveImportCommitting,
                        confirm: { confirmSaveImport($0) },
                        cancel: closeSaveImport
                    )
                }
                .background(ShellPalette.background)
                .navigationTitle("")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .navigationBarBackButtonHidden()
                .interactiveDismissDisabled(saveImportCommitting)
                .toolbar { secondaryLauncherToolbar(for: route) }
                .modifier(SecondaryEdgeSwipeBackModifier {
                    if !saveImportCommitting { clearSecondaryMenuRouteFromNavigationPop() }
                })
                .onPreferenceChange(FocusTargets.self) { targets.values = visibleTargets($0) }
            }
        case .cheats(let id):
            if let detail = games.first(where: { $0.id == id }) {
                cheatsSheetContent(id: id, detail: detail)
                    .navigationTitle(ShellStrings.text("Cheats"))
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .navigationBarBackButtonHidden()
                    .toolbar { secondaryLauncherToolbar(for: route) }
                    .modifier(SecondaryEdgeSwipeBackModifier { clearSecondaryMenuRouteFromNavigationPop() })
                    .onPreferenceChange(FocusTargets.self) { targets.values = visibleTargets($0) }
            }
        case .restoreBackup(let id):
            if let game = games.first(where: { $0.id == id })?.game {
                ScrollView {
                    RestoreSaveBackupView(game: game, backup: restoreBackupLabel,
                                          restore: { confirmRestoreBackup(id) }, cancel: closeRestoreBackup)
                }
                .background(ShellPalette.background)
                .navigationTitle("")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .navigationBarBackButtonHidden()
                .toolbar { secondaryLauncherToolbar(for: route) }
                .modifier(SecondaryEdgeSwipeBackModifier { clearSecondaryMenuRouteFromNavigationPop() })
                .onPreferenceChange(FocusTargets.self) { targets.values = visibleTargets($0) }
            }
        case .homeScreen(let id):
            if let game = games.first(where: { $0.id == id })?.game {
                homeScreenScroll(id: id, game: game)
                    .navigationTitle("")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .navigationBarBackButtonHidden()
                    .toolbar { secondaryLauncherToolbar(for: route) }
                    .modifier(SecondaryEdgeSwipeBackModifier { clearSecondaryMenuRouteFromNavigationPop() })
                    .onPreferenceChange(FocusTargets.self) { targets.values = visibleTargets($0) }
            }
        case .delete(let id):
            if let game = games.first(where: { $0.id == id })?.game {
                ScrollView { DeleteGameView(game: game, saves: $deleteSaves, delete: { confirmDelete(id) }, cancel: closeDelete) }
                    .background(ShellPalette.background)
                    .navigationTitle("")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .navigationBarBackButtonHidden()
                    .toolbar { secondaryLauncherToolbar(for: route) }
                    .modifier(SecondaryEdgeSwipeBackModifier { clearSecondaryMenuRouteFromNavigationPop() })
                    .onPreferenceChange(FocusTargets.self) { targets.values = visibleTargets($0) }
            }
        }
    }

    func homeScreenScroll(id: String, game: GameTile) -> some View {
        ScrollView {
            AddToHomeScreenView(
                game: game,
                supportsFloatingGuide: guardedActions.onAddToHomeScreenWithGuide != nil,
                prepareFloatingGuide: { guardedActions.onPrepareHomeScreenGuide?(id) },
                cancelPreparedFloatingGuide: { guardedActions.onCancelPreparedHomeScreenGuide?() },
                saveAndOpen: { floatingGuide in
                    if let withGuide = guardedActions.onAddToHomeScreenWithGuide {
                        return await withGuide(id, floatingGuide)
                    }
                    return await guardedActions.onAddToHomeScreen?(id) ?? false
                },
                copyURL: { guardedActions.onCopyShortcutURL?(id) },
                close: closeHomeScreen
            )
        }
        .background(ShellPalette.background)
    }

    func editorPage(_ model: TouchLayoutEditorModel) -> some View {
        TouchLayoutEditorView(model: model, close: confirmTouchLayout, cancel: closeTouchLayout)
            #if os(iOS)
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
            #endif
            .coordinateSpace(name: "shell")
            .environment(\.shellNativeBars, true)
            .environment(\.shellFocus, focus)
            .environment(\.shellFocusRefresh, focusRefresh)
            .environment(\.shellIgnoresPress, { [gate] in gate.isSystemEcho })
            .onPreferenceChange(FocusTargets.self) { targets.values = visibleTargets($0) }
            .tint(ShellPalette.cream)
            .preferredColorScheme(.dark)
            .interactiveDismissDisabled()
            .modifier(ShellKeyboardNavigation(active: true) { handle($0, from: .keyboard) })
    }

    func cheatsSheetContent(id: String, detail: GameDetail) -> some View {
        let placeholder = GameCheatsSnapshot(
            gameID: id,
            gameTitle: detail.game.title,
            buildID: detail.cheatsSummary?.buildID
        )
        return CheatsSheetView(snapshot: placeholder, actions: guardedActions, onClose: closeCheats)
            .id(id)
            .background(ShellPalette.background)
    }

    var menuContent: some View {
        GeometryReader { geometry in
            ZStack {
                if settingsOpen, let selected {
                    settingsPane(selected, width: geometry.size.width)
                        .accessibilityHidden(controllersOpen || shellSettingsOpen || activityLogOpen || cheatsGameID != nil || choice != nil || padMapping != nil || helpGameID != nil || saveImportPrompt != nil || restoreBackupGameID != nil || homeScreenGameID != nil || deleteGameID != nil)
                }
                if retention.draws(.controllers, open: controllersOpen) {
                    ControllersView(controllers: controllers, onBack: back, padMap: globalPadMap,
                                    padMerge: padMerge, onPadMergeChange: menuActions.onPadMergeChange,
                                    canOpenHomeButtonSettings: canOpenHomeButtonSettings,
                                    onOpenHomeButtonSettings: menuActions.onOpenHomeButtonSettings)
                        .background(ShellPalette.background)
                        .accessibilityHidden(choice != nil || padMapping != nil || buttonTestOpen || retention.isLeaving(.controllers, open: controllersOpen))
                        .allowsHitTesting(!retention.isLeaving(.controllers, open: controllersOpen))
                }
                if retention.draws(.shellSettings, open: shellSettingsOpen) {
                    ShellSettingsView(actions: menuActions, sideloadCertificate: sideloadCertificate,
                                      onOpenActivityLog: { shellSettingsOpen = false; openActivityLog() }, onClose: closeShellSettings,
                                      onModalPresentedChange: { childModalPresented = $0 })
                        .background(ShellPalette.background)
                        .accessibilityHidden(activityLogOpen || choice != nil || retention.isLeaving(.shellSettings, open: shellSettingsOpen))
                        .allowsHitTesting(!retention.isLeaving(.shellSettings, open: shellSettingsOpen))
                }
                if retention.draws(.activityLog, open: activityLogOpen) {
                    ActivityLogView(snapshot: activityLog, onSelectGame: selectFromActivityLog, onClose: closeActivityLog)
                        .background(ShellPalette.background)
                        .accessibilityHidden(retention.isLeaving(.activityLog, open: activityLogOpen))
                        .allowsHitTesting(!retention.isLeaving(.activityLog, open: activityLogOpen))
                }
                if !hasRootMenu, let id = helpGameID, let game = games.first(where: { $0.id == id })?.game {
                    ScrollView { StateHelpView(game: game, actions: menuActions, onClose: closeHelp).padding(24) }
                        .background(ShellPalette.background)
                }
                if !hasRootMenu, let id = cheatsGameID, let detail = games.first(where: { $0.id == id }) {
                    cheatsSheetContent(id: id, detail: detail)
                }
                if !hasRootMenu, let prompt = saveImportPrompt {
                    ScrollView {
                        SaveImportConfirmView(
                            prompt: prompt,
                            committing: saveImportCommitting,
                            confirm: { confirmSaveImport($0) },
                            cancel: closeSaveImport
                        )
                    }
                    .background(ShellPalette.background)
                }
                if !hasRootMenu, let id = restoreBackupGameID, let game = games.first(where: { $0.id == id })?.game {
                    ScrollView {
                        RestoreSaveBackupView(game: game, backup: restoreBackupLabel,
                                              restore: { confirmRestoreBackup(id) }, cancel: closeRestoreBackup)
                    }
                    .background(ShellPalette.background)
                }
                if !hasRootMenu, let id = homeScreenGameID, let game = games.first(where: { $0.id == id })?.game {
                    homeScreenScroll(id: id, game: game)
                }
                if !hasRootMenu, let id = deleteGameID, let game = games.first(where: { $0.id == id })?.game {
                    ScrollView { DeleteGameView(game: game, saves: $deleteSaves, delete: { confirmDelete(id) }, cancel: closeDelete) }
                        .background(ShellPalette.background)
                }
                if !hasRootMenu, let choice {
                    ChoicePickerView(request: choice, pick: pickChoice, close: closeChoice)
                        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(ShellPalette.background)
                }
            }
            .onPreferenceChange(FocusTargets.self) { all in
                if touchLayout == nil, secondaryMenuRoute == nil { targets.values = visibleTargets(all).filter { $0.frame.width > 1 } }
            }
        }
        .navigationTitle(menuTitle)
        .navigationSubtitle(tabletopSettings ? ShellStrings.text("Game settings").uppercased() : "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    var tabletopSettings: Bool {
        horizontalDivision && settingsOpen && !controllersOpen && !shellSettingsOpen && !activityLogOpen && cheatsGameID == nil && choice == nil
            && padMapping == nil && !buttonTestOpen && helpGameID == nil && saveImportPrompt == nil && restoreBackupGameID == nil && homeScreenGameID == nil && deleteGameID == nil
    }

    var menuTitle: String {
        guard choice == nil, padMapping == nil, !buttonTestOpen, helpGameID == nil, saveImportPrompt == nil, restoreBackupGameID == nil, homeScreenGameID == nil, deleteGameID == nil else { return "" }
        if !hasRootMenu, cheatsGameID != nil { return ShellStrings.text("Cheats") }
        if cheatsGameID != nil { return "" }
        if activityLogOpen { return ShellStrings.text("Activity log") }
        if controllersOpen { return ShellStrings.text("Controllers") }
        if shellSettingsOpen { return ShellStrings.text("Settings") }
        return settingsOpen && (horizontalDivision || !settingsHeroVisible) ? selected?.game.title ?? "" : ""
    }
}

/// Restores left-edge swipe-to-pop on pushed secondary routes that keep custom toolbar buttons for controller focus
/// and accessibility IDs, using `@GestureState` so interrupted drags spring back cleanly without stale offsets.
private struct SecondaryEdgeSwipeBackModifier: ViewModifier {
    let onPop: () -> Void
    @GestureState private var dragOffset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .offset(x: dragOffset)
            .animation(reduceMotion ? nil : .interactiveSpring(response: 0.24, dampingFraction: 0.88), value: dragOffset)
            .simultaneousGesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .local)
                    .updating($dragOffset) { value, state, _ in
                        guard value.startLocation.x <= 32,
                              value.translation.width > 0,
                              value.translation.width > abs(value.translation.height) * 1.4 else {
                            return
                        }
                        state = value.translation.width
                    }
                    .onEnded { value in
                        guard value.startLocation.x <= 32,
                              value.translation.width > abs(value.translation.height) * 1.4 else {
                            return
                        }
                        if value.translation.width > 72 || value.predictedEndTranslation.width > 110 {
                            onPop()
                        }
                    }
            )
    }
}
