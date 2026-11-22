import Foundation

/// A `UserDefaults` suite for a gallery scene, kept out of `~/Library/Preferences`.
///
/// A suite with a plain name writes a plist into `~/Library/Preferences`, which stays behind even after `removePersistentDomain`
/// because cfprefsd recreates an empty plist. Naming a suite by an absolute path keeps the plist in a temporary folder that is
/// removed when the process exits, matching `TestDefaults` in the test targets.
enum GalleryDefaults {
    /// A new, empty suite. `label` starts its file name.
    static func make(_ label: String) -> UserDefaults {
        UserDefaults(suiteName: domain(label)) ?? UserDefaults()
    }

    /// An absolute preferences domain path inside `folder` so `UserDefaults` and `CFPreferences` never write into `~/Library/Preferences`.
    static func domain(_ label: String) -> String {
        folder + "/" + label + "-" + UUID().uuidString
    }

    /// The folder of this process's gallery suites, removed at exit.
    static let folder: String = {
        let path = NSTemporaryDirectory() + "nx2apple-gallery-defaults-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        atexit { try? FileManager.default.removeItem(atPath: GalleryDefaults.folder) }
        return path
    }()
}
