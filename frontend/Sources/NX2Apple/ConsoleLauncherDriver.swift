import SwiftUI
import Combine

/// The desktop launcher's side of the Controllers sheet. Only the player-mode setting is real: it reads and writes
/// `ControlLayout.padMerge`, which Play passes to games as DM_PAD_MERGE. Controller discovery, Identify, assignment and
/// Disconnect arrive with the console coordinator, so the list stays empty and those intents do nothing here.
@MainActor final class LauncherControllerDriver: ConsoleDriver {
    @Published var state = ConsoleState()
    private let layout: ControlLayout
    private var cancellables = Set<AnyCancellable>()

    init(layout: ControlLayout) {
        self.layout = layout
        state.padMerge = layout.padMerge
        layout.$padMerge.sink { [weak self] merged in self?.state.padMerge = merged }.store(in: &cancellables)
    }
    func setPadMerge(_ enabled: Bool) { layout.padMerge = enabled }
    func openControllers() { state.openControllers() }
    func back() { if !state.sheets.isEmpty { state.back() } }   // the desktop has no console mode to leave
    func dismissToast() { state.toast = nil }
    func focus(_ gameID: String) {}
    func play(_ gameID: String) {}
    func openOptions(_ gameID: String) {}
    func setOption(gameID: String, setting: String, value: String) {}
    func identify(controllerID: String) {}
    func disconnect(controllerID: String) {}
    func openMenu() {}
    func openMapping() {}
    func openMappingRow(_ button: String?) {}
    func requestAssignment(controllerID: String) {}
    func requestPlayer(_ player: Int) {}
    func assignPlayer(controllerID: String, player: Int) {}
    func exitToDesktop() {}
    func returnFromGame() {}
}
