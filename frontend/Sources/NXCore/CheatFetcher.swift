import CryptoKit
import Foundation

/// Outcome status values recorded in `.cheats-fetch.json`, aligned with `scripts/cheat_fetch.py` and iOS `IOSCheatFetcher`.
package enum CheatFetchStatus: String, Codable, Equatable, Sendable {
    case fetched
    case preservedUser = "preserved_user"
    case notFound = "not_found"
    case offline
}

/// Receipt persisted as `.cheats-fetch.json` in `<DM_ROOT>/cheats/` alongside `<BID>.txt`.
package struct CheatFetchReceipt: Codable, Equatable, Sendable {
    package var schemaVersion: Int
    package var titleID: String
    package var buildID: String
    package var status: String
    package var sources: [String]
    package var entryCount: Int
    package var fetchedAt: String
    package var fileName: String
    package var fileSHA256: String
    package var origin: String
    package var detail: String

    package init(
        schemaVersion: Int = 1,
        titleID: String,
        buildID: String,
        status: String,
        sources: [String] = [],
        entryCount: Int = 0,
        fetchedAt: String,
        fileName: String = "",
        fileSHA256: String = "",
        origin: String = "",
        detail: String = ""
    ) {
        self.schemaVersion = schemaVersion
        self.titleID = titleID
        self.buildID = buildID
        self.status = status
        self.sources = sources
        self.entryCount = entryCount
        self.fetchedAt = fetchedAt
        self.fileName = fileName
        self.fileSHA256 = fileSHA256
        self.origin = origin
        self.detail = detail
    }

    package var statusKind: CheatFetchStatus? {
        CheatFetchStatus(rawValue: status)
    }

    package var fetchedDate: Date? {
        Self.parseDate(fetchedAt)
    }

    package static func parseDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: trimmed) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: trimmed) { return d }
        if let ts = Double(trimmed) {
            return Date(timeIntervalSince1970: ts)
        }
        return nil
    }

    package static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

/// Network transport abstraction for fetching cheat database JSON payloads without hitting live GitHub in unit tests.
package protocol CheatFetchTransport: Sendable {
    func fetch(url: URL, timeout: TimeInterval, maxBytes: Int) async throws -> (statusCode: Int, data: Data)
}

package enum CheatFetchTransportError: Error, LocalizedError, Equatable, Sendable {
    case responseTooLarge(Int)
    case httpStatus(Int)
    case invalidURL

    package var errorDescription: String? {
        switch self {
        case .responseTooLarge(let limit):
            return "Response exceeded \(limit) bytes"
        case .httpStatus(let code):
            return "HTTP \(code)"
        case .invalidURL:
            return "Invalid URL"
        }
    }
}

/// Live URLSession transport enforcing per-request timeout and streaming byte ceiling (4 MiB).
package struct URLSessionCheatFetchTransport: CheatFetchTransport, Sendable {
    package let session: URLSession

    package init(session: URLSession = .shared) {
        self.session = session
    }

    package func fetch(url: URL, timeout: TimeInterval, maxBytes: Int) async throws -> (statusCode: Int, data: Data) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("NX2Apple", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if http.expectedContentLength > Int64(maxBytes) {
            throw CheatFetchTransportError.responseTooLarge(maxBytes)
        }
        var collected = Data()
        for try await byte in bytes {
            if collected.count >= maxBytes {
                throw CheatFetchTransportError.responseTooLarge(maxBytes)
            }
            collected.append(byte)
        }
        return (http.statusCode, collected)
    }
}

/// Result returned by `CheatFetcher.fetch(titleID:buildID:into:transport:now:)`.
package struct CheatFetchResult: Equatable, Sendable {
    package var receipt: CheatFetchReceipt
    package var wroteFile: Bool

    package init(receipt: CheatFetchReceipt, wroteFile: Bool) {
        self.receipt = receipt
        self.wroteFile = wroteFile
    }
}

/// Online cheat database fetcher matching `scripts/cheat_fetch.py` (100% shared source order, JSON rules, and `.cheats-fetch.json` receipt).
package enum CheatFetcher {
    package static let receiptFileName = ".cheats-fetch.json"
    package static let requestTimeout: TimeInterval = 5.0
    package static let maxResponseBytes = 4 * 1024 * 1024

    package struct SourceSpec: Equatable, Sendable {
        package let name: String
        package let pathPrefix: String

        package func url(titleID: String) -> URL? {
            URL(string: "https://raw.githubusercontent.com/HamletDuFromage/switch-cheats-db/master/\(pathPrefix)/\(titleID).json")
        }
    }

    package static let sources: [SourceSpec] = [
        SourceSpec(name: "switch-cheats-db", pathPrefix: "cheats"),
        SourceSpec(name: "cheats_gbatemp", pathPrefix: "cheats_gbatemp"),
        SourceSpec(name: "cheats_gfx", pathPrefix: "cheats_gfx"),
    ]

    package struct ParsedSectionEntry: Equatable, Sendable {
        package var header: String
        package var dedupKey: String
        package var isMaster: Bool
        package var body: String
    }

    /// Normalizes a 16-hex-digit (or 32-hex-digit truncated to 16) uppercase identifier, or nil when invalid.
    package static func normalizedHex16(_ raw: String, allow32: Bool = false) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isHexDigit) else { return nil }
        if trimmed.count == 16 { return trimmed }
        if allow32 && trimmed.count == 32 { return String(trimmed.prefix(16)) }
        return nil
    }

    package static func receiptURL(in folder: URL) -> URL {
        folder.appendingPathComponent(receiptFileName)
    }

    package static func readReceipt(in folder: URL) -> CheatFetchReceipt? {
        let url = receiptURL(in: folder)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CheatFetchReceipt.self, from: data)
    }

    package static func writeReceipt(_ receipt: CheatFetchReceipt, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(receipt)
        try data.write(to: receiptURL(in: folder), options: .atomic)
    }

    package static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Extracts cheat entries matching `buildID` (case-insensitive, 16 hex or 32-hex prefix) from one source JSON document.
    package static func parseSourceJSON(_ data: Data, buildID: String) throws -> [ParsedSectionEntry] {
        guard let bid16 = normalizedHex16(buildID, allow32: true) else { return [] }
        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        guard let root = obj as? [String: Any] else { return [] }

        var matchedEntries: [String: Any]?
        // Prefer exact 16-char case-insensitive match, then 32-char prefix match.
        for (rawKey, value) in root {
            if rawKey.caseInsensitiveCompare("attribution") == .orderedSame { continue }
            guard let dict = value as? [String: Any] else { continue }
            let upper = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if upper == bid16 {
                matchedEntries = dict
                break
            }
            if matchedEntries == nil, upper.count >= 16, upper.prefix(16) == bid16, upper.allSatisfy(\.isHexDigit) {
                matchedEntries = dict
            }
        }
        guard let entriesDict = matchedEntries else { return [] }

        var out: [ParsedSectionEntry] = []
        for rawHeader in entriesDict.keys.sorted() {
            guard let bodyText = extractBodyText(from: entriesDict[rawHeader]) else { continue }
            let normalized = normalizeEntry(header: rawHeader, rawBody: bodyText)
            if let normalized {
                out.append(normalized)
            }
        }
        return out
    }

    private static func extractBodyText(from rawValue: Any?) -> String? {
        if let str = rawValue as? String {
            return str
        }
        if let lines = rawValue as? [String] {
            return lines.joined(separator: "\n")
        }
        return nil
    }

    private static func normalizeEntry(header rawHeader: String, rawBody: String) -> ParsedSectionEntry? {
        let trimmedHeader = rawHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHeader.isEmpty else { return nil }

        let isMaster: Bool
        let bareName: String
        let canonicalHeader: String
        if trimmedHeader.hasPrefix("{") && trimmedHeader.hasSuffix("}") && trimmedHeader.count > 2 {
            isMaster = true
            bareName = String(trimmedHeader.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            canonicalHeader = "{\(bareName)}"
        } else if trimmedHeader.hasPrefix("[") && trimmedHeader.hasSuffix("]") && trimmedHeader.count > 2 {
            isMaster = false
            bareName = String(trimmedHeader.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            canonicalHeader = "[\(bareName)]"
        } else {
            isMaster = false
            bareName = trimmedHeader
            canonicalHeader = "[\(bareName)]"
        }
        guard !bareName.isEmpty else { return nil }

        var lines = rawBody
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let first = lines.first {
            if first == canonicalHeader || first.caseInsensitiveCompare(canonicalHeader) == .orderedSame {
                lines.removeFirst()
            } else if isMaster, first == "{\(bareName)}" {
                lines.removeFirst()
            } else if !isMaster, first == "[\(bareName)]" {
                lines.removeFirst()
            }
        }
        guard !lines.isEmpty else { return nil }
        return ParsedSectionEntry(
            header: canonicalHeader,
            dedupKey: "\(isMaster ? "M" : "C"):\(bareName.lowercased())",
            isMaster: isMaster,
            body: lines.joined(separator: "\n")
        )
    }

    /// Merges entries from ordered sources: `{...}` Master entries come first, duplicate entry names are deduplicated (first source wins).
    package static func renderMergedText(from perSource: [(source: String, entries: [ParsedSectionEntry])]) -> (text: String, sources: [String], entryCount: Int)? {
        var seenKeys = Set<String>()
        var masters: [ParsedSectionEntry] = []
        var regulars: [ParsedSectionEntry] = []
        var usedSources: [String] = []

        for (source, entries) in perSource {
            var contributed = false
            for entry in entries {
                guard seenKeys.insert(entry.dedupKey).inserted else { continue }
                if entry.isMaster {
                    masters.append(entry)
                } else {
                    regulars.append(entry)
                }
                contributed = true
            }
            if contributed {
                usedSources.append(source)
            }
        }

        let ordered = masters + regulars
        guard !ordered.isEmpty else { return nil }
        let text = ordered.map { "\($0.header)\n\($0.body)" }.joined(separator: "\n\n") + "\n"
        return (text, usedSources, ordered.count)
    }

    /// Locates an existing `<BID>.txt` (case-insensitive) in the flat cheats folder.
    package static func existingCheatFile(buildID: String, in folder: URL, fm: FileManager = .default) -> URL? {
        guard let bid16 = normalizedHex16(buildID, allow32: true) else { return nil }
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        let expectedLower = "\(bid16.lowercased()).txt"
        if let exact = names.first(where: { $0 == "\(bid16).txt" }) {
            return folder.appendingPathComponent(exact)
        }
        if let ci = names.sorted().first(where: { $0.lowercased() == expectedLower }) {
            return folder.appendingPathComponent(ci)
        }
        return nil
    }

    /// Fetches cheat definitions across the three switch-cheats-db sources and writes `<BID>.txt` + `.cheats-fetch.json`,
    /// preserving any player-supplied or modified cheat file and leaving `.enabled` toggles untouched.
    package static func fetch(
        titleID: String,
        buildID: String,
        into folder: URL,
        transport: CheatFetchTransport = URLSessionCheatFetchTransport(),
        now: Date = Date(),
        fm: FileManager = .default
    ) async -> CheatFetchResult {
        guard let tid16 = normalizedHex16(titleID), let bid16 = normalizedHex16(buildID, allow32: true) else {
            let receipt = CheatFetchReceipt(
                titleID: titleID.uppercased(),
                buildID: buildID.uppercased(),
                status: CheatFetchStatus.notFound.rawValue,
                fetchedAt: CheatFetchReceipt.formatDate(now),
                detail: "Invalid titleID or buildID"
            )
            return CheatFetchResult(receipt: receipt, wroteFile: false)
        }

        let fetchedAt = CheatFetchReceipt.formatDate(now)
        let existingReceipt = readReceipt(in: folder)
        let existingFile = existingCheatFile(buildID: bid16, in: folder, fm: fm)

        // Check player file protection first so we never overwrite local edits or user-imported files.
        if let existingFile, let diskData = try? Data(contentsOf: existingFile) {
            let diskHash = sha256Hex(diskData)
            let isManagedFetched = existingReceipt?.buildID.uppercased() == bid16
                && existingReceipt?.origin == "fetched"
                && existingReceipt?.fileSHA256.lowercased() == diskHash.lowercased()
            if !isManagedFetched {
                let preserved = CheatFetchReceipt(
                    titleID: tid16,
                    buildID: bid16,
                    status: CheatFetchStatus.preservedUser.rawValue,
                    sources: existingReceipt?.sources ?? [],
                    entryCount: existingReceipt?.entryCount ?? 0,
                    fetchedAt: fetchedAt,
                    fileName: existingFile.lastPathComponent,
                    fileSHA256: diskHash,
                    origin: "user",
                    detail: "Preserved existing user cheat file"
                )
                try? writeReceipt(preserved, in: folder)
                return CheatFetchResult(receipt: preserved, wroteFile: false)
            }
        }

        var perSource: [(source: String, entries: [ParsedSectionEntry])] = []
        var networkErrors: [String] = []
        var successfulResponses = 0

        for spec in sources {
            guard let url = spec.url(titleID: tid16) else { continue }
            do {
                let (statusCode, data) = try await transport.fetch(url: url, timeout: requestTimeout, maxBytes: maxResponseBytes)
                if statusCode == 404 {
                    successfulResponses += 1
                    continue
                }
                guard (200..<300).contains(statusCode) else {
                    networkErrors.append("\(spec.name): HTTP \(statusCode)")
                    continue
                }
                successfulResponses += 1
                let parsed = try parseSourceJSON(data, buildID: bid16)
                if !parsed.isEmpty {
                    perSource.append((spec.name, parsed))
                }
            } catch {
                networkErrors.append("\(spec.name): \(error.localizedDescription)")
            }
        }

        if let merged = renderMergedText(from: perSource) {
            let payload = Data(merged.text.utf8)
            if payload.count > maxResponseBytes {
                let tooBig = CheatFetchReceipt(
                    titleID: tid16,
                    buildID: bid16,
                    status: CheatFetchStatus.notFound.rawValue,
                    fetchedAt: fetchedAt,
                    detail: "Merged cheat file exceeded 4 MiB"
                )
                try? writeReceipt(tooBig, in: folder)
                return CheatFetchResult(receipt: tooBig, wroteFile: false)
            }
            let targetName = "\(bid16).txt"
            let targetURL = folder.appendingPathComponent(targetName)
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                try payload.write(to: targetURL, options: .atomic)
                if let existingFile, existingFile.lastPathComponent != targetName {
                    try? fm.removeItem(at: existingFile)
                }
                let hash = sha256Hex(payload)
                let receipt = CheatFetchReceipt(
                    titleID: tid16,
                    buildID: bid16,
                    status: CheatFetchStatus.fetched.rawValue,
                    sources: merged.sources,
                    entryCount: merged.entryCount,
                    fetchedAt: fetchedAt,
                    fileName: targetName,
                    fileSHA256: hash,
                    origin: "fetched",
                    detail: ""
                )
                try writeReceipt(receipt, in: folder)
                return CheatFetchResult(receipt: receipt, wroteFile: true)
            } catch {
                let failed = CheatFetchReceipt(
                    titleID: tid16,
                    buildID: bid16,
                    status: CheatFetchStatus.offline.rawValue,
                    fetchedAt: fetchedAt,
                    detail: error.localizedDescription
                )
                return CheatFetchResult(receipt: failed, wroteFile: false)
            }
        }

        let isOffline = successfulResponses == 0 && !networkErrors.isEmpty
        let status: CheatFetchStatus = isOffline ? .offline : .notFound
        let detail = isOffline ? networkErrors.joined(separator: ", ") : ""
        let preservedExisting = (existingFile != nil && existingReceipt?.origin == "fetched" && existingReceipt?.buildID.uppercased() == bid16)
        let receipt = CheatFetchReceipt(
            titleID: tid16,
            buildID: bid16,
            status: status.rawValue,
            sources: preservedExisting ? (existingReceipt?.sources ?? []) : [],
            entryCount: preservedExisting ? (existingReceipt?.entryCount ?? 0) : 0,
            fetchedAt: fetchedAt,
            fileName: preservedExisting ? (existingReceipt?.fileName ?? "") : "",
            fileSHA256: preservedExisting ? (existingReceipt?.fileSHA256 ?? "") : "",
            origin: preservedExisting ? "fetched" : "",
            detail: detail
        )
        try? writeReceipt(receipt, in: folder)
        return CheatFetchResult(receipt: receipt, wroteFile: false)
    }
}
