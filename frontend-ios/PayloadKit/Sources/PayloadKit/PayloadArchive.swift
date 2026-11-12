import Foundation
import CryptoKit

/// A bounded JSON header followed by regular-file bytes in manifest order.
/// No compression, links, resource forks, or paths outside the named framework.
public enum PayloadArchive {
    public static let fileName = "game.nxpayload"
    public static let readyName = "ready.json"
    static let magic = Data("NXPAYLD1".utf8)
    static let chunk = 1 << 20
    static let headerLimit = 8 << 20

    public struct Ready: Codable, Sendable {
        public var generation: String
        public var bytes: UInt64
        public var sha256: String
        public var partSize: UInt64
        public init(generation: String, bytes: UInt64, sha256: String, partSize: UInt64 = 512 << 20) {
            self.generation = generation; self.bytes = bytes; self.sha256 = sha256
            self.partSize = partSize
        }
    }

    /// Called after seeing the completion marker, inside the intake actor. A
    /// missing part is still an incomplete transfer, never a permanent rejection.
    public static func joinParts(in transaction: URL, ready: Ready) throws -> Bool {
        let fm = FileManager.default
        let archive = transaction.appendingPathComponent(fileName)
        if fm.fileExists(atPath: archive.path) { return true }
        guard ready.partSize > 0, ready.partSize <= 512 << 20, ready.bytes > 0, ready.bytes <= 128 << 30 else {
            throw PayloadError.invalid("part dimensions")
        }
        let count = Int((ready.bytes + ready.partSize - 1) / ready.partSize)
        guard count > 1, count <= 65_535 else { return false }
        let parts = (0..<count).map { transaction.appendingPathComponent(String(format: "%@.nxpart.%04d.%04d", fileName, $0, count)) }
        guard parts.allSatisfy({ fm.fileExists(atPath: $0.path) }) else { return false }
        for (index, part) in parts.enumerated() {
            let attrs = try fm.attributesOfItem(atPath: part.path)
            let expected = index == count - 1 ? ready.bytes - UInt64(index) * ready.partSize : ready.partSize
            guard attrs[.type] as? FileAttributeType == .typeRegular, try size(part) == expected else {
                throw PayloadError.invalid("part size or type")
            }
        }
        let partial = transaction.appendingPathComponent(".assembling")
        guard fm.createFile(atPath: partial.path, contents: nil) else { throw PayloadError.invalid("part join destination") }
        let out = try FileHandle(forWritingTo: partial)
        defer { try? out.close(); try? fm.removeItem(at: partial) }
        try out.truncate(atOffset: 0)
        for part in parts {
            let input = try FileHandle(forReadingFrom: part)
            do {
                while let data = try input.read(upToCount: chunk), !data.isEmpty { try out.write(contentsOf: data) }
                try input.close()
            } catch { try? input.close(); throw error }
        }
        try out.synchronize()
        try out.close()
        try fm.moveItem(at: partial, to: archive)
        for part in parts { try? fm.removeItem(at: part) }
        return true
    }

    public static func digest(_ url: URL, checkCancellation: () throws -> Void = {}) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = SHA256()
        while true {
            try checkCancellation()
            guard let data = try input.read(upToCount: chunk), !data.isEmpty else { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func size(_ url: URL) throws -> UInt64 {
        guard let number = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            throw PayloadError.invalid("file size")
        }
        return number.uint64Value
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func fileList(framework: URL, checkCancellation: () throws -> Void = {}) throws -> [PayloadManifest.File] {
        let fm = FileManager.default
        let rootAttributes = try fm.attributesOfItem(atPath: framework.path)
        guard rootAttributes[.type] as? FileAttributeType == .typeDirectory else {
            throw PayloadError.invalid("framework root must be a directory, not a link")
        }
        let base = framework.resolvingSymlinksInPath().standardizedFileURL
        guard let walk = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]) else {
            throw PayloadError.invalid("framework directory")
        }
        var files: [PayloadManifest.File] = []
        for case let url as URL in walk {
            try checkCancellation()
            let attrs = try fm.attributesOfItem(atPath: url.path)
            guard let type = attrs[.type] as? FileAttributeType, type == .typeRegular || type == .typeDirectory else {
                throw PayloadError.invalid("links and special files are unsupported")
            }
            if type == .typeDirectory { continue }
            let child = url.resolvingSymlinksInPath().standardizedFileURL
            guard child.path.hasPrefix(base.path + "/") else { throw PayloadError.invalid("framework path") }
            let relative = base.lastPathComponent + "/" + String(child.path.dropFirst(base.path.count + 1))
            guard PayloadManifest.safePath(relative) else { throw PayloadError.invalid("file path") }
            files.append(.init(path: relative, bytes: try size(url), sha256: try digest(url, checkCancellation: checkCancellation),
                               executable: ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o111 != 0))
        }
        return files.sorted { $0.path < $1.path }
    }

    public static func write(manifest: PayloadManifest, parent: URL, to archive: URL, checkCancellation: () throws -> Void = {}) throws {
        try manifest.validate()
        let header = try encode(manifest)
        guard header.count <= headerLimit else { throw PayloadError.invalid("header too large") }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: archive.path), fm.createFile(atPath: archive.path, contents: nil) else {
            throw PayloadError.invalid("archive destination exists")
        }
        let out = try FileHandle(forWritingTo: archive)
        var success = false
        defer { try? out.close(); if !success { try? fm.removeItem(at: archive) } }
        try out.write(contentsOf: magic)
        var length = UInt64(header.count).bigEndian
        try withUnsafeBytes(of: &length) { try out.write(contentsOf: Data($0)) }
        try out.write(contentsOf: header)
        for file in manifest.files {
            let url = parent.appendingPathComponent(file.path)
            guard try size(url) == file.bytes, try digest(url, checkCancellation: checkCancellation) == file.sha256 else { throw PayloadError.invalid("file changed during packaging") }
            let input = try FileHandle(forReadingFrom: url)
            do {
                while true {
                    try checkCancellation()
                    guard let data = try input.read(upToCount: chunk), !data.isEmpty else { break }
                    try out.write(contentsOf: data)
                }
                try input.close()
            } catch { try? input.close(); throw error }
        }
        try out.synchronize()
        success = true
    }

    static func readHeader(_ input: FileHandle) throws -> PayloadManifest {
        guard try input.read(upToCount: 8) == magic, let lengthData = try input.read(upToCount: 8), lengthData.count == 8 else {
            throw PayloadError.invalid("archive header")
        }
        let length = lengthData.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard length > 0, length <= headerLimit, let data = try input.read(upToCount: Int(length)), data.count == Int(length) else {
            throw PayloadError.invalid("header length")
        }
        let manifest = try JSONDecoder().decode(PayloadManifest.self, from: data)
        try manifest.validate()
        return manifest
    }

    public static func manifest(at archive: URL) throws -> PayloadManifest {
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }
        return try readHeader(input)
    }

    /// destination must not already exist. Partial extraction is removed on failure.
    public static func extract(_ archive: URL, to destination: URL, host: PayloadCapabilities) throws -> PayloadManifest {
        let fm = FileManager.default
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }
        let manifest = try readHeader(input)
        try manifest.compatible(with: host)
        let expected = manifest.files.reduce(UInt64(0)) { $0 + $1.bytes }
        guard try input.offset() + expected == size(archive), !fm.fileExists(atPath: destination.path) else {
            throw PayloadError.invalid("archive length or staging destination")
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var success = false
        defer { if !success { try? fm.removeItem(at: destination) } }
        for file in manifest.files {
            let url = destination.appendingPathComponent(file.path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fm.createFile(atPath: url.path, contents: nil) else { throw PayloadError.invalid("extraction destination") }
            let out = try FileHandle(forWritingTo: url)
            do {
                var remaining = file.bytes
                var hash = SHA256()
                while remaining > 0 {
                    guard let data = try input.read(upToCount: Int(min(remaining, UInt64(chunk)))), !data.isEmpty else {
                        throw PayloadError.invalid("truncated file")
                    }
                    try out.write(contentsOf: data)
                    hash.update(data: data)
                    remaining -= UInt64(data.count)
                }
                try out.synchronize()
                try out.close()
                guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
                    throw PayloadError.invalid("file digest mismatch")
                }
                try fm.setAttributes([.posixPermissions: file.executable ? 0o755 : 0o644], ofItemAtPath: url.path)
            } catch { try? out.close(); throw error }
        }
        success = true
        return manifest
    }
}
