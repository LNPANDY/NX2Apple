import XCTest
import NXCore

/// `TestPreferences`: a stand-in game app's preferences are a plist in the test's folder, not in `~/Library/Preferences`.
final class TestPreferencesTests: XCTestCase {
    func testDomainIsAFileInTheTestFolder() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-prefs-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let domain = TestPreferences.domain(in: temporary, "check")
        let storage = SystemControllerPreferences(domain: domain)
        storage.write("launcher.DM_FPS_TARGET", value: "60")
        XCTAssertTrue(storage.synchronize())
        XCTAssertEqual(storage.read("launcher.DM_FPS_TARGET") as? String, "60")
        XCTAssertTrue(FileManager.default.fileExists(atPath: domain + ".plist"), "the domain is a plist at its own path")
        let name = URL(fileURLWithPath: domain).lastPathComponent + ".plist"
        let preferences = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/" + name)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preferences.path), "nothing in ~/Library/Preferences")
    }

    /// A per-run bundle ID made from a plain prefix (`"org.nxnative.<…>." + <UUID>`) was a plist left in `~/Library/Preferences`.
    /// Only a game app's bundle ID or preferences domain counts: the shell's bundle ID (`library.bundleID`) is no domain.
    func testNoTestBuildsAPlainPerRunBundleID() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let pattern = try NSRegularExpression(pattern: #"(CFBundleIdentifier"\s*:|domain\s*=|(domain|bundleID):\s*String\s*\{)\s*"org\.nxnative\.[^"]*"\s*\+"#)
        var found: [String] = []
        let files = FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for file in files where file.pathExtension == "swift" && file.lastPathComponent != "TestPreferences.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (n, line) in text.components(separatedBy: "\n").enumerated()
            where pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                found.append("\(file.lastPathComponent):\(n + 1)")
            }
        }
        XCTAssertFalse(files.isEmpty, "the test sources are next to this file")
        XCTAssertEqual(found, [], "use TestPreferences.domain(in:_:)")
    }
}
