import Foundation
import Testing
@testable import ShellHost
import ShellUI

private final class PlayClock: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
}

private struct PlayOkLauncher: GameLauncher {
    func launch(_ game: LaunchableGame) async throws {}
}

@Suite struct PlayHistoryTests {
    @Test func pauseAndResumeExcludeBackgroundHoursWithoutExtraSession() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("playhistory-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("play-history.json")

        let t0 = utc.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 10, minute: 0))!
        let store = PlayHistoryStore(fileURL: file)
        store.sessionDidStart(titleID: "0100aa0000010000", title: "Starlight Odyssey", at: t0, calendar: utc)
        // 20 min active play
        store.sessionWillPause(at: t0.addingTimeInterval(1200), calendar: utc)
        // 3 hours suspended in background (not counted)
        store.sessionDidResume(at: t0.addingTimeInterval(12_000))
        // 25 min active play
        store.sessionDidEnd(at: t0.addingTimeInterval(13_500), calendar: utc)

        let reloaded = PlayHistoryStore(fileURL: file)
        let record = try #require(reloaded["0100AA0000010000"])
        #expect(record.title == "Starlight Odyssey")
        #expect(record.sessions == 1)
        #expect(abs(record.seconds - 2700) < 0.01)
        #expect(abs((record.dailySeconds["2026-11-13"] ?? 0) - 2700) < 0.01)
    }

    @Test func staleSessionRecoveryUsesLastForegroundCheckpoint() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("playhistory-stale-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("play-history.json")

        let t0 = utc.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 14, minute: 0))!
        do {
            let store = PlayHistoryStore(fileURL: file)
            store.sessionDidStart(titleID: Fixtures.orbit, title: "Orbit Fixture", at: t0, calendar: utc)
            store.checkpoint(at: t0.addingTimeInterval(900), calendar: utc)
            // Simulate process termination without sessionDidEnd
        }

        let recovered = PlayHistoryStore(fileURL: file)
        recovered.recoverStaleSessionIfNeeded(calendar: utc)
        let record = try #require(recovered[Fixtures.orbit])
        #expect(record.sessions == 1)
        #expect(abs(record.seconds - 900) < 0.01)
        #expect(record.lastPlayed == t0.addingTimeInterval(900))
    }

    @Test @MainActor func historySurvivesGameDeletionAndUpdatesHostSnapshot() async throws {
        let box = try Sandbox()
        try box.giveAppData(Fixtures.orbit)
        let clock = PlayClock(Date(timeIntervalSince1970: 1_800_000_000))
        let config = box.config(now: { clock.date })
        let model = ShellHostModel(config: config, launcher: PlayOkLauncher())

        await model.playNow(Fixtures.orbit)
        clock.date = clock.date.addingTimeInterval(5100) // 1 hr, 25 min
        model.endActiveSession()

        let orbitDetail = try #require(model.details.first { $0.id == Fixtures.orbit })
        #expect(orbitDetail.playSummary != nil)
        #expect(orbitDetail.game.recentlyPlayed?.contains("Played today") == true)
        #expect(model.activityLog.gamesPlayedCount == 1)
        #expect(model.activityLog.totalSessions == 1)
        #expect(model.activityLog.entries.first?.isInstalled == true)

        model.deleteGame(Fixtures.orbit, saves: true)
        #expect(!model.details.contains { $0.id == Fixtures.orbit })
        #expect(model.activityLog.gamesPlayedCount == 1, "play history lives outside Documents/games/<titleID>/")
        let entry = try #require(model.activityLog.entries.first)
        #expect(entry.id == Fixtures.orbit)
        #expect(entry.title == "Orbit Fixture")
        #expect(!entry.isInstalled)
    }
}
