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
    public static let dataFolderNameKey = "globalDataFolderName"
    public static let cloudSavesNameKey = "globalCloudSavesFolderName"

    /// The store the app reads and writes. Tests and previews swap it.
    nonisolated(unsafe) public static var current = ShellSettingsStore()

    /// The suite itself, so the host keeps the folder bookmarks in it with its `BookmarkStore`.
    public let defaults: UserDefaults

    public init(defaults: UserDefaults = UserDefaults(suiteName: ShellSettingsStore.suiteName) ?? .standard) {
        self.defaults = defaults
    }

    public var dataBookmark: Data? { defaults.data(forKey: Self.dataFolderKey) }
    public var cloudSavesBookmark: Data? { defaults.data(forKey: Self.cloudSavesKey) }
    /// The folders' names for the page, written by the host when the player picks them.
    public var dataFolderName: String? { defaults.string(forKey: Self.dataFolderNameKey) }
    public var cloudSavesFolderName: String? { defaults.string(forKey: Self.cloudSavesNameKey) }
    public var language: String { defaults.string(forKey: Self.languageKey) ?? "" }
    public var performanceHUD: Bool? {   // nil: no shell-level choice, the game's own row decides
        defaults.object(forKey: Self.performanceHUDKey) as? Bool
    }

    public func storeDataFolderName(_ name: String) { defaults.set(name, forKey: Self.dataFolderNameKey) }
    public func storeCloudSavesFolderName(_ name: String) { defaults.set(name, forKey: Self.cloudSavesNameKey) }
    public func storeLanguage(_ code: String) { defaults.set(code, forKey: Self.languageKey) }
    public func storePerformanceHUD(_ on: Bool) { defaults.set(on, forKey: Self.performanceHUDKey) }

    /// The shell's value for each `DM_*` switch a game's own settings leave alone.
    public var gameDefaults: [String: String] {
        performanceHUD.map { ["DM_METAL_HUD": $0 ? "1" : "0"] } ?? [:]
    }
}

/// The interface language the player chose. Empty follows the device.
public enum ShellLanguage {
    public static let supported = ["zh-Hans", "en"]
    nonisolated(unsafe) private static var cache: [String: Bundle] = [:]
    private static let lock = NSLock()

    /// `bundle`, or its folder for the chosen language, so a string table is read in that language whatever the device uses.
    public static func bundle(_ bundle: Bundle, language: String = ShellSettingsStore.current.language) -> Bundle {
        guard supported.contains(language) else { return bundle }
        let key = bundle.bundlePath + "|" + language
        lock.lock(); defer { lock.unlock() }
        if let found = cache[key] { return found }
        guard let path = bundle.path(forResource: language, ofType: "lproj"), let localized = Bundle(path: path) else { return bundle }
        cache[key] = localized
        return localized
    }
}
