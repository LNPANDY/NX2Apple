import Foundation

/// Quitting a game with the controller's Home button (#336, engine patch "Mac host: quit a game by holding the controller's Home
/// button"). The game claims Home and shows its own quit prompt on macOS 27. That works only when the system's Home button setting for
/// apps lets the app decide. The game reads that setting and writes it to its log once (`front end: Home button in apps: <word>`), and
/// the launcher shows its hint once in console mode when the word is `system`: the system keeps Home for itself there.
/// The setting is read in the game's process because it may differ per app. The launcher only reads the game's log.
package enum HomeButtonHint {
    package static let shownKey = "homeButtonHintShown"
    /// The line front_mac.m writes, up to the word.
    static let marker = "Home button in apps: "

    /// The setting's word in the last line of a game's log that names it, nil when no line does (macOS 26, an older game, no controller).
    package static func setting(fromLog text: String) -> String? {
        guard let range = text.range(of: marker, options: .backwards) else { return nil }
        let word = text[range.upperBound...].prefix { $0.isLetter }
        return word.isEmpty ? nil : String(word)
    }

    /// The hint shows once: on macOS 27, when the game reported that the system keeps Home, and only if it has not shown before.
    package static func shouldShow(setting: String?, shown: Bool, macOS27: Bool) -> Bool {
        macOS27 && !shown && setting == "system"
    }

    /// DM_HOME_QUIT_TEXT: the game's quit prompt in the launcher's language, one text per line, in the engine's order
    /// (home_quit.h: the hold indicator, the title, the note, the quit button, the cancel button). Lines never hold a newline.
    /// `homeMenu` (a game started from console mode, #952, engine patch 0121) adds the Home menu's three: Resume, Back to console
    /// mode and the menu's title, the game's name.
    package static func promptText(gameName: String, labels: (String) -> String, homeMenu: Bool = false) -> String {
        let name = gameName.replacingOccurrences(of: "\n", with: " ")
        let menu = homeMenu ? [labels("homeQuit.resume"), labels("homeQuit.backToConsole"), name] : []
        return ([labels("homeQuit.hold"), String(format: labels("homeQuit.title"), name), labels("homeQuit.note"),
                 labels("homeQuit.quit"), labels("homeQuit.cancel")] + menu)
            .map { $0.replacingOccurrences(of: "\n", with: " ") }
            .joined(separator: "\n")
    }

    /// The environment of a game started from console mode (#952, engine patch 0121): the Home menu gets Back to console mode, which
    /// pauses the game in the background and hands the front to the launcher named by its bundle identifier. A game started from the
    /// desktop gets none of it.
    package static func homeMenuEnvironment(launcherBundleID: String?) -> [String: String] {
        var environment = ["DM_HOME_MENU_LAUNCHER": "1"]
        if let id = launcherBundleID, !id.isEmpty { environment["DM_LAUNCHER_BUNDLE_ID"] = id }
        return environment
    }
}
