import Foundation
import ShellUI

/// Encodes the shared shell's in-game gear menu payload passed to `GameMenu.swift` via `DM_SHELL_MENU`.
/// Keeps only live choice/toggle settings explicitly listed in `allowedEnvs` (touch customization settings stay
/// in shell/per-game settings screens) and carries the resolved effective default for two-way UserDefaults sync.
public enum ShellInGameMenu {
    public static let allowedEnvs: [String] = [
        "DM_OPMODE",
        "DM_PICTURE_FIT",
        "DM_SHOW_FPS",
        "DM_AUDIO_MIX",
        "DM_METAL_HUD",
    ]

    public struct Item: Codable, Equatable, Sendable {
        public let env: String
        public let kind: String
        public let label: String
        public let effectiveDefault: String
        public let onValue: String?
        public let offValue: String?
        public let options: [[String]]?

        public init(env: String, kind: String, label: String, effectiveDefault: String,
                    onValue: String? = nil, offValue: String? = nil, options: [[String]]? = nil) {
            self.env = env
            self.kind = kind
            self.label = label
            self.effectiveDefault = effectiveDefault
            self.onValue = onValue
            self.offValue = offValue
            self.options = options
        }

        public var resolvedOnValue: String { onValue ?? "1" }
        public var resolvedOffValue: String { offValue ?? "0" }

        public func accepts(_ value: String) -> Bool {
            switch kind {
            case "choice":
                return options?.contains { $0.count >= 2 && $0[0] == value } ?? false
            case "toggle":
                return value == resolvedOnValue || value == resolvedOffValue
            default:
                return false
            }
        }
    }

    public struct Payload: Codable, Equatable, Sendable {
        public let suiteName: String
        public let items: [Item]

        public init(suiteName: String, items: [Item]) {
            self.suiteName = suiteName
            self.items = items
        }
    }

    public static func build(profile: LauncherProfile, titleID: String, shellDefaults: [String: String],
                             bundle: Bundle = ShellStrings.bundle) -> Payload {
        let items: [Item] = allowedEnvs.compactMap { env in
            guard let setting = profile.settings.first(where: { $0.env == env }),
                  setting.kind == "choice" || setting.kind == "toggle" else {
                return nil
            }
            let effectiveDefault = shellDefaults[setting.env].flatMap { setting.accepts($0) ? $0 : nil } ?? setting.def
            let label = ShellStrings.setting(setting.label, bundle: bundle)
            if setting.kind == "toggle" {
                return Item(
                    env: setting.env,
                    kind: setting.kind,
                    label: label,
                    effectiveDefault: effectiveDefault,
                    onValue: setting.onValue,
                    offValue: setting.offValue,
                    options: nil
                )
            }
            let localizedOptions = (setting.options ?? [])
                .filter { $0.count >= 2 }
                .map { [$0[0], ShellStrings.setting($0[1], bundle: bundle)] }
            return Item(
                env: setting.env,
                kind: setting.kind,
                label: label,
                effectiveDefault: effectiveDefault,
                onValue: nil,
                offValue: nil,
                options: localizedOptions
            )
        }
        return Payload(suiteName: GameDefaults.suitePrefix + titleID, items: items)
    }

    public static func encode(profile: LauncherProfile, titleID: String, shellDefaults: [String: String],
                              bundle: Bundle = ShellStrings.bundle) -> String? {
        let payload = build(profile: profile, titleID: titleID, shellDefaults: shellDefaults, bundle: bundle)
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Mirrors `GameMenu.swift`'s UserDefaults persistence rule so tests can verify round-trip sync.
    public static func persistSelection(payload: Payload, env: String, value: String, defaults: UserDefaults) {
        guard let item = payload.items.first(where: { $0.env == env }), item.accepts(value) else { return }
        let key = "launcher." + item.env
        if value == item.effectiveDefault {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(value, forKey: key)
        }
    }
}
