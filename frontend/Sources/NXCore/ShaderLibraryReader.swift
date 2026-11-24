import CryptoKit
import Darwin
import Foundation

/// Metadata extracted from a `shader_lib` folder or `.img` (`DMROMFS1` archive) matching `dm/tools/shader_lib.py`.
package struct ShaderLibraryStamp: Equatable, Sendable {
    package var exists: Bool
    package var hasLibrary: Bool
    package var hasLeftOutPulling: Bool
    package var gameID: String?
    package var inputsDigest: String?

    package init(
        exists: Bool = false,
        hasLibrary: Bool = false,
        hasLeftOutPulling: Bool = false,
        gameID: String? = nil,
        inputsDigest: String? = nil
    ) {
        self.exists = exists
        self.hasLibrary = hasLibrary
        self.hasLeftOutPulling = hasLeftOutPulling
        self.gameID = gameID
        self.inputsDigest = inputsDigest
    }
}

extension RefreshPrecheck {
    private static let inputTables = [
        "shader_facts.tsv",
        "shader_map.tsv",
        "shader_map.tsv.conflicts.tsv",
        "shader_pairs.tsv",
        "pso_pairs.tsv",
        "bf_want.tsv",
        "geo_mesh.tsv",
        "geo_pairs.tsv",
    ]
    private static let romfsHeaderSize: UInt64 = 32
    private static let romfsEntrySize: UInt64 = 24
    private static let romfsHeaderMagic: [UInt8] = Array("DMROMFS1".utf8)
    private static let maxIndexBytes: UInt64 = 64 * 1024 * 1024

    // MARK: - Profile inputs digest (`dm/gfx/tools/dmsh_chain.py --inputs`)

    /// Computes the 12-hex-digit shader inputs digest identical to `dm/gfx/tools/dmsh_chain.py:inputs(g)`.
    package static func computeProfileInputsDigest(profileDir: String, fm: FileManager = .default) -> String? {
        let gameTSVPath = profileDir + "/game.tsv"
        guard let gameText = try? String(contentsOfFile: gameTSVPath, encoding: .utf8) else {
            return nil
        }
        var h = SHA256()
        for table in inputTables {
            h.update(data: Data(("game/" + table + "\0").utf8))
            let tablePath = profileDir + "/" + table
            if let data = fm.contents(atPath: tablePath) {
                h.update(data: data)
            } else {
                h.update(data: Data("missing".utf8))
            }
            h.update(data: Data([0]))
        }

        let manifestPath = profileDir + "/pso_manifest.tsv"
        if let manifestText = try? String(contentsOfFile: manifestPath, encoding: .utf8) {
            struct Pair: Hashable, Comparable {
                let v: String
                let g: String
                static func < (lhs: Pair, rhs: Pair) -> Bool {
                    if lhs.v != rhs.v { return lhs.v < rhs.v }
                    return lhs.g < rhs.g
                }
            }
            var pairs = Set<Pair>()
            for rawLine in manifestText.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
                let cols = rawLine.split(separator: "\t", omittingEmptySubsequences: false)
                if cols.first == "G", cols.count >= 3, !cols[1].isEmpty, !cols[2].isEmpty {
                    pairs.insert(Pair(v: String(cols[1].prefix(16)), g: String(cols[2].prefix(16))))
                }
            }
            if !pairs.isEmpty {
                h.update(data: Data("game/pso_manifest.tsv G\0".utf8))
                let serialized = pairs.sorted().map { "\($0.v)\t\($0.g)\n" }.joined()
                h.update(data: Data(serialized.utf8))
                h.update(data: Data([0]))
            }
        }

        var profileRowsText = ""
        for rawLine in gameText.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if line.drop(while: { $0.isWhitespace }).hasPrefix("#") { continue }
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard let first = cols.first else { continue }
            let key = first.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.hasPrefix("nvn_") || key.hasPrefix("shader_") {
                let vals = cols.dropFirst().map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                profileRowsText += key + "\t" + vals.joined(separator: "\t") + "\n"
            }
        }
        h.update(data: Data(profileRowsText.utf8))

        let digest = h.finalize()
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Shader library inspection (`dm/tools/shader_lib.py` + `dm/tools/romfs.py`)

    /// Reads `inputs.tsv`, `_bp_left_out`, and `*_b.metallib` presence from a `b-<chain>` folder or `.img` archive.
    package static func readShaderLibraryStamp(
        parentDir: String,
        chain: String,
        isMultiProgram: Bool = false,
        fm: FileManager = .default
    ) -> ShaderLibraryStamp {
        let norm = normalizeChain(chain) ?? chain
        let tag = "b-" + norm
        let primary = readSingleShaderLib(basePath: parentDir + "/" + tag, fm: fm)
        if primary.exists { return primary }
        if isMultiProgram {
            let p0 = readSingleShaderLib(basePath: parentDir + "/p0/" + tag, fm: fm)
            if p0.exists { return p0 }
        }
        return ShaderLibraryStamp()
    }

    static func readSingleShaderLib(basePath: String, fm: FileManager) -> ShaderLibraryStamp {
        let folder = basePath.hasSuffix(".img") ? String(basePath.dropLast(4)) : basePath
        let image = folder + ".img"
        let folderStampPath = folder + "/inputs.tsv"

        // Matches `shader_lib.view`: prefer `.img` unless folder has `inputs.tsv`.
        if fm.fileExists(atPath: image) && !fm.fileExists(atPath: folderStampPath) {
            return readShaderLibImage(path: image)
        }
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue {
            return readShaderLibFolder(path: folder, fm: fm)
        }
        if fm.fileExists(atPath: image) {
            return readShaderLibImage(path: image)
        }
        return ShaderLibraryStamp()
    }

    private static func readShaderLibFolder(path: String, fm: FileManager) -> ShaderLibraryStamp {
        guard let entries = try? fm.contentsOfDirectory(atPath: path) else {
            return ShaderLibraryStamp()
        }
        var hasLib = false
        var hasLeftOut = false
        for name in entries where !name.hasPrefix(".") && !name.contains(".tmp") {
            if name.hasSuffix("_b.metallib") { hasLib = true }
            if name == "_bp_left_out" { hasLeftOut = true }
        }
        let stampText = try? String(contentsOfFile: path + "/inputs.tsv", encoding: .utf8)
        let parsed: (gameID: String?, inputsDigest: String?) = stampText.map(parseInputsTSV) ?? (nil, nil)
        return ShaderLibraryStamp(
            exists: true,
            hasLibrary: hasLib,
            hasLeftOutPulling: hasLeftOut,
            gameID: parsed.gameID,
            inputsDigest: parsed.inputsDigest
        )
    }

    private static func readShaderLibImage(path: String) -> ShaderLibraryStamp {
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return ShaderLibraryStamp() }
        defer { Darwin.close(fd) }

        var st = Darwin.stat()
        guard Darwin.fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_size >= Int64(romfsHeaderSize) else {
            return ShaderLibraryStamp()
        }
        let fileSize = UInt64(st.st_size)
        var head = [UInt8](repeating: 0, count: Int(romfsHeaderSize))
        guard preadInto(fd: fd, buffer: &head, count: Int(romfsHeaderSize), offset: 0),
              Array(head[0..<8]) == romfsHeaderMagic else {
            return ShaderLibraryStamp()
        }

        let ioff = readUInt64LE(head, at: 8)
        let isz = readUInt64LE(head, at: 16)
        let count = readUInt64LE(head, at: 24)
        guard count > 0, count <= UInt64(UInt32.max),
              ioff >= romfsHeaderSize, ioff <= fileSize,
              isz <= fileSize - ioff, isz <= maxIndexBytes,
              count <= isz / romfsEntrySize else {
            return ShaderLibraryStamp()
        }

        var index = [UInt8](repeating: 0, count: Int(isz))
        guard preadInto(fd: fd, buffer: &index, count: Int(isz), offset: ioff) else {
            return ShaderLibraryStamp()
        }

        let poolOffset = Int(count * romfsEntrySize)
        var hasLib = false
        var hasLeftOut = false
        var gameID: String?
        var inputsDigest: String?

        for k in 1..<Int(count) {
            let base = k * Int(romfsEntrySize)
            let dataOff = readUInt64LE(index, at: base)
            let dataSize = readUInt64LE(index, at: base + 8)
            let nameOff = Int(readUInt32LE(index, at: base + 16))
            let nameLen = Int(readUInt16LE(index, at: base + 20))
            let entryType = index[base + 22]

            guard entryType == 1,
                  nameOff <= index.count - poolOffset,
                  nameLen <= index.count - poolOffset - nameOff,
                  dataOff >= romfsHeaderSize, dataOff <= ioff,
                  dataSize <= ioff - dataOff else {
                continue
            }

            let nameSlice = index[(poolOffset + nameOff)..<(poolOffset + nameOff + nameLen)]
            let name = String(decoding: nameSlice, as: UTF8.self)
            if name.hasSuffix("_b.metallib") { hasLib = true }
            if name == "_bp_left_out" { hasLeftOut = true }
            if name == "inputs.tsv", dataSize <= 65536 {
                var buf = [UInt8](repeating: 0, count: Int(dataSize))
                if preadInto(fd: fd, buffer: &buf, count: Int(dataSize), offset: dataOff) {
                    let text = String(decoding: buf, as: UTF8.self)
                    let parsed = parseInputsTSV(text)
                    gameID = parsed.gameID
                    inputsDigest = parsed.inputsDigest
                }
            }
        }

        return ShaderLibraryStamp(
            exists: true,
            hasLibrary: hasLib,
            hasLeftOutPulling: hasLeftOut,
            gameID: gameID,
            inputsDigest: inputsDigest
        )
    }

    private static func parseInputsTSV(_ text: String) -> (gameID: String?, inputsDigest: String?) {
        var gameID: String?
        var inputsDigest: String?
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = trimmed.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            let val = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if key == "game" && !val.isEmpty { gameID = val }
            if key == "inputs" && !val.isEmpty { inputsDigest = val }
        }
        return (gameID, inputsDigest)
    }

    private static func readUInt16LE(_ b: [UInt8], at i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }

    private static func readUInt32LE(_ b: [UInt8], at i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }

    private static func readUInt64LE(_ b: [UInt8], at i: Int) -> UInt64 {
        UInt64(readUInt32LE(b, at: i)) | (UInt64(readUInt32LE(b, at: i + 4)) << 32)
    }

    private static func preadInto(fd: Int32, buffer: inout [UInt8], count: Int, offset: UInt64) -> Bool {
        guard count >= 0,
              count <= buffer.count,
              offset <= UInt64(Int64.max),
              UInt64(count) <= UInt64(Int64.max) - offset else {
            return false
        }
        var got = 0
        while got < count {
            let rc = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.pread(fd, base.advanced(by: got), count - got, off_t(offset + UInt64(got)))
            }
            if rc < 0 {
                if errno == EINTR { continue }
                return false
            }
            if rc == 0 { return false }
            got += rc
        }
        return true
    }
}
