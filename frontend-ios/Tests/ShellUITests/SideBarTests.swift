import SwiftUI
import XCTest
@testable import ShellUI

/// The side column of iPhone Duo (#622): where the game settings, Controllers and Settings chips may go, and where they may not.
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

    func testNoRoomInTheColumnKeepsThemInTheHeader() {
        // Occluded areas over the whole column but a strip too short for the chips.
        let upper = CGRect(x: outer.width - 80, y: 0, width: 80, height: 300)
        let lower = CGRect(x: outer.width - 80, y: 380, width: 80, height: 300)
        XCTAssertNil(SideBar(edge: .trailing, occlusions: [upper, lower]).column(screen: outer, insets: outerInsets))
        // No occluded area reported and a screen so short that the chips would reach into the status bar's half.
        XCTAssertNil(SideBar(edge: .trailing).column(screen: CGSize(width: 466, height: 200), insets: outerInsets))
    }

    // The values below are what the iPhone Duo Simulator (iOS 27.2) reported: the size, the safe area and
    // `reservedRegions(kind: .occlusion)` in each pose.

    /// The outer display upright: the status bar is an occluded area at the top of the column, the camera inside it.
    func testTheOuterDisplayUprightAsTheSimulatorReportsIt() throws {
        let bar = SideBar(edge: .trailing, occlusions: [CGRect(x: 399.67, y: 29.33, width: 37, height: 37), CGRect(x: 382, y: 0, width: 84, height: 174)])
        let place = try XCTUnwrap(bar.place(screen: outer, insets: duoInsets(trailing: 84), top: SideBar.topHeights))
        XCTAssertEqual(place.bottom, CGRect(x: 398, y: 522, width: 52, height: 110))
        XCTAssertEqual(place.top, CGRect(x: 398, y: 186, width: 52, height: 44))
    }

    /// The outer display on its side, top to the left: no status bar, the camera at the bottom of the trailing column.
    func testTheOuterDisplayOnItsSideKeepsTheChipsAboveTheCamera() throws {
        let screen = CGSize(width: 678, height: 466)
        let bar = SideBar(edge: .trailing, occlusions: [CGRect(x: 611.67, y: 399.67, width: 37, height: 37), CGRect(x: 594, y: 384, width: 84, height: 82)])
        let place = try XCTUnwrap(bar.place(screen: screen, insets: duoInsets(trailing: 84), top: SideBar.topHeights))
        XCTAssertEqual(place.bottom, CGRect(x: 610, y: 262, width: 52, height: 110))
        XCTAssertEqual(place.top, CGRect(x: 610, y: SideBar.corner, width: 52, height: 44))
    }

    /// The outer display on its other side: the column and the camera are on the leading edge, the camera at the top.
    func testTheOuterDisplayOnItsOtherSideUsesTheLeadingColumn() throws {
        let screen = CGSize(width: 678, height: 466)
        let bar = SideBar(edge: .leading, occlusions: [CGRect(x: 29.33, y: 29.33, width: 37, height: 37), CGRect(x: 0, y: 0, width: 84, height: 82)])
        let place = try XCTUnwrap(bar.place(screen: screen, insets: EdgeInsets(top: 0, leading: 84, bottom: 34, trailing: 0), top: SideBar.topHeights))
        XCTAssertEqual(place.bottom, CGRect(x: 16, y: 310, width: 52, height: 110))
        XCTAssertEqual(place.top, CGRect(x: 16, y: 94, width: 52, height: 44))
    }

    /// The inner display on its side: the status bar at the top of the trailing column. Upright the inner display has no column.
    func testTheInnerDisplay() throws {
        let screen = CGSize(width: 951, height: 669)
        let bar = SideBar(edge: .trailing, occlusions: [CGRect(x: 867, y: 0, width: 84, height: 124)])
        let place = try XCTUnwrap(bar.place(screen: screen, insets: duoInsets(trailing: 84), top: SideBar.topHeights))
        XCTAssertEqual(place.bottom, CGRect(x: 883, y: 513, width: 52, height: 110))
        XCTAssertEqual(place.top, CGRect(x: 883, y: 136, width: 52, height: 44))
        let upright = SideBar(edge: nil, occlusions: [CGRect(x: 525, y: 0, width: 144, height: 82)])
        XCTAssertNil(upright.place(screen: CGSize(width: 669, height: 951), insets: EdgeInsets(top: 82, leading: 0, bottom: 34, trailing: 0),
                                   top: SideBar.topHeights))
    }

    /// Without an occluded area in the column the status bar's place is unknown: no chip at the top, the others in the lower half.
    func testNoReportedStatusBarLeavesTheTopEmpty() throws {
        let place = try XCTUnwrap(SideBar(edge: .trailing).place(screen: outer, insets: outerInsets, top: SideBar.topHeights))
        XCTAssertNil(place.top)
        XCTAssertGreaterThanOrEqual(place.bottom.minY, outer.height / 2)
    }

    /// A column too short for both groups keeps the bottom chips and drops the top one.
    func testTheTopChipNeedsRoomAboveTheOthers() throws {
        let screen = CGSize(width: 466, height: 330)
        let status = CGRect(x: 382, y: 0, width: 84, height: 140)
        let place = try XCTUnwrap(SideBar(edge: .trailing, occlusions: [status]).place(screen: screen, insets: duoInsets(trailing: 84),
                                                                                    top: SideBar.topHeights))
        XCTAssertNil(place.top)
        XCTAssertGreaterThanOrEqual(place.bottom.minY, status.maxY + SideBar.margin)
    }

    private func duoInsets(trailing: CGFloat) -> EdgeInsets { EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: trailing) }

    /// Seeded random screens, insets and occluded areas: chips, where there are some, lie in the side inset on the screen, clear of
    /// every occluded area, of the home indicator and of the safe area the library uses. Where no occluded area is in the column
    /// they stay in the bottom half and the top chip stays away. The top chip is always above the others with room between.
    func testRandomScreensNeverPutTheChipsOnContentOrACamera() {
        var rng = SplitMix(seed: 622)
        var placed = 0, topped = 0
        for _ in 0..<5000 {
            let size = CGSize(width: rng.next(in: 200...1400), height: rng.next(in: 200...1400))
            let insets = EdgeInsets(top: rng.next(in: 0...70), leading: rng.next(in: 0...100), bottom: rng.next(in: 0...40), trailing: rng.next(in: 0...100))
            let edge: HorizontalEdge? = [nil, .leading, .trailing][Int(rng.next(in: 0...2.99))]
            let occlusions = (0..<Int(rng.next(in: 0...3.99))).map { _ in
                CGRect(x: rng.next(in: -50...size.width), y: rng.next(in: -50...size.height), width: rng.next(in: 1...120), height: rng.next(in: 1...200))
            }
            guard let place = SideBar(edge: edge, occlusions: occlusions).place(screen: size, insets: insets, top: SideBar.topHeights) else { continue }
            placed += 1
            let safe = CGRect(x: insets.leading, y: insets.top, width: size.width - insets.leading - insets.trailing,
                              height: size.height - insets.top - insets.bottom)
            let inColumn = occlusions.contains { $0.minX < place.bottom.maxX && $0.maxX > place.bottom.minX }
            for chip in [place.bottom] + (place.top.map { [$0] } ?? []) {
                XCTAssertFalse(chip.intersects(safe), "on the library's content: \(chip) \(safe)")
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(chip), "off the screen: \(chip) \(size)")
                XCTAssertLessThanOrEqual(chip.maxY, size.height - insets.bottom, "on the home indicator: \(chip)")
                XCTAssertGreaterThanOrEqual(chip.minY, insets.top, "under the top inset: \(chip)")
                for area in occlusions { XCTAssertFalse(chip.intersects(area), "on an occluded area: \(chip) \(area)") }
            }
            if !inColumn {
                XCTAssertNil(place.top, "a top chip where nothing reports the status bar")
                XCTAssertGreaterThanOrEqual(place.bottom.minY, size.height / 2, "in the status bar's half: \(place.bottom) \(size)")
            }
            if let top = place.top {
                topped += 1
                XCTAssertLessThanOrEqual(top.maxY + SideBar.groupGap, place.bottom.minY + 0.001, "too close to the others: \(top) \(place.bottom)")
            }
        }
        XCTAssertGreaterThan(placed, 500, "the random cases should reach the column often")
        XCTAssertGreaterThan(topped, 100, "the random cases should place a top chip often")
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
