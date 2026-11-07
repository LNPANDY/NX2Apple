import XCTest
@testable import NXCore

/// The game's name in the launcher's language, from the Mac app's `DMTitleNames` (dm/mac/pack_app.py, dm/tools/nacp.py names()).
final class GameTitleNamesTests: XCTestCase {
    private let names = ["en-US": "The Legend", "en-GB": "The Legend (UK)", "ja": "伝説", "ko": "전설", "zh-Hant": "傳說", "zh-Hans": "传说",
                         "fr-CA": "La Légende (CA)", "es-419": "La Leyenda (LA)", "es": "La Leyenda"]

    func testEachLauncherLanguagePicksItsOwn() {
        XCTAssertEqual(GameTitleNames.pick(names, for: .zh, preferred: ["zh-Hans-CN"]), "传说")
        XCTAssertEqual(GameTitleNames.pick(names, for: .en, preferred: ["en-GB"]), "The Legend")   // American English first, as the control data orders them
        XCTAssertEqual(GameTitleNames.pick(names, for: Lang("ja"), preferred: []), "伝説")
        XCTAssertEqual(GameTitleNames.pick(names, for: Lang("fr"), preferred: []), "La Légende (CA)")   // no French: the Canadian French one
        XCTAssertEqual(GameTitleNames.pick(names, for: Lang("es"), preferred: []), "La Leyenda")   // Spanish before Latin American Spanish
    }

    /// The launcher's Chinese is Simplified: Simplified first, Traditional when the game has no Simplified name, and Traditional first
    /// for a system set to Traditional Chinese.
    func testChineseScripts() {
        var traditionalOnly = names; traditionalOnly["zh-Hans"] = nil
        XCTAssertEqual(GameTitleNames.pick(traditionalOnly, for: .zh, preferred: ["zh-Hans"]), "傳說")
        for system in ["zh-Hant-TW", "zh-TW", "zh-HK", "zh-Hant"] {
            XCTAssertEqual(GameTitleNames.pick(names, for: .zh, preferred: [system]), "傳說", system)
        }
        XCTAssertEqual(GameTitleNames.pick(["en-US": "The Legend", "ko": "전설"], for: .zh, preferred: []), nil)   // no Chinese name: the caller shows the bundle name
    }

    func testLanguageWithoutTitleFallsBack() {
        XCTAssertNil(GameTitleNames.pick(names, for: Lang("sv"), preferred: []))   // Horizon has no Swedish
        XCTAssertNil(GameTitleNames.pick([:], for: .en, preferred: []))
    }

    func testReadKeepsKnownLanguagesWithNames() {
        let info: [String: Any] = ["DMTitleNames": ["en-US": "Game", "ja": "  ", "xx": "Unknown", "ko": 3, "zh-Hans": " 游戏 "]]
        XCTAssertEqual(GameTitleNames.read(info), ["en-US": "Game", "zh-Hans": "游戏"])
        XCTAssertEqual(GameTitleNames.read(["DMTitleID": "0100000000010000"]), [:])   // an app packed before the key
    }
}
