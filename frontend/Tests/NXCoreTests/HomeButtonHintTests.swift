import XCTest
@testable import NXCore

/// #336: the Home button setting a game writes to its log, when the launcher's hint shows, and the texts of the game's quit prompt.
final class HomeButtonHintTests: XCTestCase {
    func testSettingFromTheGamesLog() {
        let log = """
        [dm] front end: hold the Home button to quit is on
        [dm] controller 'Xbox Wireless Controller' connected: player 1 (npad 0)
        [dm] front end: Home button in apps: system (the system's default)
        [dm] guest thread finished
        """
        XCTAssertEqual(HomeButtonHint.setting(fromLog: log), "system")
        XCTAssertEqual(HomeButtonHint.setting(fromLog: log + "\n[dm] front end: Home button in apps: app (set by the player)"), "app", "the last line wins")
        XCTAssertEqual(HomeButtonHint.setting(fromLog: "[dm] front end: Home button in apps: unavailable (the system's default), error"), "unavailable")
        XCTAssertNil(HomeButtonHint.setting(fromLog: "[dm] front end: hold the Home button to quit needs macOS 27, quit with ⌘Q"), "macOS 26 writes no setting")
        XCTAssertNil(HomeButtonHint.setting(fromLog: ""))
        XCTAssertNil(HomeButtonHint.setting(fromLog: "[dm] front end: Home button in apps: "), "a cut line")
    }

    func testHintShowsOnceWhenTheSystemKeepsHome() {
        XCTAssertTrue(HomeButtonHint.shouldShow(setting: "system", shown: false, macOS27: true))
        XCTAssertFalse(HomeButtonHint.shouldShow(setting: "system", shown: true, macOS27: true), "once")
        XCTAssertFalse(HomeButtonHint.shouldShow(setting: "system", shown: false, macOS27: false), "macOS 26 keeps Cmd+Q")
        for other in ["app", "off", "unavailable", nil] as [String?] {
            XCTAssertFalse(HomeButtonHint.shouldShow(setting: other, shown: false, macOS27: true), "\(other ?? "nil")")
        }
    }

    func testPromptTextIsOneLinePerTextInTheEnginesOrder() {
        let labels: [String: String] = ["homeQuit.hold": "Hold", "homeQuit.title": "Quit %@?", "homeQuit.note": "Note", "homeQuit.quit": "Quit", "homeQuit.cancel": "Cancel"]
        let text = HomeButtonHint.promptText(gameName: "Zelda\nTOTK", labels: { labels[$0] ?? $0 })
        XCTAssertEqual(text.components(separatedBy: "\n"), ["Hold", "Quit Zelda TOTK?", "Note", "Quit", "Cancel"], "a newline in the name would shift the lines")
        for lang in Lang.all {
            let lines = HomeButtonHint.promptText(gameName: "Hades", labels: { L10n.string($0, lang) }).components(separatedBy: "\n")
            XCTAssertEqual(lines.count, 5, lang.code)
            XCTAssertTrue(lines[1].contains("Hades"), "\(lang.code): the title names the game")
        }
    }

    /// #952 (engine patch 0121): a game started from console mode gets the Home menu's three lines after the five, in the engine's
    /// order (Resume, Back to console mode, the menu's title, which is the game's name), and the environment that offers the row.
    func testHomeMenuLinesAndEnvironment() {
        let labels: [String: String] = ["homeQuit.hold": "Hold", "homeQuit.title": "Quit %@?", "homeQuit.note": "Note", "homeQuit.quit": "Quit",
                                        "homeQuit.cancel": "Cancel", "homeQuit.resume": "Resume", "homeQuit.backToConsole": "Back"]
        let text = HomeButtonHint.promptText(gameName: "Zelda\nTOTK", labels: { labels[$0] ?? $0 }, homeMenu: true)
        XCTAssertEqual(text.components(separatedBy: "\n"), ["Hold", "Quit Zelda TOTK?", "Note", "Quit", "Cancel", "Resume", "Back", "Zelda TOTK"])
        for lang in Lang.all {
            let lines = HomeButtonHint.promptText(gameName: "Hades", labels: { L10n.string($0, lang) }, homeMenu: true).components(separatedBy: "\n")
            XCTAssertEqual(lines.count, 8, lang.code)
            XCTAssertFalse(lines[5].isEmpty || lines[6].isEmpty, lang.code)
            XCTAssertEqual(lines[7], "Hades", "\(lang.code): the menu's title is the game's name")
        }
        XCTAssertEqual(HomeButtonHint.homeMenuEnvironment(launcherBundleID: "org.nxnative.NSPortBuilder"),
                       ["DM_HOME_MENU_LAUNCHER": "1", "DM_LAUNCHER_BUNDLE_ID": "org.nxnative.NSPortBuilder"])
        XCTAssertEqual(HomeButtonHint.homeMenuEnvironment(launcherBundleID: nil), ["DM_HOME_MENU_LAUNCHER": "1"], "swift run has no bundle: the row still shows")
        XCTAssertEqual(HomeButtonHint.homeMenuEnvironment(launcherBundleID: ""), ["DM_HOME_MENU_LAUNCHER": "1"])
    }
}
