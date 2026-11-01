import AppKit

/// Where a Mac game app writes its log, and its last lines. The rule is dm/mac/launcher.c's: a game app that sits in a folder
/// holding the library marker (`.nx2apple-library`, written by the launcher's build) logs to `<that folder>/log/<title ID>.log`,
/// any other copy to `~/Library/Logs/nxnative/<title ID>.log`. The launcher renames the last session's log to `.prev.log`
/// when it starts, so `.log` is the newest while it exists. A library whose folder was moved may still hold the older
/// ~/Library log from before the move, so both places are looked in and the newest file wins.
enum GameLog {
    /// The lines Copy diagnostics takes from the end of the log.
    static let lines = 200
    /// How much of the end of a log file is read to find them, so a log of hundreds of megabytes costs a short read.
    static let readLimit = 256 * 1024
    static let marker = ".nx2apple-library"

    /// The folders the log of this app can be in, the one launcher.c writes to now first.
    static func folders(appPath: String, home: String = NSHomeDirectory()) -> [URL] {
        var folders: [URL] = []
        if !appPath.isEmpty {
            let library = URL(fileURLWithPath: appPath).deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: library.appendingPathComponent(marker).path) {
                folders.append(library.appendingPathComponent("log"))
            }
        }
        folders.append(URL(fileURLWithPath: home).appendingPathComponent("Library/Logs/nxnative"))
        return folders
    }

    /// The newest existing log of the game (`<id>.log` or `<id>.prev.log`), or nil when it was never run.
    static func latest(titleID: String, appPath: String, home: String = NSHomeDirectory()) -> URL? {
        let candidates = folders(appPath: appPath, home: home).flatMap { folder in
            [folder.appendingPathComponent(titleID + ".log"), folder.appendingPathComponent(titleID + ".prev.log")]
        }
        let found = candidates.compactMap { url -> (url: URL, date: Date)? in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), (attributes[.type] as? FileAttributeType) == .typeRegular
            else { return nil }
            return (url, attributes[.modificationDate] as? Date ?? .distantPast)
        }
        // max(by:) keeps the first of equal dates: the order above breaks ties, current log before previous, library before ~/Library.
        return found.enumerated().max { ($0.element.date, -$0.offset) < ($1.element.date, -$1.offset) }?.element.url
    }

    /// The last `count` lines of a file, without trailing blank ones; nil when it cannot be read.
    static func tail(_ url: URL, lines count: Int = lines, readLimit: Int = readLimit) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(readLimit) ? size - UInt64(readLimit) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }   // the first line is cut
        return Diagnostics.tail(text, lines: count)
    }

    /// Shows the log in Console.app, or in the Finder when Console cannot be found.
    static func show(_ url: URL) {
        if let console = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") {
            NSWorkspace.shared.open([url], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
