import XCTest
@testable import NXCore

/// The choices the launcher passes to an app nxkit built, under nxkit's own names.
final class NxkitLaunchTests: XCTestCase {
    func testConsoleModeNamesEverything() {
        let env = NxkitLaunch.environment(fullscreen: true, displayID: 2, homeText: "Hold\nQuit Zelda?", launcherBundleID: "org.example.launcher")
        XCTAssertEqual(env["NXKIT_FULLSCREEN"], "1")
        XCTAssertEqual(env["NXKIT_SCREEN"], "id:2")
        XCTAssertEqual(env["NXKIT_HOME_TEXT"], "Hold\nQuit Zelda?")
        XCTAssertEqual(env["NXKIT_LAUNCHER_BUNDLE_ID"], "org.example.launcher")
    }

    func testTheDesktopsPlayPassesOnlyWhatWasChosen() {
        let env = NxkitLaunch.environment(fullscreen: false, displayID: nil, homeText: "", launcherBundleID: nil)
        XCTAssertEqual(env, [:])
    }

    func testAnAppThatIsNotThereIsNotNxkit() {
        XCTAssertFalse(NxkitLaunch.isNxkit(app: "/nonexistent/Game.app"))
        XCTAssertEqual(NxkitLaunch.notificationPrefix(app: "/nonexistent/Game.app"), "org.nxnative")
    }
}
