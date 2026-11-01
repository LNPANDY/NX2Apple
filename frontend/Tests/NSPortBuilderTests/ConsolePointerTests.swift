import XCTest
@testable import NSPortBuilder

/// When the pointer hides in console mode. Nothing here touches NSCursor.
final class ConsolePointerTests: XCTestCase {
    private let here = CGPoint(x: 10, y: 10)

    func testHidesAfterAboutOneAndAHalfIdleSecondsAndShowsOnMovement() {
        var idle = PointerIdle()
        XCTAssertEqual(idle.tick(now: 0, location: here, buttonDown: false, over: true), .none)
        XCTAssertEqual(idle.tick(now: 1.0, location: here, buttonDown: false, over: true), .none)
        XCTAssertEqual(idle.tick(now: 1.25, location: here, buttonDown: false, over: true), .hide)
        XCTAssertEqual(idle.tick(now: 2, location: here, buttonDown: false, over: true), .none, "hidden once")
        XCTAssertEqual(idle.tick(now: 2.25, location: CGPoint(x: 11, y: 10), buttonDown: false, over: true), .show)
        XCTAssertEqual(idle.tick(now: 3, location: CGPoint(x: 11, y: 10), buttonDown: false, over: true), .none, "the idle time starts again")
        XCTAssertEqual(idle.tick(now: 3.5, location: CGPoint(x: 11, y: 10), buttonDown: false, over: true), .hide)
    }

    func testTheRealDelayIsNeverMoreThanOneAndAHalfSeconds() {
        XCTAssertEqual(PointerIdle().idleSeconds, 1.25)
        XCTAssertLessThanOrEqual(PointerIdle().idleSeconds + ConsolePointer.pollSeconds, 1.5)
        var idle = PointerIdle()
        var now = 0.0
        _ = idle.tick(now: now, location: here, buttonDown: false, over: true)
        var step = PointerIdle.Step.none
        while step == .none && now < 10 {
            now += ConsolePointer.pollSeconds
            step = idle.tick(now: now, location: here, buttonDown: false, over: true)
        }
        XCTAssertEqual(step, .hide)
        XCTAssertLessThanOrEqual(now, 1.5)
    }

    func testAClickOrAScrollShowsItAndRestartsTheWait() {
        var idle = PointerIdle()
        _ = idle.tick(now: 0, location: here, buttonDown: false, over: true)
        XCTAssertEqual(idle.tick(now: 1.5, location: here, buttonDown: false, over: true), .hide)
        XCTAssertEqual(idle.activity(now: 4), .show)
        XCTAssertEqual(idle.activity(now: 4.1), .none, "nothing to show")
        XCTAssertEqual(idle.tick(now: 5, location: here, buttonDown: false, over: true), .none)
        XCTAssertEqual(idle.tick(now: 5.5, location: here, buttonDown: false, over: true), .hide)
        XCTAssertEqual(idle.tick(now: 5.75, location: here, buttonDown: true, over: true), .show, "a held button is activity")
    }

    func testStaysVisibleOutsideTheWindowAndComesBackWhenItLeaves() {
        var idle = PointerIdle()
        _ = idle.tick(now: 0, location: here, buttonDown: false, over: false)
        XCTAssertEqual(idle.tick(now: 10, location: here, buttonDown: false, over: false), .none, "not over the launcher: left alone")
        XCTAssertEqual(idle.tick(now: 11, location: here, buttonDown: false, over: true), .hide)
        XCTAssertEqual(idle.tick(now: 12, location: here, buttonDown: false, over: false), .show, "the launcher lost the pointer or the focus")
    }

    func testEndingTheConsoleShowsAHiddenPointerOnce() {
        var idle = PointerIdle()
        XCTAssertEqual(idle.reset(), .none)
        _ = idle.tick(now: 0, location: here, buttonDown: false, over: true)
        _ = idle.tick(now: 1.5, location: here, buttonDown: false, over: true)
        XCTAssertEqual(idle.reset(), .show)
        XCTAssertEqual(idle.reset(), .none)
    }

    @MainActor func testStoppingUnhidesWhatWasHidden() {
        var balance = 0
        let pointer = ConsolePointer(window: { nil }, hide: { balance += 1 }, show: { balance -= 1 })
        pointer.start()
        pointer.stop()
        XCTAssertEqual(balance, 0)
    }
}
