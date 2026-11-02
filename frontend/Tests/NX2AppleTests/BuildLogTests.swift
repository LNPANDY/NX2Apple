import Combine
import XCTest
@testable import NXModel

/// LNPANDY/NX2Apple#387, step 3: the build log is a store of its own and needs no SwiftUI.
@MainActor final class BuildLogTests: XCTestCase {
    func testAppendAddsText() {
        let log = BuildLog()
        log.append("one\n")
        log.append("two\n")
        XCTAssertEqual(log.text, "one\ntwo\n")
    }

    func testTheTextKeepsItsTail() {
        let log = BuildLog()
        let line = String(repeating: "x", count: 99) + "\n"   // 100 characters
        for n in 0..<150 { log.append(n == 149 ? "last\n" : line) }
        XCTAssertLessThanOrEqual(log.text.count, BuildLog.limit)
        XCTAssertGreaterThanOrEqual(log.text.count, BuildLog.keep)
        XCTAssertTrue(log.text.hasSuffix("last\n"), "the newest text stays")
    }

    func testTextUnderTheLimitIsKept() {
        let log = BuildLog()
        log.append(String(repeating: "y", count: BuildLog.limit))
        XCTAssertEqual(log.text.count, BuildLog.limit)
    }

    func testFeedReturnsCompleteLines() {
        let log = BuildLog()
        XCTAssertEqual(log.feed("a\nb\n"), ["a", "b"])
        XCTAssertNil(log.flush())
    }

    func testALineAcrossChunkBoundariesIsJoined() {
        let log = BuildLog()
        XCTAssertEqual(log.feed("hel"), [])
        XCTAssertEqual(log.feed("lo wor"), [])
        XCTAssertEqual(log.feed("ld\nnext"), ["hello world"])
        XCTAssertEqual(log.feed("\n"), ["next"])
    }

    func testCarriageReturnsAreDropped() {
        let log = BuildLog()
        // A "\r" inside a line goes, as before. ("\r\n" is one Character in Swift, so it never matches "\n": the old code
        // had the same gap, and the script's output has plain "\n".)
        XCTAssertEqual(log.feed("a\rb\nc"), ["ab"])
        XCTAssertEqual(log.flush(), "c")
    }

    func testFlushReturnsThePartialLineOnce() {
        let log = BuildLog()
        _ = log.feed("done\nno newline")
        XCTAssertEqual(log.flush(), "no newline")
        XCTAssertNil(log.flush())
    }

    func testFeedDoesNotTouchTheText() {
        let log = BuildLog()
        _ = log.feed("a\nb\n")
        XCTAssertEqual(log.text, "")
    }

    func testClearEmptiesTheTextAndThePartialLine() {
        let log = BuildLog()
        log.append("old\n")
        _ = log.feed("half")
        log.clear()
        XCTAssertEqual(log.text, "")
        XCTAssertNil(log.flush())
        XCTAssertEqual(log.feed("new\n"), ["new"])
    }

    func testOnlyTheTextPublishes() {
        let log = BuildLog()
        var changes = 0
        let sink = log.objectWillChange.sink { changes += 1 }
        _ = log.feed("a\nb")
        XCTAssertEqual(changes, 0, "splitting lines is not a change of the text")
        log.append("a\n")
        XCTAssertEqual(changes, 1)
        sink.cancel()
    }
}
