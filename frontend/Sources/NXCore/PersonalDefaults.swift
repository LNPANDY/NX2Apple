import Foundation

/// The player's usual choices for a game that has none of its own (LNPANDY/NX2Apple#680): the game language, the display mode and
/// the rumble. Nothing else: performance settings stay each game's tested ones. They are written once into a game that has no choice
/// of its own for a setting, before its first start, and never over a choice that exists. A game keeps what it has when these change.
/// Kept in the app's defaults as `DM_LANG`, `DM_FULLSCREEN` and `DM_RUMBLE` values. An absent language means the System's.
package struct PersonalDefaults: Equatable {
    package static let defaultsKey = "personalDefaults"
    /// The variables of the three settings, in the order the Settings card shows them.
    package static let envs = ["DM_LANG", "DM_FULLSCREEN", "DM_RUMBLE"]

    package private(set) var values: [String: String]

    package init(values: [String: String] = [:]) {
        self.values = values.filter { Self.envs.contains($0.key) && !$0.value.isEmpty }
    }

    package static func load(_ defaults: UserDefaults = .standard) -> PersonalDefaults {
        PersonalDefaults(values: defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:])
    }

    package func save(_ defaults: UserDefaults = .standard) {
        if values.isEmpty { defaults.removeObject(forKey: Self.defaultsKey) } else { defaults.set(values, forKey: Self.defaultsKey) }
    }

    package var isEmpty: Bool { values.isEmpty }
    package func value(for env: String) -> String? { values[env] }

    /// An empty value removes the choice (the language back to System, the others back to the game's tested default).
    package mutating func set(_ value: String, for env: String) {
        guard Self.envs.contains(env) else { return }
        if value.isEmpty { values[env] = nil } else { values[env] = value }
    }

    package mutating func reset() { values = [:] }
}
