import Foundation

/// Persists each game's preferred default Mac build engine in UserDefaults, keyed by uppercased Title ID.
package enum DefaultBuildPreference {
    package static let keyPrefix = "defaultMacEngine."

    package static func key(titleID: String) -> String {
        keyPrefix + titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    package static func get(titleID: String, defaults: UserDefaults = .standard) -> EngineUpstreamKind? {
        let tid = titleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tid.isEmpty, let raw = defaults.string(forKey: key(titleID: tid)) else { return nil }
        return EngineUpstreamKind(rawValue: raw)
    }

    package static func set(_ upstream: EngineUpstreamKind?, titleID: String, defaults: UserDefaults = .standard) {
        let tid = titleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tid.isEmpty else { return }
        let k = key(titleID: tid)
        if let upstream {
            defaults.set(upstream.rawValue, forKey: k)
        } else {
            defaults.removeObject(forKey: k)
        }
    }

    /// Resolves the active Mac build upstream from available built engines:
    /// 1) persisted/explicit preference if still present,
    /// 2) `nxnative` if present,
    /// 3) first available engine in `EngineUpstreamKind.displayOrder`.
    package static func resolveActive(
        preferred: EngineUpstreamKind?,
        available: [EngineUpstreamKind]
    ) -> EngineUpstreamKind? {
        guard !available.isEmpty else { return nil }
        if let preferred, available.contains(preferred) {
            return preferred
        }
        if available.contains(.nxnative) {
            return .nxnative
        }
        return EngineUpstreamKind.displayOrder.first { available.contains($0) } ?? available.first
    }
}
