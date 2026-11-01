import Foundation

/// The identity of a RomFS image (DMROMFS1): its size and a hash of its header and index, never of the file data. The
/// same computation as `romfs_id_of_image` in `dm/host/romfs_identity.h`, so it matches the `romfs_identity` line the
/// game's manifest carries (`DMROMFSID1 title=… version=… build=… size=<bytes> index=<16 hex digits>`).
struct RomfsIdentity: Equatable, Sendable {
    var size: UInt64
    var index: UInt64

    private static let offsetBasis: UInt64 = 0xcbf29ce484222325, prime: UInt64 = 0x100000001b3, chunk: UInt64 = 1 << 20

    /// FNV-1a 64 over the little-endian 64-bit words of `bytes`, zero-padded to a multiple of 8 (`romfs_id_mix`).
    static func mix(_ hash: UInt64, _ bytes: [UInt8]) -> UInt64 {
        var h = hash
        var i = 0
        while i < bytes.count {
            var word: UInt64 = 0
            for k in 0..<8 where i + k < bytes.count { word |= UInt64(bytes[i + k]) << (8 * UInt64(k)) }
            h = (h ^ word) &* prime
            i += 8
        }
        return h
    }

    /// The `size=` and `index=` of an identity line, nil when the line has no magic, or lacks either (`romfs_id_parse`).
    static func parse(_ line: String) -> RomfsIdentity? {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard fields.first == "DMROMFSID1" else { return nil }
        var size: UInt64?, index: UInt64?
        for field in fields.dropFirst() {
            guard let eq = field.firstIndex(of: "=") else { continue }
            let value = field[field.index(after: eq)...]
            switch field[..<eq] {
            case "size": guard let v = UInt64(value) else { return nil }; size = v
            case "index": guard let v = UInt64(value, radix: 16) else { return nil }; index = v
            default: break
            }
        }
        guard let size, let index else { return nil }
        return RomfsIdentity(size: size, index: index)
    }

    /// The identity of the image at `url`, nil for a missing, cut off or invalid image (`romfs_id_of_image`).
    static func ofImage(at url: URL) -> RomfsIdentity? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let total = try? handle.seekToEnd(), (try? handle.seek(toOffset: 0)) != nil,
              let head = try? handle.read(upToCount: 32), head.count == 32 else { return nil }
        let h = [UInt8](head)
        func word(_ at: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(h[at + $1]) << (8 * UInt64($1)) } }
        let indexOffset = word(8), indexSize = word(16)
        guard Array(h[0..<8]) == Array("DMROMFS1".utf8), indexOffset >= 32, indexOffset <= total, indexSize == total - indexOffset else { return nil }
        var hash = mix(offsetBasis, h)
        do {
            try handle.seek(toOffset: indexOffset)
            var left = indexSize
            while left > 0 {
                guard let data = try handle.read(upToCount: Int(min(left, chunk))), !data.isEmpty else { return nil }
                hash = mix(hash, [UInt8](data))
                left -= UInt64(data.count)
            }
        } catch { return nil }
        return RomfsIdentity(size: total, index: hash)
    }
}

/// The `romfs.img` files under a folder the player picked for every game, found by the image's own identity so the folder
/// names do not matter. A scan lists the folder one and two levels down (a bounded number of entries, hidden items and
/// symbolic links skipped, so no loop and no deep walk of an external drive) and `stat`s each image. Only an image with the
/// size of the game's `romfs_identity` is read (its header and index), and that identity is remembered per image.
/// This reads the drive, so it runs off the main actor (`ShellHostModel` starts it and shows the games as needing data
/// until it is done).
final class ShellDataIndex: @unchecked Sendable {
    static let maxEntries = 2000

    let folder: URL
    private let fm: FileManager
    private let lock = NSLock()
    private var images: [(url: URL, size: UInt64)] = []
    private var identities: [URL: RomfsIdentity?] = [:]

    init(folder: URL, fileManager: FileManager = .default) {
        self.folder = folder
        fm = fileManager
        scan()
    }

    /// `<folder>/*/romfs.img` and `<folder>/*/*/romfs.img` (any case of the name), up to `maxEntries` entries listed.
    private func scan() {
        var seen = 0
        func children(_ dir: URL) -> [URL] {
            let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
                                                    options: [.skipsHiddenFiles])) ?? []
            seen += urls.count
            return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        func visit(_ dir: URL, depth: Int) {
            for url in children(dir) where seen <= Self.maxEntries {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
                if values?.isSymbolicLink == true { continue }
                if values?.isDirectory == true {
                    if depth < 2 { visit(url, depth: depth + 1) }
                } else if depth >= 1, url.lastPathComponent.lowercased() == "romfs.img", let size = values?.fileSize, size > 0 {
                    images.append((url, UInt64(size)))
                }
            }
        }
        visit(folder, depth: 0)
    }

    /// The folder of the image that is this game's: the size equals `want.size` and the identity equals `want`.
    func folder(matching want: RomfsIdentity) -> URL? {
        for image in images where image.size == want.size {
            lock.lock()
            let known = identities[image.url]
            lock.unlock()
            let identity: RomfsIdentity?
            if let known { identity = known } else {
                identity = RomfsIdentity.ofImage(at: image.url)
                lock.lock(); identities[image.url] = .some(identity); lock.unlock()
            }
            if identity == want { return image.url.deletingLastPathComponent() }
        }
        return nil
    }
}
