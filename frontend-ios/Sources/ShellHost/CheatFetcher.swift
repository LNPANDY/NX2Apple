import CryptoKit
import Foundation
import ShellUI

/// Standalone online cheat fetcher for iOS matching `dm/tools/cheat_fetch.py` and Mac `CheatFetcher`.
/// Pulls Atmosphère cheats from HamletDuFromage/switch-cheats-db static JSON mirrors with a 5s per-request
/// timeout, 4 MiB response cap, Master Code `{...}` prioritization, title deduplication, and user-file protection.
public struct IOSCheatFetcher: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let maxResponseBytes = 4 * 1024 * 1024
    public static let requestTimeout: TimeInterval = 5.0

    public struct Source: Equatable, Sendable {
        public let name: String
        public let folder: String

        public init(name: String, folder: String) {
            self.name = name
            self.folder = folder
        }
    }

    public static let defaultSources: [Source] = [
        Source(name: "HamletDuFromage/switch-cheats-db", folder: "cheats"),
        Source(name: "HamletDuFromage/switch-cheats-db (gbatemp)", folder: "cheats_gbatemp"),
        Source(name: "HamletDuFromage/switch-cheats-db (gfx)", folder: "cheats_gfx"),
    ]

    private let transport: Transport
    private let sources: [Source]
    private let now: @Sendable () -> Date

    public init(
        sources: [Source] = defaultSources,
        now: @escaping @Sendable () -> Date = { Date() },
        transport: Transport? = nil
    ) {
        self.sources = sources
        self.now = now
        self.transport = transport ?? { request in
            try await URLSession.shared.data(for: request)
        }
    }

    public static func sourceURL(folder: String, titleID: String) -> URL? {
        URL(string: "https://raw.githubusercontent.com/HamletDuFromage/switch-cheats-db/master/\(folder)/\(titleID).json")
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Normalizes a 16-character uppercase hex Title ID or Build ID prefix.
    public static func normalizeHex16(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.count >= 16 else { return nil }
        let prefix = String(trimmed.prefix(16))
        guard prefix.allSatisfy(\.isHexDigit) else { return nil }
        return prefix
    }

    public enum ManualFetchResult: Equatable, Sendable {
        case saved(GameCheatFetchReceipt)
        case preview(receipt: GameCheatFetchReceipt, preview: GameCheatOnlinePreview)
    }

    /// Fetches, merges, and persists cheats for `(titleID, buildID)` into `cheatsFolder`, preserving user-created files.
    public func fetchAndSave(
        titleID rawTitleID: String,
        buildID rawBuildID: String,
        to cheatsFolder: URL,
        forceOverwriteUserFile: Bool = false
    ) async -> GameCheatFetchReceipt {
        let result = await performFetch(
            titleID: rawTitleID,
            buildID: rawBuildID,
            to: cheatsFolder,
            frameworkURL: nil,
            forceOverwriteUserFile: forceOverwriteUserFile,
            includePreview: false
        )
        switch result {
        case .saved(let receipt), .preview(let receipt, _):
            return receipt
        }
    }

    /// Fetches online cheats for manual user action.
    /// If a user-created or user-modified `<BID>.txt` already exists and online cheats are found,
    /// preserves the local file and returns `.preview(...)` so the UI can present Compare / Merge / Replace.
    public func fetchForManualReview(
        titleID rawTitleID: String,
        buildID rawBuildID: String,
        to cheatsFolder: URL,
        frameworkURL: URL? = nil
    ) async -> ManualFetchResult {
        await performFetch(
            titleID: rawTitleID,
            buildID: rawBuildID,
            to: cheatsFolder,
            frameworkURL: frameworkURL,
            forceOverwriteUserFile: false,
            includePreview: true
        )
    }

    private struct FetchedPayload {
        var mergedEntries: [(header: String, text: String, isMaster: Bool)]
        var hitSources: [String]
        var reachableResponses: Int
        var networkFailures: Int
        var parseOrSizeErrors: Int
    }

    private func fetchMergedPayload(titleID tid: String, buildID bid: String) async -> FetchedPayload {
        var mergedEntries: [(header: String, text: String, isMaster: Bool)] = []
        var seenHeaders = Set<String>()
        var hitSources: [String] = []
        var reachableResponses = 0
        var networkFailures = 0
        var parseOrSizeErrors = 0

        for source in sources {
            guard let url = Self.sourceURL(folder: source.folder, titleID: tid) else {
                parseOrSizeErrors += 1
                continue
            }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.requestTimeout)
            request.timeoutInterval = Self.requestTimeout

            do {
                let (data, response) = try await transport(request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
                if statusCode == 404 {
                    reachableResponses += 1
                    continue
                }
                guard (200...299).contains(statusCode) else {
                    if statusCode >= 500 || statusCode == 429 || statusCode == 408 {
                        networkFailures += 1
                    } else {
                        parseOrSizeErrors += 1
                    }
                    continue
                }
                reachableResponses += 1
                guard data.count <= Self.maxResponseBytes else {
                    parseOrSizeErrors += 1
                    continue
                }
                guard let parsed = Self.parseBuildEntries(from: data, buildID: bid) else {
                    parseOrSizeErrors += 1
                    continue
                }
                if parsed.isEmpty { continue }

                var sourceAdded = false
                for item in parsed {
                    if seenHeaders.insert(item.header).inserted {
                        mergedEntries.append(item)
                        sourceAdded = true
                    }
                }
                if sourceAdded {
                    hitSources.append(source.name)
                }
            } catch {
                networkFailures += 1
            }
        }

        return FetchedPayload(
            mergedEntries: mergedEntries,
            hitSources: hitSources,
            reachableResponses: reachableResponses,
            networkFailures: networkFailures,
            parseOrSizeErrors: parseOrSizeErrors
        )
    }

    private func performFetch(
        titleID rawTitleID: String,
        buildID rawBuildID: String,
        to cheatsFolder: URL,
        frameworkURL: URL?,
        forceOverwriteUserFile: Bool,
        includePreview: Bool
    ) async -> ManualFetchResult {
        let timestamp = Int64(now().timeIntervalSince1970)
        guard let tid = Self.normalizeHex16(rawTitleID),
              let bid = Self.normalizeHex16(rawBuildID) else {
            return .saved(GameCheatFetchReceipt(
                titleID: rawTitleID.uppercased(),
                buildID: rawBuildID.uppercased(),
                status: "error",
                fetchedAt: TimeInterval(timestamp),
                origin: "fetched",
                detail: "invalid_id"
            ))
        }

        let payload = await fetchMergedPayload(titleID: tid, buildID: bid)
        let fileName = "\(bid).txt"
        let destURL = cheatsFolder.appendingPathComponent(fileName)
        let fm = FileManager.default
        let store = GameCheatsStore(titleID: tid, cheatsFolder: cheatsFolder, frameworkURL: frameworkURL)
        let existingURL = store.existingCheatURL(for: bid, fileManager: fm) ?? destURL
        let existingExists = fm.fileExists(atPath: existingURL.path)

        if payload.mergedEntries.isEmpty {
            let status: String
            if payload.reachableResponses == 0 && payload.networkFailures > 0 {
                status = "offline"
            } else if payload.parseOrSizeErrors > 0 && payload.reachableResponses == payload.parseOrSizeErrors {
                status = "error"
            } else if payload.networkFailures > 0 && payload.reachableResponses == 0 {
                status = "offline"
            } else {
                status = "not_found"
            }

            let receipt = GameCheatFetchReceipt(
                titleID: tid,
                buildID: bid,
                status: status,
                sources: [],
                entryCount: 0,
                fetchedAt: TimeInterval(timestamp),
                fileName: "",
                fileSHA256: "",
                origin: "fetched",
                detail: ""
            )
            // Keep existing local cheat file & valid found receipt intact when offline.
            if status != "offline" || !existingExists {
                try? store.writeFetchReceipt(receipt)
            }
            return .saved(receipt)
        }

        // Order Master Codes `{...}` first, preserving relative order within each bucket.
        let ordered = payload.mergedEntries.filter(\.isMaster) + payload.mergedEntries.filter { !$0.isMaster }
        let renderedText = ordered.map(\.text).joined(separator: "\n\n") + "\n"
        let renderedData = Data(renderedText.utf8)
        guard renderedData.count <= GameCheatsStore.maxFileBytes else {
            return .saved(GameCheatFetchReceipt(
                titleID: tid,
                buildID: bid,
                status: "error",
                sources: payload.hitSources,
                entryCount: ordered.count,
                fetchedAt: TimeInterval(timestamp),
                origin: "fetched",
                detail: "file_too_large"
            ))
        }
        let newSHA256 = Self.sha256Hex(renderedData)

        // User-file protection: only overwrite if target does not exist, or matches managed fetched/bundled SHA256.
        if !forceOverwriteUserFile, existingExists,
           let existingData = try? Data(contentsOf: existingURL) {
            let existingSHA = Self.sha256Hex(existingData).lowercased()
            let existingReceipt = store.readFetchReceipt(currentBuildID: bid)
            let seededHashes = store.readSeededHashes()

            let matchesManagedFetch = existingReceipt.map {
                $0.fileName.caseInsensitiveCompare(existingURL.lastPathComponent) == .orderedSame
                    && ($0.origin == "fetched" || $0.origin == "bundled")
                    && $0.fileSHA256.lowercased() == existingSHA
            } ?? false
            let matchesSeeded = seededHashes[existingURL.lastPathComponent]?.lowercased() == existingSHA
                || seededHashes[fileName]?.lowercased() == existingSHA

            if !matchesManagedFetch && !matchesSeeded {
                let preserved = GameCheatFetchReceipt(
                    titleID: tid,
                    buildID: bid,
                    status: "preserved_user",
                    sources: payload.hitSources,
                    entryCount: ordered.count,
                    fetchedAt: TimeInterval(timestamp),
                    fileName: existingURL.lastPathComponent,
                    fileSHA256: existingSHA,
                    origin: "user",
                    detail: "Existing user cheat file preserved"
                )
                try? store.writeFetchReceipt(preserved)
                if includePreview {
                    let preview = store.buildOnlinePreview(
                        titleID: tid,
                        buildID: bid,
                        sources: payload.hitSources,
                        onlineText: renderedText,
                        onlineSHA256: newSHA256
                    )
                    return .preview(receipt: preserved, preview: preview)
                }
                return .saved(preserved)
            }
        }

        do {
            try fm.createDirectory(at: cheatsFolder, withIntermediateDirectories: true)
            try renderedData.write(to: destURL, options: .atomic)
            if existingURL.deletingLastPathComponent() == cheatsFolder && existingURL.lastPathComponent != fileName {
                try? fm.removeItem(at: existingURL)
            }
            // Explicit user fetch re-enables a previously deleted file name so it isn't blocked later.
            try? store.unmarkDeletedCheatFile(named: fileName)
            try? store.unmarkSeededCheatFile(named: fileName)
            let receipt = GameCheatFetchReceipt(
                titleID: tid,
                buildID: bid,
                status: "found",
                sources: payload.hitSources,
                entryCount: ordered.count,
                fetchedAt: TimeInterval(timestamp),
                fileName: fileName,
                fileSHA256: newSHA256,
                origin: "fetched",
                detail: ""
            )
            try store.writeFetchReceipt(receipt)
            return .saved(receipt)
        } catch {
            return .saved(GameCheatFetchReceipt(
                titleID: tid,
                buildID: bid,
                status: "error",
                sources: payload.hitSources,
                entryCount: 0,
                fetchedAt: TimeInterval(timestamp),
                origin: "fetched",
                detail: error.localizedDescription
            ))
        }
    }

    /// Parses one `switch-cheats-db` JSON document for `buildID` (case-insensitive, skipping `"attribution"`).
    /// Returns `nil` when `data` is not a valid JSON dictionary, or `[]` when the build is absent / empty.
    static func parseBuildEntries(
        from data: Data,
        buildID: String
    ) -> [(header: String, text: String, isMaster: Bool)]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let target = buildID.uppercased()

        var matchedDict: [String: Any]?
        if let exact = root.first(where: { $0.key != "attribution" && $0.key.uppercased() == target })?.value as? [String: Any] {
            matchedDict = exact
        } else if let prefix = root.first(where: {
            $0.key != "attribution"
                && $0.key.count >= 16
                && $0.key.prefix(16).uppercased() == target
        })?.value as? [String: Any] {
            matchedDict = prefix
        }
        guard let entriesDict = matchedDict else {
            return []
        }

        var out: [(header: String, text: String, isMaster: Bool)] = []
        for rawKey in entriesDict.keys.sorted() {
            guard let rawValue = entriesDict[rawKey] as? String else { continue }
            let trimmedKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKey.isEmpty else { continue }

            let isMaster = trimmedKey.hasPrefix("{") && trimmedKey.hasSuffix("}")
            let header: String
            if (trimmedKey.hasPrefix("[") && trimmedKey.hasSuffix("]")) || isMaster {
                header = trimmedKey
            } else {
                header = "[\(trimmedKey)]"
            }

            let normalizedBody = rawValue
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedBody.isEmpty else { continue }

            let formatted: String
            let firstLine = normalizedBody.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            if firstLine == header || firstLine == trimmedKey {
                formatted = normalizedBody
            } else {
                formatted = "\(header)\n\(normalizedBody)"
            }
            out.append((header: header, text: formatted, isMaster: isMaster))
        }
        return out
    }
}
