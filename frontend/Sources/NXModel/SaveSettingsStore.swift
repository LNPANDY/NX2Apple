import Combine
import Foundation
import NXCore

/// The save settings of the launcher: the global setup and each game's own choices (SaveLocations). Kept in the launcher's
/// preferences as JSON, so a game with nothing set has no entry and plays as it always did.
@MainActor package final class SaveSettingsStore: ObservableObject {
    package static let globalKey = "saves.global"
    package static func gameKey(_ titleID: String) -> String { "saves.game." + titleID.uppercased() }

    @Published package private(set) var global: SaveGlobalSettings
    @Published package private(set) var revision = 0
    private let defaults: UserDefaults

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        global = defaults.data(forKey: Self.globalKey).flatMap { try? JSONDecoder().decode(SaveGlobalSettings.self, from: $0) } ?? SaveGlobalSettings()
    }

    package func setGlobal(_ value: SaveGlobalSettings) {
        global = value
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.globalKey) }
        revision += 1
    }

    package func game(_ titleID: String) -> SaveGameOverride {
        defaults.data(forKey: Self.gameKey(titleID)).flatMap { try? JSONDecoder().decode(SaveGameOverride.self, from: $0) } ?? SaveGameOverride()
    }

    /// An empty override removes the entry, so Reset leaves nothing behind.
    package func setGame(_ titleID: String, _ value: SaveGameOverride) {
        if value.isEmpty { defaults.removeObject(forKey: Self.gameKey(titleID)) }
        else if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.gameKey(titleID)) }
        revision += 1
    }
}
