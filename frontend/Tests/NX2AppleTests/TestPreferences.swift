import Foundation

/// The bundle ID of a stand-in game app, kept out of `~/Library/Preferences`.
///
/// The launcher keeps a game's saved choices and controller maps in the game's own preferences domain, its CFBundleIdentifier, through
/// CFPreferences. A plain bundle ID is a plist in `~/Library/Preferences`, and it stays there: clearing the keys or deleting the file
/// does not help, because cfprefsd writes an empty plist back a moment later. Each test run left about 14 `org.nxnative.*` files.
/// A domain that is an absolute path is a plist at that path instead (`<path>.plist`, folders made as needed), so the domain here is
/// in the test's own folder and goes when the test removes the folder. Synchronize the domain before that, so nothing is written to
/// it afterwards. `TestPreferencesTests` checks where the plist goes and that no test builds a bundle ID the old way.
enum TestPreferences {
    /// A bundle ID for an app of the test whose folder is `folder`; `label` tells the domains apart.
    static func domain(in folder: URL, _ label: String) -> String {
        folder.appendingPathComponent("preferences/org.nxnative.frontendtests." + label).path
    }
}
