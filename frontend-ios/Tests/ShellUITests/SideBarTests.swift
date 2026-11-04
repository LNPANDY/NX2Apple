import SwiftUI
import XCTest
@testable import ShellUI

/// The side column of iPhone Duo (#622): where the Controllers and Settings chips may go, and where they may not.
final class SideBarTests: XCTestCase {
    /// iPhone Duo's outer display upright, 466 x 678 points, with the status bar's column on the trailing side.
    private let outer = CGSize(width: 466, height: 678)
    private let outerInsets = EdgeInsets(top: 0, leading: 0, bottom: 20, trailing: 80)

    func testNoVerticalBarKeepsTheChipsInTheHeader() {
        XCTAssertNil(SideBar(edge: nil).column(screen: outer, insets: outerInsets))
        // Every other iPhone in landscape has side insets too, but the system names no vertical bar there.
        XCTAssertNil(SideBar(edge: nil).column(screen: CGSize(width: 956, height: 440), insets: EdgeInsets(top: 0, leading: 62, bottom: 20, trailing: 62)))
    }

    func testTheChipsSitAtTheBottomOfTheTrailingColumn() throws {
        let column = try XCTUnwrap(SideBar(edge: .trailing).column(screen: outer, insets: outerInsets))
        XCTAssertGreaterThanOrEqual(column.minX, outer.width - outerInsets.trailing)
        XCTAssertLessThanOrEqual(column.maxX, outer.width)
        XCTAssertEqual(column.midX, outer.width - outerInsets.trailing / 2, accuracy: 0.5)
        XCTAssertEqual(column.maxY, outer.height - outerInsets.bottom - SideBar.margin, accuracy: 0.5)
        XCTAssertEqual(column.height, SideBar.heights.reduce(0, +) + SideBar.gap, accuracy: 0.5)
    }

    func testTheLeadingColumnMirrorsIt() throws {
        let insets = EdgeInsets(top: 0, leading: 80, bottom: 20, trailing: 0)
        let column = try XCTUnwrap(SideBar(edge: .leading).column(screen: outer, insets: insets))
        XCTAssertGreaterThanOrEqual(column.minX, 0)
        XCTAssertLessThanOrEqual(column.maxX, insets.leading)
    }

    func testAColumnNarrowerThanAChipKeepsThemInTheHeader() {
        let insets = EdgeInsets(top: 0, leading: 0, bottom: 20, trailing: SideBar.chipWidth - 1)
        XCTAssertNil(SideBar(edge: .trailing).column(screen: outer, insets: insets))
        // The edge names a side whose inset is empty: nothing to put the chips in.
        XCTAssertNil(SideBar(edge: .leading).column(screen: outer, insets: outerInsets))
    }

    func testTheChipsMoveUpPastACamera() throws {
        let camera = CGRect(x: outer.width - 70, y: outer.height - 90, width: 60, height: 60)
        let column = try XCTUnwrap(SideBar(edge: .trailing, occlusions: [camera]).column(screen: outer, insets: outerInsets))
        XCTAssertFalse(column.intersects(camera))
        XCTAssertLessThanOrEqual(column.maxY, camera.minY)
    }

    func testNoRoomBelowTheStatusBarKeepsThemInTheHeader() {
        // An occluded area over the whole lower half of the column.
        let cover = CGRect(x: outer.width - 80, y: outer.height * 0.45, width: 80, height: outer.height * 0.55)
        XCTAssertNil(SideBar(edge: .trailing, occlusions: [cover]).column(screen: outer, insets: outerInsets))
        // A screen so short that the chips would reach into the status bar's half.
        XCTAssertNil(SideBar(edge: .trailing).column(screen: CGSize(width: 466, height: 200), insets: outerInsets))
    }

    /// Seeded random screens, insets and occluded areas: a column, where there is one, lies in the side inset on the screen, in the
    /// bottom half, clear of every occluded area and of the safe area the library uses.
    func testRandomScreensNeverPutTheChipsOnContentOrACamera() {
        var rng = SplitMix(seed: 622)
        var placed = 0
        for _ in 0..<5000 {
            let size = CGSize(width: rng.next(in: 200...1400), height: rng.next(in: 200...1400))
            let insets = EdgeInsets(top: rng.next(in: 0...70), leading: rng.next(in: 0...100), bottom: rng.next(in: 0...40), trailing: rng.next(in: 0...100))
            let edge: HorizontalEdge? = [nil, .leading, .trailing][Int(rng.next(in: 0...2.99))]
            let occlusions = (0..<Int(rng.next(in: 0...3.99))).map { _ in
                CGRect(x: rng.next(in: -50...size.width), y: rng.next(in: -50...size.height), width: rng.next(in: 1...120), height: rng.next(in: 1...200))
            }
            guard let column = SideBar(edge: edge, occlusions: occlusions).column(screen: size, insets: insets) else { continue }
            placed += 1
            let safe = CGRect(x: insets.leading, y: insets.top, width: size.width - insets.leading - insets.trailing,
                              height: size.height - insets.top - insets.bottom)
            XCTAssertFalse(column.intersects(safe), "on the library's content: \(column) \(safe)")
            XCTAssertTrue(CGRect(origin: .zero, size: size).contains(column), "off the screen: \(column) \(size)")
            XCTAssertGreaterThanOrEqual(column.minY, size.height / 2, "in the status bar's half: \(column) \(size)")
            XCTAssertLessThanOrEqual(column.maxY, size.height - insets.bottom, "on the home indicator: \(column)")
            for area in occlusions { XCTAssertFalse(column.intersects(area), "on an occluded area: \(column) \(area)") }
        }
        XCTAssertGreaterThan(placed, 500, "the random cases should reach the column often")
    }
}

/// A small seeded generator, so a failure repeats.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func next(in range: ClosedRange<CGFloat>) -> CGFloat {
        range.lowerBound + CGFloat(Double(next() >> 11) / Double(1 << 53)) * (range.upperBound - range.lowerBound)
    }
}
