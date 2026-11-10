import XCTest
@testable import NX2Apple

/// The console's one notice queue (LNPANDY/NX2Apple#1004).
final class ConsoleNoticeQueueTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testOneNoticeShowsAtATimeAndTheNextComesWhenItsTimeIsUp() {
        var q = ConsoleNoticeQueue()
        q.post(kind: "controller", message: "A connected", now: t0, suppressed: false)
        q.post(kind: "error", message: "Start failed", now: t0, suppressed: false)
        XCTAssertEqual(q.current?.message, "A connected")
        q.advance(now: t0.addingTimeInterval(ConsoleNoticeQueue.duration - 0.1), suppressed: false)
        XCTAssertEqual(q.current?.message, "A connected")
        q.advance(now: t0.addingTimeInterval(ConsoleNoticeQueue.duration), suppressed: false)
        XCTAssertEqual(q.current?.message, "Start failed")
        q.advance(now: t0.addingTimeInterval(2 * ConsoleNoticeQueue.duration), suppressed: false)
        XCTAssertNil(q.current)
    }

    func testANoticeOfTheKindThatShowsOrWaitsReplacesItAndABurstBuildsNoLine() {
        var q = ConsoleNoticeQueue()
        q.post(kind: "controller", message: "A connected", now: t0, suppressed: false)
        let first = q.current?.id
        q.post(kind: "controller", message: "B connected", now: t0.addingTimeInterval(1), suppressed: false)
        XCTAssertEqual(q.current?.message, "B connected")
        XCTAssertNotEqual(q.current?.id, first)
        XCTAssertEqual(q.until, t0.addingTimeInterval(1 + ConsoleNoticeQueue.duration))
        q.post(kind: "error", message: "e1", now: t0.addingTimeInterval(1), suppressed: false)
        q.post(kind: "error", message: "e2", now: t0.addingTimeInterval(1), suppressed: false)
        XCTAssertEqual(q.waiting.map(\.message), ["e2"])
    }

    func testNothingShowsOrWaitsWhileAGameStarts() {
        var q = ConsoleNoticeQueue()
        q.post(kind: "controller", message: "A", now: t0, suppressed: false)
        q.post(kind: "error", message: "B", now: t0, suppressed: false)
        q.advance(now: t0, suppressed: true)
        XCTAssertNil(q.current); XCTAssertTrue(q.waiting.isEmpty)
        q.post(kind: "controller", message: "C", now: t0, suppressed: true)
        XCTAssertNil(q.current)
    }
}
