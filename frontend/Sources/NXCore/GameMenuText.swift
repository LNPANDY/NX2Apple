import Foundation

/// The words of the iOS in-game menu (engine patch 0124, GameMenu.swift) in the launcher's language: its title, Controller layout,
/// Keys that toggle and None, in that order. A game's own app has no launcher to pass them at start, so the build bakes them into the
/// app's `dm/env.txt` (the build's `--env-file`), one line, the texts joined by a backslash and n (#1129).
package enum GameMenuText {
    /// The launcher's keys, in the engine's order.
    package static let keys = ["ingame.moreSettings", "ingame.controllerLayout", "ingame.keysThatToggle", "controls.none"]

    /// `DM_GAME_MENU_TEXT=…` for an env file: no line breaks inside a text, so the file keeps one variable per line.
    package static func envLine(_ t: (String) -> String) -> String {
        "DM_GAME_MENU_TEXT=" + keys.map { t($0).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\\", with: "") }.joined(separator: "\\n")
    }

    /// The env file of an iPhone or iPad build: the menu's words, and the CPU decode of BC textures when the player turned it on.
    package static func envFile(bcOnCPU: Bool, _ t: (String) -> String) -> String {
        (bcOnCPU ? "DM_PROF_TEX_BC_CPU=1\n" : "") + envLine(t) + "\n"
    }
}
