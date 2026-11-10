import Compression
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
        XCTAssertEqual(GameTitleNames.pick(names, for: Lang("ko"), preferred: []), "전설")
        XCTAssertEqual(GameTitleNames.pick(names, for: Lang("fr"), preferred: []), "La Légende (CA)")   // no French: the Canadian French one
        XCTAssertEqual(GameTitleNames.pick(names, for: Lang("es"), preferred: []), "La Leyenda")   // Spanish before Latin American Spanish
        XCTAssertEqual(GameTitleNames.pick(["en-US": "The Legend", "pt": "A Lenda", "pt-BR": "A Lenda (BR)"], for: Lang("pt-br"), preferred: []), "A Lenda (BR)")
        XCTAssertEqual(GameTitleNames.pick(["en-US": "The Legend", "pt": "A Lenda"], for: Lang("pt-br"), preferred: []), "A Lenda")   // no Brazilian Portuguese: the Portuguese one
    }

    /// The launcher's Chinese is Simplified: Simplified first, Traditional when the game has no Simplified name, and Traditional first
    /// for a system set to Traditional Chinese.
    func testChineseScripts() {
        var traditionalOnly = names; traditionalOnly["zh-Hans"] = nil
        XCTAssertEqual(GameTitleNames.pick(traditionalOnly, for: .zh, preferred: ["zh-Hans"]), "傳說")
        for system in ["zh-Hant-TW", "zh-TW", "zh-HK", "zh-Hant"] {
            XCTAssertEqual(GameTitleNames.pick(names, for: .zh, preferred: [system]), "傳說", system)
        }
        XCTAssertEqual(GameTitleNames.pick(["en-US": "The Legend", "ko": "전설"], for: .zh, preferred: []), "The Legend")   // no Chinese name: the English one
    }

    func testLanguageWithoutTitleFallsBack() {
        XCTAssertEqual(GameTitleNames.pick(names, for: Lang("sv"), preferred: []), "The Legend")   // Horizon has no Swedish: English
        XCTAssertEqual(GameTitleNames.pick(["en-GB": "Xenoblade Chronicles 3", "ko": "제노블레이드 크로니클스 3"], for: Lang("ja"), preferred: []), "Xenoblade Chronicles 3")
        XCTAssertNil(GameTitleNames.pick(["ko": "13기병방위권", "zh-Hans": "十三机兵防卫圈"], for: Lang("ja"), preferred: []))   // neither Japanese nor English: the bundle name
        XCTAssertNil(GameTitleNames.pick([:], for: .en, preferred: []))
    }

    /// A control.nacp's title area: 0x300 bytes per language, name first (dm/tools/nacp.py names() reads it the same way).
    static func titleArea(_ titles: [Int: String], entries: Int = 16) -> [UInt8] {
        var t = [UInt8](repeating: 0, count: 0x300 * entries)
        for (i, name) in titles { let b = Array(name.utf8); t.replaceSubrange((i * 0x300)..<(i * 0x300 + b.count), with: b) }
        return t
    }

    func testNamesFromPlainControlData() {
        let nacp = Data(Self.titleArea([0: "Xenoblade Chronicles 3", 2: "Xenoblade3", 12: "제노블레이드 크로니클스 3", 14: "异度神剑3", 3: "Bad\u{1}Name"]) + [UInt8](repeating: 0, count: 0x1000))
        XCTAssertEqual(GameTitleNames.names(nacp: nacp), ["en-US": "Xenoblade Chronicles 3", "ja": "Xenoblade3", "ko": "제노블레이드 크로니클스 3", "zh-Hans": "异度神剑3"])
        XCTAssertEqual(GameTitleNames.names(nacp: Data([0xff, 0xfe] + [UInt8](repeating: 0, count: 0x3fff))), [:])   // not UTF-8, nothing else
        XCTAssertEqual(GameTitleNames.names(nacp: Data()), [:])
    }

    /// Newer SDKs: a u16 size and raw deflate of 32 entries; the 16 after the known languages are not read.
    func testNamesFromCompressedControlData() {
        let area = Self.titleArea([0: "Super Mario Bros. Wonder", 14: "超级马力欧兄弟 惊奇", 20: "Other"], entries: 32)
        var packed = [UInt8](repeating: 0, count: 0x6000)
        let n = area.withUnsafeBufferPointer { src in
            packed.withUnsafeMutableBufferPointer { compression_encode_buffer($0.baseAddress!, $0.count, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB) }
        }
        XCTAssertGreaterThan(n, 0)
        var nacp = [UInt8](repeating: 0, count: 0x4000)
        nacp[0] = UInt8(n & 0xff); nacp[1] = UInt8(n >> 8)
        nacp.replaceSubrange(2..<(2 + n), with: packed.prefix(n))
        XCTAssertEqual(GameTitleNames.names(nacp: Data(nacp)), ["en-US": "Super Mario Bros. Wonder", "zh-Hans": "超级马力欧兄弟 惊奇"])
    }

    func testReadKeepsKnownLanguagesWithNames() {
        let info: [String: Any] = ["DMTitleNames": ["en-US": "Game", "ja": "  ", "xx": "Unknown", "ko": 3, "zh-Hans": " 游戏 "]]
        XCTAssertEqual(GameTitleNames.read(info), ["en-US": "Game", "zh-Hans": "游戏"])
        XCTAssertEqual(GameTitleNames.read(["DMTitleID": "0100000000010000"]), [:])   // an app packed before the key
    }
}
