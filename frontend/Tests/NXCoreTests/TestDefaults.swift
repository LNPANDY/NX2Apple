import Foundation

/// A `UserDefaults` suite for one test, kept out of `~/Library/Preferences`.
///
/// A suite with a plain name is a plist in `~/Library/Preferences`, and it stays there: removing the domain and deleting the file
/// does not help, because cfprefsd writes an empty plist back a moment later. Each test run left about 180 of them. A suite named
/// by an absolute path is a plist at that path instead, so every suite here is a file in a folder of this test process in the
/// temporary directory, and the folder is removed when the process exits. A test needs no clean-up of its own.
///
/// The same file is in NXCoreTests, NXModelTests and NX2AppleTests, because test targets cannot share a file without a package
/// target of its own. `TestDefaultsTests` checks that the copies match and that no test makes a suite another way.
enum TestDefaults {
    /// A new, empty suite. `label` starts its file name, to tell the suites apart.
    static func make(_ label: String) -> UserDefaults { suite(label).defaults }

    /// A new, empty suite and its name, for a test that passes the name on (`removePersistentDomain(forName:)` takes it).
    static func suite(_ label: String) -> (name: String, defaults: UserDefaults) {
        let name = folder + "/" + label + "-" + UUID().uuidString
        return (name, UserDefaults(suiteName: name)!)
    }

    /// The folder of this process's suites, removed at exit.
    static let folder: String = {
        let path = NSTemporaryDirectory() + "nx2apple-test-defaults-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        atexit { try? FileManager.default.removeItem(atPath: TestDefaults.folder) }
        return path
    }()
}
