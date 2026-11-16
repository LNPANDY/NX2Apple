import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

/// The controller focus: moves go to the nearest target in the direction and stay in their row when they can, left / right
/// change a value where the target holds one, and the first press only shows the focus.
final class PadFocusTests: IsolatedDefaultsTestCase {
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

    func testScrolledTargetKeepsFocusUntilItsLazyFrameArrives() {
        let f = grid()
        var activations = 0
        f.register("card.next", .init(activate: { activations += 1 }))
        f.focusAfterScroll("card.next")
        f.show(default: "tab.a"); f.move(dx: 0, dy: 1); f.activate()
        XCTAssertEqual(f.focused, "card.next")
        XCTAssertEqual(activations, 0)
        f.setFrames([.init(id: "card.next", frame: CGRect(x: 0, y: 300, width: 200, height: 120))], scope: "main")
        f.activate(); XCTAssertEqual(activations, 1)
        f.focusAfterScroll("card.unmounted")
        f.scope = "sheet"
        f.setFrames([.init(id: "close", frame: .init(x: 0, y: 0, width: 44, height: 44))], scope: "sheet")
        f.show(default: "close"); XCTAssertEqual(f.focused, "close")
    }

    func testReturnBelongsToTheNativeDefaultActionAndSpaceTogglesRows() {
        let f = grid()
        var toggles = 0
        f.register("tab.a", .init(activate: { toggles += 1 }))
        XCTAssertFalse(PadKeyboardInput.handle(36, focus: f, back: {}))
        XCTAssertFalse(PadKeyboardInput.handle(76, focus: f, back: {}))
        XCTAssertEqual(toggles, 0)
        f.show(default: "tab.a")
        XCTAssertFalse(PadKeyboardInput.handle(36, focus: f, back: {}))
        XCTAssertTrue(PadKeyboardInput.handle(49, focus: f, back: {}))
        XCTAssertEqual(toggles, 1)
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

    func testTargetsBehindAnotherScopeCannotActivateAndClosingRestoresFocus() {
        let f = grid()
        var activated = 0
        f.register("card.2", .init(activate: { activated += 1 }))
        f.show(default: "card.2")
        f.scope = "launch"
        f.setFrames([.init(id: "opt.done", frame: .init(x: 0, y: 0, width: 80, height: 30))], scope: "launch")
        f.focused = "card.2"
        f.activate()
        XCTAssertEqual(activated, 0, "a retained main-window target must not act through a sheet")
        f.focused = "opt.done"
        f.scope = "main"
        XCTAssertEqual(f.focused, "card.2", "closing a sheet returns to the original control")
    }

    func testReopeningAQuestionNeverRestoresItsPreviousDestructiveSelection() {
        let f = grid()
        f.show(default: "card.2")
        f.setFrames([.init(id: "remove.cancel", frame: .init(x: 0, y: 0, width: 80, height: 30)),
                     .init(id: "remove.confirm", frame: .init(x: 100, y: 0, width: 80, height: 30))], scope: "remove")
        f.scope = "remove"
        f.show(default: "remove.confirm")
        f.scope = "main"
        XCTAssertEqual(f.focused, "card.2")
        f.scope = "remove"
        XCTAssertNil(f.focused, "new presentations start fresh, only returning to a parent restores focus")
        f.show(default: nil)
        XCTAssertEqual(f.focused, "remove.cancel")
    }
}
