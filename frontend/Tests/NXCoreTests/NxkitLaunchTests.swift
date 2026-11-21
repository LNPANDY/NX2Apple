import XCTest
@testable import NXCore

/// The choices the launcher passes to an app nxkit built, under nxkit's own names.
final class NxkitLaunchTests: XCTestCase {
    func testConsoleModeNamesEverything() {
        let env = NxkitLaunch.environment(fullscreen: true, displayID: 2, homeText: "Hold\nQuit Zelda?", overlay: true)
        XCTAssertEqual(env["NXKIT_OVERLAY"], "1")
        XCTAssertEqual(env["NXKIT_FULLSCREEN"], "1")
        XCTAssertEqual(env["NXKIT_SCREEN"], "id:2")
        XCTAssertEqual(env["NXKIT_HOME_TEXT"], "Hold\nQuit Zelda?")
        XCTAssertNil(env["NXKIT_LAUNCHER_PID"], "no Back to console mode: Quit is the way back")
    }

    func testTheDesktopsPlayPassesOnlyWhatWasChosen() {
        let env = NxkitLaunch.environment(fullscreen: false, displayID: nil, homeText: "")
        XCTAssertEqual(env, [:])
    }

    func testTheControlsPagesMapsGoUnderNxkitsNames() {
        let env = NxkitLaunch.controlMaps(["DM_PAD_MAP": "A=B,B=A", "DM_KEYMAP": "A=0,", "DM_PAD_MERGE": "1",
                                           "DM_STICK_DEADZONE_L": "10", "DM_FPS_TARGET": "60"])
        XCTAssertEqual(env, ["NXKIT_PAD_MAP": "A=B,B=A", "NXKIT_KEYMAP": "A=0,"])
    }

    func testAMapTheHostWouldRejectPassesNothing() {
        XCTAssertEqual(NxkitLaunch.controlMaps(["DM_PAD_MAP": "A=Shout", "DM_KEYMAP": "A=999"]), [:])
        XCTAssertEqual(NxkitLaunch.controlMaps(["DM_PAD_MAP": ""]), [:])
    }

    func testAnAppThatIsNotThereIsNotNxkit() {
        XCTAssertFalse(NxkitLaunch.isNxkit(app: "/nonexistent/Game.app"))
        XCTAssertEqual(NxkitLaunch.notificationPrefix(app: "/nonexistent/Game.app"), "org.nxnative")
    }
}
