import Foundation

/// The shell-level settings, one suite shared by every game: the game-data folder, the cloud-saves folder,
/// the default performance HUD and the touch controls. A game's own settings and bookmarks win over these, and
/// these win over the built-in defaults (ShellSettingsStore priority: game > shell > built-in).
public final class ShellSettingsStore: @unchecked Sendable {
    public static let padMapKey = "padMap"
    public static let suiteName = "shell-settings"
    public static let dataFolderKey = "globalDataBookmark"
    public static let cloudSavesKey = "globalCloudSavesBookmark"
    public static let performanceHUDKey = "performanceHUD"       // true/false; a game's own row wins when set
    public static let dataFolderNameKey = "globalDataFolderName"
    public static let cloudSavesNameKey = "globalCloudSavesFolderName"
    public static let touchSizeKey = "touchSize"                 // small, medium or large: DM_TOUCH_SIZE for every game
    /// The touch controls' sizes, as the engine reads DM_TOUCH_SIZE. Medium is the built-in size and is never stored.
    public static let touchSizes = ["small", "medium", "large"]
    public static let touchStickKey = "touchStick"               // corner, higher or inward: DM_TOUCH_STICK for every game
    /// Where the left stick sits, as the engine reads DM_TOUCH_STICK. The corner is the built-in place and is never stored.
    public static let touchStickPlaces = ["corner", "higher", "inward"]
    public static let touchModeKey = "touchMode" // 2d/3d, separate from saved positions
    public static let touchLayoutKey = "touchLayout"             // the player's arrangement: DM_TOUCH_LAYOUT for every game

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

    /// The touch controls' size for every game: small, medium (the built-in size) or large.
    public var touchSize: String {
        let value = defaults.string(forKey: Self.touchSizeKey) ?? "medium"
        return Self.touchSizes.contains(value) ? value : "medium"
    }
    public func storeTouchSize(_ size: String) {
        guard Self.touchSizes.contains(size) else { return }
        if size == "medium" { defaults.removeObject(forKey: Self.touchSizeKey) } else { defaults.set(size, forKey: Self.touchSizeKey) }
    }

    /// Unset keeps each game's original starting layout.
    public var touchMode: String { defaults.string(forKey: Self.touchModeKey) == "2d" ? "2d" : "3d" }
    public func storeTouchMode(_ mode: String) {
        guard mode == "2d" || mode == "3d" else { return }
        defaults.set(mode, forKey: Self.touchModeKey)
    }

    /// Where the left stick sits in every game: in the corner (the built-in place), higher, or further in.
    public var touchStick: String {
        let value = defaults.string(forKey: Self.touchStickKey) ?? "corner"
        return Self.touchStickPlaces.contains(value) ? value : "corner"
    }
    public func storeTouchStick(_ place: String) {
        guard Self.touchStickPlaces.contains(place) else { return }
        if place == "corner" { defaults.removeObject(forKey: Self.touchStickKey) } else { defaults.set(place, forKey: Self.touchStickKey) }
    }

    /// The player's arrangement of the touch controls for every game (#414): stored as the value the engine reads, so what the
    /// settings show is what a game gets. A stored value the engine would ignore reads as the built-in layout.
    public var touchLayout: TouchLayout {
        defaults.string(forKey: Self.touchLayoutKey).flatMap { TouchLayout(encoded: $0) } ?? TouchLayout()
    }
    public func storeTouchLayout(_ layout: TouchLayout) {
        if layout.isEmpty { defaults.removeObject(forKey: Self.touchLayoutKey) } else { defaults.set(layout.encoded, forKey: Self.touchLayoutKey) }
    }
    /// Every control of one layout back to its built-in place.
    public func resetTouchLayout(_ kind: TouchLayout.Kind) {
        var layout = touchLayout
        layout.reset(kind)
        storeTouchLayout(layout)
    }

    public var padMap: PadMap { PadMap(defaults.dictionary(forKey: Self.padMapKey) as? [String: String] ?? [:]) }
    public func setPadButton(_ button: String, to output: String) {
        var map = padMap
        map.set(button, to: output)
        defaults.set(map.entries, forKey: Self.padMapKey)
    }
    public func setPadSwapAB(_ on: Bool) {
        var map = padMap
        map.setSwapAB(on)
        defaults.set(map.entries, forKey: Self.padMapKey)
    }
    public func resetPadMap() { defaults.removeObject(forKey: Self.padMapKey) }

    /// DM_PAD_MAP is deliberately excluded. The host merges it per button at launch.
    /// The shell's value for each `DM_*` switch a game's own settings leave alone.
    public var gameDefaults: [String: String] {
        var values = performanceHUD.map { ["DM_METAL_HUD": $0 ? "1" : "0"] } ?? [:]
        if touchSize != "medium" { values["DM_TOUCH_SIZE"] = touchSize }
        if touchStick != "corner" { values["DM_TOUCH_STICK"] = touchStick }
        if let mode = defaults.string(forKey: Self.touchModeKey), mode == "2d" || mode == "3d" {
            values["DM_PROF_PAD_LAYOUT"] = mode == "3d" ? "1" : "0"
        }
        let layout = touchLayout.encoded
        if !layout.isEmpty { values["DM_TOUCH_LAYOUT"] = layout }
        return values
    }
}
