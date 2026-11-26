import Foundation

/// The shell-level settings, one suite shared by every game: the game-data folder, the cloud-saves folder,
/// the default performance HUD and the touch controls. A game's own settings and bookmarks win over these, and
/// these win over the built-in defaults (ShellSettingsStore priority: game > shell > built-in).
public final class ShellSettingsStore: @unchecked Sendable {
    public static let padMapKey = "padMap"
    public static let padMergeKey = "padMerge"
    public static let audioMixKey = "audioMix"
    public static let suiteName = "shell-settings"
    public static let dataFolderKey = "globalDataBookmark"
    public static let cloudSavesKey = "globalCloudSavesBookmark"
    public static let performanceHUDKey = "performanceHUD"       // true/false; a game's own row wins when set
    public static let showFPSKey = "showFPS"                   // true/false; a game's own row wins when set
    public static let dataFolderNameKey = "globalDataFolderName"
    public static let cloudSavesNameKey = "globalCloudSavesFolderName"
    public static let touchSizeKey = "touchSize"                 // small, medium or large: DM_TOUCH_SIZE (landscape)
    /// The touch controls' sizes, as the engine reads DM_TOUCH_SIZE. Medium is the built-in size and is never stored.
    public static let touchSizes = ["small", "medium", "large"]
    public static let touchStickKey = "touchStick"               // corner, higher or inward: DM_TOUCH_STICK (landscape)
    /// Where the left stick sits, as the engine reads DM_TOUCH_STICK. The corner is the built-in place and is never stored.
    public static let touchStickPlaces = ["corner", "higher", "inward"]
    public static let touchModeKey = "touchMode"                 // 2d/3d for landscape, separate from saved positions
    public static let touchSizePortraitKey = "touchSizePortrait"
    public static let touchStickPortraitKey = "touchStickPortrait"
    public static let touchModePortraitKey = "touchModePortrait"
    public static let touchOrientationMigratedKey = "touchOrientationMigrated"
    public static let touchLayoutKey = "touchLayout"             // the player's arrangement: DM_TOUCH_LAYOUT for every game

    public enum TouchOrientation: String, CaseIterable, Sendable {
        case landscape, portrait
    }

    public struct TouchOrientationConfig: Equatable, Sendable {
        public var size: String
        public var stick: String
        public var mode: String
        public static let `default` = TouchOrientationConfig(size: "medium", stick: "corner", mode: "3d")
        public init(size: String = "medium", stick: String = "corner", mode: String = "3d") {
            self.size = ShellSettingsStore.touchSizes.contains(size) ? size : "medium"
            self.stick = ShellSettingsStore.touchStickPlaces.contains(stick) ? stick : "corner"
            self.mode = mode == "2d" ? "2d" : "3d"
        }
    }

    /// The store the app reads and writes. Tests and previews swap it.
    nonisolated(unsafe) public static var current = ShellSettingsStore()

    /// The suite itself, so the host keeps the folder bookmarks in it with its `BookmarkStore`.
    public let defaults: UserDefaults

    public init(defaults: UserDefaults = UserDefaults(suiteName: ShellSettingsStore.suiteName) ?? .standard) {
        self.defaults = defaults
        migrateOrientationSettingsIfNeeded()
    }

    private func migrateOrientationSettingsIfNeeded() {
        guard !defaults.bool(forKey: Self.touchOrientationMigratedKey) else { return }
        let hasLegacy = [Self.touchSizeKey, Self.touchStickKey, Self.touchModeKey].contains { defaults.object(forKey: $0) != nil }
        let hasPortrait = [Self.touchSizePortraitKey, Self.touchStickPortraitKey, Self.touchModePortraitKey].contains { defaults.object(forKey: $0) != nil }
        guard hasLegacy else { return }
        if !hasPortrait {
            if let s = defaults.string(forKey: Self.touchSizeKey), Self.touchSizes.contains(s) {
                defaults.set(s, forKey: Self.touchSizePortraitKey)
            }
            if let st = defaults.string(forKey: Self.touchStickKey), Self.touchStickPlaces.contains(st) {
                defaults.set(st, forKey: Self.touchStickPortraitKey)
            }
            if let m = defaults.string(forKey: Self.touchModeKey), m == "2d" || m == "3d" {
                defaults.set(m, forKey: Self.touchModePortraitKey)
            }
        }
        defaults.set(true, forKey: Self.touchOrientationMigratedKey)
    }

    private func markOrientationMigrated() {
        if !defaults.bool(forKey: Self.touchOrientationMigratedKey) {
            defaults.set(true, forKey: Self.touchOrientationMigratedKey)
        }
    }

    private static func sizeKey(for orientation: TouchOrientation) -> String {
        orientation == .landscape ? touchSizeKey : touchSizePortraitKey
    }

    private static func stickKey(for orientation: TouchOrientation) -> String {
        orientation == .landscape ? touchStickKey : touchStickPortraitKey
    }

    private static func modeKey(for orientation: TouchOrientation) -> String {
        orientation == .landscape ? touchModeKey : touchModePortraitKey
    }

    public var dataBookmark: Data? { defaults.data(forKey: Self.dataFolderKey) }
    public var cloudSavesBookmark: Data? { defaults.data(forKey: Self.cloudSavesKey) }
    /// The folders' names for the page, written by the host when the player picks them.
    public var dataFolderName: String? { defaults.string(forKey: Self.dataFolderNameKey) }
    public var cloudSavesFolderName: String? { defaults.string(forKey: Self.cloudSavesNameKey) }
    public var performanceHUD: Bool? {   // nil: no shell-level choice, the game's own row decides
        defaults.object(forKey: Self.performanceHUDKey) as? Bool
    }
    public var showFPS: Bool? {   // nil: no shell-level choice, the game's own row decides
        defaults.object(forKey: Self.showFPSKey) as? Bool
    }

    public func storeDataFolderName(_ name: String) { defaults.set(name, forKey: Self.dataFolderNameKey) }
    public func storeCloudSavesFolderName(_ name: String) { defaults.set(name, forKey: Self.cloudSavesNameKey) }
    public func clearDataFolderName() { defaults.removeObject(forKey: Self.dataFolderNameKey) }
    public func clearCloudSavesFolderName() { defaults.removeObject(forKey: Self.cloudSavesNameKey) }
    public func storePerformanceHUD(_ on: Bool) { defaults.set(on, forKey: Self.performanceHUDKey) }
    public func storeShowFPS(_ on: Bool) { defaults.set(on, forKey: Self.showFPSKey) }

    /// The touch controls' size for the given orientation: small, medium (built-in) or large.
    public func touchSize(for orientation: TouchOrientation) -> String {
        let value = defaults.string(forKey: Self.sizeKey(for: orientation)) ?? "medium"
        return Self.touchSizes.contains(value) ? value : "medium"
    }
    public func storeTouchSize(_ size: String, for orientation: TouchOrientation) {
        guard Self.touchSizes.contains(size) else { return }
        markOrientationMigrated()
        let key = Self.sizeKey(for: orientation)
        if size == "medium" { defaults.removeObject(forKey: key) } else { defaults.set(size, forKey: key) }
    }
    public var touchSize: String { touchSize(for: .landscape) }
    public func storeTouchSize(_ size: String) { storeTouchSize(size, for: .landscape) }

    /// Explicit mode (`"2d"` / `"3d"`) if stored for the orientation, or nil when inheriting built-in / profile default.
    public func storedTouchMode(for orientation: TouchOrientation) -> String? {
        guard let mode = defaults.string(forKey: Self.modeKey(for: orientation)), mode == "2d" || mode == "3d" else { return nil }
        return mode
    }
    public func touchMode(for orientation: TouchOrientation) -> String {
        storedTouchMode(for: orientation) ?? "3d"
    }
    public func storeTouchMode(_ mode: String, for orientation: TouchOrientation) {
        guard mode == "2d" || mode == "3d" else { return }
        markOrientationMigrated()
        defaults.set(mode, forKey: Self.modeKey(for: orientation))
    }
    public var touchMode: String { touchMode(for: .landscape) }
    public func storeTouchMode(_ mode: String) { storeTouchMode(mode, for: .landscape) }

    /// Where the left stick sits for the given orientation: corner (built-in), higher, or inward.
    public func touchStick(for orientation: TouchOrientation) -> String {
        let value = defaults.string(forKey: Self.stickKey(for: orientation)) ?? "corner"
        return Self.touchStickPlaces.contains(value) ? value : "corner"
    }
    public func storeTouchStick(_ place: String, for orientation: TouchOrientation) {
        guard Self.touchStickPlaces.contains(place) else { return }
        markOrientationMigrated()
        let key = Self.stickKey(for: orientation)
        if place == "corner" { defaults.removeObject(forKey: key) } else { defaults.set(place, forKey: key) }
    }
    public var touchStick: String { touchStick(for: .landscape) }
    public func storeTouchStick(_ place: String) { storeTouchStick(place, for: .landscape) }

    public func touchConfiguration(for orientation: TouchOrientation) -> TouchOrientationConfig {
        TouchOrientationConfig(size: touchSize(for: orientation),
                               stick: touchStick(for: orientation),
                               mode: touchMode(for: orientation))
    }

    public func isTouchCustomized(for orientation: TouchOrientation) -> Bool {
        let cfg = touchConfiguration(for: orientation)
        let customMode = storedTouchMode(for: orientation) == "2d"
        return cfg.size != "medium" || cfg.stick != "corner" || customMode || !touchLayout.isEmpty(for: orientation)
    }

    /// Resets only the requested orientation's preset options and coordinates without touching the opposite orientation.
    public func resetTouchConfiguration(for orientation: TouchOrientation) {
        markOrientationMigrated()
        defaults.removeObject(forKey: Self.sizeKey(for: orientation))
        defaults.removeObject(forKey: Self.stickKey(for: orientation))
        defaults.removeObject(forKey: Self.modeKey(for: orientation))
        var layout = touchLayout
        layout.reset(for: orientation)
        storeTouchLayout(layout)
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

    /// Whether every connected controller and touch controls drive player 1 together (`DM_PAD_MERGE`).
    public var padMerge: Bool { defaults.bool(forKey: Self.padMergeKey) }
    public func storePadMerge(_ on: Bool) {
        if on {
            defaults.set(true, forKey: Self.padMergeKey)
        } else {
            defaults.removeObject(forKey: Self.padMergeKey)
        }
    }

    /// Whether game audio mixes with other apps instead of interrupting background playback (`DM_AUDIO_MIX`).
    public var audioMix: Bool { defaults.bool(forKey: Self.audioMixKey) }
    public func storeAudioMix(_ on: Bool) {
        if on {
            defaults.set(true, forKey: Self.audioMixKey)
        } else {
            defaults.removeObject(forKey: Self.audioMixKey)
        }
    }

    /// DM_PAD_MAP is deliberately excluded. The host merges it per button at launch.
    /// The shell's value for each `DM_*` switch a game's own settings leave alone.
    public var gameDefaults: [String: String] {
        var values = performanceHUD.map { ["DM_METAL_HUD": $0 ? "1" : "0"] } ?? [:]
        if let showFPS { values["DM_SHOW_FPS"] = showFPS ? "1" : "0" }
        if padMerge { values["DM_PAD_MERGE"] = "1" }
        if audioMix { values["DM_AUDIO_MIX"] = "1" }
        let landscapeSize = touchSize(for: .landscape)
        let portraitSize = touchSize(for: .portrait)
        if landscapeSize != "medium" { values["DM_TOUCH_SIZE"] = landscapeSize }
        if portraitSize != "medium" || portraitSize != landscapeSize { values["DM_TOUCH_SIZE_PORTRAIT"] = portraitSize }

        let landscapeStick = touchStick(for: .landscape)
        let portraitStick = touchStick(for: .portrait)
        if landscapeStick != "corner" { values["DM_TOUCH_STICK"] = landscapeStick }
        if portraitStick != "corner" || portraitStick != landscapeStick { values["DM_TOUCH_STICK_PORTRAIT"] = portraitStick }

        let landscapeMode = storedTouchMode(for: .landscape)
        let portraitMode = storedTouchMode(for: .portrait)
        if let landscapeMode {
            values["DM_PROF_PAD_LAYOUT"] = landscapeMode == "3d" ? "1" : "0"
        }
        if let portraitMode {
            values["DM_PAD_LAYOUT_PORTRAIT"] = portraitMode == "3d" ? "1" : "0"
        } else if landscapeMode != nil {
            // Keep an explicit landscape mode from overriding portrait when portrait was left built-in (3d).
            values["DM_PAD_LAYOUT_PORTRAIT"] = "1"
        }

        let layout = touchLayout.encoded
        if !layout.isEmpty { values["DM_TOUCH_LAYOUT"] = layout }
        return values
    }
}
