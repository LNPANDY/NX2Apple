import XCTest
@testable import NSPortBuilder

/// When the launcher comes back to the front after a game it started quits. Nothing here touches NSWorkspace.
@MainActor final class ReturnAfterPlayTests: XCTestCase {
    func testComesBackForAGameItStarted() {
        let watcher = GameReturnWatcher(observesSystem: false)
        var forward = 0, quit = 0
        watcher.didStart(pid: 4242) { quit += 1 }
        XCTAssertTrue(watcher.quit(pid: 4242, enabled: true) { forward += 1 })
        XCTAssertEqual(quit, 1, "the caller's bookkeeping ran")
        XCTAssertEqual(forward, 1, "the launcher came forward")
        XCTAssertFalse(watcher.quit(pid: 4242, enabled: true) { forward += 1 }, "only once per start")
        XCTAssertEqual(forward, 1)
    }

    func testStaysPutForOtherProcesses() {
        let watcher = GameReturnWatcher(observesSystem: false)
        var forward = 0
        watcher.didStart(pid: 4242)
        XCTAssertFalse(watcher.quit(pid: 1, enabled: true) { forward += 1 }, "a process the launcher did not start (a game opened from Finder)")
        XCTAssertEqual(forward, 0)
    }

    func testSwitchedOffStillRunsTheBookkeeping() {
        let watcher = GameReturnWatcher(observesSystem: false)
        var forward = 0, quit = 0
        watcher.didStart(pid: 4242) { quit += 1 }
        XCTAssertTrue(watcher.quit(pid: 4242, enabled: false) { forward += 1 })
        XCTAssertEqual(quit, 1, "console mode still ends its Starting state")
        XCTAssertEqual(forward, 0, "switched off in Settings: the launcher stays where it is")
    }

    func testOnUntilSwitchedOff() {
        let saved = UserDefaults.standard.object(forKey: ReturnAfterPlay.defaultsKey)
        defer { UserDefaults.standard.set(saved, forKey: ReturnAfterPlay.defaultsKey) }
        UserDefaults.standard.removeObject(forKey: ReturnAfterPlay.defaultsKey)
        XCTAssertTrue(ReturnAfterPlay.enabled)
        UserDefaults.standard.set(false, forKey: ReturnAfterPlay.defaultsKey)
        XCTAssertFalse(ReturnAfterPlay.enabled)
    }

    func testTheSettingIsInEveryLanguage() {
        for key in ["settings.returnAfterPlay", "settings.returnAfterPlayNote"] {
            XCTAssertNotEqual(L10n.string(key, .en), key)
            XCTAssertNotEqual(L10n.string(key, .zh), key)
            XCTAssertNotEqual(L10n.string(key, .en), L10n.string(key, .zh))
            XCTAssertNotEqual(L10n.string(key, .sv), L10n.string(key, .en), "a Swedish entry, not the English fallback")
        }
    }
}
