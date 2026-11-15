import Foundation
import NXCore

// The title ID of a package whose file name has none (LNPANDY/NX2Apple#1012). The library scan reads title IDs from file names
// (`Game [0100000000010000][v0].nsp`), so a renamed file was not a game of the library. The package names it too: each NCA
// header holds the program ID (0x210) and the content type (0x205), encrypted with header_key. The meta NCA (type 1) belongs to
// the content meta, so its program ID is the package's own title ID: the base game's (…000), its update's (…800) or an add-on's.
// The headers are read as the key check reads them (KeyCheck.readContainer, a few kilobytes per file) for NSP, NSZ, XCI and XCZ
// packages. Key values are never logged or shown.

enum PackageTitleID {
    static let supportedExtensions: Set<String> = ["nsp", "nsz", "xci", "xcz"]

    /// header_key of a keys file, nil when the file cannot be read or has no usable one.
    static func headerKey(keysFile: String) -> [UInt8]? {
        guard !keysFile.isEmpty, let data = FileManager.default.contents(atPath: keysFile),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              let key = KeyCheck.parseKeys(text)["header_key"], key.count == 32 else { return nil }
        return key
    }

    /// The program ID of a decrypted NCA header and whether it is the meta NCA. nil when it is not an NCA header.
    static func programID(header h: [UInt8]) -> (id: UInt64, meta: Bool)? {
        guard h.count >= 0x218, ["NCA3", "NCA2"].contains(String(bytes: h[0x200..<0x204], encoding: .ascii) ?? "") else { return nil }
        let id = (0..<8).reduce(UInt64(0)) { $0 | UInt64(h[0x210 + $1]) << (8 * UInt64($1)) }
        return id == 0 ? nil : (id, h[0x205] == 1)
    }

    /// The package's title ID from its NCA headers: the meta NCA's program ID. When a multi-content cartridge holds both a base
    /// game and an update or add-on meta NCA, the base game Title ID wins. nil when the package has no readable meta NCA or when
    /// the key does not open it.
    static func read(_ path: String, headerKey: [UInt8]) -> UInt64? {
        guard headerKey.count == 32, case let .pfs0(ncas) = KeyCheck.readContainer(path) else { return nil }
        var metaIDs: [UInt64] = []
        for nca in ncas {
            guard let plain = KeyCheck.xts(nca.header, key: headerKey, encrypt: false),
                  let found = programID(header: plain),
                  found.meta else { continue }
            metaIDs.append(found.id)
        }
        if let base = metaIDs.first(where: { $0 & 0x1FFF == 0 }) {
            return base
        }
        if let aligned = metaIDs.first(where: { $0 & 0xFFF == 0 }) {
            return aligned
        }
        return metaIDs.first
    }

    /// The title IDs of one scan: the file name's, else the package's own when there is a header_key. Each file is read at most once.
    final class Resolver {
        private let headerKey: [UInt8]?
        private var read: [String: UInt64?] = [:]

        init(headerKey: [UInt8]?) { self.headerKey = headerKey }

        func titleID(_ path: String) -> UInt64? {
            let name = (path as NSString).lastPathComponent
            if let id = TitleID.parse(name) { return id }
            let ext = (name as NSString).pathExtension.lowercased()
            guard let headerKey, PackageTitleID.supportedExtensions.contains(ext) else { return nil }
            if let known = read[path] { return known }
            let id = PackageTitleID.read(path, headerKey: headerKey)
            read[path] = id
            return id
        }
    }
}
