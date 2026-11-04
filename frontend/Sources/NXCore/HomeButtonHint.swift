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
    package static func promptText(gameName: String, labels: (String) -> String) -> String {
        let name = gameName.replacingOccurrences(of: "\n", with: " ")
        return [labels("homeQuit.hold"), String(format: labels("homeQuit.title"), name), labels("homeQuit.note"),
                labels("homeQuit.quit"), labels("homeQuit.cancel")]
            .map { $0.replacingOccurrences(of: "\n", with: " ") }
            .joined(separator: "\n")
    }
}
