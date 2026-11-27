import Foundation

/// Diff status of an online cheat entry when compared with the local `<BID>.txt`.
package enum CheatDiffEntryStatus: String, Equatable, Sendable {
    case added
    case sameName
}

/// One parsed effective entry in an Atmosphère `<BID>.txt` preview/diff.
package struct CheatDiffEntry: Equatable, Identifiable, Sendable {
    package var id: String
    package var name: String
    package var key: String
    package var section: String
    package var isMaster: Bool
    package var status: CheatDiffEntryStatus
    package var rawBlock: String
    package var capability: CheatCapability
    package var hasFixedAddress: Bool
    package var keyMask: UInt64
    package var isBroken: Bool

    package init(
        id: String,
        name: String,
        key: String,
        section: String = "",
        isMaster: Bool,
        status: CheatDiffEntryStatus,
        rawBlock: String,
        capability: CheatCapability = .dataReady,
        hasFixedAddress: Bool = false,
        keyMask: UInt64 = 0,
        isBroken: Bool = false
    ) {
        self.id = id
        self.name = name
        self.key = key
        self.section = section
        self.isMaster = isMaster
        self.status = status
        self.rawBlock = rawBlock
        self.capability = capability
        self.hasFixedAddress = hasFixedAddress
        self.keyMask = keyMask
        self.isBroken = isBroken
    }

    package var triggerCombo: String? {
        CheatKeyMask.formattedCombo(for: keyMask)
    }
}

/// Structured comparison between local `<BID>.txt` and an online candidate.
package struct CheatDiffSummary: Equatable, Sendable {
    package var entries: [CheatDiffEntry]
    package var localCount: Int
    package var onlineCount: Int
    package var addedCount: Int
    package var sameNameCount: Int
    package var localOnlyCount: Int

    package init(
        entries: [CheatDiffEntry],
        localCount: Int,
        onlineCount: Int,
        addedCount: Int,
        sameNameCount: Int,
        localOnlyCount: Int
    ) {
        self.entries = entries
        self.localCount = localCount
        self.onlineCount = onlineCount
        self.addedCount = addedCount
        self.sameNameCount = sameNameCount
        self.localOnlyCount = localOnlyCount
    }
}

/// Result returned after merging or replacing `<BID>.txt`.
package struct CheatWriteOutcome: Equatable, Sendable {
    package var receipt: CheatFetchReceipt
    package var addedCount: Int
    package var totalEntryCount: Int
    package var backupFileName: String

    package init(receipt: CheatFetchReceipt, addedCount: Int, totalEntryCount: Int, backupFileName: String) {
        self.receipt = receipt
        self.addedCount = addedCount
        self.totalEntryCount = totalEntryCount
        self.backupFileName = backupFileName
    }
}

package enum CheatMergeError: Error, LocalizedError, Equatable, Sendable {
    case invalidBuildID
    case invalidTitleID

    package var errorDescription: String? {
        switch self {
        case .invalidBuildID: return "Invalid build ID"
        case .invalidTitleID: return "Invalid title ID"
        }
    }
}

extension CheatFetcher {
    private struct ParsedTextBlock {
        var name: String
        var key: String
        var matchKey: String
        var section: String
        var isMaster: Bool
        var isSectionHeader: Bool
        var isLabel: Bool
        var isBroken: Bool
        var rawBlock: String
        var words: [UInt32]
        var hasNonZeroWord: Bool
    }

    /// Compares local and online Atmosphère cheat text, ignoring pure section headers (`[--SectionStart:...--]`, `20000000`/`20000001`)
    /// and trimming whitespace when matching entry names.
    package static func diffSummary(
        localText: String,
        onlineText: String,
        rxEnd: UInt64? = nil,
        trampolines: CheatTrampolineMetadata? = nil,
        buildID: String? = nil
    ) -> CheatDiffSummary {
        let localEffective = parseEffectiveBlocks(localText)
        let onlineEffective = parseEffectiveBlocks(onlineText)

        let localMatchKeys = Set(localEffective.map(\.matchKey))
        let onlineMatchKeys = Set(onlineEffective.map(\.matchKey))

        let analysisInputs = onlineEffective.map {
            CheatStaticAnalyzer.InputEntry(
                key: $0.key,
                isMaster: $0.isMaster,
                isLabel: false,
                isBroken: $0.isBroken,
                words: $0.words
            )
        }
        let analyses = CheatStaticAnalyzer.analyze(
            entries: analysisInputs,
            rxEnd: rxEnd,
            trampolines: trampolines,
            buildID: buildID
        )

        var diffEntries: [CheatDiffEntry] = []
        var addedCount = 0
        var sameNameCount = 0

        for (idx, block) in onlineEffective.enumerated() {
            let status: CheatDiffEntryStatus = localMatchKeys.contains(block.matchKey) ? .sameName : .added
            if status == .added {
                addedCount += 1
            } else {
                sameNameCount += 1
            }
            let analysis = analyses[idx]
            diffEntries.append(
                CheatDiffEntry(
                    id: "\(idx):\(block.key)",
                    name: block.name,
                    key: block.key,
                    section: block.section,
                    isMaster: block.isMaster,
                    status: status,
                    rawBlock: block.rawBlock,
                    capability: analysis.capability,
                    hasFixedAddress: analysis.hasFixedAddress,
                    keyMask: analysis.keyMask,
                    isBroken: analysis.isBroken || block.isBroken
                )
            )
        }

        let localOnlyCount = localEffective.filter { !onlineMatchKeys.contains($0.matchKey) }.count
        return CheatDiffSummary(
            entries: diffEntries,
            localCount: localEffective.count,
            onlineCount: onlineEffective.count,
            addedCount: addedCount,
            sameNameCount: sameNameCount,
            localOnlyCount: localOnlyCount
        )
    }

    /// Atomically backs up local `<BID>.txt` to `<BID>.txt.bak`, merges missing online entries
    /// (missing `{Master}` prepended, regular entries appended) without touching `.enabled`, and updates `.cheats-fetch.json`.
    @discardableResult
    package static func mergeMissingEntries(
        localText: String,
        onlineText: String,
        into folder: URL,
        buildID: String,
        titleID: String,
        sources: [String],
        now: Date = Date(),
        fm: FileManager = .default
    ) throws -> CheatWriteOutcome {
        guard let tid16 = normalizedHex16(titleID) else { throw CheatMergeError.invalidTitleID }
        guard let bid16 = normalizedHex16(buildID, allow32: true) else { throw CheatMergeError.invalidBuildID }

        let targetName = "\(bid16).txt"
        let targetURL = folder.appendingPathComponent(targetName)
        let backupName = "\(targetName).bak"
        let existingFile = existingCheatFile(buildID: bid16, in: folder, fm: fm)

        let diskText: String = {
            if let existingFile, let data = try? Data(contentsOf: existingFile) {
                return String(decoding: data, as: UTF8.self)
            }
            return localText
        }()

        let localEffective = parseEffectiveBlocks(diskText)
        let localMatchKeys = Set(localEffective.map(\.matchKey))
        let onlineEffective = parseEffectiveBlocks(onlineText)

        var seenAdded = Set<String>()
        var addedMasters: [String] = []
        var addedRegulars: [String] = []
        for block in onlineEffective where !localMatchKeys.contains(block.matchKey) {
            guard seenAdded.insert(block.matchKey).inserted else { continue }
            if block.isMaster {
                addedMasters.append(block.rawBlock)
            } else {
                addedRegulars.append(block.rawBlock)
            }
        }

        let addedCount = addedMasters.count + addedRegulars.count
        let normalizedLocal = diskText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .newlines)

        var parts: [String] = []
        parts.append(contentsOf: addedMasters)
        if !normalizedLocal.isEmpty {
            parts.append(normalizedLocal)
        }
        parts.append(contentsOf: addedRegulars)
        let mergedText = parts.isEmpty ? "" : (parts.joined(separator: "\n\n") + "\n")

        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeBackupIfNonEmpty(existingFile: existingFile, fallbackText: diskText, backupURL: folder.appendingPathComponent(backupName))

        let payload = Data(mergedText.utf8)
        try payload.write(to: targetURL, options: .atomic)
        if let existingFile, existingFile.lastPathComponent != targetName {
            try? fm.removeItem(at: existingFile)
        }

        let totalEffective = parseEffectiveBlocks(mergedText).count
        let receipt = CheatFetchReceipt(
            titleID: tid16,
            buildID: bid16,
            status: CheatFetchStatus.fetched.rawValue,
            sources: sources,
            entryCount: totalEffective,
            fetchedAt: CheatFetchReceipt.formatDate(now),
            fileName: targetName,
            fileSHA256: sha256Hex(payload),
            origin: "user",
            detail: ""
        )
        try writeReceipt(receipt, in: folder)
        return CheatWriteOutcome(
            receipt: receipt,
            addedCount: addedCount,
            totalEntryCount: totalEffective,
            backupFileName: backupName
        )
    }

    /// Atomically backs up local `<BID>.txt` to `<BID>.txt.bak`, replaces `<BID>.txt` with `onlineText`,
    /// prunes `.enabled` keys that no longer exist in the online file, and updates `.cheats-fetch.json`.
    @discardableResult
    package static func replaceWithOnline(
        onlineText: String,
        into folder: URL,
        buildID: String,
        titleID: String,
        sources: [String],
        now: Date = Date(),
        fm: FileManager = .default
    ) throws -> CheatWriteOutcome {
        guard let tid16 = normalizedHex16(titleID) else { throw CheatMergeError.invalidTitleID }
        guard let bid16 = normalizedHex16(buildID, allow32: true) else { throw CheatMergeError.invalidBuildID }

        let targetName = "\(bid16).txt"
        let targetURL = folder.appendingPathComponent(targetName)
        let backupName = "\(targetName).bak"
        let existingFile = existingCheatFile(buildID: bid16, in: folder, fm: fm)

        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeBackupIfNonEmpty(existingFile: existingFile, fallbackText: nil, backupURL: folder.appendingPathComponent(backupName))

        let normalizedOnline = onlineText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let finalOnline = normalizedOnline.hasSuffix("\n") || normalizedOnline.isEmpty ? normalizedOnline : (normalizedOnline + "\n")
        let payload = Data(finalOnline.utf8)
        try payload.write(to: targetURL, options: .atomic)
        if let existingFile, existingFile.lastPathComponent != targetName {
            try? fm.removeItem(at: existingFile)
        }

        let onlineEffective = parseEffectiveBlocks(finalOnline)
        let validSwitchableKeys = Set(onlineEffective.filter { !$0.isMaster && !$0.isBroken }.map(\.key))
        pruneEnabledFile(in: folder, buildID: bid16, validKeys: validSwitchableKeys, fm: fm)

        let receipt = CheatFetchReceipt(
            titleID: tid16,
            buildID: bid16,
            status: CheatFetchStatus.fetched.rawValue,
            sources: sources,
            entryCount: onlineEffective.count,
            fetchedAt: CheatFetchReceipt.formatDate(now),
            fileName: targetName,
            fileSHA256: sha256Hex(payload),
            origin: "fetched",
            detail: ""
        )
        try writeReceipt(receipt, in: folder)
        return CheatWriteOutcome(
            receipt: receipt,
            addedCount: onlineEffective.count,
            totalEntryCount: onlineEffective.count,
            backupFileName: backupName
        )
    }

    private static func writeBackupIfNonEmpty(existingFile: URL?, fallbackText: String?, backupURL: URL) throws {
        if let existingFile, let existingData = try? Data(contentsOf: existingFile), !existingData.isEmpty {
            try existingData.write(to: backupURL, options: .atomic)
        } else if let fallbackText, !fallbackText.isEmpty {
            try Data(fallbackText.utf8).write(to: backupURL, options: .atomic)
        }
    }

    private static func pruneEnabledFile(in folder: URL, buildID: String, validKeys: Set<String>, fm: FileManager) {
        let enabledURL = folder.appendingPathComponent("\(buildID).enabled")
        guard fm.fileExists(atPath: enabledURL.path),
              let raw = try? String(contentsOf: enabledURL, encoding: .utf8) else {
            return
        }
        let kept = raw
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { validKeys.contains($0) }
        let updated = kept.isEmpty ? "" : (kept.joined(separator: "\n") + "\n")
        try? Data(updated.utf8).write(to: enabledURL, options: .atomic)
    }

    // MARK: - Block Parsing

    private static func parseEffectiveBlocks(_ rawText: String) -> [ParsedTextBlock] {
        let normalized = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let rawBytes = Array(normalized.utf8)

        func isWS(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }
        func isHex(_ c: UInt8) -> Bool { (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66) }

        var splitBytes: [UInt8] = []
        splitBytes.reserveCapacity(rawBytes.count * 2)
        for (i, c) in rawBytes.enumerated() {
            if (c == 0x5B || c == 0x7B), i >= 8, rawBytes[(i - 8)..<i].allSatisfy(isHex), i == 8 || isWS(rawBytes[i - 9]) {
                splitBytes.append(0x0B)
            }
            splitBytes.append(c)
        }

        let lines = String(decoding: splitBytes, as: UTF8.self)
            .split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\u{0B}" })
            .map(String.init)

        struct Builder {
            var name: String
            var key: String
            var headerLine: String
            var isMaster: Bool
            var isSectionHeader: Bool
            var sectionStart: Bool?
            var sectionTitle: String
            var bodyLines: [String] = []
            var words: [UInt32] = []
            var hasNonZeroWord = false
            var junk = false
            var broken = false
            var skip = false
        }

        var builders: [Builder] = []
        var activeSection = ""
        var nameCounts: [String: Int] = [:]

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
                let endChar: Character = trimmed.hasPrefix("[") ? "]" : "}"
                if let closeIdx = trimmed.dropFirst().firstIndex(of: endChar), closeIdx > trimmed.index(after: trimmed.startIndex) {
                    let isMaster = trimmed.hasPrefix("{")
                    let rawName = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closeIdx])
                    let cleanName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleanName.isEmpty else {
                        builders.append(Builder(name: "", key: "", headerLine: "", isMaster: false, isSectionHeader: false, sectionStart: nil, sectionTitle: "", skip: true))
                        continue
                    }
                    let headerToken = String(trimmed[...closeIdx])
                    let trailing = String(trimmed[trimmed.index(after: closeIdx)...]).trimmingCharacters(in: .whitespaces)

                    let count = (nameCounts[cleanName] ?? 0) + 1
                    nameCounts[cleanName] = count
                    let uniqueKey = count > 1 ? "\(cleanName) #\(count)" : cleanName

                    let marker = edizonSectionMarker(cleanName)
                    var b = Builder(
                        name: cleanName,
                        key: uniqueKey,
                        headerLine: headerToken,
                        isMaster: isMaster,
                        isSectionHeader: marker != nil,
                        sectionStart: marker?.start,
                        sectionTitle: marker?.name ?? ""
                    )
                    if !trailing.isEmpty {
                        parseCodeTokens(trailing, into: &b.words, hasNonZero: &b.hasNonZeroWord, junk: &b.junk, broken: &b.broken)
                        b.bodyLines.append(trailing)
                    }
                    builders.append(b)
                } else {
                    builders.append(Builder(name: "", key: "", headerLine: "", isMaster: false, isSectionHeader: false, sectionStart: nil, sectionTitle: "", skip: true))
                }
                continue
            }

            guard !builders.isEmpty, !builders[builders.count - 1].skip else { continue }
            var current = builders[builders.count - 1]
            if !trimmed.isEmpty {
                var words = current.words
                var hasNonZero = current.hasNonZeroWord
                var junk = current.junk
                var broken = current.broken
                parseCodeTokens(trimmed, into: &words, hasNonZero: &hasNonZero, junk: &junk, broken: &broken)
                current.words = words
                current.hasNonZeroWord = hasNonZero
                current.junk = junk
                current.broken = broken
            }
            current.bodyLines.append(rawLine)
            builders[builders.count - 1] = current
        }

        var result: [ParsedTextBlock] = []
        for var b in builders where !b.skip {
            if let zingStart = CheatStaticAnalyzer.zingSectionMarker(words: b.words, isMaster: b.isMaster, isBroken: b.broken) {
                if zingStart { activeSection = b.name } else { activeSection = "" }
                continue
            }
            if b.isSectionHeader && !b.isMaster && !b.hasNonZeroWord {
                if b.sectionStart == true {
                    activeSection = b.sectionTitle
                } else {
                    activeSection = ""
                }
                continue
            }
            if b.words.isEmpty && !b.junk {
                // Pure label with no code words.
                continue
            }
            if b.words.isEmpty && b.junk {
                b.broken = true
            } else if !b.words.isEmpty && !CheatStaticAnalyzer.hasValidOpcodes(b.words) {
                b.broken = true
            }

            while let last = b.bodyLines.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                b.bodyLines.removeLast()
            }
            let rawBlock = ([b.headerLine] + b.bodyLines).joined(separator: "\n")
            let matchKey = "\(b.isMaster ? "M" : "C"):\(b.name.lowercased())"
            result.append(
                ParsedTextBlock(
                    name: b.name,
                    key: b.key,
                    matchKey: matchKey,
                    section: activeSection,
                    isMaster: b.isMaster,
                    isSectionHeader: false,
                    isLabel: false,
                    isBroken: b.broken,
                    rawBlock: rawBlock,
                    words: b.words,
                    hasNonZeroWord: b.hasNonZeroWord
                )
            )
        }
        return result
    }

    private static func edizonSectionMarker(_ name: String) -> (start: Bool, name: String)? {
        guard name.count >= 4, name.hasSuffix("--") else { return nil }
        for (prefix, start) in [("--SectionStart:", true), ("--SectionEnd:", false)] where name.hasPrefix(prefix) {
            return (start, String(name.dropFirst(prefix.count).dropLast(2)).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func parseCodeTokens(
        _ text: String,
        into words: inout [UInt32],
        hasNonZero: inout Bool,
        junk: inout Bool,
        broken: inout Bool
    ) {
        var gotWords: [UInt32] = []
        var prose = false
        var oddHex = false
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let s = String(token)
            if !s.allSatisfy(\.isHexDigit) {
                prose = true
                continue
            }
            if s.count % 8 != 0 {
                oddHex = true
                continue
            }
            var idx = s.startIndex
            while idx < s.endIndex {
                let end = s.index(idx, offsetBy: 8)
                if let w = UInt32(s[idx..<end], radix: 16) {
                    gotWords.append(w)
                }
                idx = end
            }
        }
        if prose && gotWords.isEmpty && !oddHex {
            junk = true
        } else if prose || oddHex {
            broken = true
        } else {
            words.append(contentsOf: gotWords)
            if gotWords.contains(where: { $0 != 0 }) {
                hasNonZero = true
            }
        }
    }
}
