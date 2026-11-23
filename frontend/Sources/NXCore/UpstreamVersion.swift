import Foundation

/// Persisted version receipt stored at `<upstream-dir>/.upstream-version.json` when installing or updating
/// an optional external build engine, or synthesized from entry-script mtime / `.upstream-ref`.
package struct UpstreamVersionReceipt: Codable, Equatable, Sendable {
    package let commit: String?
    package let version: String
    package let installedAt: String

    package init(commit: String?, version: String, installedAt: String) {
        self.commit = commit
        self.version = version
        self.installedAt = installedAt
    }

    package var shortCommit: String? {
        guard let commit, commit.count >= 7 else { return nil }
        return String(commit.prefix(7))
    }
}

/// Latest remote revision metadata fetched from GitHub for an optional external build engine.
package struct UpstreamRemoteInfo: Equatable, Sendable {
    package let kind: EngineUpstreamKind
    package let commit: String
    package let version: String
    package let date: String

    package init(kind: EngineUpstreamKind, commit: String, version: String, date: String) {
        self.kind = kind
        self.commit = commit
        self.version = version
        self.date = date
    }

    package var shortCommit: String {
        String(commit.prefix(7))
    }

    /// Compact detail string for tooltips, avoiding redundant short-SHA parentheses.
    package var tooltipDetail: String {
        let short = shortCommit
        guard !short.isEmpty, version != short else { return version }
        return "\(version) (\(short))"
    }
}

/// Pure helpers for external upstream version receipts, ZIP EOCD commit extraction,
/// remote GitHub version checking, update comparison, and compact badge formatting.
package enum UpstreamVersion {
    package static let receiptFileName = ".upstream-version.json"
    package static let cacheTTL: TimeInterval = 600
    package static let quickFetchTimeout: TimeInterval = 8

    private static let eocdSignature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
    private static let maxEOCDTailBytes = 65_557 // 22-byte fixed EOCD + 65535-byte max comment
    private static let semverTagRegex = try! NSRegularExpression(pattern: #"^v(\d+)\.(\d+)(?:\.(\d+))?$"#)
    private static let mngSourceTagRegex = try! NSRegularExpression(pattern: #"^source-(\d{4})(\d{2})(\d{2})-([0-9a-f]{7,40})$"#, options: .caseInsensitive)

    package static func infoRefsURL(for kind: EngineUpstreamKind) -> URL? {
        switch kind {
        case .nxnative, .nxkit:
            return nil
        case .s2arm:
            return URL(string: "https://github.com/jhaizhou-ops/S2Arm/info/refs?service=git-upload-pack")
        case .macNativeGames:
            return URL(string: "https://github.com/ly05010419/MacNativeGames/info/refs?service=git-upload-pack")
        case .kidWithSword:
            return URL(string: "https://github.com/cheemu21/kid-with-sword-remake/info/refs?service=git-upload-pack")
        case .noLagKart:
            return URL(string: "https://github.com/kingbumi31/no-lag-kart/info/refs?service=git-upload-pack")
        }
    }

    package static func normalizedCommit(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count == 40, trimmed.unicodeScalars.allSatisfy(isLowerHex) else {
            return nil
        }
        return trimmed
    }

    private static func isLowerHex(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 0x30 && scalar.value <= 0x39) || (scalar.value >= 0x61 && scalar.value <= 0x66)
    }

    package static func formatDate(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        let y = comps.year ?? 1970
        let m = comps.month ?? 1
        let d = comps.day ?? 1
        return String(format: "%04d.%02d.%02d", y, m, d)
    }

    package static func formatISODate(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else { return nil }
        let prefix = String(trimmed.prefix(10))
        let parts = prefix.split(separator: "-")
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.unicodeScalars.allSatisfy { $0.value >= 0x30 && $0.value <= 0x39 } }) else {
            return nil
        }
        return "\(parts[0]).\(parts[1]).\(parts[2])"
    }

    /// Reads only the trailing bytes of a ZIP archive and extracts a 40-hex Git commit SHA
    /// from the End of Central Directory (EOCD) comment written by GitHub codeload archives.
    package static func extractGitCommitFromZip(_ zipURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: zipURL) else { return nil }
        defer { try? handle.close() }
        let fileSize: UInt64
        do {
            fileSize = try handle.seekToEnd()
            guard fileSize >= 22 else { return nil }
            let readSize = min(fileSize, UInt64(maxEOCDTailBytes))
            let startOffset = fileSize - readSize
            try handle.seek(toOffset: startOffset)
            guard let tail = try handle.read(upToCount: Int(readSize)) else { return nil }
            return extractGitCommitFromZipData(tail)
        } catch {
            return nil
        }
    }

    package static func extractGitCommitFromZipData(_ tail: Data) -> String? {
        let count = tail.count
        guard count >= 22 else { return nil }
        let bytes = [UInt8](tail)
        let maxStart = count - 22
        for idx in stride(from: maxStart, through: 0, by: -1) {
            guard bytes[idx] == eocdSignature[0],
                  bytes[idx + 1] == eocdSignature[1],
                  bytes[idx + 2] == eocdSignature[2],
                  bytes[idx + 3] == eocdSignature[3] else {
                continue
            }
            let commentLen = Int(bytes[idx + 20]) | (Int(bytes[idx + 21]) << 8)
            let remaining = count - idx - 22
            guard commentLen == remaining else { continue }
            guard commentLen >= 40 else { return nil }
            let commentSlice = bytes[(idx + 22)..<(idx + 22 + commentLen)]
            guard let comment = String(bytes: commentSlice, encoding: .utf8) else { return nil }
            return normalizedCommit(comment)
        }
        return nil
    }

    package static func receiptForInstall(
        kind: EngineUpstreamKind,
        zipURL: URL,
        remoteInfo: UpstreamRemoteInfo?,
        now: Date = Date()
    ) -> UpstreamVersionReceipt {
        let installedAt = formatDate(now)
        let zipCommit = extractGitCommitFromZip(zipURL)
        let remoteCommit = normalizedCommit(remoteInfo?.commit)
        let commit = zipCommit ?? remoteCommit

        let version: String
        if let remoteInfo, let commit, remoteCommit == commit, !remoteInfo.version.isEmpty {
            version = remoteInfo.version
        } else if let commit {
            switch kind {
            case .macNativeGames:
                version = installedAt
            case .s2arm:
                if let remoteInfo, !remoteInfo.version.isEmpty, isSemanticTagPrefix(remoteInfo.version) {
                    version = remoteInfo.version.hasSuffix("+") ? remoteInfo.version : remoteInfo.version + "+"
                } else {
                    version = String(commit.prefix(7))
                }
            case .nxnative, .nxkit, .kidWithSword, .noLagKart:
                version = String(commit.prefix(7))
            }
        } else if let remoteInfo, !remoteInfo.version.isEmpty {
            version = remoteInfo.version
        } else {
            version = installedAt
        }

        return UpstreamVersionReceipt(commit: commit, version: version, installedAt: installedAt)
    }

    private static func isSemanticTagPrefix(_ text: String) -> Bool {
        let base = text.hasSuffix("+") ? String(text.dropLast()) : text
        let range = NSRange(location: 0, length: (base as NSString).length)
        return semverTagRegex.firstMatch(in: base, range: range) != nil
    }

    package static func writeReceipt(_ receipt: UpstreamVersionReceipt, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(receipt)
        let url = directory.appendingPathComponent(receiptFileName)
        try data.write(to: url, options: .atomic)
    }

    package static func readReceipt(in directory: URL, fileManager fm: FileManager = .default) -> UpstreamVersionReceipt? {
        let url = directory.appendingPathComponent(receiptFileName)
        guard let data = fm.contents(atPath: url.path),
              let raw = try? JSONDecoder().decode(UpstreamVersionReceipt.self, from: data) else {
            return nil
        }
        let ver = raw.version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ver.isEmpty else { return nil }
        return UpstreamVersionReceipt(
            commit: normalizedCommit(raw.commit),
            version: ver,
            installedAt: raw.installedAt.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Reads the built-in nxnative short commit from `.upstream-ref` beside the checkout, engine root, or app bundle.
    package static func builtInReceipt(
        repoPath: String,
        bundleResources: URL? = Bundle.main.resourceURL,
        fileManager fm: FileManager = .default
    ) -> UpstreamVersionReceipt? {
        var candidates: [String] = []
        if !repoPath.isEmpty {
            candidates.append(repoPath + "/.upstream-ref")
            let engineRoot = EngineLayout.root(repoPath)
            if !engineRoot.isEmpty {
                candidates.append(engineRoot + "/.upstream-ref")
            }
        }
        if let res = bundleResources {
            candidates.append(res.appendingPathComponent("engine/.upstream-ref").path)
        }
        for path in candidates {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard trimmed.count >= 7, trimmed.unicodeScalars.allSatisfy(isLowerHex) else { continue }
            return UpstreamVersionReceipt(
                commit: trimmed.count == 40 ? trimmed : nil,
                version: String(trimmed.prefix(7)),
                installedAt: ""
            )
        }
        return nil
    }

    /// Reads local version metadata for `kind`: `.upstream-version.json` first, falling back to
    /// representative entry-script mtime (`YYYY.MM.DD`) with `commit = nil` for pre-existing installs.
    package static func localReceipt(
        for kind: EngineUpstreamKind,
        directory: String,
        repoPath: String = "",
        bundleResources: URL? = Bundle.main.resourceURL,
        fileManager fm: FileManager = .default
    ) -> UpstreamVersionReceipt? {
        if kind == .nxnative {
            return builtInReceipt(repoPath: repoPath, bundleResources: bundleResources, fileManager: fm)
        }
        guard !directory.isEmpty, UpstreamEngineStore.isUsableTree(directory, kind: kind, fileManager: fm) else {
            return nil
        }
        let dirURL = URL(fileURLWithPath: directory, isDirectory: true)
        if let receipt = readReceipt(in: dirURL, fileManager: fm) {
            return receipt
        }
        let entryRel: String
        switch kind {
        case .macNativeGames:
            entryRel = "build_app.py"
        case .s2arm:
            entryRel = "pack/jobs/main.py"
        case .kidWithSword, .noLagKart:
            entryRel = RepoLayout.buildScript
        case .nxnative, .nxkit:
            return nil
        }
        let entryPath = dirURL.appendingPathComponent(entryRel).path
        guard let attrs = try? fm.attributesOfItem(atPath: entryPath),
              let mtime = attrs[.modificationDate] as? Date else {
            return nil
        }
        let dateStr = formatDate(mtime)
        return UpstreamVersionReceipt(commit: nil, version: dateStr, installedAt: dateStr)
    }

    /// Parses a Git Smart HTTP `info/refs?service=git-upload-pack` payload (pkt-line format)
    /// into compact remote version metadata without consuming GitHub REST API rate-limit quota.
    package static func parseInfoRefs(
        kind: EngineUpstreamKind,
        data: Data,
        now: Date = Date()
    ) -> UpstreamRemoteInfo? {
        guard kind != .nxnative,
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }

        var targetBranchCommit: String?
        var mainCommit: String?
        var headCommit: String?
        var tagCommits: [String: String] = [:]
        var dereferencedTags: Set<String> = []
        let targetBranchRef = "refs/heads/" + kind.gitBranch

        for rawLine in text.split(whereSeparator: \.isNewline) {
            // Strip NUL capabilities suffix (present on the first HEAD ref line).
            let beforeNul: Substring
            if let nulIdx = rawLine.firstIndex(of: "\0") {
                beforeNul = rawLine[..<nulIdx]
            } else {
                beforeNul = rawLine
            }
            var line = beforeNul.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.contains("# service=") { continue }

            // Strip any leading pkt-line flush ("0000") and 4-hex length header before the 40-hex SHA.
            while line.hasPrefix("0000") && line.count > 4 {
                line = String(line.dropFirst(4))
            }
            if line.count >= 45,
               let firstSpace = line.firstIndex(of: " "),
               line.distance(from: line.startIndex, to: firstSpace) == 44,
               line.prefix(4).lowercased().unicodeScalars.allSatisfy(isLowerHex) {
                line = String(line.dropFirst(4))
            }

            let parts = line.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard parts.count == 2,
                  let sha = normalizedCommit(String(parts[0])) else {
                continue
            }
            let ref = String(parts[1])
            if ref == targetBranchRef {
                targetBranchCommit = sha
            } else if ref == "refs/heads/main" {
                mainCommit = sha
            } else if ref == "HEAD" {
                headCommit = sha
            } else if ref.hasPrefix("refs/tags/") {
                let rawTag = String(ref.dropFirst("refs/tags/".count))
                if rawTag.hasSuffix("^{}") {
                    let baseName = String(rawTag.dropLast(3))
                    tagCommits[baseName] = sha
                    dereferencedTags.insert(baseName)
                } else if !dereferencedTags.contains(rawTag) {
                    tagCommits[rawTag] = sha
                }
            }
        }

        guard let mainSHA = targetBranchCommit ?? mainCommit ?? headCommit else {
            return nil
        }
        let shortSHA = String(mainSHA.prefix(7))

        switch kind {
        case .s2arm:
            let version = resolveS2ArmVersion(mainSHA: mainSHA, tagCommits: tagCommits) ?? shortSHA
            return UpstreamRemoteInfo(kind: kind, commit: mainSHA, version: version, date: "")
        case .macNativeGames:
            let (version, dateStr) = resolveMNGVersion(mainSHA: mainSHA, tagCommits: tagCommits, now: now)
            return UpstreamRemoteInfo(kind: kind, commit: mainSHA, version: version, date: dateStr)
        case .kidWithSword, .noLagKart:
            return UpstreamRemoteInfo(kind: kind, commit: mainSHA, version: shortSHA, date: "")
        case .nxnative, .nxkit:
            return nil
        }
    }

    private static func resolveS2ArmVersion(mainSHA: String, tagCommits: [String: String]) -> String? {
        var best: (tuple: (Int, Int, Int), name: String, sha: String)?
        for (name, sha) in tagCommits {
            let ns = name as NSString
            guard let m = semverTagRegex.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)),
                  let major = Int(ns.substring(with: m.range(at: 1))),
                  let minor = Int(ns.substring(with: m.range(at: 2))) else {
                continue
            }
            let patchRange = m.range(at: 3)
            let patch = patchRange.location == NSNotFound ? 0 : (Int(ns.substring(with: patchRange)) ?? 0)
            let cand = (major, minor, patch)
            if let cur = best {
                if cand > cur.tuple || (cand == cur.tuple && sha == mainSHA) {
                    best = (cand, name, sha)
                }
            } else {
                best = (cand, name, sha)
            }
        }
        guard let best else { return nil }
        return best.sha == mainSHA ? best.name : best.name + "+"
    }

    private static func resolveMNGVersion(
        mainSHA: String,
        tagCommits: [String: String],
        now: Date
    ) -> (version: String, date: String) {
        var bestDateKey = ""
        var bestDateFormatted = ""
        var bestMatchedMain = false

        for (name, sha) in tagCommits {
            let ns = name as NSString
            guard let m = mngSourceTagRegex.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)) else {
                continue
            }
            let yyyy = ns.substring(with: m.range(at: 1))
            let mm = ns.substring(with: m.range(at: 2))
            let dd = ns.substring(with: m.range(at: 3))
            let tagPrefix = ns.substring(with: m.range(at: 4)).lowercased()
            let key = yyyy + mm + dd
            let formatted = "\(yyyy).\(mm).\(dd)"
            let matchesMain = sha == mainSHA || mainSHA.hasPrefix(tagPrefix)

            if key > bestDateKey {
                bestDateKey = key
                bestDateFormatted = formatted
                bestMatchedMain = matchesMain
            } else if key == bestDateKey && matchesMain {
                bestMatchedMain = true
            }
        }

        if !bestDateFormatted.isEmpty {
            let version = bestMatchedMain ? bestDateFormatted : bestDateFormatted + "+"
            return (version, bestDateFormatted)
        }
        let today = formatDate(now)
        return (today, today)
    }

    /// Blocking network fetch for remote upstream metadata via Git Smart HTTP `info/refs`;
    /// always call off the main actor.
    package static func fetchRemoteInfo(
        for kind: EngineUpstreamKind,
        transport: EngineTransport,
        timeout: TimeInterval = 15,
        now: Date = Date()
    ) -> UpstreamRemoteInfo? {
        guard let url = infoRefsURL(for: kind) else { return nil }
        guard case .ok(let data) = transport.data(from: url, timeout: timeout) else { return nil }
        return parseInfoRefs(kind: kind, data: data, now: now)
    }

    /// Update predicate: compares 40-char commit SHAs strictly. Pre-existing local trees without
    /// a recorded commit SHA report an update as soon as a remote commit is known.
    package static func hasUpdate(local: UpstreamVersionReceipt?, remote: UpstreamRemoteInfo?) -> Bool {
        guard let remote, let remoteCommit = normalizedCommit(remote.commit) else { return false }
        guard let local else { return false }
        guard let localCommit = normalizedCommit(local.commit) else { return true }
        return localCommit != remoteCommit
    }

    /// Compact single-capsule badge text shown beside the engine name.
    package static func compactBadgeText(
        kind: EngineUpstreamKind,
        local: UpstreamVersionReceipt?,
        hasUpdate: Bool,
        builtInFallback: String,
        installedFallback: String
    ) -> String {
        if kind.isBuiltIn {
            if let ver = local?.version, !ver.isEmpty {
                return ver
            }
            return builtInFallback
        }
        let base = (local?.version.isEmpty == false) ? local!.version : installedFallback
        return hasUpdate ? "\(base) ↑" : base
    }
}
