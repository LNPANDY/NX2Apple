import Foundation
import ShellUI

/// Where the touch controls' groups are kept (DM_TOUCH_GROUPS, `TouchGroups`): the value the game's layout editor saves (the gear ›
/// Controller layout › Adjust Gamepad Layout, through ShellMain.m's `dm_shell_touch_groups_save`), the shell's own layout editor shows and
/// keeps, and a start passes. Every game's value is in the shell settings (`ShellSettingsStore.touchGroups`); a game's own is in the game's
/// suite under the per-game app's key, `launcher.DM_TOUCH_GROUPS`, so the same name means the same thing in both apps. A game's own value,
/// empty included (the built-in layout for that game), wins over every game's. The game's editor saves whole values: when the player picks
/// the other scope it loads what that scope holds and keeps the layouts it neither showed nor changed (DmPadEditing.h, "Where Done saves"),
/// so a save for every game from a game with its own layout replaces only those in every game's value.
public struct TouchGroupsStore {
    public static let ownKey = "launcher.DM_TOUCH_GROUPS"
    /// Posted after the game's editor saved a value, with the game's title ID as the object: the library shows it.
    public static var didChange: Notification.Name { Notification.Name("TouchGroupsStore.didChange") }
    /// The game settings' row: whether this game follows every game's layout or has its own.
    public static let rowID = "touch.groups"
    public static let sectionID = "touch"

    public let shell: ShellSettingsStore
    /// The game's suite, nil for no game.
    public let game: UserDefaults?

    public init(shell: ShellSettingsStore, game: UserDefaults?) {
        self.shell = shell
        self.game = game
    }

    /// This game's own value as stored, nil when it follows every game's. A value the engine would not read counts as none.
    public var own: String? {
        guard let value = game?.object(forKey: Self.ownKey) as? String, TouchGroups(encoded: value) != nil else { return nil }
        return value
    }
    /// Every game's value as stored, nil for none ("" when the built-in layout was saved for every game).
    public var everyGame: String? { shell.touchGroupsStored }

    /// What the game's editor finds for a scope (0 every game, 1 this game): the stored value, nil for none.
    public func load(scope: Int) -> String? { scope == 1 ? own : everyGame }

    /// Saves what the game's editor asks for a scope. Saving for every game also makes this game follow every game's layout again, as the
    /// player chose. False, and nothing changes, for a value the engine would not read or a game's value with no game.
    @discardableResult public func save(scope: Int, value: String) -> Bool {
        guard let groups = TouchGroups(encoded: value) else { return false }
        if scope == 1 {
            guard let game else { return false }
            game.set(groups.encoded, forKey: Self.ownKey)
        } else {
            shell.storeTouchGroups(groups)
            game?.removeObject(forKey: Self.ownKey)
        }
        return true
    }

    /// Forgets the game's own value: it follows every game's again.
    public func reset() { game?.removeObject(forKey: Self.ownKey) }

    /// What the game's editor forgets for a scope: this game's own value (the game follows every game's again; false with no game), or every
    /// game's (nothing stored, a game gets none). The game's editor uses it when the player has the game follow every game's layout again
    /// ("Same as All games"), and its self-test to put back "nothing stored".
    @discardableResult public func forget(scope: Int) -> Bool {
        if scope == 1 {
            guard game != nil else { return false }
            reset()
        } else {
            shell.forgetTouchGroups()
        }
        return true
    }

    /// The game's row: every game's layout, or this game's own. Choosing this game's own starts from every game's value; the game's editor
    /// then saves for this game by default.
    public func section() -> SettingSection {
        let mine = own != nil
        var row = SettingRow(id: Self.rowID, label: hostText("Gamepad layout"),
                             note: hostText("Change it in the game: the button at the top centre, Controller layout, Adjust Gamepad Layout."),
                             kind: .choice([SettingOption("follow", hostText("All games")), SettingOption("own", hostText("This game"))]),
                             value: mine ? "own" : "follow", fromShell: !mine)
        row.changed = mine
        return SettingSection(id: Self.sectionID, title: hostText("Touch controls"), rows: [row])
    }

    public func change(_ setting: String, value: String) {
        guard setting == Self.rowID, let game else { return }
        switch value {
        case "follow": reset()
        case "own": if own == nil { game.set(shell.touchGroups.encoded, forKey: Self.ownKey) }
        default: break
        }
    }

    /// The values a start passes: DM_TOUCH_GROUPS and DM_TOUCH_GROUPS_OWN for a game with its own (every game's value comes with the
    /// shell's defaults, `ShellSettingsStore.gameDefaults`).
    public var launchValues: [String: String] {
        guard let own else { return [:] }
        return ["DM_TOUCH_GROUPS": own, "DM_TOUCH_GROUPS_OWN": "1"]
    }
}
