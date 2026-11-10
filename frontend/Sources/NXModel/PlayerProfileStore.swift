import Combine
import Foundation
import NXCore

/// The players of this Mac and which one plays now (PlayerProfile). Play reads `active` and starts the game with that player's
/// save folder. The list and the choice are kept in the launcher's preferences, so the last player stays chosen after a restart.
@MainActor package final class PlayerProfileStore: ObservableObject {
    package static let listKey = "players.list"
    package static let activeKey = "players.active"

    @Published package private(set) var profiles: [PlayerProfile]
    @Published package private(set) var activeID: String

    private let defaults: UserDefaults
    private let defaultName: () -> String

    /// - Parameter defaultName: the default player's name when the player has not renamed it (the launcher's language).
    package init(defaults: UserDefaults = .standard, defaultName: @escaping () -> String = { "Player 1" }) {
        self.defaults = defaults; self.defaultName = defaultName
        var list = (defaults.data(forKey: Self.listKey)).flatMap { try? JSONDecoder().decode([PlayerProfile].self, from: $0) } ?? []
        if !list.contains(where: \.isDefault) { list.insert(PlayerProfile(id: PlayerProfile.defaultID, name: ""), at: 0) }
        profiles = list
        let saved = defaults.string(forKey: Self.activeKey) ?? PlayerProfile.defaultID
        activeID = list.contains(where: { $0.id == saved }) ? saved : PlayerProfile.defaultID
    }

    package var active: PlayerProfile { profiles.first { $0.id == activeID } ?? profiles[0] }

    /// The name to show: the default player is "Player 1" in the launcher's language until it is renamed.
    package func displayName(_ profile: PlayerProfile) -> String { profile.name.isEmpty ? defaultName() : profile.name }

    /// Whether `name` may be used for a new player or as `id`'s new name: not empty, and no other player has it.
    package func canUse(name: String, for id: String? = nil) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !profiles.contains { $0.id != id && displayName($0).caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// Adds a player and makes them the one who plays. Returns nil for a name `canUse` refuses.
    @discardableResult package func create(name: String) -> PlayerProfile? {
        guard canUse(name: name) else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = PlayerProfile(id: PlayerProfile.slug(for: trimmed, taken: Set(profiles.map(\.id))), name: trimmed)
        profiles.append(profile)
        activeID = profile.id
        save()
        return profile
    }

    package func select(_ id: String) {
        guard id != activeID, profiles.contains(where: { $0.id == id }) else { return }
        activeID = id
        save()
    }

    /// A new name only: the folder stays, so the saves stay with the player.
    package func rename(_ id: String, to name: String) {
        guard canUse(name: name, for: id), let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    /// Takes the player off the list. Their save folders stay on disk, so adding a player of the same name brings them back.
    /// The default player cannot be removed: their saves are the game's usual ones.
    package func remove(_ id: String) {
        guard id != PlayerProfile.defaultID else { return }
        profiles.removeAll { $0.id == id }
        if activeID == id { activeID = PlayerProfile.defaultID }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: Self.listKey) }
        defaults.set(activeID, forKey: Self.activeKey)
    }
}
