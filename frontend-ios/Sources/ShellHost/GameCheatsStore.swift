import CryptoKit
import Foundation
import ShellUI

/// Reads, classifies, imports, and persists Atmosphère cheats for a game inside `Documents/games/<TID>/cheats/`.
/// Mirrors `dm/tools/cheat_bake.py` and `dm/host/hle_cheats.c` so Mac and iOS report identical four-tier
/// compatibility states, Zing/EdiZon section grouping, and Switch trigger key pills.
public struct GameCheatsStore: Sendable {
    public enum StoreError: Error, Equatable, Sendable {
        case fileTooLarge
    }

    public static let maxFileBytes = 4 * 1024 * 1024
    public static let seededFileName = ".seeded.json"
    public static let deletedFileName = ".deleted.json"
    public static let fetchReceiptFileName = ".cheats-fetch.json"
    private static let nameMax = 127
    private static let cheatMax = 256
    private static let insMax = 0x2000

    public static func isWithinSizeLimit(_ url: URL, limit: Int = maxFileBytes) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              size >= 0 else {
            return false
        }
        return size <= Int64(limit)
    }

    public struct FixupsMetadata: Equatable, Sendable {
        public var buildID: String?
        public var mainRxEnd: UInt64?

        public init(buildID: String? = nil, mainRxEnd: UInt64? = nil) {
            self.buildID = buildID
            self.mainRxEnd = mainRxEnd
        }

        public static func parse(_ text: String) -> FixupsMetadata {
            var buildID: String?
            var mainRxEnd: UInt64?
            var textEnd: UInt64?
            for rawLine in text.split(whereSeparator: \.isNewline) where rawLine.hasPrefix("#") {
                let fields = rawLine.dropFirst().split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard fields.count >= 2 else { continue }
                switch fields[0] {
                case "BUILD_ID":
                    if buildID == nil, fields[1].count >= 16, fields[1].prefix(16).allSatisfy(\.isHexDigit) {
                        buildID = fields[1].prefix(16).uppercased()
                    }
                case "MAIN_RX_END":
                    mainRxEnd = parseHexOrDec(fields[1])
                case "TEXT_END":
                    textEnd = parseHexOrDec(fields[1])
                default:
                    break
                }
            }
            if mainRxEnd == nil, let textEnd, textEnd > 0 {
                mainRxEnd = (textEnd &+ 0x3FFF) & ~UInt64(0x3FFF)
            }
            return FixupsMetadata(buildID: buildID, mainRxEnd: mainRxEnd)
        }
    }

    public struct TrampolineMetadata: Equatable, Sendable {
        public struct EntryRecord: Equatable, Sendable {
            public var kind: String
            public var keyMask: UInt64
            public var detail: String
            public var isBaked: Bool { kind == "baked_static" || kind == "baked_conditional" }

            public init(kind: String, keyMask: UInt64 = 0, detail: String = "") {
                self.kind = kind
                self.keyMask = keyMask
                self.detail = detail
            }
        }

        public var buildID: String?
        public var mainRxEnd: UInt64?
        public var entries: [String: EntryRecord]
        public var bakedSiteKeys: Set<String>

        public static func parse(_ text: String) -> TrampolineMetadata {
            var buildID: String?
            var mainRxEnd: UInt64?
            var entries: [String: EntryRecord] = [:]
            var bakedSiteKeys = Set<String>()
            var colMap: [String: Int]?

            for rawLine in text.split(whereSeparator: \.isNewline) {
                if rawLine.hasPrefix("#") {
                    let fields = rawLine.dropFirst().split(whereSeparator: { $0 == " " || $0 == "\t" })
                    guard fields.count >= 2 else { continue }
                    if fields[0] == "BUILD_ID", fields[1].count >= 16, fields[1].prefix(16).allSatisfy(\.isHexDigit) {
                        buildID = fields[1].prefix(16).uppercased()
                    } else if fields[0] == "MAIN_RX_END" {
                        mainRxEnd = parseHexOrDec(fields[1])
                    }
                    continue
                }
                let cols = rawLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard !cols.isEmpty else { continue }
                if colMap == nil {
                    if cols[0] == "row_type" {
                        var map: [String: Int] = [:]
                        for (idx, name) in cols.enumerated() { map[name] = idx }
                        colMap = map
                        continue
                    }
                    colMap = [
                        "row_type": 0, "name": 1, "cheat_key": 2, "kind": 3,
                        "slot_id": 4, "variant_mask": 5, "target_off": 6,
                        "patched_word": 7, "key_mask": 8, "detail": 9,
                    ]
                }
                guard let map = colMap else { continue }
                func field(_ name: String) -> String {
                    guard let idx = map[name], idx < cols.count else { return "" }
                    return cols[idx]
                }
                let rowType = field("row_type")
                let key = field("cheat_key")
                guard !key.isEmpty else { continue }
                let kind = field("kind")
                let keyMask = parseHexOrDec(field("key_mask")) ?? 0
                let detail = field("detail")
                if rowType == "entry" {
                    entries[key] = EntryRecord(kind: kind, keyMask: keyMask, detail: detail)
                } else if rowType == "site" {
                    if kind != "unsafe_code" && kind != "unbaked_code" {
                        bakedSiteKeys.insert(key)
                    }
                    if let existing = entries[key] {
                        let resolvedDetail = existing.detail.isEmpty ? detail : existing.detail
                        entries[key] = EntryRecord(
                            kind: existing.isBaked ? existing.kind : kind,
                            keyMask: existing.keyMask | keyMask,
                            detail: resolvedDetail
                        )
                    } else {
                        entries[key] = EntryRecord(kind: kind, keyMask: keyMask, detail: detail)
                    }
                }
            }
            return TrampolineMetadata(buildID: buildID, mainRxEnd: mainRxEnd, entries: entries, bakedSiteKeys: bakedSiteKeys)
        }

        public func isBaked(key: String) -> Bool {
            if entries[key]?.kind == "unsafe_code" { return false }
            return bakedSiteKeys.contains(key) || (entries[key]?.isBaked ?? false)
        }
    }

    public let titleID: String
    public let cheatsFolder: URL
    public let frameworkURL: URL?

    public init(titleID: String, appFolder: URL, frameworkURL: URL?) {
        self.titleID = titleID.uppercased()
        self.cheatsFolder = appFolder.appendingPathComponent("cheats", isDirectory: true)
        self.frameworkURL = frameworkURL
    }

    public init(titleID: String, cheatsFolder: URL, frameworkURL: URL?) {
        self.titleID = titleID.uppercased()
        self.cheatsFolder = cheatsFolder
        self.frameworkURL = frameworkURL
    }

    public var masterOffURL: URL { cheatsFolder.appendingPathComponent(".cheats-off-\(titleID)") }
    public var masterOn: Bool { !FileManager.default.fileExists(atPath: masterOffURL.path) }

    public func enabledURL(for buildID: String) -> URL {
        cheatsFolder.appendingPathComponent(buildID.uppercased() + ".enabled")
    }

    public func flatCheatURL(for buildID: String) -> URL {
        cheatsFolder.appendingPathComponent(buildID.uppercased() + ".txt")
    }

    private var scanFolders: [URL] {
        [
            cheatsFolder,
            cheatsFolder.appendingPathComponent("atmosphere/contents/\(titleID)/cheats", isDirectory: true),
            cheatsFolder.appendingPathComponent("contents/\(titleID)/cheats", isDirectory: true),
        ]
    }

    // MARK: - Metadata & Files

    public func readFixupsMetadata() -> FixupsMetadata {
        guard let fw = frameworkURL else { return FixupsMetadata() }
        let url = fw.appendingPathComponent("dm/main.fixups.tsv")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return FixupsMetadata() }
        return FixupsMetadata.parse(text)
    }

    public func readTrampolineMetadata() -> TrampolineMetadata? {
        guard let fw = frameworkURL else { return nil }
        let url = fw.appendingPathComponent("dm/cheat_trampolines.tsv")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return TrampolineMetadata.parse(text)
    }

    public func resolvedBuildID() -> String? {
        readFixupsMetadata().buildID ?? readTrampolineMetadata()?.buildID
    }

    public func foundFiles() -> [(buildID: String, url: URL)] {
        let fm = FileManager.default
        var seen = Set<String>()
        var out: [(buildID: String, url: URL)] = []
        for dir in scanFolders {
            let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
            for name in names where name.count >= 20 && name.lowercased().hasSuffix(".txt") && name.prefix(16).allSatisfy(\.isHexDigit) {
                let id = name.prefix(16).uppercased()
                guard seen.insert(id).inserted else { continue }
                out.append((buildID: id, url: dir.appendingPathComponent(name)))
            }
        }
        return out.sorted { $0.buildID < $1.buildID }
    }

    public static func buildID(ofFileNamed name: String) -> String? {
        guard name.lowercased().hasSuffix(".txt") else { return nil }
        let stem = String(name.dropLast(4))
        guard (stem.count == 16 || stem.count == 32), stem.allSatisfy(\.isHexDigit) else { return nil }
        return stem.prefix(16).uppercased()
    }

    // MARK: - Snapshots & Mutations

    private func matchedFile(
        for currentBuild: String?,
        in found: [(buildID: String, url: URL)]
    ) -> (buildID: String, url: URL)? {
        if let bid = currentBuild {
            return found.first(where: { $0.buildID == bid })
        }
        return found.count == 1 ? found[0] : nil
    }

    public var seededURL: URL { cheatsFolder.appendingPathComponent(Self.seededFileName) }
    public var deletedURL: URL { cheatsFolder.appendingPathComponent(Self.deletedFileName) }
    public var fetchReceiptURL: URL { cheatsFolder.appendingPathComponent(Self.fetchReceiptFileName) }

    public func readSeededHashes(fileManager fm: FileManager = .default) -> [String: String] {
        guard fm.fileExists(atPath: seededURL.path),
              let data = try? Data(contentsOf: seededURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    public func readDeletedCheatFiles(fileManager fm: FileManager = .default) -> Set<String> {
        guard fm.fileExists(atPath: deletedURL.path),
              let data = try? Data(contentsOf: deletedURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(decoded)
    }

    public func readFetchReceipt(currentBuildID: String? = nil, fileManager fm: FileManager = .default) -> GameCheatFetchReceipt? {
        guard fm.fileExists(atPath: fetchReceiptURL.path),
              let data = try? Data(contentsOf: fetchReceiptURL),
              let receipt = try? JSONDecoder().decode(GameCheatFetchReceipt.self, from: data) else {
            return nil
        }
        if let currentBuildID, !currentBuildID.isEmpty, !receipt.buildID.isEmpty,
           receipt.buildID.uppercased() != currentBuildID.uppercased() {
            return nil
        }
        return receipt
    }

    public func writeFetchReceipt(_ receipt: GameCheatFetchReceipt, fileManager fm: FileManager = .default) throws {
        try fm.createDirectory(at: cheatsFolder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(receipt)
        try data.write(to: fetchReceiptURL, options: .atomic)
    }

    public func unmarkDeletedCheatFile(named fileName: String, fileManager fm: FileManager = .default) throws {
        var deleted = readDeletedCheatFiles(fileManager: fm)
        guard deleted.remove(fileName) != nil else { return }
        try writeDeletedCheatFiles(deleted, fileManager: fm)
    }

    public func unmarkSeededCheatFile(named fileName: String, fileManager fm: FileManager = .default) throws {
        var seeded = readSeededHashes(fileManager: fm)
        guard seeded.removeValue(forKey: fileName) != nil else { return }
        try writeSeededHashes(seeded, fileManager: fm)
    }

    private func writeSeededHashes(_ map: [String: String], fileManager fm: FileManager) throws {
        try fm.createDirectory(at: cheatsFolder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(map)
        try data.write(to: seededURL, options: .atomic)
    }

    private func writeDeletedCheatFiles(_ set: Set<String>, fileManager fm: FileManager) throws {
        try fm.createDirectory(at: cheatsFolder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(set.sorted())
        try data.write(to: deletedURL, options: .atomic)
    }

    /// Seeds bundled `<BID>.txt` and `.cheats-fetch.json` from `<framework>/dm/cheats/` into `cheatsFolder`
    /// with 4-state user protection (never re-seeds deleted files, detects deletion via Files app, preserves
    /// user-imported or modified files, and updates unedited bundled files on app upgrade). Never modifies `.enabled`.
    public func seedBundledCheatsIfNeeded(fileManager fm: FileManager = .default) {
        var seeded = readSeededHashes(fileManager: fm)
        var deleted = readDeletedCheatFiles(fileManager: fm)
        var seededChanged = false
        var deletedChanged = false

        // State 2 (pre-pass): any previously seeded .txt file missing from cheatsFolder was deleted in Files app.
        for fileName in Array(seeded.keys) where fileName != Self.fetchReceiptFileName {
            let targetURL = cheatsFolder.appendingPathComponent(fileName)
            if !fm.fileExists(atPath: targetURL.path) {
                deleted.insert(fileName)
                seeded.removeValue(forKey: fileName)
                deletedChanged = true
                seededChanged = true
            }
        }

        let bundledDir = frameworkURL?.appendingPathComponent("dm/cheats", isDirectory: true)
        let bundledNames: [String] = {
            guard let bundledDir else { return [] }
            return ((try? fm.contentsOfDirectory(atPath: bundledDir.path)) ?? []).sorted()
        }()
        let bundledCheatNames = bundledNames.filter { Self.buildID(ofFileNamed: $0) != nil }

        var previousBundledTxtHashes: Set<String> = []
        var canSyncBundledReceipt = false

        if let bundledDir, !bundledCheatNames.isEmpty {
            for name in bundledCheatNames {
                let srcURL = bundledDir.appendingPathComponent(name)
                guard Self.isWithinSizeLimit(srcURL), let srcData = try? Data(contentsOf: srcURL) else { continue }
                let bundledHash = Self.sha256Hex(srcData)
                let destURL = cheatsFolder.appendingPathComponent(name)

                // State 1: deleted previously -> never re-seed.
                if deleted.contains(name) { continue }

                if fm.fileExists(atPath: destURL.path) {
                    // State 3: user-imported (not in .seeded.json) or user-modified (SHA256 mismatch) -> never overwrite.
                    guard let recordedHash = seeded[name] else { continue }
                    guard let destData = try? Data(contentsOf: destURL) else { continue }
                    let currentHash = Self.sha256Hex(destData)
                    if currentHash.lowercased() != recordedHash.lowercased() { continue }
                    previousBundledTxtHashes.insert(recordedHash.lowercased())

                    // State 4 (upgrade): player did not alter the bundled file; refresh if bundle changed.
                    if currentHash.lowercased() != bundledHash.lowercased() {
                        do {
                            try fm.createDirectory(at: cheatsFolder, withIntermediateDirectories: true)
                            try srcData.write(to: destURL, options: .atomic)
                            seeded[name] = bundledHash
                            seededChanged = true
                        } catch {
                            continue
                        }
                    }
                    canSyncBundledReceipt = true
                } else {
                    // State 4 (first install): copy atomically without creating or touching .enabled.
                    do {
                        try fm.createDirectory(at: cheatsFolder, withIntermediateDirectories: true)
                        try srcData.write(to: destURL, options: .atomic)
                        seeded[name] = bundledHash
                        seededChanged = true
                        canSyncBundledReceipt = true
                    } catch {
                        continue
                    }
                }
            }

            let bundledReceiptURL = bundledDir.appendingPathComponent(Self.fetchReceiptFileName)
            if canSyncBundledReceipt,
               Self.isWithinSizeLimit(bundledReceiptURL),
               let receiptData = try? Data(contentsOf: bundledReceiptURL) {
                let bundledReceiptHash = Self.sha256Hex(receiptData)
                let shouldCopyReceipt: Bool = {
                    if !fm.fileExists(atPath: fetchReceiptURL.path) { return true }
                    guard let existingData = try? Data(contentsOf: fetchReceiptURL) else { return false }
                    let existingHash = Self.sha256Hex(existingData).lowercased()
                    if let seededReceiptHash = seeded[Self.fetchReceiptFileName]?.lowercased(),
                       existingHash == seededReceiptHash {
                        return true
                    }
                    if let existingReceipt = try? JSONDecoder().decode(GameCheatFetchReceipt.self, from: existingData) {
                        if existingReceipt.origin == "bundled" { return true }
                        if previousBundledTxtHashes.contains(existingReceipt.fileSHA256.lowercased()) { return true }
                    }
                    return false
                }()
                if shouldCopyReceipt {
                    let existingHash = (try? Data(contentsOf: fetchReceiptURL)).map { Self.sha256Hex($0).lowercased() }
                    if existingHash != bundledReceiptHash.lowercased() {
                        try? fm.createDirectory(at: cheatsFolder, withIntermediateDirectories: true)
                        try? receiptData.write(to: fetchReceiptURL, options: .atomic)
                    }
                    if seeded[Self.fetchReceiptFileName]?.lowercased() != bundledReceiptHash.lowercased() {
                        seeded[Self.fetchReceiptFileName] = bundledReceiptHash
                        seededChanged = true
                    }
                }
            }
        }

        if deletedChanged {
            try? writeDeletedCheatFiles(deleted, fileManager: fm)
        }
        if seededChanged {
            try? writeSeededHashes(seeded, fileManager: fm)
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func loadSnapshot(gameTitle: String) -> GameCheatsSnapshot {
        seedBundledCheatsIfNeeded()
        let fixups = readFixupsMetadata()
        let trampolines = readTrampolineMetadata()
        let currentBuild = fixups.buildID ?? trampolines?.buildID
        let found = foundFiles()
        let matched = matchedFile(for: currentBuild, in: found)
        let activeBuildID = currentBuild ?? matched?.buildID
        let otherBuilds = found.map(\.buildID).filter { $0 != activeBuildID }
        let receipt = readFetchReceipt(currentBuildID: activeBuildID)

        let fuseGuard = CheatFuseGuard(titleID: titleID, folder: cheatsFolder)
        let fuseAlert: GameCheatFuseAlert? = fuseGuard.readTripped().map {
            GameCheatFuseAlert(disabledItems: $0.disabled, disabledMaster: $0.disabledMaster)
        }

        var entries: [GameCheatEntry] = []
        if let matched, Self.isWithinSizeLimit(matched.url), let data = try? Data(contentsOf: matched.url) {
            let enabled = readEnabled(for: matched.buildID)
            let metaURL = matched.url.deletingPathExtension().appendingPathExtension("meta.tsv")
            let fallbackMetaURL = cheatsFolder.appendingPathComponent(matched.buildID + ".meta.tsv")
            let meta: String? = {
                if Self.isWithinSizeLimit(metaURL), let text = try? String(contentsOf: metaURL, encoding: .utf8) {
                    return text
                }
                if Self.isWithinSizeLimit(fallbackMetaURL), let text = try? String(contentsOf: fallbackMetaURL, encoding: .utf8) {
                    return text
                }
                return nil
            }()
            entries = Self.parse(
                data,
                meta: meta,
                enabled: enabled,
                rxEnd: fixups.mainRxEnd,
                trampolines: trampolines,
                buildID: matched.buildID
            )
        }

        return GameCheatsSnapshot(
            gameID: titleID,
            gameTitle: gameTitle,
            buildID: currentBuild,
            hasCurrentFile: matched != nil,
            otherBuildIDs: otherBuilds,
            masterOn: masterOn,
            entries: entries,
            fuseAlert: fuseAlert,
            exportFileURL: matched?.url,
            fetchReceipt: receipt
        )
    }

    public func loadSummary(gameTitle: String) -> GameCheatsSummary {
        let snap = loadSnapshot(gameTitle: gameTitle)
        let enabledCount = snap.entries.filter { $0.switchableOnIOS && $0.enabled }.count
        return GameCheatsSummary(
            buildID: snap.buildID,
            totalCount: snap.totalActiveCount,
            enabledCount: enabledCount,
            needsBakeCount: snap.codeNeedsBakeCount,
            masterOn: snap.masterOn,
            fuseTripped: snap.fuseAlert != nil
        )
    }

    public func setMaster(_ on: Bool) throws {
        let fm = FileManager.default
        if on {
            if fm.fileExists(atPath: masterOffURL.path) {
                try fm.removeItem(at: masterOffURL)
            }
        } else {
            try fm.createDirectory(at: cheatsFolder, withIntermediateDirectories: true)
            try Data().write(to: masterOffURL, options: .atomic)
        }
    }

    public func setEntryEnabled(key: String, on: Bool, gameTitle: String) throws -> GameCheatsSnapshot {
        let snap = loadSnapshot(gameTitle: gameTitle)
        guard snap.hasCurrentFile,
              let matched = matchedFile(for: snap.buildID, in: foundFiles()) else {
            return snap
        }
        let buildID = matched.buildID
        var enabledSet = readEnabled(for: buildID)
        if on { enabledSet.insert(key) } else { enabledSet.remove(key) }
        let ordered = snap.entries.filter { $0.switchableOnIOS && enabledSet.contains($0.key) }.map(\.key)
        try FileManager.default.createDirectory(at: cheatsFolder, withIntermediateDirectories: true)
        let body = ordered.map { $0 + "\n" }.joined()
        try Data(body.utf8).write(to: enabledURL(for: buildID), options: .atomic)
        return loadSnapshot(gameTitle: gameTitle)
    }

    public func dismissFuseAlert(gameTitle: String) -> GameCheatsSnapshot {
        CheatFuseGuard(titleID: titleID, folder: cheatsFolder).clearTripped()
        return loadSnapshot(gameTitle: gameTitle)
    }

    /// Saves a validated `.txt` cheat payload directly under `Documents/games/<TID>/cheats/<targetBuildID>.txt`.
    public func saveCheatFile(data: Data, targetBuildID: String, gameTitle: String) throws -> GameCheatsSnapshot {
        guard data.count <= Self.maxFileBytes else {
            throw StoreError.fileTooLarge
        }
        try FileManager.default.createDirectory(at: cheatsFolder, withIntermediateDirectories: true)
        let dest = flatCheatURL(for: targetBuildID)
        try data.write(to: dest, options: .atomic)
        let fileName = dest.lastPathComponent
        try? unmarkDeletedCheatFile(named: fileName)
        try? unmarkSeededCheatFile(named: fileName)
        return loadSnapshot(gameTitle: gameTitle)
    }

    /// Deletes the active cheat file, clears its `.enabled` switches, and records it in `.deleted.json`
    /// so bundled re-seeding does not restore a file the player explicitly deleted.
    public func deleteCurrentCheatFile(gameTitle: String) throws -> GameCheatsSnapshot {
        let fm = FileManager.default
        let fixups = readFixupsMetadata()
        let trampolines = readTrampolineMetadata()
        let currentBuild = fixups.buildID ?? trampolines?.buildID
        guard let matched = matchedFile(for: currentBuild, in: foundFiles()) else {
            return loadSnapshot(gameTitle: gameTitle)
        }
        let fileName = matched.url.lastPathComponent
        if fm.fileExists(atPath: matched.url.path) {
            try fm.removeItem(at: matched.url)
        }
        let enabledFile = enabledURL(for: matched.buildID)
        if fm.fileExists(atPath: enabledFile.path) {
            try? fm.removeItem(at: enabledFile)
        }
        if let receipt = readFetchReceipt(currentBuildID: matched.buildID, fileManager: fm),
           receipt.fileName == fileName || receipt.buildID.uppercased() == matched.buildID.uppercased() {
            try? fm.removeItem(at: fetchReceiptURL)
        }
        var deleted = readDeletedCheatFiles(fileManager: fm)
        deleted.insert(fileName)
        try writeDeletedCheatFiles(deleted, fileManager: fm)
        var seeded = readSeededHashes(fileManager: fm)
        var seededChanged = seeded.removeValue(forKey: fileName) != nil
        if seeded.removeValue(forKey: Self.fetchReceiptFileName) != nil { seededChanged = true }
        if seededChanged {
            try? writeSeededHashes(seeded, fileManager: fm)
        }
        return loadSnapshot(gameTitle: gameTitle)
    }

    public func readEnabled(for buildID: String) -> Set<String> {
        guard let text = try? String(contentsOf: enabledURL(for: buildID), encoding: .utf8) else { return [] }
        return Set(text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty })
    }

    // MARK: - Parser & Static Analyzer (aligned with dm/tools/cheat_bake.py)

    private struct RawEntry {
        var entry: GameCheatEntry
        var wordsCount = 0
        var words: [UInt32] = []
        var hasNonZeroWord = false
        var junk = false
        var pairName = ""
        var offByMeta = false
        var pairOff = false
        var nd = false
    }

    public static func parse(
        _ data: Data,
        meta: String? = nil,
        enabled: Set<String> = [],
        rxEnd: UInt64? = nil,
        trampolines: TrampolineMetadata? = nil,
        buildID: String? = nil
    ) -> [GameCheatEntry] {
        let raw = [UInt8](data)
        func ws(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }
        func hex(_ c: UInt8) -> Bool { (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66) }
        func hexVal(_ c: UInt8) -> UInt32 {
            if c >= 0x30 && c <= 0x39 { return UInt32(c - 0x30) }
            if c >= 0x41 && c <= 0x46 { return UInt32(c - 0x41 + 10) }
            return UInt32(c - 0x61 + 10)
        }

        var text: [UInt8] = []
        text.reserveCapacity(raw.count * 2)
        for (i, c) in raw.enumerated() {
            if (c == 0x5B || c == 0x7B) && i >= 8, raw[(i - 8)..<i].allSatisfy(hex), i == 8 || ws(raw[i - 9]) {
                text.append(0x0B)
            }
            text.append(c)
        }

        var entries: [RawEntry] = []
        var section = ""

        func finalizePrev() {
            guard var prev = entries.last, prev.wordsCount >= 0 else { return }
            if !prev.entry.isMaster && !prev.entry.isBroken && prev.words.count == 1
                && (prev.words[0] == 0x2000_0000 || prev.words[0] == 0x2000_0001) {
                let isStart = prev.words[0] == 0x2000_0000
                prev.wordsCount = 0
                prev.words.removeAll()
                prev.entry.isLabel = true
                prev.entry.isSectionMarker = true
                if isStart {
                    section = prev.entry.name
                    prev.entry.section = section
                } else {
                    prev.entry.section = section
                    section = ""
                }
                entries[entries.count - 1] = prev
            }
        }

        for piece in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == 0x0A || $0 == 0x0B }) {
            var p = piece[...]
            while let f = p.first, f == 0x20 || f == 0x09 { p = p.dropFirst() }
            var rest = p
            if let f = p.first, f == 0x5B || f == 0x7B {
                finalizePrev()
                let end: UInt8 = f == 0x5B ? 0x5D : 0x7D
                guard let q = p.dropFirst().firstIndex(of: end), q > p.startIndex + 1, entries.count < cheatMax else {
                    entries.append(RawEntry(entry: GameCheatEntry(name: "", key: "", isLabel: true), wordsCount: -1))
                    continue
                }
                var keep = min(q - (p.startIndex + 1), nameMax)
                while keep > 0, (p[p.startIndex + 1 + keep] & 0xC0) == 0x80 { keep -= 1 }
                let name = String(decoding: p[(p.startIndex + 1)..<(p.startIndex + 1 + keep)], as: UTF8.self)
                let earlier = entries.filter { $0.wordsCount >= 0 && $0.entry.name == name }.count
                let key = earlier > 0 ? "\(name) #\(earlier + 1)" : name
                var item = GameCheatEntry(name: name, key: key, isMaster: f == 0x7B)
                if let mark = edizonSectionMarker(name) {
                    item.isSectionMarker = true
                    if mark.start { section = mark.name }
                    item.section = section
                    if !mark.start { section = "" }
                } else {
                    item.section = section
                }
                entries.append(RawEntry(entry: item))
                rest = p[(q + 1)...]
                while let r = rest.first, r == 0x20 || r == 0x09 || r == 0x0D { rest = rest.dropFirst() }
                if rest.isEmpty { continue }
            }
            guard var current = entries.last, current.wordsCount >= 0 else { continue }
            var gotWords: [UInt32] = [], prose = false, oddhex = false
            for token in rest.split(whereSeparator: { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) {
                if !token.allSatisfy(hex) { prose = true; continue }
                if token.count % 8 != 0 { oddhex = true; continue }
                var pos = token.startIndex
                while pos < token.endIndex {
                    var word: UInt32 = 0
                    for _ in 0..<8 {
                        word = (word << 4) | hexVal(token[pos])
                        pos = token.index(after: pos)
                    }
                    gotWords.append(word)
                }
            }
            if gotWords.isEmpty && !prose && !oddhex { continue }
            if prose && gotWords.isEmpty && !oddhex { current.junk = true }
            else if prose || oddhex { current.entry.isBroken = true }
            else {
                current.wordsCount += gotWords.count
                if gotWords.contains(where: { $0 != 0 }) { current.hasNonZeroWord = true }
                let budget = max(0, insMax - current.words.count)
                if budget > 0 { current.words.append(contentsOf: gotWords.prefix(budget)) }
            }
            entries[entries.count - 1] = current
        }
        finalizePrev()
        entries.removeAll { $0.wordsCount < 0 }

        for i in entries.indices where !entries[i].entry.isBroken {
            if entries[i].wordsCount == 0 && entries[i].junk {
                entries[i].entry.isBroken = true
            } else if entries[i].wordsCount == 0
                || (entries[i].entry.isSectionMarker
                    && !entries[i].entry.isMaster
                    && !entries[i].hasNonZeroWord) {
                entries[i].wordsCount = 0
                entries[i].words.removeAll()
                entries[i].entry.isLabel = true
            } else if !hasValidOpcodes(entries[i].words) {
                entries[i].entry.isBroken = true
            }
        }
        if let meta { applyMeta(meta, to: &entries) }
        linkPairs(&entries)

        classify(&entries, rxEnd: rxEnd, trampolines: trampolines, buildID: buildID, enabled: enabled)
        return entries.filter { !$0.pairOff }.map(\.entry)
    }

    private static func edizonSectionMarker(_ name: String) -> (start: Bool, name: String)? {
        guard name.count >= 4, name.hasSuffix("--") else { return nil }
        if name.hasPrefix("--SectionStart:") { return (true, String(name.dropFirst(15).dropLast(2))) }
        if name.hasPrefix("--SectionEnd:") { return (false, String(name.dropFirst(13).dropLast(2))) }
        return nil
    }

    private static func applyMeta(_ meta: String, to entries: inout [RawEntry]) {
        var head: [String: Int]?
        var cursor = 0
        for line in meta.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) where !line.hasPrefix("#") && !line.isEmpty {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let h = head else {
                var map: [String: Int] = [:]
                for (i, n) in f.enumerated() { map[n] = i }
                if map["name"] == nil { return }
                head = map
                continue
            }
            func col(_ n: String) -> String { h[n].flatMap { $0 < f.count ? f[$0] : nil } ?? "" }
            let kind = col("kind")
            if kind == "unresolved" { continue }
            var j = cursor
            while j < entries.count && entries[j].entry.name != col("name") { j += 1 }
            if j >= entries.count { continue }
            cursor = j + 1
            if !col("section").isEmpty && entries[j].entry.section.isEmpty { entries[j].entry.section = col("section") }
            if col("once") == "1" { entries[j].entry.isOnce = true }
            if kind == "patch-off" { entries[j].offByMeta = true }
            entries[j].pairName = col("pair")
            let address = col("address"), type = col("type")
            if col("action") == "never-decrease", entries[j].wordsCount == 0, !type.isEmpty,
               let colon = address.firstIndex(of: ":"), (Int(address[..<colon]) ?? 0) <= 1 {
                entries[j].nd = true
                entries[j].entry.isLabel = false
            }
        }
    }

    private static func linkPairs(_ entries: inout [RawEntry]) {
        var pair = [Int?](repeating: nil, count: entries.count)
        func plain(_ e: RawEntry) -> Bool { !e.entry.isLabel && !e.entry.isMaster && !e.nd && !e.entry.isBroken }
        for i in entries.indices where !entries[i].pairName.isEmpty && pair[i] == nil && plain(entries[i]) {
            guard let j = entries.indices.first(where: { $0 != i && pair[$0] == nil && plain(entries[$0]) && entries[$0].entry.name == entries[i].pairName }) else { continue }
            pair[i] = j; pair[j] = i
        }
        for i in entries.indices where pair[i] == nil && plain(entries[i]) {
            guard let a = onOffSplit(entries[i].entry.name) else { continue }
            for j in (i + 1)..<max(entries.count, i + 1) where pair[j] == nil && plain(entries[j]) {
                guard let b = onOffSplit(entries[j].entry.name), a.off != b.off, a.base.lowercased() == b.base.lowercased() else { continue }
                pair[i] = j; pair[j] = i
                entries[i].offByMeta = a.off; entries[j].offByMeta = b.off
                break
            }
        }
        for i in entries.indices where pair[i] != nil && entries[i].offByMeta {
            entries[i].pairOff = true
        }
    }

    private static func onOffSplit(_ name: String) -> (base: String, off: Bool)? {
        var s = Substring(name)
        while let l = s.last, l.isWhitespace { s = s.dropLast() }
        if let l = s.last, l == ")" || l == "]" { s = s.dropLast() }
        let off: Bool
        if s.count >= 3, s.suffix(3).lowercased() == "off" { off = true; s = s.dropLast(3) }
        else if s.count >= 2, s.suffix(2).lowercased() == "on" { off = false; s = s.dropLast(2) }
        else { return nil }
        var sep = false
        while let l = s.last, " -:_([".contains(l) { s = s.dropLast(); sep = true }
        guard sep, !s.isEmpty else { return nil }
        return (String(s), off)
    }

    private static func classify(
        _ entries: inout [RawEntry],
        rxEnd: UInt64?,
        trampolines: TrampolineMetadata?,
        buildID: String?,
        enabled: Set<String>
    ) {
        let effectiveRxEnd = rxEnd ?? trampolines?.mainRxEnd ?? 0
        let trampolinesMatch: Bool = {
            guard let trampolines else { return false }
            guard let expected = buildID?.uppercased(), !expected.isEmpty,
                  let tBuild = trampolines.buildID?.uppercased(), !tBuild.isEmpty else {
                return true
            }
            return expected == tBuild
        }()
        let activeTrampolines = trampolinesMatch ? trampolines : nil

        var masterDirty = Set<Int>()
        for pass in 0...1 {
            let wantMaster = (pass == 0)
            for idx in entries.indices {
                let raw = entries[idx]
                guard !raw.entry.isLabel, !raw.entry.isBroken, raw.entry.isMaster == wantMaster else { continue }
                var dirty = wantMaster ? Set<Int>() : masterDirty
                var keyMask: UInt64 = 0
                var hasCodeWrite = false
                var hasFixedHeap = false
                var hasFixedAddress = false
                var failedDecode = false

                var pc = 0
                while pc < raw.words.count {
                    guard let op = decodeOp(words: raw.words, index: pc) else {
                        failedDecode = true
                        break
                    }
                    switch op.op {
                    case 0:
                        let isMain = op.mem == 0 || op.mem >= 5
                        let isNonMain = op.mem >= 1 && op.mem <= 4
                        if isMain {
                            if !dirty.contains(op.reg) {
                                if effectiveRxEnd > 0, op.rel < effectiveRxEnd { hasCodeWrite = true }
                            } else {
                                hasCodeWrite = true
                            }
                        } else if isNonMain, !dirty.contains(op.reg) {
                            hasFixedAddress = true
                            if op.mem == 1, op.rel > 0 { hasFixedHeap = true }
                        }
                    case 1:
                        let isNonMain = op.mem >= 1 && op.mem <= 4
                        let isPointerChain = op.useReg && dirty.contains(op.reg)
                        if isNonMain, !isPointerChain {
                            hasFixedAddress = true
                        }
                    case 8, 0xC4:
                        keyMask |= op.keyMask
                    case 3, 4, 7, 9:
                        dirty.insert(op.reg)
                    case 5:
                        if op.flags == 0, op.mem >= 1, op.mem <= 4 {
                            hasFixedAddress = true
                        }
                        dirty.insert(op.reg)
                    case 6:
                        if op.inc { dirty.insert(op.reg) }
                    case 0xA:
                        if op.inc { dirty.insert(op.reg) }
                        if (op.operand == 3 || op.operand == 4 || op.operand == 5) && (op.mem == 0 || op.mem >= 5) {
                            hasCodeWrite = true
                        }
                    case 0xC1:
                        if op.cond != 1 && op.cond != 2 { dirty.insert(op.reg) }
                    case 0xC2:
                        if op.cond != 1 && op.cond != 2 {
                            for bit in 0..<16 where (op.regMask & (1 << bit)) != 0 { dirty.insert(bit) }
                        }
                    case 0xC3:
                        if op.extra < 0x80 { dirty.insert(op.reg) }
                    default:
                        break
                    }
                    pc += op.length
                }

                if failedDecode {
                    entries[idx].entry.isBroken = true
                    entries[idx].entry.capability = .dataReady
                    entries[idx].entry.hasFixedAddress = false
                    entries[idx].entry.unsafeCodeReason = nil
                    entries[idx].entry.triggerKeys = []
                    entries[idx].entry.enabled = false
                    continue
                }
                if wantMaster { masterDirty.formUnion(dirty) }
                let tRec = activeTrampolines?.entries[raw.entry.key]
                if let tm = tRec?.keyMask, tm != 0 { keyMask |= tm }

                let unsafeReason: String? = (tRec?.kind == "unsafe_code") ? tRec?.detail : nil
                let cap: CheatCapability
                if unsafeReason != nil {
                    cap = .codeNeedsBake
                } else if let activeTrampolines, activeTrampolines.isBaked(key: raw.entry.key) {
                    cap = .codeBaked
                } else if tRec?.kind == "unbaked_code" || hasCodeWrite {
                    cap = .codeNeedsBake
                } else if hasFixedHeap || hasFixedAddress {
                    cap = .fixedHeapWarning
                } else {
                    cap = .dataReady
                }

                entries[idx].entry.capability = cap
                entries[idx].entry.hasFixedAddress = hasFixedAddress
                entries[idx].entry.unsafeCodeReason = unsafeReason
                entries[idx].entry.triggerKeys = buttonNames(for: keyMask)
                entries[idx].entry.enabled = entries[idx].entry.switchableOnIOS && enabled.contains(raw.entry.key)
            }
        }
    }

    private struct DecodedOp {
        var op: UInt32
        var length: Int
        var mem: Int = 0
        var reg: Int = 0
        var rel: UInt64 = 0
        var flags: Int = 0
        var useReg: Bool = false
        var inc: Bool = false
        var operand: Int = 0
        var cond: Int = 0
        var regMask: Int = 0
        var extra: Int = 0
        var keyMask: UInt64 = 0
    }

    private static func widthOK(_ t: Int) -> Bool { t == 1 || t == 2 || t == 4 || t == 8 }

    private static func hasValidOpcodes(_ words: [UInt32]) -> Bool {
        var pc = 0
        while pc < words.count {
            guard let op = decodeOp(words: words, index: pc) else { return false }
            pc += op.length
        }
        return true
    }

    private static func decodeOp(words: [UInt32], index: Int) -> DecodedOp? {
        let remaining = words.count - index
        guard remaining > 0 else { return nil }
        let w = words[index]
        var op = w >> 28
        if op >= 0xC { op = (op << 4) | ((w >> 24) & 0xF) }
        if op >= 0xF0 { op = (op << 4) | ((w >> 20) & 0xF) }
        switch op {
        case 0:
            let t = Int((w >> 24) & 0xF)
            let len = t == 8 ? 4 : 3
            guard widthOK(t), remaining >= len else { return nil }
            let rel = (UInt64(w & 0xFF) << 32) | UInt64(words[index + 1])
            return DecodedOp(op: op, length: len, mem: Int((w >> 20) & 0xF), reg: Int((w >> 16) & 0xF), rel: rel)
        case 1:
            let t = Int((w >> 24) & 0xF), c = Int((w >> 16) & 0xF)
            let len = t == 8 ? 4 : 3
            guard widthOK(t), c >= 1, c <= 6, remaining >= len else { return nil }
            let rel = (UInt64(w & 0xFF) << 32) | UInt64(words[index + 1])
            return DecodedOp(
                op: op,
                length: len,
                mem: Int((w >> 20) & 0xF),
                reg: Int((w >> 8) & 0xF),
                rel: rel,
                useReg: ((w >> 12) & 0xF) != 0
            )
        case 2:
            return DecodedOp(op: op, length: 1)
        case 3:
            let isEnd = ((w >> 24) & 0xF) != 0
            let len = isEnd ? 1 : 2
            guard remaining >= len else { return nil }
            return DecodedOp(op: op, length: len, reg: Int((w >> 16) & 0xF))
        case 4:
            guard remaining >= 3 else { return nil }
            return DecodedOp(op: op, length: 3, reg: Int((w >> 16) & 0xF))
        case 5:
            let t = Int((w >> 24) & 0xF), flags = Int((w >> 12) & 0xF)
            guard widthOK(t), flags <= 3, remaining >= 2 else { return nil }
            return DecodedOp(
                op: op,
                length: 2,
                mem: Int((w >> 20) & 0xF),
                reg: Int((w >> 16) & 0xF),
                flags: flags
            )
        case 6:
            let t = Int((w >> 24) & 0xF)
            guard widthOK(t), remaining >= 3 else { return nil }
            return DecodedOp(op: op, length: 3, reg: Int((w >> 16) & 0xF), inc: ((w >> 12) & 0xF) != 0)
        case 7:
            let t = Int((w >> 24) & 0xF), c = Int((w >> 12) & 0xF)
            guard widthOK(t), c <= 4, remaining >= 2 else { return nil }
            return DecodedOp(op: op, length: 2, reg: Int((w >> 16) & 0xF))
        case 8:
            return DecodedOp(op: op, length: 1, keyMask: UInt64(w & 0x0FFF_FFFF))
        case 9:
            let t = Int((w >> 24) & 0xF)
            guard widthOK(t) else { return nil }
            let imm = ((w >> 8) & 0xF) != 0
            let len = imm ? (t == 8 ? 3 : 2) : 1
            guard remaining >= len else { return nil }
            return DecodedOp(op: op, length: len, reg: Int((w >> 16) & 0xF))
        case 0xA:
            let t = Int((w >> 24) & 0xF), o = Int((w >> 8) & 0xF)
            guard widthOK(t), o <= 5 else { return nil }
            let len = (o == 2 || o == 4 || o == 5) ? 2 : 1
            guard remaining >= len else { return nil }
            return DecodedOp(op: op, length: len, mem: Int((w >> 4) & 0xF), reg: Int((w >> 16) & 0xF), inc: ((w >> 12) & 0xF) != 0, operand: o)
        case 0xC0:
            let t = Int((w >> 20) & 0xF), c = Int((w >> 16) & 0xF), o = Int((w >> 8) & 0xF)
            guard widthOK(t), c >= 1, c <= 6, o <= 5 else { return nil }
            let len = (o == 0 || o == 2) ? 2 : (o == 4 ? (t == 8 ? 3 : 2) : 1)
            guard remaining >= len else { return nil }
            return DecodedOp(op: op, length: len)
        case 0xC1:
            return DecodedOp(op: op, length: 1, reg: Int((w >> 16) & 0xF), cond: Int((w >> 4) & 0xF))
        case 0xC2:
            return DecodedOp(op: op, length: 1, cond: Int((w >> 20) & 0xF), regMask: Int(w & 0xFFFF))
        case 0xC3:
            return DecodedOp(op: op, length: 1, reg: Int(w & 0xF), extra: Int((w >> 4) & 0xFF))
        case 0xC4:
            guard remaining >= 3 else { return nil }
            let km = (UInt64(words[index + 1]) << 32) | UInt64(words[index + 2])
            return DecodedOp(op: op, length: 3, keyMask: km)
        default:
            return nil
        }
    }

    public static func buttonNames(for mask: UInt64) -> [String] {
        guard mask != 0 else { return [] }
        let labels: [(Int, String)] = [
            (0, "A"), (1, "B"), (2, "X"), (3, "Y"),
            (4, "LS"), (5, "RS"), (6, "L"), (7, "R"),
            (8, "ZL"), (9, "ZR"), (10, "Plus"), (11, "Minus"),
            (12, "D-Left"), (13, "D-Up"), (14, "D-Right"), (15, "D-Down"),
            (16, "L-Left"), (17, "L-Up"), (18, "L-Right"), (19, "L-Down"),
            (20, "R-Left"), (21, "R-Up"), (22, "R-Right"), (23, "R-Down"),
            (24, "SL"), (25, "SR"),
        ]
        var names: [String] = []
        for (bit, label) in labels where (mask & (UInt64(1) << bit)) != 0 {
            names.append(label)
        }
        return names
    }

    private static func parseHexOrDec<S: StringProtocol>(_ raw: S) -> UInt64? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
            return UInt64(trimmed.dropFirst(2), radix: 16)
        }
        return UInt64(trimmed, radix: 10)
    }
}
