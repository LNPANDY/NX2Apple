import XCTest

/// The tests' `UserDefaults` suites stay out of `~/Library/Preferences`: every run of `swift test` left about 180 plists there.
final class TestDefaultsTests: XCTestCase {
    private let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    func testASuiteIsAFileInTheRunsFolderNotInPreferences() throws {
        let (name, defaults) = TestDefaults.suite("test-defaults")
        defaults.set("kept", forKey: "key")
        XCTAssertTrue(name.hasPrefix(TestDefaults.folder + "/"))
        XCTAssertTrue(TestDefaults.folder.hasPrefix(NSTemporaryDirectory()))
        XCTAssertEqual(UserDefaults(suiteName: name)?.string(forKey: "key"), "kept", "a second instance reads the same suite")
        XCTAssertNil(TestDefaults.make("test-defaults").string(forKey: "key"), "a new suite starts empty")
        let preferences = NSHomeDirectory() + "/Library/Preferences/" + URL(fileURLWithPath: name).lastPathComponent + ".plist"
        XCTAssertFalse(FileManager.default.fileExists(atPath: preferences))
    }

    func testTheCopiesInTheTestTargetsMatch() throws {
        let copies = try ["NXCoreTests", "NXModelTests", "NX2AppleTests"].map {
            try String(contentsOf: tests.appendingPathComponent($0 + "/TestDefaults.swift"), encoding: .utf8)
        }
        XCTAssertEqual(Set(copies).count, 1, "TestDefaults.swift differs between the test targets")
    }

    func testNoTestMakesASuiteAnotherWay() throws {
        let files = try XCTUnwrap(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil))
        let allowed: Set = ["TestDefaults.swift", "TestDefaultsTests.swift"]
        var offenders: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" && !allowed.contains(url.lastPathComponent) {
            if try String(contentsOf: url, encoding: .utf8).contains("UserDefaults(suiteName:") { offenders.append(url.lastPathComponent) }
        }
        XCTAssertEqual(offenders, [], "use TestDefaults.make or TestDefaults.suite, a suite with a plain name stays in ~/Library/Preferences")
    }

    func testDesignGalleryMakesNoSuiteAnotherWay() throws {
        let gallery = tests.deletingLastPathComponent().appendingPathComponent("Sources/NX2Apple/DesignGallery")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: gallery, includingPropertiesForKeys: nil))
        let bundlePattern = try NSRegularExpression(pattern: #""CFBundleIdentifier"\s*:\s*"(org\.(nxnative|macnativegames|nxkit|s2arm)\.|[^/])"#)
        var offenders: [String] = []
        var plainDomains: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" && url.lastPathComponent != "GalleryDefaults.swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("UserDefaults(suiteName:") { offenders.append(url.lastPathComponent) }
            if bundlePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                plainDomains.append(url.lastPathComponent)
            }
        }
        XCTAssertEqual(offenders, [], "use GalleryDefaults.make so gallery suites stay out of ~/Library/Preferences")
        XCTAssertEqual(plainDomains, [], "use GalleryDefaults.domain so gallery CFBundleIdentifiers stay out of ~/Library/Preferences")
        let helper = try String(contentsOf: gallery.appendingPathComponent("GalleryDefaults.swift"), encoding: .utf8)
        XCTAssertTrue(helper.contains("NSTemporaryDirectory()") && helper.contains("atexit"),
                      "GalleryDefaults must place suites in a temporary directory cleaned up at exit")
    }
}
