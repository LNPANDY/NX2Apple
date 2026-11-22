import Foundation
import Testing

/// Keeps every `frontend-ios` test suite out of `~/Library/Preferences` and `cfprefsd`.
@Suite struct TestDefaultsTests {
    private let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    @Test func makeAndKeyedIsolateValuesAndStayOutOfStandardAndPreferences() throws {
        let probeKey = "nx_ios_probe_" + UUID().uuidString
        let defaults = TestDefaults.make("ios-test-defaults")
        defaults.set("kept", forKey: probeKey)
        defaults.set(true, forKey: probeKey + ".bool")
        defaults.set(42, forKey: probeKey + ".int")
        #expect(defaults.string(forKey: probeKey) == "kept")
        #expect(defaults.bool(forKey: probeKey + ".bool") == true)
        #expect(defaults.integer(forKey: probeKey + ".int") == 42)
        #expect(TestDefaults.make("ios-test-defaults").string(forKey: probeKey) == nil)
        #expect(UserDefaults.standard.object(forKey: probeKey) == nil)

        defaults.removeObject(forKey: probeKey)
        defaults.removeObject(forKey: probeKey + ".bool")
        #expect(defaults.string(forKey: probeKey) == nil)
        #expect(defaults.bool(forKey: probeKey + ".bool") == false)

        let keyed = TestDefaults.keyed("ios-keyed")
        let game = keyed("0100000000010000")
        game.set("1", forKey: "launcher.DM_SHOW_FPS")
        #expect(keyed("0100000000010000").string(forKey: "launcher.DM_SHOW_FPS") == "1")
        #expect(keyed("0100000000020000").string(forKey: "launcher.DM_SHOW_FPS") == nil)
        keyed("0100000000010000").removeObject(forKey: "launcher.DM_SHOW_FPS")
        #expect(game.string(forKey: "launcher.DM_SHOW_FPS") == nil)
    }

    @Test func copiesInTestTargetsMatch() throws {
        let copies = try ["ShellHostTests", "ShellUITests"].map {
            try String(contentsOf: tests.appendingPathComponent($0 + "/TestDefaults.swift"), encoding: .utf8)
        }
        #expect(Set(copies).count == 1, "TestDefaults.swift differs between the iOS test targets")
    }

    @Test func noTestMakesASuiteAnotherWay() throws {
        let files = try #require(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil))
        let allowed: Set = ["TestDefaults.swift", "TestDefaultsTests.swift"]
        var offenders: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" && !allowed.contains(url.lastPathComponent) {
            if try String(contentsOf: url, encoding: .utf8).contains("UserDefaults(suiteName:") {
                offenders.append(url.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty, "use TestDefaults.make or .keyed, a plain suite name writes into ~/Library/Preferences")
    }
}
