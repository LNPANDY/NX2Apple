import Foundation

/// Runtime diagnostics for an nxkit Mac app (`~/Library/Logs/nxkit/last-error.log`, per-game host logs if present,
/// and the newest matching macOS `.ips` crash report summary in `~/Library/Logs/DiagnosticReports`), read on demand when
/// preparing an issue report whose build log is empty or that reports a post-build launch failure.
package enum NxkitRuntimeLog {
    static let readLimit = 64 * 1024
    static let hostLogLines = 80
    static let lastErrorLines = 20
    static let crashFramesLimit = 12
    static let maxCrashReportsChecked = 10
    static let maxIPSBytes = 2 * 1024 * 1024
    static let libraryMarker = ".nx2apple-library"

    /// Collects available runtime diagnostics ordered from least-specific to most-specific at the end so
    /// `NxkitFeedback`'s top-trimming keeps crash summaries and `last-error.log` intact within the URL cap.
    package static func collect(
        titleID: String,
        appPath: String = "",
        since: Date? = nil,
        home: String = NSHomeDirectory(),
        fileManager fm: FileManager = .default
    ) -> String {
        var sections: [String] = []
        if let host = latestHostLog(titleID: titleID, appPath: appPath, since: since, home: home, fileManager: fm) {
            sections.append(host)
        }
        if let crash = latestCrashSummary(titleID: titleID, appPath: appPath, since: since, home: home, fileManager: fm) {
            sections.append(crash)
        }
        if let lastError = lastErrorLog(since: since, home: home, fileManager: fm) {
            sections.append(lastError)
        }
        return sections.joined(separator: "\n")
    }

    // MARK: - Host log & last-error.log

    static func lastErrorLog(
        since: Date? = nil,
        home: String = NSHomeDirectory(),
        fileManager fm: FileManager = .default
    ) -> String? {
        let url = URL(fileURLWithPath: home).appendingPathComponent("Library/Logs/nxkit/last-error.log")
        guard regularFileDate(url, since: since, fileManager: fm) != nil else { return nil }
        let lines = tailLines(url, maxLines: lastErrorLines)
        guard !lines.isEmpty else { return nil }
        return "--- last-error.log ---\n" + lines.joined(separator: "\n")
    }

    static func latestHostLog(
        titleID: String,
        appPath: String = "",
        since: Date? = nil,
        home: String = NSHomeDirectory(),
        fileManager fm: FileManager = .default
    ) -> String? {
        guard !titleID.isEmpty else { return nil }
        let folders = hostLogFolders(appPath: appPath, home: home, fileManager: fm)
        let lowerID = titleID.lowercased()
        let currentName = lowerID + ".log"
        let prevName = lowerID + ".prev.log"
        var candidates: [(url: URL, date: Date, priority: Int)] = []
        for (folderIndex, folder) in folders.enumerated() {
            guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }
            for url in entries {
                let lower = url.lastPathComponent.lowercased()
                let isPrev: Bool
                if lower == currentName {
                    isPrev = false
                } else if lower == prevName {
                    isPrev = true
                } else {
                    continue
                }
                guard let date = regularFileDate(url, since: since, fileManager: fm) else { continue }
                let priority = folderIndex * 2 + (isPrev ? 1 : 0)
                candidates.append((url, date, priority))
            }
        }
        guard let newest = candidates.max(by: { ($0.date, -$0.priority) < ($1.date, -$1.priority) })?.url else {
            return nil
        }
        let lines = tailLines(newest, maxLines: hostLogLines)
        guard !lines.isEmpty else { return nil }
        return "--- host log (\(newest.lastPathComponent)) ---\n" + lines.joined(separator: "\n")
    }

    private static func hostLogFolders(appPath: String, home: String, fileManager fm: FileManager) -> [URL] {
        var folders: [URL] = []
        if !appPath.isEmpty {
            let library = URL(fileURLWithPath: appPath).deletingLastPathComponent()
            if fm.fileExists(atPath: library.appendingPathComponent(libraryMarker).path) {
                folders.append(library.appendingPathComponent("log"))
            }
        }
        folders.append(URL(fileURLWithPath: home).appendingPathComponent("Library/Logs/nxkit"))
        return folders
    }

    private static func regularFileDate(_ url: URL, since: Date?, fileManager fm: FileManager) -> Date? {
        guard let attributes = try? fm.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              ((attributes[.size] as? NSNumber)?.uint64Value ?? 0) > 0 else { return nil }
        let date = attributes[.modificationDate] as? Date ?? .distantPast
        if let since, date < since { return nil }
        return date
    }

    private static func tailLines(_ url: URL, maxLines: Int, limit: Int = readLimit) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return [] }
        let start = size > UInt64(limit) ? size - UInt64(limit) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return [] }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        var lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .newlines) }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        lines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return Array(lines.suffix(maxLines))
    }

    // MARK: - macOS .ips crash reports

    static func latestCrashSummary(
        titleID: String,
        appPath: String = "",
        since: Date? = nil,
        home: String = NSHomeDirectory(),
        fileManager fm: FileManager = .default
    ) -> String? {
        let dir = URL(fileURLWithPath: home).appendingPathComponent("Library/Logs/DiagnosticReports")
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let bundleInfo = readBundleInfo(appPath: appPath)
        var expectedBundleIDs: Set<String> = []
        if !titleID.isEmpty { expectedBundleIDs.insert("org.nxkit.game.\(titleID.lowercased())") }
        if let bid = bundleInfo.bundleID, !bid.isEmpty { expectedBundleIDs.insert(bid.lowercased()) }

        var prefixes: Set<String> = ["nxkit-host", "excuserfault_nxkit-host"]
        let appBase = appPath.isEmpty ? "" : URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent.lowercased()
        for name in [appBase, bundleInfo.bundleName?.lowercased(), bundleInfo.executable?.lowercased()].compactMap({ $0 }) where !name.isEmpty {
            prefixes.insert(name)
            prefixes.insert("excuserfault_\(name)")
        }

        let candidates = entries.compactMap { url -> (url: URL, date: Date)? in
            guard url.pathExtension.lowercased() == "ips" else { return nil }
            let lowerName = url.lastPathComponent.lowercased()
            guard prefixes.contains(where: { lowerName.hasPrefix($0) }) else { return nil }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  (values.fileSize ?? 0) > 0, (values.fileSize ?? 0) <= maxIPSBytes else { return nil }
            let date = values.contentModificationDate ?? .distantPast
            if let since, date < since { return nil }
            return (url, date)
        }
        .sorted { ($0.date, $0.url.lastPathComponent) > ($1.date, $1.url.lastPathComponent) }

        for candidate in candidates.prefix(maxCrashReportsChecked) {
            guard let data = try? Data(contentsOf: candidate.url),
                  let summary = summarizeIPS(data, filename: candidate.url.lastPathComponent, expectedBundleIDs: expectedBundleIDs, appPath: appPath) else {
                continue
            }
            return summary
        }
        return nil
    }

    static func summarizeIPS(_ data: Data, filename: String, expectedBundleIDs: Set<String>, appPath: String = "") -> String? {
        guard let (header, body) = parseIPS(data) else { return nil }
        let reportBundleID = nonEmpty((header?["bundleID"] as? String) ?? ((body["bundleInfo"] as? [String: Any])?["CFBundleIdentifier"] as? String))?.lowercased()
        if !expectedBundleIDs.isEmpty {
            if let reportBundleID {
                guard expectedBundleIDs.contains(reportBundleID) else { return nil }
            } else {
                guard matchesProcPath(body["procPath"] as? String, appPath: appPath) else { return nil }
            }
        }

        var lines: [String] = ["--- crash report (\(filename)) ---"]
        if let time = nonEmpty((body["captureTime"] as? String) ?? (header?["timestamp"] as? String)) {
            lines.append("time: \(time)")
        }
        if let exc = body["exception"] as? [String: Any] {
            let kind = nonEmpty(exc["type"] as? String) ?? "unknown"
            let signal = nonEmpty(exc["signal"] as? String).map { " (\($0))" } ?? ""
            let codes = nonEmpty(exc["codes"] as? String).map { " [\($0)]" } ?? ""
            lines.append("exception: \(kind)\(signal)\(codes)")
        }
        if let term = body["termination"] as? [String: Any] {
            let parts = [
                nonEmpty(term["namespace"] as? String),
                nonEmpty(term["indicator"] as? String),
                (term["code"] as? NSNumber).map { "code \($0)" },
            ].compactMap { $0 }
            if !parts.isEmpty { lines.append("termination: " + parts.joined(separator: " ")) }
        }
        if let asi = body["asi"] as? [String: Any] {
            var notes: [String] = []
            for key in asi.keys.sorted() {
                if let list = asi[key] as? [String] {
                    let joined = list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "; ")
                    if !joined.isEmpty { notes.append("\(key): \(joined)") }
                }
            }
            if !notes.isEmpty { lines.append("asi: " + notes.prefix(3).joined(separator: " | ")) }
        }
        if let ft = body["faultingThread"] as? Int,
           let threads = body["threads"] as? [[String: Any]],
           ft >= 0, ft < threads.count {
            let thread = threads[ft]
            let threadName = nonEmpty(thread["name"] as? String).map { " (\($0))" } ?? ""
            lines.append("faultingThread \(ft)\(threadName):")
            let images = body["usedImages"] as? [[String: Any]] ?? []
            let frames = thread["frames"] as? [[String: Any]] ?? []
            for (index, frame) in frames.prefix(crashFramesLimit).enumerated() {
                lines.append("  " + formatFrame(index: index, frame: frame, images: images))
            }
        }
        return lines.count > 1 ? lines.joined(separator: "\n") : nil
    }

    private static func formatFrame(index: Int, frame: [String: Any], images: [[String: Any]]) -> String {
        let imageIndex = frame["imageIndex"] as? Int ?? -1
        let imageName = (imageIndex >= 0 && imageIndex < images.count ? nonEmpty(images[imageIndex]["name"] as? String) : nil) ?? "?"
        if let symbol = nonEmpty(frame["symbol"] as? String) {
            let loc = (frame["symbolLocation"] as? Int).map { " + \($0)" } ?? ""
            return "\(index) \(imageName) \(symbol)\(loc)"
        }
        if let offset = frame["imageOffset"] as? Int {
            return "\(index) \(imageName) +0x\(String(offset, radix: 16))"
        }
        return "\(index) \(imageName)"
    }

    private static func parseIPS(_ data: Data) -> (header: [String: Any]?, body: [String: Any])? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        if let newline = text.firstIndex(of: "\n") {
            let first = String(text[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rest = String(text[text.index(after: newline)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let bodyData = rest.data(using: .utf8),
               let body = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] {
                let header = first.data(using: .utf8).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
                return (header, body)
            }
        }
        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return (nil, body)
    }

    private static func matchesProcPath(_ procPath: String?, appPath: String) -> Bool {
        guard !appPath.isEmpty, let procPath = nonEmpty(procPath) else { return false }
        let appURL = URL(fileURLWithPath: appPath).standardizedFileURL
        let procURL = URL(fileURLWithPath: procPath).standardizedFileURL
        if procURL.path.hasPrefix(appURL.path + "/") { return true }
        let bundleComponent = "/\(appURL.lastPathComponent)/Contents/MacOS/"
        return procURL.path.contains(bundleComponent)
    }

    private static func readBundleInfo(appPath: String) -> (bundleID: String?, bundleName: String?, executable: String?) {
        guard !appPath.isEmpty else { return (nil, nil, nil) }
        let plist = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plist) else { return (nil, nil, nil) }
        return (
            nonEmpty(dict["CFBundleIdentifier"] as? String),
            nonEmpty(dict["CFBundleName"] as? String),
            nonEmpty(dict["CFBundleExecutable"] as? String)
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let s = value?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}
