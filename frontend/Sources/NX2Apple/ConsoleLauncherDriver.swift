import SwiftUI
import Combine

/// The desktop launcher's side of the Controllers sheet. Only the player-mode setting is real: it reads and writes
/// `ControlLayout.padMerge`, which Play passes to games as DM_PAD_MERGE. Controller discovery, Identify, assignment and
/// Disconnect arrive with the console coordinator, so the list stays empty and those intents do nothing here.
@MainActor final class LauncherControllerDriver: ConsoleDriver {
    @Published var state = ConsoleState()
    private let layout: ControlLayout
    private var subscription: AnyCancellable?

    init(layout: ControlLayout) {
        self.layout = layout
        state.padMerge = layout.padMerge
        subscription = layout.$padMerge.sink { [weak self] merged in self?.state.padMerge = merged }
    }
    func setPadMerge(_ enabled: Bool) { layout.padMerge = enabled }
    func openControllers() { state.openControllers() }
    func back() { state.back() }
    func dismissToast() { state.toast = nil }
    func focus(_ gameID: String) {}
    func play(_ gameID: String) {}
    func openOptions(_ gameID: String) {}
    func setOption(gameID: String, setting: String, value: String) {}
    func identify(controllerID: String) {}
    func disconnect(controllerID: String) {}
    func requestAssignment(controllerID: String) {}
    func requestPlayer(_ player: Int) {}
    func assignPlayer(controllerID: String, player: Int) {}
    func exitToDesktop() {}
    func returnFromGame() {}
}
