import XCTest
@testable import NXCore

/// The in-game menu's words for a game's own app (#1129): one env line, the two texts in the engine's order, joined by a backslash and n.
final class GameMenuTextTests: XCTestCase {
    func testOneLineInTheEnginesOrder() {
        let words = ["ingame.moreSettings": "Mehr Einstellungen", "ingame.controllerLayout": "Controller-Layout"]
        let line = GameMenuText.envLine { words[$0] ?? $0 }
        XCTAssertEqual(line, "DM_GAME_MENU_TEXT=Mehr Einstellungen\\nController-Layout")
        XCTAssertFalse(line.contains("\n"), "one variable per line of the env file")
    }

    func testAFileKeepsOneVariablePerLine() {
        let file = GameMenuText.envFile(bcOnCPU: false) { $0 == "ingame.controllerLayout" ? "Menu\nLine" : "x\\y" }
        XCTAssertEqual(file.split(separator: "\n").count, 1)
        XCTAssertEqual(file, "DM_GAME_MENU_TEXT=xy\\nMenu Line\n")
        XCTAssertTrue(GameMenuText.envFile(bcOnCPU: true) { $0 }.hasPrefix("DM_PROF_TEX_BC_CPU=1\n"))
    }
}
