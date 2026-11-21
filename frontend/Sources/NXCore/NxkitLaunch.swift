import Foundation

/// What the launcher tells a Mac app nxkit built when it starts it. nxkit-host reads its own `NXKIT_*` names and never the
/// dm engine's `DM_*` ones, so the launcher passes the same choices under nxkit's names: full screen, the screen and the
/// Home button's texts in the player's language. The launcher names no launcher to go back to (`NXKIT_LAUNCHER_PID`), so the
/// game's Home menu has Resume and Quit. A game paused in the background would post `org.nxkit.paused.<pid>` /
/// `org.nxkit.resumed.<pid>` and listen for `org.nxkit.resume.<pid>` / `org.nxkit.quit.<pid>` (nxkit `docs/nxkit-host.md`).
package enum NxkitLaunch {
    /// The prefix of nxkit's distributed notifications; the dm engine's is `org.nxnative`.
    package static let notificationPrefix = "org.nxkit"

    /// The app at `path` is one nxkit built (its program is nxkit-host).
    package static func isNxkit(app path: String) -> Bool {
        (try? MacGameBundle.read(URL(fileURLWithPath: path)))?.upstream == .nxkit
    }

    /// The prefix of the game's pause notifications: nxkit's for an app nxkit built, the dm engine's for the others.
    package static func notificationPrefix(app path: String) -> String {
        isNxkit(app: path) ? notificationPrefix : "org.nxnative"
    }

    /// nxkit's names for the choices the launcher made. `displayID` is the screen's `NSScreenNumber`, `homeText` the lines
    /// of `HomeButtonHint.promptText`. `overlay` (console mode): the game opens over the console's full-screen Space, not on
    /// a Space of its own, fades in with its first picture (`org.nxkit.shown.<pid>`) and sends the progress of its start
    /// (`org.nxkit.loading.<pid>`, `done` and `total`) for the Starting screen.
    package static func environment(fullscreen: Bool, displayID: UInt32?, homeText: String?, overlay: Bool = false) -> [String: String] {
        var environment: [String: String] = [:]
        if overlay { environment["NXKIT_OVERLAY"] = "1" }
        if fullscreen { environment["NXKIT_FULLSCREEN"] = "1" }
        if let displayID { environment["NXKIT_SCREEN"] = "id:\(displayID)" }
        if let homeText, !homeText.isEmpty { environment["NXKIT_HOME_TEXT"] = homeText }
        return environment
    }
}
