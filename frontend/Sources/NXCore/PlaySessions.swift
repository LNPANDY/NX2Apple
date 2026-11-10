import Foundation

/// What console mode knows about the times a game was played (LNPANDY/NX2Apple#816): the launcher records a session when it starts a
/// game and sees it end. Nothing comes from the game itself. Kept per title ID, so a rebuilt or moved app keeps its history.
package struct PlayRecord: Codable, Equatable, Sendable {
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

    package init(lastStart: Date, lastEnd: Date? = nil, seconds: Double = 0, sessions: Int = 1, endedUnexpectedly: Bool = false) {
        self.lastStart = lastStart; self.lastEnd = lastEnd; self.seconds = seconds; self.sessions = sessions
        self.endedUnexpectedly = endedUnexpectedly
    }

    /// When the game was last played: the end of the last session, or its start while it runs or when its end is not known.
    package var lastPlayed: Date { max(lastEnd ?? lastStart, lastStart) }
    /// A session started and has not ended yet.
    package var isOpen: Bool { lastEnd.map { $0 < lastStart } ?? true }
}

/// Every game's record, keyed by title ID. A value type: the store (`PlaySessionStore`) reads and writes it.
package struct PlaySessions: Equatable, Sendable {
    package private(set) var records: [String: PlayRecord] = [:]

    package init(records: [String: PlayRecord] = [:]) { self.records = records }

    package subscript(_ titleID: String) -> PlayRecord? { records[Self.key(titleID)] }

    /// A session of the game starts now.
    package mutating func start(titleID: String, at date: Date) {
        let key = Self.key(titleID)
        guard !key.isEmpty else { return }
        var record = records[key] ?? PlayRecord(lastStart: date, sessions: 0)
        record.lastStart = date
        record.sessions += 1
        record.endedUnexpectedly = false
        records[key] = record
    }

    /// The open session ends now. `paused`: the seconds it spent paused in the background, not counted as played. A session that is not
    /// open (the start was never recorded, or it ended already) changes nothing.
    package mutating func end(titleID: String, at date: Date, paused: Double = 0, unexpectedly: Bool = false) {
        let key = Self.key(titleID)
        guard var record = records[key], record.isOpen else { return }
        let played = date.timeIntervalSince(record.lastStart) - max(paused, 0)
        if played.isFinite, played > 0 { record.seconds += played }
        record.lastEnd = max(date, record.lastStart)
        record.endedUnexpectedly = unexpectedly
        records[key] = record
    }

    /// The title IDs of the games played, the one played last first. Ties fall to the title ID, so the order is stable.
    package var recentTitleIDs: [String] {
        records.sorted { l, r in l.value.lastPlayed == r.value.lastPlayed ? l.key < r.key : l.value.lastPlayed > r.value.lastPlayed }.map(\.key)
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
        return PlaySessions(records: Dictionary(file.games.map { (key($0.key), $0.value) }) { a, b in a.lastPlayed >= b.lastPlayed ? a : b })
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
package final class PlaySessionStore {
    package private(set) var sessions: PlaySessions
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

    package func started(titleID: String, at date: Date = Date()) {
        sessions.start(titleID: titleID, at: date)
        persist()
    }

    package func ended(titleID: String, at date: Date = Date(), paused: Double = 0, unexpectedly: Bool = false) {
        sessions.end(titleID: titleID, at: date, paused: paused, unexpectedly: unexpectedly)
        persist()
    }

    private func persist() {
        guard let file else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? sessions.encode().write(to: file, options: .atomic)
    }
}
