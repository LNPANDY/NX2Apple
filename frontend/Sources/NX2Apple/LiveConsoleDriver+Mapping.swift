import Foundation
import NXCore

/// The console's menu and its button mappings. The mapping of all games is the Controls page's controller layout (`ControlLayout`):
/// the console changes the same layout the desktop's Controls page does, which Play passes to every game as DM_PAD_MAP. A game's own
/// mapping is the one the desktop's mapping sheet for that game edits (GameControllerMappingView): DM_PAD_MAP in the game's saved
/// choices, which a build that reads them (DMControllerMappings) uses instead of the launcher's.
extension LiveConsoleDriver {
    func back() {
        if cloudGate.isActive { cloudGate.cancel(); return }   // the cloud save's wait before a start (#957)
        let wasGame = state.mappingGameID != nil
        state.back()
        if wasGame, state.mappingGameID == nil { refreshPadLayout() }   // the sheets below show the mapping of all games again
    }
    func openMenu() { state.openMenu() }
    /// The switches are read again first: the desktop's Settings may have changed them since.
    func openLibrary() { refreshDesktop(); state.openLibrary() }
    func openSettings() { refreshDesktop(); state.openSettings() }
    func openLanguage() { state.openLanguage() }
    /// Kept in the launcher's defaults, read again with the layout (refreshPadLayout), so it lasts from one console session to the next.
    static let menuSwapKey = "console.menuSwapAB"
    /// On the mapping page it waits for Save (finishMapping), so the menus keep their buttons while it is open.
    func setMenuSwapAB(_ on: Bool) {
        if state.mappingOrigin != nil { state.pendingMenuSwapAB = on; return }
        UserDefaults.standard.set(on, forKey: Self.menuSwapKey)
        state.menuSwapAB = on
    }
    func finishMapping(save: Bool) {
        guard state.presentedSheet == .confirmMapping else { return }
        if save {
            if let swap = state.pendingMenuSwapAB { UserDefaults.standard.set(swap, forKey: Self.menuSwapKey); state.menuSwapAB = swap }
        } else if let undo = state.mappingUndo {
            if let game = mappedGame { game.controllerPreferences().setMap("DM_PAD_MAP", value: undo.gameMap) }
            else { controls.restorePad(mode: undo.mode, pad: undo.pad) }
        }
        state.endMappingEdit()
        refreshPadLayout()
    }
    func confirmExit() { state.confirmExit() }
    /// The page opens once the rows are read: each game's log and cloud folder, off the main thread, nothing written.
    /// Read off the main thread; the page opens only if nothing was opened or closed meanwhile (B before the rows are read stays back).
    func openCloudSaves() {
        let inputs = ConsoleCloudSaves.inputs(library: library)
        let from = state.sheets
        DispatchQueue.global(qos: .userInitiated).async {
            let rows = ConsoleCloudSaves.rows(inputs)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.state.sheets == from else { return }
                    self.state.openCloudSaves(rows)
                }
            }
        }
    }
    func openMapping() {
        guard state.presentedSheet != .mapping else { return }
        state.openMapping(); refreshPadLayout()
        state.beginMappingEdit(undo: ConsoleMappingUndo(mode: controls.padMode, pad: controls.pad))
    }
    /// The first time, the game's mapping starts as a copy of all games' (as on the desktop), then it is its own.
    func openGameMapping(_ gameID: String) {
        guard let game = libraryGame(gameID), state.games.first(where: { $0.id == gameID })?.mapsButtons == true else { return }
        _ = game.controllerPreferences().launchControls(controls.environment)
        state.openMapping(game: gameID)
        refreshPadLayout()
        let preferences = game.controllerPreferences()
        preferences.refresh()
        state.beginMappingEdit(undo: ConsoleMappingUndo(gameMap: preferences.map("DM_PAD_MAP")))
    }
    func openGamePad(_ gameID: String) { state.openGamePad(gameID) }
    func openMappingRow(_ button: String?) { state.openMappingRow(button) }
    /// A game's mapping has no layouts: only all games' does.
    func setPadMode(_ mode: PadMode) {
        guard state.mappingGameID == nil else { return }
        controls.setPadMode(mode)
    }
    func setPadSends(button: String, to output: String) {
        guard ConsolePadLayout.buttons.contains(button), output == "none" || ConsolePadLayout.buttons.contains(output) else { return }
        guard let game = mappedGame else { controls.setSends(button, output); return }
        var map = state.padLayout.sends
        map[button] = output == button ? nil : output
        let value = ConsolePadLayout.buttons.compactMap { b in map[b].map { "\(b)=\($0)" } }.joined(separator: ",")
        game.controllerPreferences().setMap("DM_PAD_MAP", value: value.isEmpty ? nil : value)
        refreshPadLayout()
    }
    /// All games: back to the standard layout. A game: the same as all games again.
    func resetPadMapping() {
        guard let game = mappedGame else { controls.resetController(); return }
        game.controllerPreferences().setMap("DM_PAD_MAP", value: controls.environment["DM_PAD_MAP"])
        refreshPadLayout()
    }

    private var mappedGame: LibraryGame? { state.mappingGameID.flatMap(libraryGame) }

    /// What all games' buttons send now (Auto's follow the controller connected now).
    private var globalSends: [String: String] {
        Dictionary(uniqueKeysWithValues: ConsolePadLayout.buttons.compactMap { b -> (String, String)? in
            let to = controls.sends(b)
            return to == b ? nil : (b, to)
        })
    }

    /// The mapping the sheet shows: a game's own while one is open, else all games'. A controller change reads it again (Auto).
    func refreshPadLayout() {
        let layout: ConsolePadLayout
        if let game = mappedGame {
            let preferences = game.controllerPreferences()
            preferences.refresh()
            layout = ConsolePadLayout(mode: .custom, gameTitle: game.name, baseline: globalSends, sends: ControllerMap.pad(preferences.map("DM_PAD_MAP")))
        } else {
            layout = ConsolePadLayout(mode: controls.padMode, sends: globalSends, custom: controls.pad)
        }
        if layout != state.padLayout { state.padLayout = layout }
        let swap = UserDefaults.standard.bool(forKey: Self.menuSwapKey)
        if swap != state.menuSwapAB { state.menuSwapAB = swap }
    }
}
