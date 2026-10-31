import CoreText
import XCTest
@testable import NSPortBuilder

/// Each size and weight of Manrope is made once and then reused, so a page with hundreds of labels does not
/// create hundreds of fonts each time it is drawn.
final class TypographyTests: XCTestCase {
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
}
