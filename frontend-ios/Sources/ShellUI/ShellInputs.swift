import Foundation

/// The caller supplies display data. These types never load, validate, or store game data.
public enum GameState: Equatable, Sendable {
    case playable
    case needsGameData
    case needsAppUpdate
    /// `reason` is one short line for under the title, such as "Game files damaged". `detail` is a plain sentence
    /// for the player (what happened, what to do), shown under the title and in the How to fix sheet. `technical`
    /// is the underlying message, shown only as small secondary Details in the sheet.
    case broken(reason: String, detail: String = "", technical: String = "")
}

public struct GameTile: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    /// One short line under the title, such as the version.
    public var subtitle: String
    /// The game's 16:9 key art, such as its eShop banner. Covers, Cover Flow cards and the hero all use it.
    public var banner: Artwork?
    /// The square NACP icon. Only a fallback without a banner: shown whole inside a 16:9 card, never stretched.
    public var icon: Artwork?
    public var state: GameState
    /// Already localized, such as "Played today". Nil leaves the game out of Recently played.
    public var recentlyPlayed: String?
    public init(id: String, title: String, subtitle: String = "", banner: Artwork? = nil, icon: Artwork? = nil,
                state: GameState = .playable, recentlyPlayed: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.banner = banner
        self.icon = icon
        self.state = state
        self.recentlyPlayed = recentlyPlayed
    }
}

public struct SettingOption: Identifiable, Equatable, Sendable {
    public var id: String
    public var label: String
    public init(_ value: String, _ label: String) { id = value; self.label = label }
}

public enum SettingKind: Equatable, Sendable {
    case toggle(on: String, off: String)
    case choice([SettingOption])
    case range(min: Double, max: Double, step: Double, unit: String)
}

public struct SettingRow: Identifiable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var note: String
    public var kind: SettingKind
    public var value: String
    /// The caller resolves dependencies and locks before supplying rows.
    public var enabled: Bool
    /// The value is the shell settings' choice, because the game has none of its own.
    public var fromShell: Bool
    public init(id: String, label: String, note: String = "", kind: SettingKind, value: String, enabled: Bool = true, fromShell: Bool = false) {
        self.id = id
        self.label = label
        self.note = note
        self.kind = kind
        self.value = value
        self.enabled = enabled
        self.fromShell = fromShell
    }
}

public struct SettingSection: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var rows: [SettingRow]
    public init(id: String, title: String, rows: [SettingRow]) { self.id = id; self.title = title; self.rows = rows }
}

public struct GameDetail: Identifiable, Equatable, Sendable {
    public var id: String { game.id }
    public var game: GameTile
    public var sections: [SettingSection]
    public var dataSource: String
    public var dataNote: String
    public var cloudSaves: String?
    public var cloudNote: String
    public var dlc: String
    public var hasModifiedSettings: Bool
    /// The data or cloud-saves folder is the shell settings' one, not one the player picked for this game.
    public var dataFromShell: Bool
    public var cloudFromShell: Bool
    /// The shell settings have a cloud-saves folder this game does not use now, so the game can follow it.
    public var cloudCanUseShell: Bool
    public init(game: GameTile, sections: [SettingSection] = [], dataSource: String = "", dataNote: String = "",
                cloudSaves: String? = nil, cloudNote: String = "", dlc: String = "", hasModifiedSettings: Bool = false,
                dataFromShell: Bool = false, cloudFromShell: Bool = false, cloudCanUseShell: Bool = false) {
        self.game = game
        self.sections = sections
        self.dataSource = dataSource
        self.dataNote = dataNote
        self.cloudSaves = cloudSaves
        self.cloudNote = cloudNote
        self.dlc = dlc
        self.hasModifiedSettings = hasModifiedSettings
        self.dataFromShell = dataFromShell
        self.cloudFromShell = cloudFromShell
        self.cloudCanUseShell = cloudCanUseShell
    }
}

public struct ControllerInfo: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var player: String
    /// Nil means the controller does not report battery level.
    public var batteryPercent: Int?
    public var charging: Bool
    public init(id: String, name: String, player: String, batteryPercent: Int? = nil, charging: Bool = false) {
        self.id = id
        self.name = name
        self.player = player
        self.batteryPercent = batteryPercent
        self.charging = charging
    }
}

/// Which kind of controller a family of glyphs belongs to, from GameController's `productCategory`.
/// The buttons are read by label, as on the Mac: GameController's buttonA is the cross on a PlayStation controller,
/// A at the bottom on an Xbox controller and A on the right on a Nintendo controller, so each confirms with its own.
public enum ControllerFamily: Equatable, Sendable {
    case xbox, playStation, nintendo, neutral
    public init(productCategory: String?) {
        let c = (productCategory ?? "").lowercased().replacingOccurrences(of: "-", with: "")
        if c.contains("dual") || c.contains("playstation") { self = .playStation }
        else if c.contains("xbox") { self = .xbox }
        else if c.contains("nintendo") || c.contains("switch") || c.contains("joycon") { self = .nintendo }
        else { self = .neutral }
    }
}

/// What sent the last input, so the hints show that device's own glyphs.
public enum InputDevice: Equatable, Sendable {
    case controller(ControllerFamily)
    case keyboard
}

/// An optional event supplied by the host's input adapter. Increment sequence for repeated presses.
public struct ShellInput: Equatable, Sendable {
    public enum Action: Sendable { case up, down, left, right, activate, back, settings, controllers }
    public var sequence: Int
    public var action: Action
    public var device: InputDevice
    public init(sequence: Int, action: Action, device: InputDevice = .controller(.neutral)) {
        self.sequence = sequence
        self.action = action
        self.device = device
    }
}

/// All effects leave the package through these closures. The game ID is always explicit.
public struct ShellActions {
    public var onSelect: (String) -> Void
    public var onPlay: (String) -> Void
    public var onChange: (_ gameID: String, _ settingID: String, _ value: String) -> Void
    public var onPickGameData: (String) -> Void
    public var onUseAppData: (String) -> Void
    public var onPickCloudSaves: (String) -> Void
    public var onDisableCloudSaves: (String) -> Void
    public var onResetDefaults: (String) -> Void
    public var onShowLog: (String) -> Void
    public var onAppUpdate: () -> Void
    public var onBack: () -> Void
    public var onPickShellData: () -> Void
    public var onPickShellCloud: () -> Void
    public var onUseShellCloud: (String) -> Void
    public var onClearShellData: () -> Void
    public var onClearShellCloud: () -> Void
    public init(onSelect: @escaping (String) -> Void = { _ in }, onPlay: @escaping (String) -> Void = { _ in },
                onChange: @escaping (String, String, String) -> Void = { _, _, _ in },
                onPickGameData: @escaping (String) -> Void = { _ in }, onUseAppData: @escaping (String) -> Void = { _ in },
                onPickCloudSaves: @escaping (String) -> Void = { _ in }, onDisableCloudSaves: @escaping (String) -> Void = { _ in },
                onResetDefaults: @escaping (String) -> Void = { _ in }, onShowLog: @escaping (String) -> Void = { _ in },
                onAppUpdate: @escaping () -> Void = {}, onBack: @escaping () -> Void = {},
                onPickShellData: @escaping () -> Void = {}, onPickShellCloud: @escaping () -> Void = {},
                onUseShellCloud: @escaping (String) -> Void = { _ in }, onClearShellData: @escaping () -> Void = {},
                onClearShellCloud: @escaping () -> Void = {}) {
        self.onSelect = onSelect
        self.onPlay = onPlay
        self.onChange = onChange
        self.onPickGameData = onPickGameData
        self.onUseAppData = onUseAppData
        self.onPickCloudSaves = onPickCloudSaves
        self.onDisableCloudSaves = onDisableCloudSaves
        self.onResetDefaults = onResetDefaults
        self.onShowLog = onShowLog
        self.onAppUpdate = onAppUpdate
        self.onBack = onBack
        self.onPickShellData = onPickShellData
        self.onPickShellCloud = onPickShellCloud
        self.onUseShellCloud = onUseShellCloud
        self.onClearShellData = onClearShellData
        self.onClearShellCloud = onClearShellCloud
    }
}
