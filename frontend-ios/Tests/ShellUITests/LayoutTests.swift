import XCTest
@testable import ShellUI

final class LayoutTests: XCTestCase {
    private func layout(_ width: CGFloat, _ height: CGFloat, large: Bool = false) -> ShellLayout {
        ShellLayout.resolve(CGSize(width: width, height: height), accessibilityText: large)
    }
    func testPhone() {
        XCTAssertEqual(layout(402, 874), .column)
        XCTAssertEqual(layout(874, 402), .coverFlow(regular: false))
    }
    func testPad() {
        XCTAssertEqual(layout(834, 1194), .grid)
        XCTAssertEqual(layout(1194, 834), .coverFlow(regular: true))
        // Split View and narrow Stage Manager windows are compact.
        XCTAssertEqual(layout(507, 834), .column)
        XCTAssertEqual(layout(375, 688), .column)
    }
    /// The foldable as reported so far: both screens about 1.4:1, the outer compact, the inner regular.
    /// These are sample sizes, not values the views know about.
    func testFoldable() {
        XCTAssertEqual(layout(375, 525), .column)
        XCTAssertEqual(layout(525, 375), .coverFlow(regular: false))
        XCTAssertEqual(layout(626, 890), .grid)
        XCTAssertEqual(layout(890, 626), .coverFlow(regular: true))
        XCTAssertEqual(layout(669, 951), .grid)
        XCTAssertEqual(layout(951, 669), .coverFlow(regular: true))
    }
    /// A nearly square window keeps the upright library. Cover Flow needs clearly more width than height.
    func testSquareWindowKeepsTwoPanes() {
        XCTAssertEqual(layout(800, 760), .grid)
    }
    func testAccessibilityTextUsesOneColumn() {
        XCTAssertEqual(layout(834, 1194, large: true), .column)
    }
    func testPaneWidths() {
        XCTAssertEqual(ShellLayout.column.paneWidth(402), 402)
        XCTAssertEqual(ShellLayout.grid.paneWidth(626), 380)
        XCTAssertEqual(ShellLayout.grid.paneWidth(834), 417)
        XCTAssertEqual(ShellLayout.coverFlow(regular: true).paneWidth(1194), 500)
        XCTAssertTrue(ShellLayout.grid.settingsFloat)
        XCTAssertFalse(ShellLayout.column.settingsFloat)
    }

    /// Cover Flow moves one card per gesture: a flick to the neighbour of where the touch began, a slow drag to the
    /// nearest card.
    func testCardSnap() {
        let stride: CGFloat = 100
        XCTAssertEqual(CardSnap.card(target: 160, velocity: 0, stride: stride, count: 7, start: 0), 2, "slow drag: nearest")
        XCTAssertEqual(CardSnap.card(target: 40, velocity: 0, stride: stride, count: 7, start: 0), 0)
        XCTAssertEqual(CardSnap.card(target: 30, velocity: 0.6, stride: stride, count: 7, start: 0), 1, "a short flick still moves one")
        XCTAssertEqual(CardSnap.card(target: 450, velocity: 2, stride: stride, count: 7, start: 1), 2, "a hard flick moves one, not four")
        XCTAssertEqual(CardSnap.card(target: 90, velocity: -0.8, stride: stride, count: 7, start: 1), 0)
        XCTAssertEqual(CardSnap.card(target: 700, velocity: 0.8, stride: stride, count: 7, start: 6), 6, "never past the last card")
        XCTAssertEqual(CardSnap.card(target: -50, velocity: -0.8, stride: stride, count: 7, start: 0), 0)
    }
}
