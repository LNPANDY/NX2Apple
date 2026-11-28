import Foundation
import ShellUI

/// Encodes the shared shell's in-game gear menu payload passed to `GameMenu.swift` via `DM_SHELL_MENU`.
/// Keeps only live choice/toggle settings explicitly listed in `allowedEnvs` (touch customization settings stay
/// in shell/per-game settings screens) and carries the resolved effective default for two-way UserDefaults sync.
public enum ShellInGameMenu {
    public static let allowedEnvs: [String] = [
        "DM_OPMODE",
        "DM_PICTURE_FIT",
        "DM_ROTATION",
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
                             envFileOverrides: [String: String] = [:],
                             bundle: Bundle = ShellStrings.bundle) -> Payload {
        let items: [Item] = allowedEnvs.compactMap { env in
            guard let setting = profile.settings.first(where: { $0.env == env }),
                  setting.kind == "choice" || setting.kind == "toggle" else {
                return nil
            }
            let effectiveDefault = envFileOverrides[setting.env].flatMap { setting.accepts($0) ? $0 : nil }
                ?? shellDefaults[setting.env].flatMap { setting.accepts($0) ? $0 : nil }
                ?? setting.def
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
                              envFileOverrides: [String: String] = [:],
                              bundle: Bundle = ShellStrings.bundle) -> String? {
        let payload = build(profile: profile, titleID: titleID, shellDefaults: shellDefaults,
                            envFileOverrides: envFileOverrides, bundle: bundle)
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

/// Encodes the localized in-game Cheats submenu & Memory Scanner UI strings passed to `GameMenuCheats.swift` via `DM_CHEATS_MENU_TEXT`.
public struct ShellCheatsMenuText: Codable, Equatable, Sendable {
    public let cheatsTitle: String
    public let memoryScannerMenu: String
    public let masterSwitch: String
    public let masterSubtitle: String
    public let needsBuilderBake: String
    public let unavailable: String
    public let scannerTitle: String
    public let hideButton: String
    public let resetButton: String
    public let valuePlaceholder: String
    public let firstScanButton: String
    public let equalsButton: String
    public let increasedButton: String
    public let decreasedButton: String
    public let changedButton: String
    public let unchangedButton: String
    public let modifyAction: String
    public let saveAction: String
    public let cancelAction: String
    public let confirmAction: String
    public let saveConfirmAction: String
    public let modifyTitle: String
    public let modifyMessage: String
    public let saveTitle: String
    public let saveMessage: String
    public let cheatNamePlaceholder: String
    public let defaultCheatName: String
    public let hitsSummary: String
    public let hitsCappedNotice: String
    public let emptyPrompt: String
    public let noMatches: String
    public let scanningStatus: String
    public let invalidValueError: String
    public let writeSuccess: String
    public let writeFailed: String
    public let saveSuccess: String
    public let saveFailed: String
    public let saveUnavailable: String

    public static func build(bundle: Bundle? = nil) -> ShellCheatsMenuText {
        let resolvedBundle = bundle ?? HostStrings.bundle
        func t(_ key: String.LocalizationValue) -> String {
            String(localized: key, bundle: resolvedBundle)
        }
        return ShellCheatsMenuText(
            cheatsTitle: t("Cheats"),
            memoryScannerMenu: t("Memory Scanner…"),
            masterSwitch: t("Enable All Cheats"),
            masterSubtitle: t("Always on"),
            needsBuilderBake: t("Needs builder bake"),
            unavailable: t("Unavailable"),
            scannerTitle: t("Memory Scanner"),
            hideButton: t("Hide"),
            resetButton: t("Reset"),
            valuePlaceholder: t("Enter value"),
            firstScanButton: t("First Scan"),
            equalsButton: t("Equals"),
            increasedButton: t("Increased"),
            decreasedButton: t("Decreased"),
            changedButton: t("Changed"),
            unchangedButton: t("Unchanged"),
            modifyAction: t("Modify"),
            saveAction: t("Save"),
            cancelAction: t("Cancel"),
            confirmAction: t("Apply"),
            saveConfirmAction: t("Save"),
            modifyTitle: t("Modify Value"),
            modifyMessage: t("Address: %@"),
            saveTitle: t("Save as Cheat"),
            saveMessage: t("Adds this address to %@.txt and reloads cheats."),
            cheatNamePlaceholder: t("Cheat name"),
            defaultCheatName: t("Scan %@"),
            hitsSummary: t("%@ hits"),
            hitsCappedNotice: t("Showing first %@ of %@ hits. Narrow down to refine."),
            emptyPrompt: t("Choose a data type and enter a starting value to scan game memory."),
            noMatches: t("No matching addresses found. Try resetting the scan."),
            scanningStatus: t("Scanning memory…"),
            invalidValueError: t("Enter a valid value for the selected type."),
            writeSuccess: t("Updated %@ to %@"),
            writeFailed: t("Could not write to %@"),
            saveSuccess: t("Saved \"%@\" and refreshed cheats"),
            saveFailed: t("Could not save cheat"),
            saveUnavailable: t("Saving cheats is unavailable without a build ID.")
        )
    }

    public static func encode(bundle: Bundle? = nil) -> String? {
        guard let data = try? JSONEncoder().encode(build(bundle: bundle)) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
