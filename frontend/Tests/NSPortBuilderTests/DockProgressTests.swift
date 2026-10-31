import XCTest
@testable import NSPortBuilder

/// The Dock tile's text for a running build (DockProgress): the visible part is
/// pure, so it is tested; the AppKit half (drawing the tile) is not.
final class DockProgressTests: XCTestCase {
    func testThePercentTextForAProgressFraction() {
        XCTAssertEqual(DockProgress.percentText(0), "0%")
        XCTAssertEqual(DockProgress.percentText(0.404), "40%", "rounded, never 40.4%")
        XCTAssertEqual(DockProgress.percentText(1), "100%")
    }

    func testNilAndOddValuesClearTheTile() {
        XCTAssertNil(DockProgress.percentText(nil), "build not running: the plain icon comes back")
        XCTAssertNil(DockProgress.percentText(-0.2))
        XCTAssertNil(DockProgress.percentText(1.5))
        XCTAssertNil(DockProgress.percentText(.nan))
    }
}
