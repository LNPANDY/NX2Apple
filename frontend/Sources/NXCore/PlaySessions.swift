import Combine
import Foundation

/// What the launcher knows about the times a game was played (#816, #1161): a session is recorded when a game starts and ends.
/// Nothing comes from the game itself. Kept per title ID, so a rebuilt, moved or removed game keeps its history.
package struct PlayRecord: Codable, Equatable, Sendable {
    /// Last known display name, kept so a game removed from the library still has a readable name in the activity log.
    package var title: String?
    /// When the first recorded session started. Older schema-1 records without this field fall back to `lastStart`.
    package var firstStart: Date?
    /// When the last session started.
    package var lastStart: Date
    /// When the last session ended, nil while it runs or when the launcher never saw it end (it quit first).
    package var lastEnd: Date?
    /// The time played over all the sessions that ended, without the time a session was paused in the background.
    package var seconds: Double
    /// How many sessions started.
    package var sessions: Int
    /// The last session ended without a normal quit (GameExit.stoppedUnexpectedly).
    package var endedUnexpectedly: Bool
    /// Seconds played per local calendar day (`YYYY-MM-DD`).
    package var dailySeconds: [String: Double]

    package init(
        title: String? = nil,
        firstStart: Date? = nil,
        lastStart: Date,
        lastEnd: Date? = nil,
        seconds: Double = 0,
        sessions: Int = 1,
        endedUnexpectedly: Bool = false,
        dailySeconds: [String: Double] = [:]
    ) {
        self.title = title
        self.firstStart = firstStart
        self.lastStart = lastStart
        self.lastEnd = lastEnd
        self.seconds = seconds
        self.sessions = sessions
        self.endedUnexpectedly = endedUnexpectedly
        self.dailySeconds = dailySeconds
    }

    private enum CodingKeys: String, CodingKey {
        case title, firstStart, lastStart, lastEnd, seconds, sessions, endedUnexpectedly, dailySeconds
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        firstStart = try c.decodeIfPresent(Date.self, forKey: .firstStart)
        lastStart = try c.decode(Date.self, forKey: .lastStart)
        lastEnd = try c.decodeIfPresent(Date.self, forKey: .lastEnd)
        seconds = try c.decode(Double.self, forKey: .seconds)
        sessions = try c.decode(Int.self, forKey: .sessions)
        endedUnexpectedly = try c.decodeIfPresent(Bool.self, forKey: .endedUnexpectedly) ?? false
        dailySeconds = try c.decodeIfPresent([String: Double].self, forKey: .dailySeconds) ?? [:]
    }

    /// When the game was first played.
    package var firstPlayed: Date {
        guard let firstStart, firstStart.timeIntervalSinceReferenceDate <= lastStart.timeIntervalSinceReferenceDate else {
            return lastStart
        }
        return firstStart
    }

    /// When the game was last played: the end of the last session, or its start while it runs or when its end is not known.
    package var lastPlayed: Date {
        guard let lastEnd, lastEnd.timeIntervalSinceReferenceDate >= lastStart.timeIntervalSinceReferenceDate else { return lastStart }
        return lastEnd
    }

    /// A session started and has not ended yet.
    package var isOpen: Bool {
        guard let lastEnd else { return true }
        return lastEnd.timeIntervalSinceReferenceDate < lastStart.timeIntervalSinceReferenceDate
    }

    /// Average seconds played per session.
    package var averageSeconds: Double {
        guard sessions > 0, seconds > 0 else { return 0 }
        return seconds / Double(sessions)
    }

    /// Calendar day keys (`YYYY-MM-DD`) on which this game was played.
    package func playedDays(calendar: Calendar = .current) -> Set<String> {
        var keys = Set(dailySeconds.keys)
        if sessions > 0 {
            keys.insert(PlaySessions.dayKey(for: firstPlayed, calendar: calendar))
            keys.insert(PlaySessions.dayKey(for: lastPlayed, calendar: calendar))
        }
        return keys
    }

    package static func == (lhs: PlayRecord, rhs: PlayRecord) -> Bool {
        lhs.title == rhs.title
            && lhs.firstStart?.timeIntervalSinceReferenceDate == rhs.firstStart?.timeIntervalSinceReferenceDate
            && lhs.lastStart.timeIntervalSinceReferenceDate == rhs.lastStart.timeIntervalSinceReferenceDate
            && lhs.lastEnd?.timeIntervalSinceReferenceDate == rhs.lastEnd?.timeIntervalSinceReferenceDate
            && lhs.seconds == rhs.seconds
            && lhs.sessions == rhs.sessions
            && lhs.endedUnexpectedly == rhs.endedUnexpectedly
            && lhs.dailySeconds == rhs.dailySeconds
    }
}

/// Every game's record, keyed by title ID. A value type: the store (`PlaySessionStore`) reads and writes it.
package struct PlaySessions: Equatable, Sendable {
    package private(set) var records: [String: PlayRecord] = [:]

    package init(records: [String: PlayRecord] = [:]) { self.records = records }

    package subscript(_ titleID: String) -> PlayRecord? { records[Self.key(titleID)] }

    /// A session of the game starts now.
    package mutating func start(titleID: String, title: String? = nil, at date: Date, calendar: Calendar = .current) {
        let key = Self.key(titleID)
        guard !key.isEmpty else { return }
        var record = records[key] ?? PlayRecord(firstStart: date, lastStart: date, sessions: 0)
        if let first = record.firstStart {
            if date.timeIntervalSinceReferenceDate < first.timeIntervalSinceReferenceDate {
                record.firstStart = date
            }
        } else {
            record.firstStart = record.sessions > 0 ? record.lastStart : date
        }
        if let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            record.title = trimmed
        }
        record.lastStart = date
        record.sessions += 1
        record.endedUnexpectedly = false
        let day = Self.dayKey(for: date, calendar: calendar)
        if record.dailySeconds[day] == nil {
            record.dailySeconds[day] = 0
        }
        records[key] = record
    }

    /// The open session ends now. `paused`: the seconds it spent paused in the background, not counted as played. A session that is not
    /// open (the start was never recorded, or it ended already) changes nothing.
    package mutating func end(
        titleID: String,
        at date: Date,
        paused: Double = 0,
        unexpectedly: Bool = false,
        calendar: Calendar = .current
    ) {
        let key = Self.key(titleID)
        guard var record = records[key], record.isOpen else { return }
        let rawSpan = date.timeIntervalSince(record.lastStart)
        let played = rawSpan - max(paused, 0)
        if played.isFinite, played > 0 {
            record.seconds += played
            Self.addDailySeconds(
                into: &record.dailySeconds,
                from: record.lastStart,
                to: date,
                played: played,
                calendar: calendar
            )
        }
        record.lastEnd = date.timeIntervalSinceReferenceDate >= record.lastStart.timeIntervalSinceReferenceDate ? date : record.lastStart
        record.endedUnexpectedly = unexpectedly
        records[key] = record
    }

    /// Distributes `played` seconds across each local calendar day spanned from `start` to `end`.
    static func addDailySeconds(
        into buckets: inout [String: Double],
        from start: Date,
        to end: Date,
        played: Double,
        calendar: Calendar
    ) {
        let totalSpan = end.timeIntervalSince(start)
        guard totalSpan > 0, played > 0 else { return }
        let ratio = min(1, played / totalSpan)
        var cursor = start
        var steps = 0
        while cursor.timeIntervalSinceReferenceDate < end.timeIntervalSinceReferenceDate, steps < 366 {
            steps += 1
            let dayStart = calendar.startOfDay(for: cursor)
            let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? end
            let sliceEnd = nextDay.timeIntervalSinceReferenceDate < end.timeIntervalSinceReferenceDate ? nextDay : end
            let sliceSeconds = max(0, sliceEnd.timeIntervalSince(cursor)) * ratio
            if sliceSeconds > 0 {
                buckets[dayKey(for: cursor, calendar: calendar), default: 0] += sliceSeconds
            }
            if sliceEnd.timeIntervalSinceReferenceDate <= cursor.timeIntervalSinceReferenceDate { break }
            cursor = sliceEnd
        }
    }

    /// Formats a date as `YYYY-MM-DD` in `calendar`.
    package static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let y = c.year ?? 1970
        let m = c.month ?? 1
        let d = c.day ?? 1
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// Total played seconds across all recorded titles.
    package var totalSeconds: Double {
        records.values.reduce(0) { $0 + max(0, $1.seconds) }
    }

    /// Total sessions started across all recorded titles.
    package var totalSessions: Int {
        records.values.reduce(0) { $0 + max(0, $1.sessions) }
    }

    /// Number of distinct titles that have been launched at least once.
    package var gamesPlayedCount: Int {
        records.values.filter { $0.sessions > 0 }.count
    }

    /// Every calendar day (`YYYY-MM-DD`) on which at least one session occurred.
    package func activeDays(calendar: Calendar = .current) -> Set<String> {
        var all = Set<String>()
        for record in records.values where record.sessions > 0 {
            all.formUnion(record.playedDays(calendar: calendar))
        }
        return all
    }

    /// Summed seconds per local calendar day (`YYYY-MM-DD`) across all recorded games.
    package var dailyTotals: [String: Double] {
        var totals: [String: Double] = [:]
        for record in records.values {
            for (day, value) in record.dailySeconds where value > 0 {
                totals[day, default: 0] += value
            }
        }
        return totals
    }

    /// The title IDs of the games played, the one played last first. Ties fall to the title ID, so the order is stable.
    package var recentTitleIDs: [String] {
        records.sorted { l, r in
            let lt = l.value.lastPlayed.timeIntervalSinceReferenceDate
            let rt = r.value.lastPlayed.timeIntervalSinceReferenceDate
            return lt == rt ? l.key < r.key : lt > rt
        }.map(\.key)
    }

    /// Title IDs are hex: the same game in upper or lower case is one record.
    static func key(_ titleID: String) -> String { titleID.trimmingCharacters(in: .whitespaces).uppercased() }

    // MARK: File

    private struct File: Codable {
        var schema = 1
        var games: [String: PlayRecord]
    }

    /// The file's JSON, dates as ISO 8601. Anything that cannot be read is an empty history, never an error that stops a game.
    package static func decode(_ data: Data) -> PlaySessions {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(File.self, from: data) else { return PlaySessions() }
        return PlaySessions(records: Dictionary(file.games.map { (key($0.key), $0.value) }) { a, b in
            a.lastPlayed.timeIntervalSinceReferenceDate >= b.lastPlayed.timeIntervalSinceReferenceDate ? a : b
        })
    }

    package func encode() -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(File(games: records))) ?? Data()
    }
}

/// The play history on disk: `play-sessions.json` in the launcher's state folder (`~/Library/Application Support/NS Port Builder/`, beside
/// `library.json`), so it survives an update of the app. A store with no file (tests) keeps it in memory.
package final class PlaySessionStore: ObservableObject {
    @Published package private(set) var sessions: PlaySessions
    private let file: URL?

    package static var defaultFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NS Port Builder/play-sessions.json")
    }

    package init(file: URL?) {
        self.file = file
        sessions = file.flatMap { try? Data(contentsOf: $0) }.map(PlaySessions.decode) ?? PlaySessions()
    }

    package subscript(_ titleID: String) -> PlayRecord? { sessions[titleID] }

    package func started(titleID: String, title: String? = nil, at date: Date = Date(), calendar: Calendar = .current) {
        sessions.start(titleID: titleID, title: title, at: date, calendar: calendar)
        persist()
    }

    package func ended(
        titleID: String,
        at date: Date = Date(),
        paused: Double = 0,
        unexpectedly: Bool = false,
        calendar: Calendar = .current
    ) {
        sessions.end(titleID: titleID, at: date, paused: paused, unexpectedly: unexpectedly, calendar: calendar)
        persist()
    }

    private func persist() {
        guard let file else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? sessions.encode().write(to: file, options: .atomic)
    }
}
