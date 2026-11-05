import XCTest
@testable import ShellUI

/// The events between two view updates all reach the library, in order: one value kept only the last one written.
final class ShellInputLogTests: XCTestCase {
    func testEveryEventSinceTheLastSeenInOrder() {
        var log = ShellInputLog()
        XCTAssertEqual(log.last, 0)
        log.append(.activate)
        log.append(.activate, released: true)
        log.append(.back)
        log.append(.back, released: true)
        let seen = log.since(0)
        XCTAssertEqual(seen.map(\.action), [.activate, .activate, .back, .back])
        XCTAssertEqual(seen.map(\.released), [false, true, false, true])
        XCTAssertEqual(seen.map(\.sequence), [1, 2, 3, 4])
        XCTAssertEqual(log.since(2).map(\.sequence), [3, 4])
        XCTAssertEqual(log.since(4), [])
    }
    /// Two buttons let go in one controller change, and a press with a release in one: each one counts on the gate.
    @MainActor func testReleasesInOneUpdateKeepTheHeldCountRight() {
        var log = ShellInputLog()
        var now: TimeInterval = 10
        let gate = InputGate(clock: { now }, echoes: true)
        var seen = 0
        func update() {
            for event in log.since(seen) {
                if event.released { gate.controllerUp(event.action) } else { gate.controller(event.action) }
            }
            seen = log.last
        }
        log.append(.activate)
        log.append(.back)
        update()
        log.append(.activate, released: true)
        log.append(.back, released: true)
        log.append(.left, released: true)
        log.append(.up)
        update()
        now = 11.1
        XCTAssertFalse(gate.isSystemEcho, "both buttons came up: nothing held, the window is over")
    }
    func testOnlyTheLastEventsAreKept() {
        var log = ShellInputLog()
        for _ in 0..<(ShellInputLog.kept + 10) { log.append(.down) }
        XCTAssertEqual(log.events.count, ShellInputLog.kept)
        XCTAssertEqual(log.last, ShellInputLog.kept + 10)
        XCTAssertEqual(log.since(0).first?.sequence, 11)
    }
}
