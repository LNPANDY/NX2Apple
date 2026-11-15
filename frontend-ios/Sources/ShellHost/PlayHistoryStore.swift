import Foundation
import ShellUI

/// Persistent per-title play history for the iOS and iPadOS shell (#1161).
/// Stored at `Documents/play-history.json` outside `Documents/games/<titleID>/` so play history survives
/// game data deletion, hot-framework updates, app re-signing and RomFS moves.
public final class PlayHistoryStore: @unchecked Sendable {
    public struct Record: Codable, Equatable, Sendable {
        public var title: String?
        public var firstStart: Date
        public var lastStart: Date
        public var lastEnd: Date?
        public var seconds: Double
        public var sessions: Int
        public var dailySeconds: [String: Double]

        public init(
            title: String? = nil,
            firstStart: Date,
            lastStart: Date,
            lastEnd: Date? = nil,
            seconds: Double = 0,
            sessions: Int = 1,
            dailySeconds: [String: Double] = [:]
        ) {
            self.title = title
            self.firstStart = firstStart
            self.lastStart = lastStart
            self.lastEnd = lastEnd
            self.seconds = seconds
            self.sessions = sessions
            self.dailySeconds = dailySeconds
        }

        public var lastPlayed: Date {
            guard let lastEnd, lastEnd.timeIntervalSinceReferenceDate >= lastStart.timeIntervalSinceReferenceDate else {
                return lastStart
            }
            return lastEnd
        }

        public var averageSeconds: Double {
            guard sessions > 0, seconds > 0 else { return 0 }
            return seconds / Double(sessions)
        }

        public func playedDays(calendar: Calendar = .current) -> Set<String> {
            var keys = Set(dailySeconds.keys)
            if sessions > 0 {
                keys.insert(PlayHistoryStore.dayKey(for: firstStart, calendar: calendar))
                keys.insert(PlayHistoryStore.dayKey(for: lastPlayed, calendar: calendar))
            }
            return keys
        }
    }

    /// Tracks an in-progress session so backgrounding pauses timing and force-quit or crash recovery preserves accrued foreground time.
    struct OpenSession: Codable, Equatable, Sendable {
        var titleID: String
        var startedAt: Date
        /// Start of the current active foreground slice, or nil while backgrounded.
        var activeSliceStart: Date?
        /// Last timestamp flushed to disk so stale-session recovery on next launch never over-counts backgrounded hours.
        var lastCheckpoint: Date
    }

    private struct StorageFile: Codable {
        var schema = 1
        var games: [String: Record] = [:]
        var openSession: OpenSession?
    }

    private let fileURL: URL?
    private let lock = NSLock()
    private var state: StorageFile

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            self.state = (try? decoder.decode(StorageFile.self, from: data)) ?? StorageFile()
        } else {
            self.state = StorageFile()
        }
    }

    public static func defaultFileURL(appDataRoot: URL) -> URL {
        appDataRoot.deletingLastPathComponent().appendingPathComponent("play-history.json", isDirectory: false)
    }

    public subscript(_ titleID: String) -> Record? {
        lock.lock()
        defer { lock.unlock() }
        return state.games[Self.normalize(titleID)]
    }

    public var allRecords: [String: Record] {
        lock.lock()
        defer { lock.unlock() }
        return state.games
    }

    /// Closes any unfinished session left over from a previous process exit using its last foreground checkpoint.
    public func recoverStaleSessionIfNeeded(calendar: Calendar = .current) {
        lock.lock()
        defer { lock.unlock() }
        guard let open = state.openSession else { return }
        if var record = state.games[open.titleID] {
            if let sliceStart = open.activeSliceStart,
               open.lastCheckpoint.timeIntervalSinceReferenceDate > sliceStart.timeIntervalSinceReferenceDate {
                let delta = open.lastCheckpoint.timeIntervalSince(sliceStart)
                if delta.isFinite, delta > 0 {
                    record.seconds += delta
                    Self.addDaily(into: &record.dailySeconds, from: sliceStart, to: open.lastCheckpoint, seconds: delta, calendar: calendar)
                }
            }
            record.lastEnd = Self.laterDate(open.startedAt, open.lastCheckpoint)
            state.games[open.titleID] = record
        }
        state.openSession = nil
        persistLocked()
    }

    /// Starts tracking a foreground gameplay session.
    public func sessionDidStart(titleID: String, title: String?, at now: Date, calendar: Calendar = .current) {
        let key = Self.normalize(titleID)
        guard !key.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if state.openSession != nil {
            closeOpenSessionLocked(at: now, calendar: calendar)
        }
        var record = state.games[key] ?? Record(firstStart: now, lastStart: now, sessions: 0)
        if now.timeIntervalSinceReferenceDate < record.firstStart.timeIntervalSinceReferenceDate {
            record.firstStart = now
        }
        if let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            record.title = trimmed
        }
        record.lastStart = now
        record.lastEnd = nil
        record.sessions += 1
        let day = Self.dayKey(for: now, calendar: calendar)
        if record.dailySeconds[day] == nil {
            record.dailySeconds[day] = 0
        }
        state.games[key] = record
        state.openSession = OpenSession(titleID: key, startedAt: now, activeSliceStart: now, lastCheckpoint: now)
        persistLocked()
    }

    /// Flushes accrued foreground time and pauses accumulation when the app resigns active or enters background.
    public func sessionWillPause(at now: Date, calendar: Calendar = .current) {
        lock.lock()
        defer { lock.unlock() }
        guard var open = state.openSession else { return }
        if let sliceStart = open.activeSliceStart {
            let delta = now.timeIntervalSince(sliceStart)
            if delta.isFinite, delta > 0, var record = state.games[open.titleID] {
                record.seconds += delta
                record.lastEnd = now
                Self.addDaily(into: &record.dailySeconds, from: sliceStart, to: now, seconds: delta, calendar: calendar)
                state.games[open.titleID] = record
            }
            open.activeSliceStart = nil
            open.lastCheckpoint = Self.laterDate(open.lastCheckpoint, now)
            state.openSession = open
            persistLocked()
        }
    }

    /// Resumes foreground accumulation without inflating the session count.
    public func sessionDidResume(at now: Date) {
        lock.lock()
        defer { lock.unlock() }
        guard var open = state.openSession else { return }
        if open.activeSliceStart == nil {
            open.activeSliceStart = now
            open.lastCheckpoint = Self.laterDate(open.lastCheckpoint, now)
            state.openSession = open
            persistLocked()
        }
    }

    /// Periodic foreground checkpoint so an unexpected crash preserves already-played minutes.
    public func checkpoint(at now: Date, calendar: Calendar = .current) {
        lock.lock()
        defer { lock.unlock() }
        guard var open = state.openSession, let sliceStart = open.activeSliceStart else { return }
        let delta = now.timeIntervalSince(sliceStart)
        guard delta.isFinite, delta > 0, var record = state.games[open.titleID] else { return }
        record.seconds += delta
        record.lastEnd = now
        Self.addDaily(into: &record.dailySeconds, from: sliceStart, to: now, seconds: delta, calendar: calendar)
        state.games[open.titleID] = record
        open.activeSliceStart = now
        open.lastCheckpoint = now
        state.openSession = open
        persistLocked()
    }

    /// Closes the active session when returning to the library or terminating cleanly.
    public func sessionDidEnd(at now: Date, calendar: Calendar = .current) {
        lock.lock()
        defer { lock.unlock() }
        guard state.openSession != nil else { return }
        closeOpenSessionLocked(at: now, calendar: calendar)
        persistLocked()
    }

    /// Builds a display-ready `ActivityLogSnapshot` for `ShellUI`.
    public func makeSnapshot(
        installedDetails: [GameDetail],
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = ShellFormat.activeLocale
    ) -> ActivityLogSnapshot {
        lock.lock()
        let gamesMap = state.games
        lock.unlock()

        let installedByID = Dictionary(uniqueKeysWithValues: installedDetails.map { ($0.id.uppercased(), $0.game) })
        var totalSeconds: Double = 0
        var totalSessions = 0
        var activeDays = Set<String>()
        var dailyTotals: [String: Double] = [:]

        let dateFormatter = DateFormatter()
        dateFormatter.locale = locale
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none

        var entries: [ActivityGameEntry] = []
        for (id, record) in gamesMap where record.sessions > 0 {
            totalSeconds += max(0, record.seconds)
            totalSessions += record.sessions
            let days = record.playedDays(calendar: calendar)
            activeDays.formUnion(days)
            for (day, sec) in record.dailySeconds where sec > 0 {
                dailyTotals[day, default: 0] += sec
            }
            let tile = installedByID[id]
            let displayTitle = tile?.title ?? record.title ?? id
            let totalTimeLabel = record.seconds >= 60
                ? ShellFormat.duration(record.seconds, locale: locale)
                : ShellFormat.underOneMinute()
            let avgLabel = record.averageSeconds >= 60
                ? ShellFormat.duration(record.averageSeconds, locale: locale)
                : ShellFormat.underOneMinute()
            entries.append(
                ActivityGameEntry(
                    id: id,
                    title: displayTitle,
                    game: tile,
                    seconds: record.seconds,
                    totalTime: totalTimeLabel,
                    sessions: record.sessions,
                    averageTime: avgLabel,
                    daysPlayed: days.count,
                    firstPlayed: dateFormatter.string(from: record.firstStart),
                    lastPlayed: dateFormatter.string(from: record.lastPlayed),
                    lastPlayedDate: record.lastPlayed,
                    isInstalled: tile != nil
                )
            )
        }

        entries.sort {
            if $0.seconds != $1.seconds { return $0.seconds > $1.seconds }
            if $0.sessions != $1.sessions { return $0.sessions > $1.sessions }
            return $0.id < $1.id
        }

        let recentDays: [ActivityDayBar] = (0..<14).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: now) ?? now
            let key = Self.dayKey(for: date, calendar: calendar)
            let dayNum = calendar.component(.day, from: date)
            return ActivityDayBar(id: key, label: "\(dayNum)", seconds: dailyTotals[key] ?? 0)
        }

        let totalLabel: String
        if entries.isEmpty {
            totalLabel = ShellFormat.zeroMinutes(locale: locale)
        } else if totalSeconds >= 60 {
            totalLabel = ShellFormat.duration(totalSeconds, locale: locale)
        } else {
            totalLabel = ShellFormat.underOneMinute()
        }

        return ActivityLogSnapshot(
            totalTime: totalLabel,
            totalSeconds: totalSeconds,
            totalSessions: totalSessions,
            activeDaysCount: activeDays.count,
            gamesPlayedCount: entries.count,
            activeDayKeys: activeDays,
            recentDays: recentDays,
            entries: entries,
            referenceDate: now
        )
    }

    public static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    // MARK: Private

    private static func normalize(_ titleID: String) -> String {
        titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private static func earlierDate(_ a: Date, _ b: Date) -> Date {
        a.timeIntervalSinceReferenceDate <= b.timeIntervalSinceReferenceDate ? a : b
    }

    private static func laterDate(_ a: Date, _ b: Date) -> Date {
        a.timeIntervalSinceReferenceDate >= b.timeIntervalSinceReferenceDate ? a : b
    }

    private func closeOpenSessionLocked(at now: Date, calendar: Calendar) {
        guard let open = state.openSession else { return }
        if var record = state.games[open.titleID] {
            if let sliceStart = open.activeSliceStart {
                let delta = now.timeIntervalSince(sliceStart)
                if delta.isFinite, delta > 0 {
                    record.seconds += delta
                    Self.addDaily(into: &record.dailySeconds, from: sliceStart, to: now, seconds: delta, calendar: calendar)
                }
            }
            record.lastEnd = Self.laterDate(open.startedAt, now)
            state.games[open.titleID] = record
        }
        state.openSession = nil
    }

    private static func addDaily(
        into buckets: inout [String: Double],
        from start: Date,
        to end: Date,
        seconds: Double,
        calendar: Calendar
    ) {
        let span = end.timeIntervalSince(start)
        guard span > 0, seconds > 0 else { return }
        let ratio = min(1, seconds / span)
        var cursor = start
        var steps = 0
        while cursor.timeIntervalSinceReferenceDate < end.timeIntervalSinceReferenceDate, steps < 366 {
            steps += 1
            let dayStart = calendar.startOfDay(for: cursor)
            let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? end
            let sliceEnd = earlierDate(nextDay, end)
            let slice = max(0, sliceEnd.timeIntervalSince(cursor)) * ratio
            if slice > 0 {
                buckets[dayKey(for: cursor, calendar: calendar), default: 0] += slice
            }
            if sliceEnd.timeIntervalSinceReferenceDate <= cursor.timeIntervalSinceReferenceDate { break }
            cursor = sliceEnd
        }
    }

    private func persistLocked() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
