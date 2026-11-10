import Foundation
import NXCore

/// Personal defaults (PersonalDefaults, #680) reaching a game. They are written once, into a game the library added after they could
/// exist (`defaultsApplied` false), for each of the three settings the game has no choice of its own for. A saved choice, an explicit
/// language and a game the library already had are never touched. The game language then goes through the same path as any choice,
/// so a start from Finder speaks it too, and the Mac's language (SavedChoices.preselectLanguage) only fills what is still empty.
extension SavedChoices {
    /// Writes the personal values for the settings of `settings` that have no stored value. Returns the variables it wrote.
    @discardableResult func applyPersonal(_ personal: PersonalDefaults, to settings: [LaunchSetting], preferred: [String] = []) -> [String] {
        var wrote: [String] = []
        for s in settings where s.storeBacked && PersonalDefaults.envs.contains(s.env) && raw(s.env) == nil {
            guard let want = personal.value(for: s.env) else { continue }
            if s.env == "DM_LANG" {
                // The language the game has that fits the choice (en-US asked of a game with en-GB only gets en-GB). Always written:
                // a value equal to the packed default is still the player's choice, which the Mac's language must not replace.
                guard s.kind == "choice", let options = s.options,
                      let code = SavedChoices.gameLanguage(preferred: [want], offered: options.compactMap(\.first)) else { continue }
                CFPreferencesSetAppValue(Self.key(s.env) as CFString, code as CFString, domain as CFString)
                CFPreferencesAppSynchronize(domain as CFString)
                wrote.append(s.env)
            } else if s.accepts(want) {
                set(s, want)
                CFPreferencesAppSynchronize(domain as CFString)
                wrote.append(s.env)
            }
        }
        return wrote
    }
}

extension GameLibrary {
    /// Gives every game that has not had them yet the personal defaults, then marks it. A game whose app has no settings list yet waits.
    /// The Display mode is the launcher's own setting (not a saved choice): it goes into the game's launch options.
    func applyPersonalDefaults(_ personal: PersonalDefaults = .load()) {
        for var game in games where !game.defaultsApplied && !game.appPath.isEmpty {
            guard let settings = LaunchSetting.read(app: game.appPath) else { continue }
            if !personal.isEmpty {
                SavedChoices(app: game.appPath, titleID: game.titleID).applyPersonal(personal, to: settings)
                if let display = personal.value(for: "DM_FULLSCREEN"), display != "0", game.launchOptions["DM_FULLSCREEN"] == nil {
                    game.launchOptions["DM_FULLSCREEN"] = display
                }
            }
            game.defaultsApplied = true
            upsert(game)   // saves the library
        }
    }
}
