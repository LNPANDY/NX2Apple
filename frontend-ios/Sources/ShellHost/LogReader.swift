import Foundation

/// A game's `log.txt` for the read-only log view.
public struct LogPresentation: Identifiable, Equatable, Sendable {
    public var id: String { gameID }
    public var gameID: String
    public var title: String
    /// Nil when the game has no log yet.
    public var text: String?
    /// True when only the end of a long log is shown.
    public var truncated: Bool
}

public enum LogReader {
    public static let maxBytes = 256 * 1024

    /// The tail of `<folder>/log.txt`, nil when there is none. The file is read in one piece: logs stay small, and a
    /// very long one shows its last `maxBytes`.
    public static func read(_ url: URL, maxBytes: Int = LogReader.maxBytes) -> (text: String, truncated: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        return (String(decoding: data, as: UTF8.self), start > 0)
    }

    /// True when the log at `url` is a run of the game `id`: the shell's first lines name the game's framework
    /// (`shell: starting …/DmGame<title ID>.framework/…`, ShellMain.m).
    public static func isRun(of id: String, _ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8192) else { return false }
        return String(decoding: head, as: UTF8.self).contains("/DmGame\(id).framework/")
    }
}
