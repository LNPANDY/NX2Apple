import XCTest
@testable import ShellUI

final class FocusNavigationTests: XCTestCase {
    private func target(_ id: String, _ x: CGFloat, _ y: CGFloat) -> FocusTarget {
        FocusTarget(id: id, frame: CGRect(x: x, y: y, width: 44, height: 44), activate: {})
    }
    func testDirectionalNavigationPrefersSameRowAndDoesNotWrap() {
        let targets = [target("a", 0, 0), target("b", 80, 0), target("c", 0, 100), target("d", 80, 100)]
        XCTAssertEqual(FocusNavigation.next(from: "a", action: .right, targets: targets), "b")
        XCTAssertEqual(FocusNavigation.next(from: "b", action: .down, targets: targets), "d")
        XCTAssertEqual(FocusNavigation.next(from: "d", action: .left, targets: targets), "c")
        XCTAssertEqual(FocusNavigation.next(from: "c", action: .left, targets: targets), "c")
        XCTAssertEqual(FocusNavigation.next(from: "missing", action: .down, targets: targets), "a")
        XCTAssertNil(FocusNavigation.next(from: nil, action: .down, targets: []))
    }
}
