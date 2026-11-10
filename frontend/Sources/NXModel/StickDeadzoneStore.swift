import Combine
import Foundation
import NXCore

/// The stick deadzone settings (StickDeadzoneSettings), kept in the launcher's preferences. Play adds `settings.environment` to the start.
@MainActor package final class StickDeadzoneStore: ObservableObject {
    package static let key = "stickDeadzones"
    @Published package private(set) var settings: StickDeadzoneSettings
    private let defaults: UserDefaults

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(StickDeadzoneSettings.self, from: $0) } ?? StickDeadzoneSettings()
    }

    package func setCustom(_ on: Bool) { update { $0.custom = on } }
    package func setLeft(_ percent: Int) { update { $0.left = StickDeadzoneSettings.clamp(percent) } }
    package func setRight(_ percent: Int) { update { $0.right = StickDeadzoneSettings.clamp(percent) } }

    /// Reset disables the custom values: back to what the engine does without them.
    package func reset() { update { $0 = .reset } }

    private func update(_ change: (inout StickDeadzoneSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        settings = next
        if next.isDefault { defaults.removeObject(forKey: Self.key) }
        else if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: Self.key) }
    }
}
