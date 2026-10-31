import XCTest
@testable import NSPortBuilder

/// The Dock tile's text for a running build (DockProgress): the text is pure, the tile view is built without a Dock.
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

    @MainActor
    func testTheTileHoldsTheIconAndAGrayBar() {
        let icon = NSImage(size: NSSize(width: 64, height: 64))
        let tile = DockProgress.makeTileView(fraction: 0.5, icon: icon, size: 128)
        XCTAssertEqual(tile.frame.size, NSSize(width: 128, height: 128))
        XCTAssertEqual(tile.subviews.count, 2, "the icon and the bar")
        XCTAssertNotNil((tile.subviews.last as? NSImageView)?.image)
    }
}
