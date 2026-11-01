import Foundation

/// The shell-level settings, one suite shared by every game: the game-data folder, the cloud-saves folder, the
/// interface language and the default performance HUD. A game's own settings and bookmarks win over these, and
/// these win over the built-in defaults (ShellSettingsStore priority: game > shell > built-in).
public final class ShellSettingsStore: @unchecked Sendable {
    public static let suiteName = "shell-settings"
    public static let dataFolderKey = "globalDataBookmark"
    public static let cloudSavesKey = "globalCloudSavesBookmark"
    public static let languageKey = "interfaceLanguage"          // "" = follow the device, "zh-Hans", "en"
    public static let performanceHUDKey = "performanceHUD"       // true/false; a game's own row wins when set

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = UserDefaults(suiteName: ShellSettingsStore.suiteName) ?? .standard) {
        self.defaults = defaults
    }

    public var dataBookmark: Data? { defaults.data(forKey: Self.dataFolderKey) }
    public var cloudSavesBookmark: Data? { defaults.data(forKey: Self.cloudSavesKey) }
    public var language: String { defaults.string(forKey: Self.languageKey) ?? "" }
    public var performanceHUD: Bool? {   // nil: no shell-level choice, the game's own row decides
        defaults.object(forKey: Self.performanceHUDKey) as? Bool
    }

    public func storeDataBookmark(_ data: Data) { defaults.set(data, forKey: Self.dataFolderKey) }
    public func storeCloudSavesBookmark(_ data: Data) { defaults.set(data, forKey: Self.cloudSavesKey) }
    public func storeLanguage(_ code: String) { defaults.set(code, forKey: Self.languageKey) }
    public func storePerformanceHUD(_ on: Bool) { defaults.set(on, forKey: Self.performanceHUDKey) }

    /// A per-game defaults that resolves a missing key from the shell store: the game wins, the shell backs it up.
    public static func effective(_ gameDefaults: UserDefaults, shell: ShellSettingsStore, key: String) -> Bool? {
        if gameDefaults.object(forKey: key) != nil { return gameDefaults.bool(forKey: key) }
        return shell.performanceHUD
    }
}
