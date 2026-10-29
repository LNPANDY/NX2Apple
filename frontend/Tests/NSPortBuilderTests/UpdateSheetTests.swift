import XCTest
@testable import NSPortBuilder

/// The update sheet's bilingual split (ReleaseNotes.lines, read here as the displayed text of each block): the release bodies follow
/// docs/RELEASE-NOTES-GUIDE.md — a bilingual heading, `**中文** …` / `**English** …` paragraphs, then
/// bullets that interleave. A Chinese reader must not get the English paragraph and vice versa.
final class UpdateSheetTests: XCTestCase {
    /// What a reader sees: each block's text, bullets prefixed with "- ".
    static func plain(_ notes: String, for lang: Lang) -> [String] {
        ReleaseNotes.blocks(from: ReleaseNotes.markdown(notes, for: lang)).map {
            switch $0 {
            case .heading(let t), .paragraph(let t): return String(t.characters)
            case .bullet(let t): return "- " + String(t.characters)
            }
        }
    }

    private let body = """
    ## 这一版做了什么 / What this release does

    **中文** 游戏数据现在打成一个 `romfs.img`，拷到手机上快得多。

    **English** Game data is now one `romfs.img`, which copies to a phone far faster.

    ## 修复 / Fixes

    - iOS 构建修好了：两处宏未定义。
    - The iOS build is fixed: two macros were left undefined.
    """

    func testChineseReaderGetsTheChineseParagraphNotTheEnglishOne() {
        let zh = Self.plain(body, for: .zh)
        XCTAssertTrue(zh.contains { $0.contains("拷到手机上快得多") })
        XCTAssertFalse(zh.contains { $0.contains("copies to a phone far faster") },
                       "the English paragraph must not reach a Chinese reader: \(zh)")
    }

    func testEnglishReaderGetsTheEnglishParagraphNotTheChineseOne() {
        let en = Self.plain(body, for: .en)
        XCTAssertTrue(en.contains { $0.contains("copies to a phone far faster") })
        XCTAssertFalse(en.contains { $0.contains("拷到手机上快得多") })
    }

    func testTheHeadingAppearsInBoth() {
        for lang in [Lang.zh, Lang.en] {
            XCTAssertTrue(Self.plain(body, for: lang).contains { $0.contains("这一版做了什么") }, "\(lang)")
        }
    }

    func testBulletsGoToTheirOwnLanguage() {
        let zh = Self.plain(body, for: .zh)
        let en = Self.plain(body, for: .en)
        XCTAssertTrue(zh.contains { $0.hasPrefix("- iOS 构建修好了") })
        XCTAssertFalse(zh.contains { $0.hasPrefix("- The iOS build is fixed") })
        XCTAssertTrue(en.contains { $0.hasPrefix("- The iOS build is fixed") })
    }

    func testAMonolingualBodyComesThroughWhole() {
        let one = "## What changed\n\n- One thing.\n- Another thing."
        XCTAssertEqual(Self.plain(one, for: .zh), ["What changed", "- One thing.", "- Another thing."])
    }

    func testMarkdownMarksAreStripped() {
        let bold = "**中文** 见 **NX2Apple** 的设置。"
        XCTAssertEqual(Self.plain(bold, for: .zh), ["见 NX2Apple 的设置。"])
    }

    // The format used from 0.4.8 on: English in full, `---`, Chinese in full.
    private let twoHalves = """
    ## What this release does

    The launcher installs to a paired device.

    ## Fixes

    - Every rewrite crashed.

    ---

    ## 这一版做了什么

    启动器可以装到配对设备。

    ## 修复

    - 每一次重写都会崩。
    """

    func testTheTwoHalvesFormatGivesEachReaderItsOwnHalf() {
        let en = Self.plain(twoHalves, for: .en)
        let zh = Self.plain(twoHalves, for: .zh)
        XCTAssertTrue(en.contains { $0.contains("installs to a paired device") })
        XCTAssertFalse(en.contains { $0.contains("启动器可以装到配对设备") }, "English half leaked: \(en)")
        XCTAssertTrue(zh.contains { $0.contains("启动器可以装到配对设备") })
        XCTAssertFalse(zh.contains { $0.contains("installs to a paired device") }, "Chinese half leaked: \(zh)")
    }

    func testTheTwoHalvesKeepTheirOwnHeadings() {
        let en = Self.plain(twoHalves, for: .en)
        let zh = Self.plain(twoHalves, for: .zh)
        XCTAssertTrue(en.contains("What this release does"))
        XCTAssertTrue(en.contains("Fixes"))
        XCTAssertFalse(en.contains("这一版做了什么"))
        XCTAssertTrue(zh.contains("这一版做了什么"))
        XCTAssertTrue(zh.contains("修复"))
        XCTAssertFalse(zh.contains("What this release does"))
    }

    func testAHalvesBodyWrittenChineseFirstStillReadsCorrectly() {
        let flipped = """
        ## 这一版做了什么

        中文在前。

        ---

        ## What this release does

        English second.
        """
        XCTAssertTrue(Self.plain(flipped, for: .en).contains { $0.contains("English second") })
        XCTAssertTrue(Self.plain(flipped, for: .zh).contains { $0.contains("中文在前") })
    }
}
