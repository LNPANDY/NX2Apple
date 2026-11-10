import XCTest
@testable import NXCore

/// The in-game menu's words for a game's own app (#1129): one env line, the four texts in the engine's order, joined by a backslash and n.
final class GameMenuTextTests: XCTestCase {
    func testOneLineInTheEnginesOrder() {
        let words = ["ingame.moreSettings": "Mehr Einstellungen", "ingame.controllerLayout": "Controller-Layout",
                     "ingame.keysThatToggle": "Tasten zum Umschalten", "controls.none": "Keine"]
        let line = GameMenuText.envLine { words[$0] ?? $0 }
        XCTAssertEqual(line, "DM_GAME_MENU_TEXT=Mehr Einstellungen\\nController-Layout\\nTasten zum Umschalten\\nKeine")
        XCTAssertFalse(line.contains("\n"), "one variable per line of the env file")
    }

    func testAFileKeepsOneVariablePerLine() {
        let file = GameMenuText.envFile(bcOnCPU: false) { $0 == "controls.none" ? "No\nne" : "x\\y" }
        XCTAssertEqual(file.split(separator: "\n").count, 1)
        XCTAssertEqual(file, "DM_GAME_MENU_TEXT=xy\\nxy\\nxy\\nNo ne\n")
        XCTAssertTrue(GameMenuText.envFile(bcOnCPU: true) { $0 }.hasPrefix("DM_PROF_TEX_BC_CPU=1\n"))
    }
}
