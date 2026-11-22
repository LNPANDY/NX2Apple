import Foundation

/// Summary of a game profile's `shader_seen.tsv` partial shader list versus its full `shader_map.tsv`.
package struct SeenShadersInfo: Equatable, Sendable {
    package let seenCount: Int
    package let totalCount: Int
    package let supportsIOS: Bool

    package init(seenCount: Int, totalCount: Int, supportsIOS: Bool = false) {
        self.seenCount = seenCount
        self.totalCount = totalCount
        self.supportsIOS = supportsIOS
    }
}

/// Inspects an engine game profile to determine whether `--seen-shaders` is valid and beneficial.
/// Uses streaming byte scans and caches only successful results keyed by file metadata (`path|size|mtime`).
package enum SeenShadersProfile {
    private struct CacheEntry {
        let key: String
        let info: SeenShadersInfo
    }

    private static let lock = NSLock()
    private static var cache: [String: CacheEntry] = [:]

    /// Fast existence check for `dm/games/<TID>/shader_seen.tsv` and `shader_map.tsv`.
    package static func hasSeenList(titleID: String, engineRoot: String, fileManager fm: FileManager = .default) -> Bool {
        guard let tid = normalizedHex16(titleID), !engineRoot.isEmpty else { return false }
        let base = profileDir(titleID: tid, engineRoot: engineRoot)
        return fm.fileExists(atPath: base + "/shader_seen.tsv") && fm.fileExists(atPath: base + "/shader_map.tsv")
    }

    /// Returns a previously computed result when file metadata matches, without scanning files.
    package static func cached(titleID: String, engineRoot: String, fileManager fm: FileManager = .default) -> SeenShadersInfo? {
        guard let tid = normalizedHex16(titleID), !engineRoot.isEmpty else { return nil }
        let base = profileDir(titleID: tid, engineRoot: engineRoot)
        guard let stamp = metadataKey(profileDir: base, fileManager: fm) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let entry = cache[base], entry.key == stamp {
            return entry.info
        }
        return nil
    }

    /// Reads profile metadata and counts entries in `shader_seen.tsv` and `shader_map.tsv`.
    /// Returns nil when the profile is non-NVN, missing either table, empty, or already covers all shaders.
    package static func inspect(titleID: String, engineRoot: String, fileManager fm: FileManager = .default) -> SeenShadersInfo? {
        guard let tid = normalizedHex16(titleID), !engineRoot.isEmpty else { return nil }
        let base = profileDir(titleID: tid, engineRoot: engineRoot)
        let seenPath = base + "/shader_seen.tsv"
        let mapPath = base + "/shader_map.tsv"
        guard let stamp = metadataKey(profileDir: base, fileManager: fm) else { return nil }

        lock.lock()
        if let entry = cache[base], entry.key == stamp {
            lock.unlock()
            return entry.info
        }
        lock.unlock()

        let profileFlags = readProfileFlags(gameTSVPath: base + "/game.tsv", fileManager: fm)
        guard profileFlags.isNVN else { return nil }
        guard let seenCount = countSeenKeys(atPath: seenPath), seenCount > 0 else { return nil }
        guard let totalCount = countNonCommentLines(atPath: mapPath), seenCount < totalCount else { return nil }

        let info = SeenShadersInfo(seenCount: seenCount, totalCount: totalCount, supportsIOS: profileFlags.supportsIOS)
        lock.lock()
        cache[base] = CacheEntry(key: stamp, info: info)
        lock.unlock()
        return info
    }

    package static func clearCacheForTesting() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    private static func normalizedHex16(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.count == 16, trimmed.unicodeScalars.allSatisfy({
            ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x41 && $0.value <= 0x46)
        }) else {
            return nil
        }
        return trimmed
    }

    private static func profileDir(titleID: String, engineRoot: String) -> String {
        let root = engineRoot.hasSuffix("/") ? String(engineRoot.dropLast()) : engineRoot
        return root + "/dm/games/" + titleID
    }

    private static func metadataKey(profileDir: String, fileManager fm: FileManager) -> String? {
        let seenPath = profileDir + "/shader_seen.tsv"
        let mapPath = profileDir + "/shader_map.tsv"
        let gamePath = profileDir + "/game.tsv"
        guard let seenAttr = try? fm.attributesOfItem(atPath: seenPath),
              let mapAttr = try? fm.attributesOfItem(atPath: mapPath) else {
            return nil
        }
        let seenSize = (seenAttr[.size] as? NSNumber)?.int64Value ?? -1
        let seenMtime = (seenAttr[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let mapSize = (mapAttr[.size] as? NSNumber)?.int64Value ?? -1
        let mapMtime = (mapAttr[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let gameAttr = try? fm.attributesOfItem(atPath: gamePath)
        let gameSize = (gameAttr?[.size] as? NSNumber)?.int64Value ?? -1
        let gameMtime = (gameAttr?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(profileDir)|\(seenSize)|\(seenMtime)|\(mapSize)|\(mapMtime)|\(gameSize)|\(gameMtime)"
    }

    /// Matches upstream `build_ipa_from_nsp.py`: `--seen-shaders` is only supported for NVN profiles,
    /// and iOS builds additionally require `ios_seen_shaders\t1`.
    private static func readProfileFlags(gameTSVPath: String, fileManager fm: FileManager) -> (isNVN: Bool, supportsIOS: Bool) {
        guard fm.fileExists(atPath: gameTSVPath),
              let text = try? String(contentsOfFile: gameTSVPath, encoding: .utf8) else {
            return (true, false)
        }
        var isNVN = true
        var supportsIOS = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == "\t" || $0 == " " })
            guard parts.count == 2 else { continue }
            let key = parts[0]
            let value = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
            if key == "graphics" {
                isNVN = value.isEmpty || value == "nvn"
            } else if key == "ios_seen_shaders" && value == "1" {
                supportsIOS = true
            }
        }
        return (isNVN, supportsIOS)
    }

    /// Counts unique 16-hex shader keys at line starts, matching `build_ipa_from_nsp.py:seen_listed`.
    private static func countSeenKeys(atPath path: String) -> Int? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var keys = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.count >= 16 else { continue }
            let prefix = line.prefix(16)
            guard prefix.unicodeScalars.allSatisfy({
                ($0.value >= 0x30 && $0.value <= 0x39)
                    || ($0.value >= 0x61 && $0.value <= 0x66)
                    || ($0.value >= 0x41 && $0.value <= 0x46)
            }) else {
                continue
            }
            if line.count == 16 {
                keys.insert(prefix.lowercased())
            } else {
                let next = line[line.index(line.startIndex, offsetBy: 16)]
                if next == "\t" || next == " " {
                    keys.insert(prefix.lowercased())
                }
            }
        }
        return keys.count
    }

    /// Streams raw bytes in 64 KB chunks to count data rows (excluding comments and the `package\t` header)
    /// without decoding the entire file into a String.
    private static func countNonCommentLines(atPath path: String) -> Int? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let headerPrefix: [UInt8] = Array("package\t".utf8)
        var count = 0
        var atLineStart = true
        var lineHasContent = false
        var lineIsComment = false
        var headerMatch = 0
        var lineIsHeader = false
        while true {
            let chunk: Data
            do {
                guard let data = try handle.read(upToCount: 65_536), !data.isEmpty else { break }
                chunk = data
            } catch {
                return nil
            }
            for byte in chunk {
                if byte == 0x0A { // '\n'
                    if lineHasContent && !lineIsComment && !lineIsHeader { count += 1 }
                    atLineStart = true
                    lineHasContent = false
                    lineIsComment = false
                    headerMatch = 0
                    lineIsHeader = false
                } else if byte == 0x0D { // '\r'
                    continue
                } else if atLineStart {
                    if byte == 0x20 || byte == 0x09 {
                        continue
                    }
                    atLineStart = false
                    if byte == 0x23 { // '#'
                        lineIsComment = true
                    } else {
                        lineHasContent = true
                        if byte == headerPrefix[0] {
                            headerMatch = 1
                        }
                    }
                } else if !lineIsComment {
                    lineHasContent = true
                    if headerMatch > 0 && headerMatch < headerPrefix.count {
                        if byte == headerPrefix[headerMatch] {
                            headerMatch += 1
                            if headerMatch == headerPrefix.count {
                                lineIsHeader = true
                            }
                        } else {
                            headerMatch = 0
                        }
                    }
                }
            }
        }
        if lineHasContent && !lineIsComment && !lineIsHeader { count += 1 }
        return count
    }
}
