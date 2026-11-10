import Foundation

// The first start of a freshly built Mac app waited for macOS, often for minutes, before any window showed (#1005). The app
// is signed ad hoc, and the first open through LaunchServices has syspolicyd scan the whole bundle, the RomFS image of
// several GB included. macOS remembers the result for that cdhash only, so every rebuild brought the wait back. The build's
// last stage opens the new app once, hidden, with DM_PREFLIGHT set: its launcher (dm/mac/launcher.c) exits at once, before
// it reads anything or touches the log and the saves, and the scan happens on the build page instead of at Play.

package enum MacPreflight {
    /// The Settings switch (Settings > App), on unless switched off.
    package static let defaultsKey = "preflightAfterBuild"
    /// What the app is opened with: its launcher returns 0 at once.
    package static let environmentKey = "DM_PREFLIGHT"
    /// How long the build waits for macOS before it gives up on the check (the build is done either way).
    package static let timeout: TimeInterval = 600

    package static func enabled(_ defaults: UserDefaults) -> Bool { defaults.object(forKey: defaultsKey) as? Bool ?? true }

    /// Whether the app's launcher knows DM_PREFLIGHT (patch 0099, seedds/nxnative#1881). A launcher without it would start
    /// the game: its executable has to name the variable. Read from the bundle's own Info.plist, not `Bundle`, which caches.
    package static func supports(_ app: URL) -> Bool {
        let contents = app.appendingPathComponent("Contents")
        guard let plist = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let name = info["CFBundleExecutable"] as? String,
              let binary = try? Data(contentsOf: contents.appendingPathComponent("MacOS").appendingPathComponent(name), options: .alwaysMapped)
        else { return false }
        return binary.range(of: Data(environmentKey.utf8)) != nil
    }

    /// The check did not end in time, or the player stopped the wait.
    package enum Failure: Error { case timedOut, stopped }
}
