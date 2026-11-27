import CryptoKit
import Foundation

/// Outcome status values recorded in `.cheats-fetch.json`, aligned with `scripts/cheat_fetch.py` and iOS `IOSCheatFetcher`.
/// Accepts both `"found"` (current canonical) and `"fetched"` (legacy Mac) when decoding.
package enum CheatFetchStatus: String, Codable, Equatable, Sendable {
    case fetched = "found"
    case preservedUser = "preserved_user"
    case notFound = "not_found"
    case offline

    package init?(rawValue: String) {
        switch rawValue {
        case "found", "fetched":
            self = .fetched
        case "preserved_user":
            self = .preservedUser
        case "not_found":
            self = .notFound
        case "offline":
            self = .offline
        default:
            return nil
        }
    }
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

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        titleID = try c.decodeIfPresent(String.self, forKey: .titleID) ?? ""
        buildID = try c.decodeIfPresent(String.self, forKey: .buildID) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        sources = try c.decodeIfPresent([String].self, forKey: .sources) ?? []
        entryCount = try c.decodeIfPresent(Int.self, forKey: .entryCount) ?? 0
        if let str = try? c.decodeIfPresent(String.self, forKey: .fetchedAt) {
            fetchedAt = str
        } else if let tsInt = try? c.decodeIfPresent(Int64.self, forKey: .fetchedAt) {
            fetchedAt = tsInt > 0 ? Self.formatDate(Date(timeIntervalSince1970: TimeInterval(tsInt))) : ""
        } else if let tsDouble = try? c.decodeIfPresent(Double.self, forKey: .fetchedAt) {
            fetchedAt = tsDouble > 0 ? Self.formatDate(Date(timeIntervalSince1970: tsDouble)) : ""
        } else {
            fetchedAt = ""
        }
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName) ?? ""
        fileSHA256 = try c.decodeIfPresent(String.self, forKey: .fileSHA256) ?? ""
        origin = try c.decodeIfPresent(String.self, forKey: .origin) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
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

/// Outcome of querying online cheat repositories without touching local files.
package enum CheatOnlineLookupStatus: String, Equatable, Sendable {
    case found
    case notFound = "not_found"
    case offline
}

/// Raw online candidate returned by `CheatFetcher.fetchOnlineCandidate`.
package struct CheatOnlineCandidate: Equatable, Sendable {
    package var status: CheatOnlineLookupStatus
    package var onlineText: String?
    package var sources: [String]
    package var entryCount: Int
    package var detail: String

    package init(
        status: CheatOnlineLookupStatus,
        onlineText: String? = nil,
        sources: [String] = [],
        entryCount: Int = 0,
        detail: String = ""
    ) {
        self.status = status
        self.onlineText = onlineText
        self.sources = sources
        self.entryCount = entryCount
        self.detail = detail
    }
}

/// Result returned by `CheatFetcher.fetch(titleID:buildID:into:transport:now:)`.
package struct CheatFetchResult: Equatable, Sendable {
    package var receipt: CheatFetchReceipt
    package var wroteFile: Bool
    package var onlineText: String?
    package var onlineSources: [String]
    package var onlineEntryCount: Int
    package var onlineLookupStatus: CheatOnlineLookupStatus

    package init(
        receipt: CheatFetchReceipt,
        wroteFile: Bool,
        onlineText: String? = nil,
        onlineSources: [String] = [],
        onlineEntryCount: Int = 0,
        onlineLookupStatus: CheatOnlineLookupStatus = .notFound
    ) {
        self.receipt = receipt
        self.wroteFile = wroteFile
        self.onlineText = onlineText
        self.onlineSources = onlineSources
        self.onlineEntryCount = onlineEntryCount
        self.onlineLookupStatus = onlineLookupStatus
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

    /// Queries the three switch-cheats-db sources and returns the merged candidate text without modifying disk files.
    package static func fetchOnlineCandidate(
        titleID: String,
        buildID: String,
        transport: CheatFetchTransport = URLSessionCheatFetchTransport()
    ) async -> CheatOnlineCandidate {
        guard let tid16 = normalizedHex16(titleID), let bid16 = normalizedHex16(buildID, allow32: true) else {
            return CheatOnlineCandidate(status: .notFound, detail: "Invalid titleID or buildID")
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
            if merged.text.utf8.count > maxResponseBytes {
                return CheatOnlineCandidate(status: .notFound, detail: "Merged cheat file exceeded 4 MiB")
            }
            return CheatOnlineCandidate(
                status: .found,
                onlineText: merged.text,
                sources: merged.sources,
                entryCount: merged.entryCount
            )
        }

        let isOffline = successfulResponses == 0 && !networkErrors.isEmpty
        return CheatOnlineCandidate(
            status: isOffline ? .offline : .notFound,
            detail: isOffline ? networkErrors.joined(separator: ", ") : ""
        )
    }

    /// Fetches cheat definitions across the three switch-cheats-db sources.
    /// When no user-protected file exists, writes `<BID>.txt` + `.cheats-fetch.json`.
    /// When a user-supplied or edited `<BID>.txt` exists, still queries online repositories so the caller can preview,
    /// diff, merge, or replace, while leaving the local `<BID>.txt` and `.enabled` toggles untouched.
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
            return CheatFetchResult(receipt: receipt, wroteFile: false, onlineLookupStatus: .notFound)
        }

        let candidate = await fetchOnlineCandidate(titleID: tid16, buildID: bid16, transport: transport)
        let fetchedAt = CheatFetchReceipt.formatDate(now)
        let existingReceipt = readReceipt(in: folder)
        let existingFile = existingCheatFile(buildID: bid16, in: folder, fm: fm)

        // Check player file protection after network wait (Check-Read-Revalidate) so user files are never silently overwritten.
        if let existingFile, let diskData = try? Data(contentsOf: existingFile) {
            let diskHash = sha256Hex(diskData)
            let isManagedFetched = existingReceipt?.buildID.uppercased() == bid16
                && existingReceipt?.origin == "fetched"
                && existingReceipt?.fileSHA256.lowercased() == diskHash.lowercased()
            if !isManagedFetched {
                let preservedDetail: String
                switch candidate.status {
                case .found:
                    preservedDetail = "Preserved existing user cheat file"
                case .notFound:
                    preservedDetail = "Preserved existing user cheat file (not listed online)"
                case .offline:
                    preservedDetail = candidate.detail.isEmpty ? "Preserved existing user cheat file (offline)" : candidate.detail
                }
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
                    detail: preservedDetail
                )
                try? writeReceipt(preserved, in: folder)
                return CheatFetchResult(
                    receipt: preserved,
                    wroteFile: false,
                    onlineText: candidate.onlineText,
                    onlineSources: candidate.sources,
                    onlineEntryCount: candidate.entryCount,
                    onlineLookupStatus: candidate.status
                )
            }
        }

        if candidate.status == .found, let onlineText = candidate.onlineText {
            let payload = Data(onlineText.utf8)
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
                    sources: candidate.sources,
                    entryCount: candidate.entryCount,
                    fetchedAt: fetchedAt,
                    fileName: targetName,
                    fileSHA256: hash,
                    origin: "fetched",
                    detail: ""
                )
                try writeReceipt(receipt, in: folder)
                return CheatFetchResult(
                    receipt: receipt,
                    wroteFile: true,
                    onlineText: onlineText,
                    onlineSources: candidate.sources,
                    onlineEntryCount: candidate.entryCount,
                    onlineLookupStatus: .found
                )
            } catch {
                let failed = CheatFetchReceipt(
                    titleID: tid16,
                    buildID: bid16,
                    status: CheatFetchStatus.offline.rawValue,
                    fetchedAt: fetchedAt,
                    detail: error.localizedDescription
                )
                return CheatFetchResult(receipt: failed, wroteFile: false, onlineLookupStatus: .offline)
            }
        }

        let status: CheatFetchStatus = candidate.status == .offline ? .offline : .notFound
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
            detail: candidate.detail
        )
        try? writeReceipt(receipt, in: folder)
        return CheatFetchResult(receipt: receipt, wroteFile: false, onlineLookupStatus: candidate.status)
    }
}
