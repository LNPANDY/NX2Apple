import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

/// The controller focus: moves go to the nearest target in the direction and stay in their row when they can, left / right
/// change a value where the target holds one, and the first press only shows the focus.
final class PadFocusTests: XCTestCase {
    private func grid() -> PadFocus {
        let f = PadFocus()
        // a row of three cards under a tab bar of two, and one button far right on the tab bar's line
        f.setFrames([.init(id: "tab.a", frame: CGRect(x: 0, y: 0, width: 80, height: 30)),
                     .init(id: "tab.b", frame: CGRect(x: 100, y: 0, width: 80, height: 30)),
                     .init(id: "build", frame: CGRect(x: 900, y: 0, width: 80, height: 30)),
                     .init(id: "card.1", frame: CGRect(x: 0, y: 300, width: 200, height: 120)),
                     .init(id: "card.2", frame: CGRect(x: 220, y: 300, width: 200, height: 120)),
                     .init(id: "card.3", frame: CGRect(x: 440, y: 300, width: 200, height: 120))], scope: "main")
        return f
    }

    func testFirstShowFocusesTheDefaultOrTheTopLeft() {
        let f = grid()
        f.show(default: "card.2")
        XCTAssertEqual(f.focused, "card.2")
        XCTAssertTrue(f.visible)
        let g = grid()
        g.show(default: "missing")
        XCTAssertEqual(g.focused, "tab.a")
    }

    func testMovesStayInTheRowAndFindTheNearestAboveOrBelow() {
        let f = grid()
        f.show(default: "card.1")
        f.move(dx: 1, dy: 0); XCTAssertEqual(f.focused, "card.2")
        f.move(dx: 1, dy: 0); XCTAssertEqual(f.focused, "card.3")
        f.move(dx: 1, dy: 0); XCTAssertEqual(f.focused, "card.3", "nothing further right in reach of the row")
        f.move(dx: 0, dy: -1); XCTAssertEqual(f.focused, "tab.b", "up from the third card: the tab nearest above, not the far button")
        f.move(dx: 0, dy: 1); XCTAssertEqual(f.focused, "card.1")
    }

    func testLeftAndRightChangeAValueWhereTheTargetHoldsOne() {
        let f = grid()
        var value = 0, activated = 0
        f.register("card.2", .init(activate: { activated += 1 }, adjust: { value += $0 }))
        f.show(default: "card.2")
        f.horizontal(1); f.horizontal(1); f.horizontal(-1)
        XCTAssertEqual(value, 1)
        XCTAssertEqual(f.focused, "card.2", "a value target keeps the focus")
        f.activate(); XCTAssertEqual(activated, 1)
        f.scope = "launch"
        XCTAssertNil(f.focused, "another scope starts without a focus")
    }

    /// A card the library filter hides keeps its handler but loses its frame: A does not start it, and moves skip it.
    func testAHiddenTargetIsNeitherActivatedNorReached() {
        let f = grid()
        var activated = 0
        f.register("card.2", .init(activate: { activated += 1 }, adjust: nil))
        f.show(default: "card.2")
        f.setFrames([.init(id: "card.1", frame: CGRect(x: 0, y: 300, width: 200, height: 120)),
                     .init(id: "card.3", frame: CGRect(x: 440, y: 300, width: 200, height: 120))], scope: "main")
        f.activate()
        XCTAssertEqual(activated, 0)
        f.focused = "card.1"
        f.move(dx: 1, dy: 0)
        XCTAssertEqual(f.focused, "card.3")
    }
}
