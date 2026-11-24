import Darwin
import Foundation

/// Per-game entry reported by `build_seed.py scan-uncompressed --json`.
package struct SeedScanGame: Codable, Equatable, Identifiable, Sendable {
    package var titleID: String
    package var appName: String
    package var files: [String]
    package var uncompressedBytes: Int64
    package var estimatedCompressedBytes: Int64

    package var id: String { titleID }
    package var estimatedSavedBytes: Int64 { max(0, uncompressedBytes - estimatedCompressedBytes) }

    enum CodingKeys: String, CodingKey {
        case titleID = "title_id"
        case appName = "app_name"
        case files
        case uncompressedBytes = "uncompressed_bytes"
        case estimatedCompressedBytes = "estimated_compressed_bytes"
    }

    package init(
        titleID: String,
        appName: String = "",
        files: [String] = [],
        uncompressedBytes: Int64 = 0,
        estimatedCompressedBytes: Int64 = 0
    ) {
        self.titleID = titleID
        self.appName = appName
        self.files = files
        self.uncompressedBytes = uncompressedBytes
        self.estimatedCompressedBytes = estimatedCompressedBytes
    }
}

/// Summary reported by `build_seed.py scan-uncompressed --json`.
package struct SeedScanResult: Codable, Equatable, Sendable {
    package var seedRoot: String
    package var zstdAvailable: Bool
    package var totalGames: Int
    package var totalFiles: Int
    package var uncompressedBytes: Int64
    package var estimatedCompressedBytes: Int64
    package var estimatedSavedBytes: Int64
    package var games: [SeedScanGame]

    package var hasUncompressed: Bool { totalGames > 0 && totalFiles > 0 && uncompressedBytes > 0 }

    enum CodingKeys: String, CodingKey {
        case seedRoot = "seed_root"
        case zstdAvailable = "zstd_available"
        case totalGames = "total_games"
        case totalFiles = "total_files"
        case uncompressedBytes = "uncompressed_bytes"
        case estimatedCompressedBytes = "estimated_compressed_bytes"
        case estimatedSavedBytes = "estimated_saved_bytes"
        case games
    }

    package init(
        seedRoot: String = "",
        zstdAvailable: Bool = false,
        totalGames: Int = 0,
        totalFiles: Int = 0,
        uncompressedBytes: Int64 = 0,
        estimatedCompressedBytes: Int64 = 0,
        estimatedSavedBytes: Int64 = 0,
        games: [SeedScanGame] = []
    ) {
        self.seedRoot = seedRoot
        self.zstdAvailable = zstdAvailable
        self.totalGames = totalGames
        self.totalFiles = totalFiles
        self.uncompressedBytes = uncompressedBytes
        self.estimatedCompressedBytes = estimatedCompressedBytes
        self.estimatedSavedBytes = estimatedSavedBytes
        self.games = games
    }
}

/// Per-game final entry inside `SeedCompressSummary.results`.
package struct SeedCompressItemResult: Codable, Equatable, Identifiable, Sendable {
    package var titleID: String
    package var status: String
    package var beforeBytes: Int64
    package var afterBytes: Int64
    package var savedBytes: Int64
    package var filesCompressed: Int
    package var error: String?

    package var id: String { titleID }

    enum CodingKeys: String, CodingKey {
        case titleID = "title_id"
        case status
        case beforeBytes = "before_bytes"
        case afterBytes = "after_bytes"
        case savedBytes = "saved_bytes"
        case filesCompressed = "files_compressed"
        case error
    }

    package init(
        titleID: String,
        status: String,
        beforeBytes: Int64,
        afterBytes: Int64,
        savedBytes: Int64,
        filesCompressed: Int = 0,
        error: String? = nil
    ) {
        self.titleID = titleID
        self.status = status
        self.beforeBytes = beforeBytes
        self.afterBytes = afterBytes
        self.savedBytes = savedBytes
        self.filesCompressed = filesCompressed
        self.error = error
    }
}

/// Final completion summary emitted by `build_seed.py compress-seeds --progress json`.
package struct SeedCompressSummary: Codable, Equatable, Sendable {
    package enum Status: String, Codable, Equatable, CaseIterable, Sendable {
        case completed
        case partial
        case stopped
    }

    package var status: Status
    package var completedGames: Int
    package var failedGames: Int
    package var beforeBytes: Int64
    package var afterBytes: Int64
    package var savedBytes: Int64
    package var elapsedSec: Double
    package var results: [SeedCompressItemResult]

    enum CodingKeys: String, CodingKey {
        case status
        case completedGames = "completed_games"
        case failedGames = "failed_games"
        case beforeBytes = "before_bytes"
        case afterBytes = "after_bytes"
        case savedBytes = "saved_bytes"
        case elapsedSec = "elapsed_sec"
        case results
    }

    package init(
        status: Status,
        completedGames: Int,
        failedGames: Int,
        beforeBytes: Int64,
        afterBytes: Int64,
        savedBytes: Int64,
        elapsedSec: Double,
        results: [SeedCompressItemResult]
    ) {
        self.status = status
        self.completedGames = completedGames
        self.failedGames = failedGames
        self.beforeBytes = beforeBytes
        self.afterBytes = afterBytes
        self.savedBytes = savedBytes
        self.elapsedSec = elapsedSec
        self.results = results
    }
}

/// NDJSON progress events emitted by `build_seed.py compress-seeds --progress json`.
package enum SeedCompressEvent: Equatable, Sendable {
    case start(totalGames: Int, totalFiles: Int, totalBytes: Int64)
    case itemStart(index: Int, totalGames: Int, titleID: String, beforeBytes: Int64)
    case itemDone(index: Int, totalGames: Int, titleID: String, beforeBytes: Int64, afterBytes: Int64, savedBytes: Int64, filesCompressed: Int)
    case itemError(index: Int, totalGames: Int, titleID: String, beforeBytes: Int64, error: String)
    case done(SeedCompressSummary)
    case error(String)
}

/// CLI builders, NDJSON parsers, and local probe helpers for build-seed zstd compression (`dm/tools/build_seed.py`).
package enum SeedCompression {
    package static let estimateRatio: Double = 0.08
    private static let maxScanEntries = 500_000

    /// Path to `dm/tools/build_seed.py` inside `repoPath` (checkout `engine/` or release engine tree).
    package static func toolPath(repoPath: String) -> String {
        let root = EngineLayout.root(repoPath)
        guard !root.isEmpty else { return "" }
        return root + "/" + RepoLayout.buildSeedTool
    }

    /// Arguments for `python3 -I <build_seed.py> scan-uncompressed --seed-root <dir> --json`.
    package static func scanArguments(toolPath: String, seedRoot: String) -> [String] {
        ["-I", toolPath, "scan-uncompressed", "--seed-root", seedRoot, "--json"]
    }

    /// Arguments for `python3 -I <build_seed.py> compress-seeds --seed-root <dir> --progress json`.
    package static func compressArguments(
        toolPath: String,
        seedRoot: String,
        titleIDs: [String] = [],
        level: Int = 3
    ) -> [String] {
        var args = ["-I", toolPath, "compress-seeds", "--seed-root", seedRoot, "--progress", "json", "--level", "\(level)"]
        for tid in titleIDs where !tid.isEmpty {
            args += ["--title-id", tid.uppercased()]
        }
        return args
    }

    /// Parses stdout from `build_seed.py scan-uncompressed --json`.
    package static func parseScanJSON(_ text: String) -> SeedScanResult? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SeedScanResult.self, from: data)
    }

    private struct RawEventEnvelope: Decodable {
        var event: String
        var totalGames: Int?
        var totalFiles: Int?
        var totalBytes: Int64?
        var index: Int?
        var titleID: String?
        var beforeBytes: Int64?
        var afterBytes: Int64?
        var savedBytes: Int64?
        var filesCompressed: Int?
        var error: String?

        enum CodingKeys: String, CodingKey {
            case event
            case totalGames = "total_games"
            case totalFiles = "total_files"
            case totalBytes = "total_bytes"
            case index
            case titleID = "title_id"
            case beforeBytes = "before_bytes"
            case afterBytes = "after_bytes"
            case savedBytes = "saved_bytes"
            case filesCompressed = "files_compressed"
            case error
        }
    }

    /// Parses a single NDJSON line from `build_seed.py compress-seeds --progress json`.
    package static func parseEvent(line: String) -> SeedCompressEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawEventEnvelope.self, from: data) else {
            return nil
        }
        switch raw.event {
        case "start":
            return .start(
                totalGames: raw.totalGames ?? 0,
                totalFiles: raw.totalFiles ?? 0,
                totalBytes: raw.totalBytes ?? 0
            )
        case "item_start":
            guard let tid = raw.titleID else { return nil }
            return .itemStart(
                index: raw.index ?? 0,
                totalGames: raw.totalGames ?? 0,
                titleID: tid,
                beforeBytes: raw.beforeBytes ?? 0
            )
        case "item_done":
            guard let tid = raw.titleID else { return nil }
            return .itemDone(
                index: raw.index ?? 0,
                totalGames: raw.totalGames ?? 0,
                titleID: tid,
                beforeBytes: raw.beforeBytes ?? 0,
                afterBytes: raw.afterBytes ?? 0,
                savedBytes: raw.savedBytes ?? 0,
                filesCompressed: raw.filesCompressed ?? 0
            )
        case "item_error":
            guard let tid = raw.titleID else { return nil }
            return .itemError(
                index: raw.index ?? 0,
                totalGames: raw.totalGames ?? 0,
                titleID: tid,
                beforeBytes: raw.beforeBytes ?? 0,
                error: raw.error ?? ""
            )
        case "done":
            guard let summary = try? JSONDecoder().decode(SeedCompressSummary.self, from: data) else {
                return nil
            }
            return .done(summary)
        case "error":
            return .error(raw.error ?? "unknown error")
        default:
            return nil
        }
    }

    /// Returns true if `seedRoot` contains at least one valid `<16-hex-TID>` directory (non-symlink).
    package static func hasAnySeedDirectory(in seedRoot: String, fm: FileManager = .default) -> Bool {
        guard !seedRoot.isEmpty, !isSymlink(seedRoot, fm: fm) else { return false }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: seedRoot, isDirectory: &isDir), isDir.boolValue,
              let entries = try? fm.contentsOfDirectory(atPath: seedRoot) else {
            return false
        }
        for name in entries where !name.hasPrefix(".") && isTitleID(name) {
            let full = seedRoot + "/" + name
            guard !isSymlink(full, fm: fm) else { continue }
            var subDir: ObjCBool = false
            if fm.fileExists(atPath: full, isDirectory: &subDir), subDir.boolValue {
                return true
            }
        }
        return false
    }

    /// Fast local scan of `<seedRoot>/<16-hex-TID>/metal-sources/**/b-*.img` without spawning Python.
    package static func quickScanLocal(
        seedRoot: String,
        zstdAvailable: Bool = false,
        fm: FileManager = .default
    ) -> SeedScanResult {
        guard !seedRoot.isEmpty, !isSymlink(seedRoot, fm: fm) else {
            return SeedScanResult(seedRoot: seedRoot, zstdAvailable: zstdAvailable)
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: seedRoot, isDirectory: &isDir), isDir.boolValue,
              let entries = try? fm.contentsOfDirectory(atPath: seedRoot) else {
            return SeedScanResult(seedRoot: seedRoot, zstdAvailable: zstdAvailable)
        }

        var games: [SeedScanGame] = []
        for entry in entries.sorted() {
            if entry.hasPrefix(".") { continue }
            let tid = entry.uppercased()
            guard isTitleID(tid) else { continue }
            let seedDir = seedRoot + "/" + entry
            guard !isSymlink(seedDir, fm: fm) else { continue }
            var seedIsDir: ObjCBool = false
            guard fm.fileExists(atPath: seedDir, isDirectory: &seedIsDir), seedIsDir.boolValue else { continue }

            let metalDir = seedDir + "/metal-sources"
            let found = scanUncompressedMetalImages(in: metalDir, fm: fm)
            guard !found.isEmpty else { continue }

            let totalBytes = found.reduce(Int64(0)) { $0 + $1.sizeBytes }
            let estComp = totalBytes > 0 ? Int64((Double(totalBytes) * estimateRatio).rounded()) : 0
            let appName = readAppName(in: seedDir, fm: fm)
            games.append(SeedScanGame(
                titleID: tid,
                appName: appName,
                files: found.map(\.relPath),
                uncompressedBytes: totalBytes,
                estimatedCompressedBytes: estComp
            ))
        }

        games.sort { lhs, rhs in
            if lhs.uncompressedBytes != rhs.uncompressedBytes {
                return lhs.uncompressedBytes > rhs.uncompressedBytes
            }
            return lhs.titleID < rhs.titleID
        }
        let totalFiles = games.reduce(0) { $0 + $1.files.count }
        let totalUncomp = games.reduce(Int64(0)) { $0 + $1.uncompressedBytes }
        let totalEstComp = games.reduce(Int64(0)) { $0 + $1.estimatedCompressedBytes }
        return SeedScanResult(
            seedRoot: seedRoot,
            zstdAvailable: zstdAvailable,
            totalGames: games.count,
            totalFiles: totalFiles,
            uncompressedBytes: totalUncomp,
            estimatedCompressedBytes: totalEstComp,
            estimatedSavedBytes: max(0, totalUncomp - totalEstComp),
            games: games
        )
    }

    private struct DirLoopKey: Hashable {
        let dev: UInt64
        let ino: UInt64
    }

    private static func scanUncompressedMetalImages(
        in metalDir: String,
        fm: FileManager
    ) -> [(relPath: String, sizeBytes: Int64)] {
        guard !isSymlink(metalDir, fm: fm) else { return [] }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: metalDir, isDirectory: &isDir), isDir.boolValue else { return [] }

        var st = Darwin.stat()
        guard Darwin.lstat(metalDir, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return [] }

        var visited: Set<DirLoopKey> = [DirLoopKey(dev: UInt64(st.st_dev), ino: UInt64(st.st_ino))]
        var stack: [(dir: String, rel: String)] = [(metalDir, "")]
        var found: [(relPath: String, sizeBytes: Int64)] = []
        var entriesSeen = 0

        while let current = stack.popLast() {
            guard let names = try? fm.contentsOfDirectory(atPath: current.dir) else { continue }
            for name in names.sorted() {
                entriesSeen += 1
                if entriesSeen > maxScanEntries { return found.sorted { $0.relPath < $1.relPath } }
                if name.hasPrefix(".") || name.contains(".tmp") || name.hasSuffix(".part") { continue }
                let full = current.dir + "/" + name
                let rel = current.rel.isEmpty ? name : (current.rel + "/" + name)

                var est = Darwin.stat()
                guard Darwin.lstat(full, &est) == 0 else { continue }
                let kind = est.st_mode & S_IFMT
                if kind == S_IFLNK { continue }
                if kind == S_IFDIR {
                    let key = DirLoopKey(dev: UInt64(est.st_dev), ino: UInt64(est.st_ino))
                    if visited.insert(key).inserted {
                        stack.append((full, rel))
                    }
                } else if kind == S_IFREG, name.hasPrefix("b-"), name.hasSuffix(".img") {
                    found.append((rel, Int64(est.st_size)))
                }
            }
        }
        return found.sorted { $0.relPath < $1.relPath }
    }

    private static func readAppName(in seedDir: String, fm: FileManager) -> String {
        let seedJSON = seedDir + "/seed.json"
        guard !isSymlink(seedJSON, fm: fm),
              let data = fm.contents(atPath: seedJSON),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = obj["app_name"] as? String else {
            return ""
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isTitleID(_ raw: String) -> Bool {
        raw.count == 16 && raw.unicodeScalars.allSatisfy {
            ("0"..."9").contains($0) || ("A"..."F").contains($0) || ("a"..."f").contains($0)
        }
    }

    private static func isSymlink(_ path: String, fm: FileManager) -> Bool {
        (try? fm.destinationOfSymbolicLink(atPath: path)) != nil
    }
}
