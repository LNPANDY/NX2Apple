import XCTest
@testable import NXCore

/// #816: the play history console mode records per title ID, and the file it keeps it in.
final class PlaySessionsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testASessionAddsItsTimeWithoutThePausedPart() throws {
        var sessions = PlaySessions()
        sessions.start(titleID: "0100abc", at: start)
        XCTAssertEqual(sessions["0100ABC"]?.isOpen, true, "title IDs are one record in either case")
        sessions.end(titleID: "0100ABC", at: start.addingTimeInterval(3600), paused: 600)
        let record = try XCTUnwrap(sessions["0100abc"])
        XCTAssertEqual(record.seconds, 3000, "the paused ten minutes are not played time")
        XCTAssertEqual(record.sessions, 1)
        XCTAssertFalse(record.isOpen)
        XCTAssertEqual(record.lastPlayed, start.addingTimeInterval(3600), "last played is when the session ended")
        XCTAssertFalse(record.endedUnexpectedly)

        sessions.start(titleID: "0100ABC", at: start.addingTimeInterval(7200))
        XCTAssertEqual(sessions["0100ABC"]?.lastPlayed, start.addingTimeInterval(7200), "while it runs, from its start")
        sessions.end(titleID: "0100ABC", at: start.addingTimeInterval(7260), unexpectedly: true)
        XCTAssertEqual(sessions["0100ABC"]?.seconds, 3060)
        XCTAssertEqual(sessions["0100ABC"]?.sessions, 2)
        XCTAssertEqual(sessions["0100ABC"]?.endedUnexpectedly, true)
    }

    func testAnEndWithoutAnOpenSessionChangesNothing() {
        var sessions = PlaySessions()
        sessions.end(titleID: "A", at: start)
        XCTAssertNil(sessions["A"], "a game the launcher did not start has no history")
        sessions.start(titleID: "A", at: start)
        sessions.end(titleID: "A", at: start.addingTimeInterval(60))
        sessions.end(titleID: "A", at: start.addingTimeInterval(600))
        XCTAssertEqual(sessions["A"]?.seconds, 60, "a second end of the same session counts nothing")
        sessions.start(titleID: "B", at: start)
        sessions.end(titleID: "B", at: start.addingTimeInterval(-5))
        XCTAssertEqual(sessions["B"]?.seconds, 0, "a clock that went back adds no negative time")
        sessions.start(titleID: "", at: start)
        XCTAssertNil(sessions[""])
    }

    func testRecentTitlesNewestFirstWithAStableTie() {
        var sessions = PlaySessions()
        sessions.start(titleID: "B", at: start)
        sessions.start(titleID: "A", at: start)
        sessions.start(titleID: "C", at: start.addingTimeInterval(10))
        XCTAssertEqual(sessions.recentTitleIDs, ["C", "A", "B"])
    }

    func testTheFileRoundTripsAndBadFilesAreAnEmptyHistory() throws {
        var sessions = PlaySessions()
        sessions.start(titleID: "A", at: start)
        sessions.end(titleID: "A", at: start.addingTimeInterval(90), paused: 30)
        XCTAssertEqual(PlaySessions.decode(sessions.encode()), sessions)
        XCTAssertEqual(PlaySessions.decode(Data("not json".utf8)), PlaySessions())
        XCTAssertEqual(PlaySessions.decode(Data(#"{"schema":1,"games":{"a":{"lastStart":"nope"}}}"#.utf8)), PlaySessions())
        let text = try XCTUnwrap(String(data: sessions.encode(), encoding: .utf8))
        XCTAssertTrue(text.contains("\"schema\""), text)
        XCTAssertTrue(text.contains("2027-01-15T08:00:00Z"), "dates as ISO 8601: \(text)")
    }

    func testTheStoreKeepsTheHistoryInItsFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PlaySessionsTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("state/play-sessions.json")
        let store = PlaySessionStore(file: file)
        XCTAssertNil(store["A"])
        store.started(titleID: "A", at: start)
        store.ended(titleID: "A", at: start.addingTimeInterval(120))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the folder is made")
        let again = PlaySessionStore(file: file)
        XCTAssertEqual(again["A"]?.seconds, 120, "an update of the app reads the same file")
        let memory = PlaySessionStore(file: nil)
        memory.started(titleID: "A", at: start)
        XCTAssertEqual(memory["A"]?.sessions, 1)
        XCTAssertTrue(PlaySessionStore.defaultFile.path.hasSuffix("Application Support/NS Port Builder/play-sessions.json"), "beside library.json")
    }
}
