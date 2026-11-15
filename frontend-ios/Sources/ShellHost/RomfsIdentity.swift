import Darwin
import Foundation

enum RomfsImageName {
    static func isNonPartImage(_ name: String) -> Bool {
        guard !name.hasPrefix(".") else { return false }
        let lower = name.lowercased()
        guard (lower as NSString).pathExtension == "img" else { return false }
        return DataParts.parse(name) == nil && !lower.contains(".nxpart")
    }
}

/// Optional page-aligned MSL shader archive trailer (`DMMSLTR1` 64-byte footer) appended after the base `DMROMFS1` index.
public struct RomfsTrailer: Equatable, Sendable {
    public static let footerSize: UInt64 = 64
    public static let pageAlignment: UInt64 = 16_384

    public var version: UInt32
    public var gfxAPI: UInt8
    public var multiProgram: Bool
    public var baseRomfsSize: UInt64
    public var mslOffset: UInt64
    public var mslSize: UInt64
    public var chain: String

    public init(version: UInt32, gfxAPI: UInt8, multiProgram: Bool,
                baseRomfsSize: UInt64, mslOffset: UInt64, mslSize: UInt64, chain: String) {
        self.version = version
        self.gfxAPI = gfxAPI
        self.multiProgram = multiProgram
        self.baseRomfsSize = baseRomfsSize
        self.mslOffset = mslOffset
        self.mslSize = mslSize
        self.chain = chain
    }

    /// Inspects the 32-byte `DMROMFS1` header and 64-byte `DMMSLTR1` footer via `pread` in O(1) without reading the payload.
    public static func inspect(at url: URL) -> RomfsTrailer? {
        let fd = Darwin.open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { _ = Darwin.close(fd) }
        var st = Darwin.stat()
        guard Darwin.fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size > 0 else { return nil }
        let fileSize = UInt64(st.st_size)
        guard let head = preadAll(fd: fd, offset: 0, count: 32),
              head[0..<8].elementsEqual("DMROMFS1".utf8) else { return nil }
        let ioff = le64(head, 8), isz = le64(head, 16)
        return inspect(fd: fd, fileSize: fileSize, ioff: ioff, isz: isz)
    }

    static func inspect(fd: Int32, fileSize: UInt64, ioff: UInt64, isz: UInt64) -> RomfsTrailer? {
        guard ioff >= 32, ioff <= fileSize, isz <= fileSize - ioff else { return nil }
        let baseEnd = ioff + isz
        guard baseEnd < fileSize, fileSize - baseEnd >= footerSize else { return nil }
        let footerOffset = fileSize - footerSize
        guard let footer = preadAll(fd: fd, offset: footerOffset, count: Int(footerSize)),
              footer[0..<8].elementsEqual("DMMSLTR1".utf8) else { return nil }
        let version = le32(footer, 8)
        let gfxAPI = footer[12]
        let flags = footer[13]
        let chainLen = Int(le16(footer, 14))
        let baseRomfsSize = le64(footer, 16)
        let mslOffset = le64(footer, 24)
        let mslSize = le64(footer, 32)
        guard version == 1,
              (1...3).contains(gfxAPI),
              baseRomfsSize == baseEnd,
              baseEnd <= UInt64.max - (pageAlignment - 1),
              mslOffset == ((baseEnd + (pageAlignment - 1)) & ~(pageAlignment - 1)),
              mslSize >= 32,
              mslOffset <= footerOffset,
              mslSize <= footerOffset - mslOffset else { return nil }
        let rawEnd = mslOffset + mslSize
        guard rawEnd <= UInt64.max - 7,
              ((rawEnd + 7) & ~7) == footerOffset,
              chainLen <= 24 else { return nil }
        let prefix = footer[40..<(40 + chainLen)]
        let padding = footer[(40 + chainLen)..<64]
        guard !prefix.contains(0),
              padding.allSatisfy({ $0 == 0 }),
              let chain = String(bytes: prefix, encoding: .utf8) else { return nil }
        return RomfsTrailer(
            version: version,
            gfxAPI: gfxAPI,
            multiProgram: (flags & 1) != 0,
            baseRomfsSize: baseRomfsSize,
            mslOffset: mslOffset,
            mslSize: mslSize,
            chain: chain
        )
    }

    private static func preadAll(fd: Int32, offset: UInt64, count: Int) -> [UInt8]? {
        guard count > 0,
              offset <= UInt64(Int64.max),
              UInt64(count) <= UInt64(Int64.max) - offset else { return nil }
        var buf = [UInt8](repeating: 0, count: count)
        var done = 0
        while done < count {
            let n = buf.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.pread(fd, base.advanced(by: done), count - done, off_t(offset) + off_t(done))
            }
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { return nil }
            done += n
        }
        return buf
    }

    private static func le16(_ b: [UInt8], _ o: Int) -> UInt16 {
        UInt16(b[o]) | (UInt16(b[o + 1]) << 8)
    }

    private static func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }

    private static func le64(_ b: [UInt8], _ o: Int) -> UInt64 {
        (0..<8).reduce(0) { $0 | (UInt64(b[o + $1]) << (8 * UInt64($1))) }
    }
}

/// The identity of a RomFS image (DMROMFS1): its base size and a hash of its header and index, never of the file data or trailer.
/// The same computation as `romfs_id_of_image` in `dm/host/romfs_identity.h`, so it matches the `romfs_identity` line the
/// game's manifest carries (`DMROMFSID1 title=… version=… build=… size=<bytes> index=<16 hex digits>`).
public struct RomfsIdentity: Equatable, Hashable, Sendable {
    public var size: UInt64
    public var index: UInt64

    public init(size: UInt64, index: UInt64) {
        self.size = size
        self.index = index
    }

    public static let chunkSize: UInt64 = 1 << 20
    private static let offsetBasis: UInt64 = 0xcbf29ce484222325, prime: UInt64 = 0x100000001b3

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
    public static func parse(_ line: String) -> RomfsIdentity? {
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
    /// The index is mixed in chunks of `chunk` bytes, each read completely first (a read may return less, on a file provider or an
    /// external drive) and only the last chunk padded, as `romfs_id_of_image` does. The chunk is a parameter for tests.
    public static func ofImage(at url: URL, chunk: UInt64 = chunkSize) -> RomfsIdentity? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let total = try? handle.seekToEnd(), (try? handle.seek(toOffset: 0)) != nil,
              let head = try? handle.read(upToCount: 32), head.count == 32 else { return nil }
        let h = [UInt8](head)
        func word(_ at: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(h[at + $1]) << (8 * UInt64($1)) } }
        let indexOffset = word(8), indexSize = word(16)
        guard Array(h[0..<8]) == Array("DMROMFS1".utf8),
              indexOffset >= 32,
              indexOffset <= total,
              indexSize <= total - indexOffset else { return nil }
        let baseEnd = indexOffset + indexSize
        if total > baseEnd {
            guard RomfsTrailer.inspect(fd: handle.fileDescriptor, fileSize: total, ioff: indexOffset, isz: indexSize)?.baseRomfsSize == baseEnd else {
                return nil
            }
        }
        var hash = mix(offsetBasis, h)
        do {
            try handle.seek(toOffset: indexOffset)
            var left = indexSize
            while left > 0 {
                let want = Int(min(left, chunk))
                var piece = Data()
                while piece.count < want {
                    guard let part = try handle.read(upToCount: want - piece.count), !part.isEmpty else { return nil }   // cut off
                    piece.append(part)
                }
                hash = mix(hash, [UInt8](piece))
                left -= UInt64(want)
            }
        } catch { return nil }
        return RomfsIdentity(size: baseEnd, index: hash)
    }
}

/// The `*.img` files under a folder the player picked for every game, found by the image's own identity so the file and folder
/// names do not matter. A scan lists the folder itself and one and two levels down (a bounded number of entries, hidden items and
/// symbolic links skipped, so no loop and no deep walk of an external drive) and `stat`s each image. Only an image whose base
/// RomFS size matches the game's `romfs_identity` is hashed, and that identity is remembered per image.
/// This reads the drive, so it runs off the main actor (`ShellHostModel` starts it and shows the games as needing data
/// until it is done).
public final class ShellDataIndex: @unchecked Sendable {
    public static let maxEntries = 2000

    public let folder: URL
    private let fm: FileManager
    private let lock = NSLock()
    private var images: [(url: URL, size: UInt64)] = []
    private var trailers: [URL: RomfsTrailer?] = [:]
    private var identities: [URL: RomfsIdentity?] = [:]

    public init(folder: URL, fileManager: FileManager = .default) {
        self.folder = folder
        fm = fileManager
        scan()
    }

    /// `<folder>/*.img`, `<folder>/*/*.img` and `<folder>/*/*/*.img` (excluding split `.nxpart` files), up to `maxEntries` entries listed.
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
                let name = url.lastPathComponent
                if name.hasPrefix(".") { continue }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
                if values?.isSymbolicLink == true { continue }
                if values?.isDirectory == true {
                    if depth < 2 { visit(url, depth: depth + 1) }
                } else if depth >= 0,
                          url.pathExtension.lowercased() == "img",
                          DataParts.parse(name) == nil,
                          !name.lowercased().contains(".nxpart"),
                          let size = values?.fileSize, size > 0 {
                    images.append((url, UInt64(size)))
                }
            }
        }
        visit(folder, depth: 0)
    }

    /// The exact image URL that matches `want`: `size == want.size` (or `size > want.size` with a valid trailer whose
    /// `baseRomfsSize == want.size`) and `RomfsIdentity.ofImage` equal to `want`.
    public func imageURL(matching want: RomfsIdentity) -> URL? {
        for image in images where image.size >= want.size {
            lock.lock()
            let knownIdentity = identities[image.url]
            lock.unlock()
            if let knownIdentity {
                if knownIdentity == want { return image.url }
                continue
            }
            if image.size > want.size {
                lock.lock()
                let knownTrailer = trailers[image.url]
                lock.unlock()
                let trailer: RomfsTrailer?
                if let knownTrailer {
                    trailer = knownTrailer
                } else {
                    trailer = RomfsTrailer.inspect(at: image.url)
                    lock.lock()
                    trailers[image.url] = .some(trailer)
                    if trailer == nil { identities[image.url] = .some(nil) }
                    lock.unlock()
                }
                guard let trailer, trailer.baseRomfsSize == want.size else { continue }
            }
            let identity = RomfsIdentity.ofImage(at: image.url)
            lock.lock()
            identities[image.url] = .some(identity)
            lock.unlock()
            if identity == want { return image.url }
        }
        return nil
    }

    /// The folder of the image that is this game's.
    public func folder(matching want: RomfsIdentity) -> URL? {
        imageURL(matching: want)?.deletingLastPathComponent()
    }
}
