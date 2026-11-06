import Foundation
import Combine
import NXCore

@MainActor package final class ControllerMappingStore: ObservableObject {
    @Published package private(set) var steam: SteamControllerMapping
    @Published package private(set) var keyMap: String?
    @Published package private(set) var padMap: String?
    @Published package private(set) var saveFailed = false
    package let preferences: ControllerPreferences
    private let canSave: () -> Bool
    package init(preferences: ControllerPreferences, canSave: @escaping () -> Bool = { true }) {
        self.canSave = canSave
        self.preferences = preferences
        steam = preferences.steam
        keyMap = preferences.map("DM_KEYMAP")
        padMap = preferences.map("DM_PAD_MAP")
    }
    package func refresh() {
        saveFailed = !preferences.refresh()
        reload()
    }
    private func reload() {
        steam = preferences.steam
        keyMap = preferences.map("DM_KEYMAP")
        padMap = preferences.map("DM_PAD_MAP")
    }
    package func setMap(_ env: String, value: String?) { save { preferences.setMap(env, value: value) } }
    package func copyStandardMaps(_ environment: [String: String]) {
        guard canSave() else { return }
        let keysSaved = preferences.setMap("DM_KEYMAP", value: environment["DM_KEYMAP"])
        let padSaved = preferences.setMap("DM_PAD_MAP", value: environment["DM_PAD_MAP"])
        saveFailed = !keysSaved || !padSaved
        reload()
    }
    package func setPad(_ index: Int, mode: Int) { save { preferences.setSteamPad(index, mode: mode) } }
    package func setGyro(_ enabled: Bool) { save { preferences.setSteamGyro(enabled) } }
    package func setButton(_ id: Int, target: Int) { save { preferences.setSteamButton(id, target: target) } }
    package func resetSteam() { save { preferences.resetSteam() } }
    private func save(_ change: () -> Bool) {
        guard canSave() else { return }
        saveFailed = !change()
        reload()
    }
}
