import Foundation

/// What the launcher tells a Mac app nxkit built when it starts it. nxkit-host reads its own `NXKIT_*` names and never the
/// dm engine's `DM_*` ones, so the launcher passes the same choices under nxkit's names: full screen, the screen, the Home
/// button's texts in the player's language, the Controls page's maps and, from console mode, the launcher to go back to.
/// The pause in the background goes out as `org.nxkit.paused.<pid>` / `org.nxkit.resumed.<pid>`, and the launcher asks with
/// `org.nxkit.resume.<pid>` / `org.nxkit.quit.<pid>` (nxkit `docs/nxkit-host.md`, The Home button).
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
    /// of `HomeButtonHint.promptText` and `launcherBundleID` the launcher a Home menu's Back to console mode shows (nil from
    /// the desktop's Play).
    package static func environment(fullscreen: Bool, displayID: UInt32?, homeText: String?, launcherBundleID: String?) -> [String: String] {
        var environment: [String: String] = [:]
        if fullscreen { environment["NXKIT_FULLSCREEN"] = "1" }
        if let displayID { environment["NXKIT_SCREEN"] = "id:\(displayID)" }
        if let homeText, !homeText.isEmpty { environment["NXKIT_HOME_TEXT"] = homeText }
        if let launcherBundleID, !launcherBundleID.isEmpty { environment["NXKIT_LAUNCHER_BUNDLE_ID"] = launcherBundleID }
        return environment
    }

    /// The Controls page's maps, global or the game's own, under nxkit's names: `DM_PAD_MAP` as `NXKIT_PAD_MAP`, `DM_KEYMAP`
    /// as `NXKIT_KEYMAP`. nxkit-host reads the dm engine's format (input_map.h), so a value passes as it is. A value
    /// ControllerMap rejects passes nothing. The dead zones, merging, press to join and the frame rate stay out: an nxkit app
    /// keeps them as its own saved choices (NXKIT_STICK_DEADZONE_L and the others), which the environment would override.
    package static func controlMaps(_ dm: [String: String]) -> [String: String] {
        var environment: [String: String] = [:]
        for (from, to, pad) in [("DM_PAD_MAP", "NXKIT_PAD_MAP", true), ("DM_KEYMAP", "NXKIT_KEYMAP", false)] {
            if let value = dm[from], ControllerMap.valid(value, pad: pad) { environment[to] = value }
        }
        return environment
    }
}
