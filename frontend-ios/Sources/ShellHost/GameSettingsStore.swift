import Foundation
import ShellUI

/// Per-game defaults, one suite per title ID. A suite keeps two games' choices apart without prefixes, and the keys
/// inside are the ones the per-game app uses in its standard defaults: `launcher.<VAR>`, `pickedDataBookmark`,
/// `cloudSavesBookmark`, so the engine can read the same names later.
public enum GameDefaults {
    public static let suitePrefix = "dev.nx2apple.shell.game."
    /// True when the player turned cloud saves off for this game. It wins over the shell's cloud-saves folder, and
    /// choosing a folder for the game clears it.
    public static let cloudSavesOffKey = "cloudSavesOff"
    public static func suite(for titleID: String) -> UserDefaults {
        UserDefaults(suiteName: suitePrefix + titleID) ?? .standard
    }
}

/// A game's saved choices over its `launcher.json`. As in dm/ios/Sources/LauncherSettings.swift, only a choice that
/// differs from the tested default is stored (a setting left alone follows a later build's defaults), a saved value
/// the game no longer offers reads as the default, and reset forgets every saved choice. A setting the player left alone
/// takes the shell's default for its variable (`shell`) when the game offers that value: game > shell > built-in.
public struct GameSettingsStore {
    public let profile: LauncherProfile
    private let defaults: UserDefaults
    private let shell: [String: String]

    public init(profile: LauncherProfile, defaults: UserDefaults, shell: [String: String] = [:]) {
        self.profile = profile
        self.defaults = defaults
        self.shell = shell
    }

    /// The saved value as a string, as launcher.c reads it (not `string(forKey:)`, which turns a number into one).
    private func saved(_ setting: LauncherSetting) -> String? {
        (defaults.object(forKey: setting.defaultsKey) as? String).flatMap { setting.accepts($0) ? $0 : nil }
    }

    /// What the game does without a saved choice: the shell's default when the game offers it, else its own.
    private func fallback(_ setting: LauncherSetting) -> String {
        shell[setting.env].flatMap { setting.accepts($0) ? $0 : nil } ?? setting.def
    }

    public func value(of setting: LauncherSetting) -> String { saved(setting) ?? fallback(setting) }

    /// True when the row shows the shell's choice: the game has none saved and the shell asks for a value the game offers.
    public func isFromShell(_ setting: LauncherSetting) -> Bool {
        saved(setting) == nil && shell[setting.env].map(setting.accepts) == true
    }

    public func values() -> [String: String] {
        Dictionary(uniqueKeysWithValues: profile.settings.map { ($0.env, value(of: $0)) })
    }

    /// Saves a choice. False when the game has no such setting or does not offer the value. A choice equal to what the
    /// game does anyway is forgotten, so it follows a later default. The game's own default is still saved when the shell
    /// asks for something else, or the shell's value would win again.
    @discardableResult public func set(_ env: String, to value: String) -> Bool {
        guard let setting = profile.settings.first(where: { $0.env == env }), setting.accepts(value) else { return false }
        let follows = shell[setting.env].flatMap { setting.accepts($0) ? $0 : nil }.map { $0 == value } ?? setting.isDefault(value)
        if follows { defaults.removeObject(forKey: setting.defaultsKey) } else { defaults.set(value, forKey: setting.defaultsKey) }
        return true
    }

    /// Back to the profile's tested defaults.
    public func reset() {
        for setting in profile.settings { defaults.removeObject(forKey: setting.defaultsKey) }
    }

    /// Any saved choice can be forgotten by the reset, also one that keeps the game's default against the shell's.
    public var hasModifiedSettings: Bool {
        profile.settings.contains { saved($0) != nil }
    }
}

/// The profile and its values as the views' sections.
public enum SettingsPresenter {
    /// A row with `needs` (`<VAR>=<value>`) is drawn only while the row that sets that variable has that value. A row
    /// naming a variable the list does not have stays drawn. Sections come in the list's order.
    public static func sections(profile: LauncherProfile, values: [String: String], fromShell: Set<String> = []) -> [SettingSection] {
        func visible(_ s: LauncherSetting) -> Bool {
            guard let needs = s.needs, let eq = needs.firstIndex(of: "=") else { return true }
            guard let v = values[String(needs[..<eq])] else { return true }
            return v == String(needs[needs.index(after: eq)...])
        }
        var titles: [String] = []
        for s in profile.settings where !titles.contains(s.sectionTitle) { titles.append(s.sectionTitle) }
        return titles.compactMap { title in
            let rows = profile.settings.filter { $0.sectionTitle == title && visible($0) }.map { row($0, value: values[$0.env] ?? $0.def, fromShell: fromShell.contains($0.env)) }
            return rows.isEmpty ? nil : SettingSection(id: title, title: title, rows: rows)
        }
    }

    static func row(_ s: LauncherSetting, value: String, fromShell: Bool = false) -> SettingRow {
        let kind: SettingKind
        switch s.kind {
        case "toggle": kind = .toggle(on: s.onValue, off: s.offValue)
        case "range": kind = .range(min: s.min ?? 0, max: s.max ?? 1, step: s.step ?? 0.1, unit: s.env.hasSuffix("SCALE") ? "×" : "")
        default: kind = .choice((s.options ?? []).map { SettingOption($0[0], $0[1]) })
        }
        return SettingRow(id: s.env, label: s.label, note: s.note, kind: kind, value: value, fromShell: fromShell)
    }
}
