import SwiftUI

/// The library's actions, panels opening and closing, and the focus rules.
extension LibraryView {
    // MARK: Actions and focus

    /// The system's echo of a controller button (see `SystemEchoWindow`), for the actions that close or go back: they
    /// do not change the touch mode, but the echo must not close the panel the button just opened.
    var fromSystemEcho: Bool { gate.isSystemEcho }
    /// `actions` for the views that change settings or data themselves (a switch, a row, a button in the settings): the
    /// system's echo of a controller button changes nothing through them.
    var guardedActions: ShellActions {
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
    func noteTouch() -> Bool {
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
    var libraryPressAllowed: Bool { FocusLayer.libraryTakesPress(fromShell: gate.handling, under: topLayer) }
    func primary(_ detail: GameDetail, fromSettings: Bool = false) {
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
    func select(_ id: String) {
        guard libraryPressAllowed, noteTouch() else { return }
        guard id != selectedID else { return }
        selectedID = id
        actions.onSelect(id)
        settingsHeroVisible = true
        settingsPosition.scrollTo(edge: .top)
    }
    func openSettings() {
        guard !shellSettingsOpen else { return }
        guard noteTouch() else { return }
        controllersOpen = false
        settingsOpen = true
        focus.id = "set.back"
    }
    func closeSettings() {
        guard !fromSystemEcho else { return }
        settingsOpen = false
        focus.id = "lib.settings"
    }
    func openControllers() { guard !shellSettingsOpen else { return }; guard noteTouch() else { return }; retention.reset(); controllersOpen = true; focus.id = "ctl.close" }
    func openShellSettings() { guard noteTouch() else { return }; retention.reset(); shellSettingsOpen = true; focus.id = "shs.close" }
    func closeShellSettings() { guard !fromSystemEcho else { return }; shellSettingsOpen = false; retention.closed(.shellSettings, sheetStaysOpen: menuPresented); focus.id = "lib.shellSettings" }
    func openTouchLayout(_ window: CGSize, _ insets: EdgeInsets) {
        guard noteTouch() else { return }
        touchLayout = TouchLayoutEditorModel.forDevice(window: window, insets: insets)
        focus.id = "lay.options"
    }
    func closeTouchLayout() { guard !fromSystemEcho else { return }; touchLayout = nil; focus.id = "shs.arrange" }
    func confirmTouchLayout() {
        guard !fromSystemEcho, let touchLayout, !touchLayout.invalidPlacement else { return }
        touchLayout.commit()
        closeTouchLayout()
    }
    func openHelp(_ id: String) { guard !fromSystemEcho else { return }; returnFocus = focus.id; helpGameID = id; focus.id = "help.done" }
    func closeHelp() { guard !fromSystemEcho else { return }; helpGameID = nil; focus.id = returnFocus }
    /// The question starts on Cancel, with the saves kept.
    func openDelete(_ id: String) { guard noteTouch() else { return }; returnFocus = focus.id; deleteSaves = false; deleteGameID = id; focus.id = "del.cancel" }
    func closeDelete() { guard !fromSystemEcho else { return }; deleteGameID = nil; focus.id = returnFocus }
    func confirmDelete(_ id: String) {
        guard !fromSystemEcho else { return }
        let saves = deleteSaves
        deleteGameID = nil
        settingsOpen = false
        focus.id = nil
        actions.onDeleteGame(id, saves)
    }
    func openChoice(_ request: ChoiceRequest) {
        guard noteTouch() else { return }
        returnFocus = focus.id
        choice = request
        focus.id = "pick." + request.row.value
    }
    func closeChoice() {
        guard !fromSystemEcho else { return }
        guard let request = choice else { return }
        choice = nil
        let prefix = request.gameID == ShellSettingsRows.gameID ? ShellSettingsRows.targetPrefix : request.gameID == TouchLayoutEditorView.gameID ? "lay.row." : "set.row."
        focus.id = prefix + request.row.id
    }
    func pickChoice(_ value: String) {
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
    func padMappingRows(_ id: String) -> [SettingRow] {
        if id == ControllersView.mappingID { return PadMappingRows.global(globalPadMap) }
        return games.first { $0.id == id }.map(PadMappingRows.game) ?? []
    }
    func padMappingTitle(_ id: String) -> String {
        if id == ControllersView.mappingID { return ShellStrings.text("All games") }
        return games.first { $0.id == id }?.game.title ?? ""
    }
    func openPadMapping(_ id: String) {
        guard noteTouch() else { return }
        returnFocus = focus.id
        padMapping = PadMappingState(gameID: id)
        focus.id = "map.close"
    }
    func closePadMapping() { guard !fromSystemEcho else { return }; padMapping = nil; focus.id = returnFocus }
    func openPadRow(_ row: String) {
        guard noteTouch() else { return }
        padMapping?.row = row
        focus.id = "map.opt." + (padMappingRows(padMapping?.gameID ?? "").first { $0.id == row }?.value ?? "")
    }
    func closePadRow() {
        guard !fromSystemEcho else { return }
        guard let row = padMapping?.row else { return }
        padMapping?.row = nil
        focus.id = "map.row." + row
    }
    func pickPadValue(_ row: String, _ value: String) {
        guard noteTouch() else { return }
        guard let id = padMapping?.gameID else { return }
        if id == ControllersView.mappingID { actions.onGlobalPadMapChange(row, value) } else { actions.onChange(id, row, value) }
        closePadRow()
    }
    func resetPadMapping() {
        guard noteTouch() else { return }
        guard let id = padMapping?.gameID else { return }
        let global = id == ControllersView.mappingID
        if global { actions.onGlobalPadMapReset() } else { actions.onChange(id, PadMappingRows.resetID, "") }
        // Reset is disabled now: the focus goes to the swap, which is back at its default.
        focus.id = "map.swap.toggle"
    }
    func openButtonTest() { guard noteTouch() else { return }; buttonTestOpen = true; focus.id = "test.close"; actions.onButtonTest(true) }
    func closeButtonTest() {
        guard buttonTestOpen else { return }
        buttonTestOpen = false
        actions.onButtonTest(false)
        focus.id = "ctl.test"
    }
    func back() {
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
        else if controllersOpen { controllersOpen = false; retention.closed(.controllers, sheetStaysOpen: menuPresented); focus.id = settingsOpen ? "set.back" : "lib.controllers" }
        else if shellSettingsOpen { closeShellSettings() }
        else if settingsOpen { closeSettings() }
        else { actions.onBack() }
    }
    func handle(_ action: ShellInput.Action, from source: InputDevice) {
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
    var topLayer: FocusLayer? {
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
    func move(_ action: ShellInput.Action) {
        let candidates = layout.isCoverFlow
            ? activeTargets.filter { !$0.id.hasPrefix("lib.tile.") || $0.id == "lib.tile.\(selected?.id ?? "")" }
            : activeTargets
        focus.id = FocusNavigation.next(from: focus.id, action: action, targets: candidates)
        if let id = focus.id, id.hasPrefix("lib.tile.") { select(String(id.dropFirst("lib.tile.".count))) }
    }
    var defaultFocus: String? {
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
