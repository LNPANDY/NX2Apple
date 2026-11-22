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

    func testSchemaOneMigrationPreservesExistingRecords() throws {
        let legacy = #"""
        {
          "schema": 1,
          "games": {
            "0100aa0000010000": {
              "lastStart": "2026-11-10T10:00:00Z",
              "lastEnd": "2026-11-10T11:30:00Z",
              "seconds": 5400,
              "sessions": 3,
              "endedUnexpectedly": false
            }
          }
        }
        """#
        let decoded = PlaySessions.decode(Data(legacy.utf8))
        let record = try XCTUnwrap(decoded["0100AA0000010000"])
        XCTAssertEqual(record.seconds, 5400)
        XCTAssertEqual(record.sessions, 3)
        XCTAssertEqual(record.averageSeconds, 1800)
        XCTAssertEqual(record.firstPlayed, record.lastStart)
        XCTAssertNil(record.title)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        XCTAssertTrue(record.playedDays(calendar: utc).contains("2026-11-10"))
    }

    func testMidnightSessionSplitsAcrossDailyBucketsAndKeepsTitle() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let night = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 23, minute: 0)))
        let morning = night.addingTimeInterval(7200)

        var sessions = PlaySessions()
        sessions.start(titleID: "0100aa0000010000", title: "Starlight Odyssey", at: night, calendar: utc)
        sessions.end(titleID: "0100AA0000010000", at: morning, calendar: utc)

        sessions.start(titleID: "0100AA0000010000", title: nil, at: morning.addingTimeInterval(3600), calendar: utc)
        sessions.end(titleID: "0100AA0000010000", at: morning.addingTimeInterval(5400), calendar: utc)

        let record = try XCTUnwrap(sessions["0100AA0000010000"])
        XCTAssertEqual(record.title, "Starlight Odyssey", "stored title stays intact when removed from library")
        XCTAssertEqual(record.firstPlayed, night)
        XCTAssertEqual(record.sessions, 2)
        XCTAssertEqual(record.seconds, 9000, accuracy: 0.01)
        XCTAssertEqual(record.dailySeconds["2026-11-12"] ?? 0, 3600, accuracy: 0.01)
        XCTAssertEqual(record.dailySeconds["2026-11-13"] ?? 0, 5400, accuracy: 0.01)
        XCTAssertEqual(sessions.totalSeconds, 9000, accuracy: 0.01)
        XCTAssertEqual(sessions.totalSessions, 2)
        XCTAssertEqual(sessions.gamesPlayedCount, 1)
        XCTAssertEqual(sessions.activeDays(calendar: utc), ["2026-11-12", "2026-11-13"])
    }
}
