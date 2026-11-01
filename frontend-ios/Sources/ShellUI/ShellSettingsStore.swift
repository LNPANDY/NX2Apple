import Foundation

/// The shell-level settings, one suite shared by every game: the game-data folder, the cloud-saves folder
/// and the default performance HUD. A game's own settings and bookmarks win over these, and
/// these win over the built-in defaults (ShellSettingsStore priority: game > shell > built-in).
public final class ShellSettingsStore: @unchecked Sendable {
    public static let suiteName = "shell-settings"
    public static let dataFolderKey = "globalDataBookmark"
    public static let cloudSavesKey = "globalCloudSavesBookmark"
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
    public var performanceHUD: Bool? {   // nil: no shell-level choice, the game's own row decides
        defaults.object(forKey: Self.performanceHUDKey) as? Bool
    }

    public func storeDataFolderName(_ name: String) { defaults.set(name, forKey: Self.dataFolderNameKey) }
    public func storeCloudSavesFolderName(_ name: String) { defaults.set(name, forKey: Self.cloudSavesNameKey) }
    public func clearDataFolderName() { defaults.removeObject(forKey: Self.dataFolderNameKey) }
    public func clearCloudSavesFolderName() { defaults.removeObject(forKey: Self.cloudSavesNameKey) }
    public func storePerformanceHUD(_ on: Bool) { defaults.set(on, forKey: Self.performanceHUDKey) }

    /// The shell's value for each `DM_*` switch a game's own settings leave alone.
    public var gameDefaults: [String: String] {
        performanceHUD.map { ["DM_METAL_HUD": $0 ? "1" : "0"] } ?? [:]
    }
}
