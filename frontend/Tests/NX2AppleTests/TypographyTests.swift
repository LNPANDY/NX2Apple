import CoreText
import XCTest
import SwiftUI
import AppKit
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher
@testable import NXModel

/// Each size and weight of Manrope is made once and then reused, so a page with hundreds of labels does not
/// create hundreds of fonts each time it is drawn.
final class TypographyTests: IsolatedDefaultsTestCase {
    func testTheSameSizeAndWeightGiveTheSameFont() throws {
        let first = try XCTUnwrap(Typography.manropeFont(size: 13, weight: .semibold))
        let second = try XCTUnwrap(Typography.manropeFont(size: 13, weight: .semibold))
        XCTAssertTrue(first === second)
        XCTAssertEqual(Typography.text(13, .semibold), Typography.text(13, .semibold))
    }

    func testSizesAndWeightsStayApart() throws {
        let regular = try XCTUnwrap(Typography.manropeFont(size: 13, weight: .regular))
        let semibold = try XCTUnwrap(Typography.manropeFont(size: 13, weight: .semibold))
        let larger = try XCTUnwrap(Typography.manropeFont(size: 15, weight: .semibold))
        XCTAssertFalse(regular === semibold)
        XCTAssertEqual(CTFontGetSize(semibold), 13)
        XCTAssertEqual(CTFontGetSize(larger), 15)
        let wght = NSNumber(value: 0x7767_6874)
        let axes = { (font: CTFont) in (CTFontCopyVariation(font) as? [NSNumber: Double])?[wght] }
        XCTAssertEqual(axes(regular), 400)
        XCTAssertEqual(axes(semibold), 600)
    }

    /// The face Core Text sets `text` in, from `font` and its cascade list.
    private func face(_ font: CTFont, _ text: String) -> CTFont {
        CTFontCreateForString(font, text as CFString, CFRange(location: 0, length: (text as NSString).length))
    }
    private func name(_ font: CTFont) -> String { CTFontCopyPostScriptName(font) as String }
    private func family(_ font: CTFont) -> String { CTFontCopyFamilyName(font) as String }

    /// #1514: in Chinese, 塞 (which Japanese has too) and 尔 (Simplified only) come from the same Chinese face, whatever the Mac's
    /// first language, at the weight asked for. With Japanese first they came from a heavy Japanese face and a lighter Chinese one.
    func testChineseTitlesTakeEveryCharacterFromOneFace() throws {
        for weight: Font.Weight in [.regular, .semibold, .heavy] {
            let font = try XCTUnwrap(Typography.manropeFont(size: 34, weight: weight, lang: .zh))
            let shared = face(font, "塞"), simplified = face(font, "尔")
            XCTAssertEqual(family(shared), "PingFang SC", "\(weight)")
            XCTAssertEqual(name(shared), name(simplified), "\(weight): one face for the whole title")
            XCTAssertEqual(family(face(font, "A")), family(font), "Latin letters stay in Manrope")
        }
        let regular = try XCTUnwrap(Typography.manropeFont(size: 34, weight: .regular, lang: .zh))
        let heavy = try XCTUnwrap(Typography.manropeFont(size: 34, weight: .heavy, lang: .zh))
        XCTAssertNotEqual(name(face(regular, "塞")), name(face(heavy, "塞")), "the Chinese face follows the weight")
    }

    func testJapaneseAndKoreanHaveTheirOwnFacesAndOtherLanguagesTheSystemsFallback() throws {
        let japanese = try XCTUnwrap(Typography.manropeFont(size: 17, weight: .bold, lang: Lang("ja")))
        XCTAssertEqual(family(face(japanese, "塞")), "Hiragino Sans")
        let korean = try XCTUnwrap(Typography.manropeFont(size: 17, weight: .bold, lang: Lang("ko")))
        XCTAssertEqual(family(face(korean, "한")), "Apple SD Gothic Neo")
        let english = try XCTUnwrap(Typography.manropeFont(size: 17, weight: .bold, lang: .en))
        XCTAssertNil(CTFontCopyAttribute(english, kCTFontCascadeListAttribute), "no list of our own: the system's fallback")
        XCTAssertNil(Typography.cjkFamily(Lang("sv")))
        let sameFont = try XCTUnwrap(Typography.manropeFont(size: 17, weight: .bold, lang: Lang("sv")))
        XCTAssertTrue(english === sameFont, "languages without a CJK face share their fonts")
    }

    /// The launcher's language is what the Localizer was given, not the stored choice: the captures and the state gallery draw in a
    /// language of their own.
    func testTheLocalizersLanguageChoosesTheFace() throws {
        let saved = Lang.interface
        defer { Lang.interface = saved }
        let localizer = Localizer(.zh)
        XCTAssertEqual(Lang.interface, .zh)
        XCTAssertEqual(family(face(try XCTUnwrap(Typography.manropeFont(size: 21, weight: .heavy)), "塞")), "PingFang SC")
        localizer.lang = Lang("ja")
        XCTAssertEqual(family(face(try XCTUnwrap(Typography.manropeFont(size: 21, weight: .heavy)), "塞")), "Hiragino Sans")
    }

    /// The title of #1514 at console mode's large title for the PR's images (`NX_LAUNCHER_CAPTURE_DIR`): without a list of our own
    /// (as before, the Mac's languages pick each character's face) and in Chinese.
    @MainActor func testRenderTheTitleOfTheIssue() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture") }
        let saved = Lang.interface
        defer { Lang.interface = saved }
        for (name, lang) in [("title-system-fallback", Lang.en), ("title-zh", Lang.zh)] {
            Lang.interface = lang
            let view = Text("塞尔达传说 智慧的再现").font(.manrope(34, .heavy)).foregroundStyle(.white)
                .padding(24).background(Color(white: 0.06))
            let host = NSHostingView(rootView: view)
            host.frame.size = host.fittingSize
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }
}
