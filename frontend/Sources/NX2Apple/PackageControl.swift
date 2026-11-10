import Foundation

// The base game's control data (`control.nacp`) read straight from its package with the player's keys, for the names of a game
// whose app was packed before `DMTitleNames` (LNPANDY/NX2Apple#895). The engine's nx_extract writes the control data only as part
// of a full extraction, and it is a prebuilt binary whose sources the engine pins, so the launcher reads it itself, as
// `PackageTitleID` reads the NCA headers: the package's file table (an NSP or NSZ is a PFS0, an XCI or XCZ keeps its NCAs in the
// secure HFS0 partition), the Control NCA's header (header_key), its key (a common ticket's title key under titlekek_XX, else the
// key area under key_area_key_<area>_XX), then its RomFS (AES-CTR), whose root holds control.nacp. Only a few kilobytes are read.
// nsz leaves the Control NCA uncompressed. Key values are never logged or shown.

enum PackageControl {
    /// The control data of the package's Control NCA for `titleID` (any Control NCA when nil or when none has that ID), nil when the
    /// package cannot be read, has no control data or the keys do not open it.
    static func read(package path: String, keysFile: String, titleID: UInt64?) -> Data? {
        guard let data = FileManager.default.contents(atPath: keysFile),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        return read(package: path, keys: KeyCheck.parseKeys(text), titleID: titleID)
    }

    static func read(package path: String, keys: [String: [UInt8]], titleID: UInt64?) -> Data? {
        guard let headerKey = keys["header_key"], headerKey.count == 32, let file = Reader(path) else { return nil }
        let entries = file.entries()
        var controls: [(entry: Entry, header: [UInt8], id: UInt64)] = []
        for entry in entries where entry.name.hasSuffix(".nca") && entry.size >= 0xC00 {
            guard let header = ncaHeader(file, at: entry.offset, key: headerKey), header[0x205] == 2 else { continue }   // 2: Control
            controls.append((entry, header, le(header, 0x210, 8)))
        }
        let wanted = controls.filter { $0.id == titleID }
        for control in (wanted.isEmpty ? controls : wanted) {
            guard let key = sectionKey(header: control.header, keys: keys, tickets: entries.filter { $0.name.hasSuffix(".tik") }, file: file),
                  let nacp = controlNACP(file, nca: control.entry.offset, header: control.header, key: key) else { continue }
            return nacp
        }
        return nil
    }

    // MARK: Package

    struct Entry { let name: String; let offset: UInt64; let size: UInt64 }

    final class Reader {
        private let handle: FileHandle
        init?(_ path: String) {
            guard let h = FileHandle(forReadingAtPath: path) else { return nil }
            handle = h
        }
        deinit { try? handle.close() }

        func read(_ offset: UInt64, _ count: Int) -> [UInt8]? {
            guard count >= 0, (try? handle.seek(toOffset: offset)) != nil, let d = try? handle.read(upToCount: count), d.count == count else { return nil }
            return [UInt8](d)
        }

        /// The files of a PFS0 (NSP, NSZ), else of the secure partition of a cartridge image (XCI, XCZ; with or without the 0x1000
        /// bytes of key area some dumps keep in front), with offsets from the start of the file.
        func entries() -> [Entry] {
            if let pfs0 = partition(at: 0, magic: "PFS0", entrySize: 0x18) { return pfs0 }
            for base: UInt64 in [0, 0x1000] {
                guard let card = read(base, 0x140), card[0x100..<0x104].elementsEqual("HEAD".utf8),
                      let rootAt = PackageControl.add(base, PackageControl.le(card, 0x130, 8)),
                      let root = partition(at: rootAt, magic: "HFS0", entrySize: 0x40),
                      let secure = root.first(where: { $0.name == "secure" }) else { continue }
                return partition(at: secure.offset, magic: "HFS0", entrySize: 0x40) ?? []
            }
            return []
        }

        /// A PFS0 or HFS0 file table at `at`: count (0x4), size of the names (0x8), then the entries (offset 0x0, size 0x8, name 0x10).
        private func partition(at: UInt64, magic: String, entrySize: Int) -> [Entry]? {
            guard let head = read(at, 0x10), head[0..<4].elementsEqual(magic.utf8),
                  let tableAt = PackageControl.add(at, 0x10) else { return nil }
            let count = Int(PackageControl.le(head, 4, 4)), names = Int(PackageControl.le(head, 8, 4))
            guard count > 0, count <= 4096, names <= 1 << 20 else { return nil }
            let tableSize = count * entrySize + names
            guard let data = PackageControl.add(tableAt, UInt64(tableSize)),
                  let table = read(tableAt, tableSize) else { return nil }
            return (0..<count).compactMap { i in
                let e = i * entrySize, nameAt = count * entrySize + Int(PackageControl.le(table, e + 0x10, 4))
                guard nameAt < table.count, let offset = PackageControl.add(data, PackageControl.le(table, e, 8)) else { return nil }
                let name = String(decoding: table[nameAt...].prefix { $0 != 0 }, as: UTF8.self).lowercased()
                return Entry(name: name, offset: offset, size: PackageControl.le(table, e + 8, 8))
            }
        }
    }

    // MARK: NCA

    /// The decrypted NCA header with its four section headers (0xC00 bytes). An NCA3 runs XTS over all six sectors in order, an NCA2
    /// encrypts each section header as sector 0.
    static func ncaHeader(_ file: Reader, at offset: UInt64, key: [UInt8]) -> [UInt8]? {
        guard let raw = file.read(offset, 0xC00), let head = KeyCheck.xts(Array(raw[0..<0x400]), key: key, encrypt: false) else { return nil }
        switch String(bytes: head[0x200..<0x204], encoding: .ascii) {
        case "NCA3": return KeyCheck.xts(raw, key: key, encrypt: false)
        case "NCA2":
            var out = head
            for s in 0..<4 {
                guard let section = KeyCheck.xts(Array(raw[(0x400 + s * 0x200)..<(0x600 + s * 0x200)]), key: key, encrypt: false) else { return nil }
                out += section
            }
            return out
        default: return nil
        }
    }

    /// The AES-CTR key of the NCA's sections: the title key of its common ticket when it has a rights ID, else the key area's
    /// third key. The derived keys come from the file, or from master_key_XX and the sources when the file lists only those.
    static func sectionKey(header h: [UInt8], keys: [String: [UInt8]], tickets: [Entry], file: Reader) -> [UInt8]? {
        guard let need = KeyCheck.needs(header: h) else { return nil }
        let suffix = String(format: "%02x", need.revision)
        let rightsID = Array(h[0x230..<0x240])
        if rightsID.contains(where: { $0 != 0 }) {
            guard let titlekek = keys["titlekek_" + suffix] ?? derived(keys, suffix: suffix, source: "titlekek_source", kek: false),
                  let encrypted = tickets.lazy.compactMap({ titleKey(file, $0, rightsID: rightsID) }).first else { return nil }
            return KeyCheck.ecb(encrypted, key: titlekek, encrypt: false)
        }
        let area = ["application", "ocean", "system"][Int(h[0x207])]   // needs() has checked the index
        guard let kaek = keys[need.key] ?? derived(keys, suffix: suffix, source: "key_area_key_\(area)_source", kek: true),
              let plain = KeyCheck.ecb(Array(h[0x300..<0x340]), key: kaek, encrypt: false) else { return nil }
        return Array(plain[0x20..<0x30])
    }

    /// titlekek_XX (AES-ECB of its source under master_key_XX) or key_area_key_<area>_XX (the source under the kek that
    /// aes_kek_generation_source gives, then aes_key_generation_source under that), as LibHac and hactool derive them.
    private static func derived(_ keys: [String: [UInt8]], suffix: String, source: String, kek: Bool) -> [UInt8]? {
        guard let master = keys["master_key_" + suffix], master.count == 16, let src = keys[source], src.count == 16 else { return nil }
        guard kek else { return KeyCheck.ecb(src, key: master, encrypt: false) }
        guard let kekSource = keys["aes_kek_generation_source"], kekSource.count == 16,
              let keySource = keys["aes_key_generation_source"], keySource.count == 16,
              let k = KeyCheck.ecb(kekSource, key: master, encrypt: false), let sourceKek = KeyCheck.ecb(src, key: k, encrypt: false) else { return nil }
        return KeyCheck.ecb(keySource, key: sourceKek, encrypt: false)
    }

    /// The encrypted title key of a common ticket for this rights ID, nil for another rights ID or a personalized ticket.
    static func titleKey(_ file: Reader, _ ticket: Entry, rightsID: [UInt8]) -> [UInt8]? {
        guard let t = file.read(ticket.offset, Int(min(ticket.size, 0x700))), t.count >= 0x4 else { return nil }
        let signature: [UInt64: Int] = [0x10000: 0x23C, 0x10001: 0x13C, 0x10002: 0x7C, 0x10003: 0x23C, 0x10004: 0x13C, 0x10005: 0x7C]   // size + padding
        guard let sig = signature[le(t, 0, 4)] else { return nil }
        let data = 4 + sig
        // title key type at 0x141 (0: common), rights ID at 0x160
        guard t.count >= data + 0x170, t[data + 0x141] == 0, Array(t[(data + 0x160)..<(data + 0x170)]) == rightsID else { return nil }
        return Array(t[(data + 0x40)..<(data + 0x50)])
    }

    /// control.nacp from the root of section 0's RomFS (IVFC level 6), decrypted with `key` when the section is AES-CTR.
    static func controlNACP(_ file: Reader, nca: UInt64, header h: [UInt8], key: [UInt8]) -> Data? {
        let fs = 0x400
        guard let start = add(nca, le(h, 0x240, 4) * 0x200), let end = add(nca, le(h, 0x244, 4) * 0x200),
              end > start, h[fs + 2] == 0, h[fs + 3] == 3, [1, 3].contains(h[fs + 4]),   // RomFS, hierarchical integrity, no crypto or CTR
              h[(fs + 8)..<(fs + 12)].elementsEqual("IVFC".utf8),
              let romfsBase = add(start, le(h, fs + 0x18 + 5 * 0x18, 8)), romfsBase <= end else { return nil }
        let counter = Array(h[(fs + 0x140)..<(fs + 0x148)].reversed())
        func read(_ offset: UInt64, _ count: Int) -> [UInt8]? {
            guard count > 0, count <= 1 << 20,
                  let at = add(romfsBase, offset), let reqEnd = add(at, UInt64(count)), reqEnd <= end else { return nil }
            let aligned = nca + ((at - nca) & ~0xF), skip = Int(at - aligned), total = (skip + count + 15) & ~15   // CTR blocks start at the NCA's
            guard let raw = file.read(aligned, total) else { return nil }
            if h[fs + 4] == 1 { return Array(raw[skip..<(skip + count)]) }
            var blocks: [UInt8] = []
            blocks.reserveCapacity(total)
            for i in 0..<UInt64(total / 16) { blocks += counter + be(((aligned - nca) >> 4) + i) }   // the offset in the NCA
            guard let stream = KeyCheck.ecb(blocks, key: key, encrypt: true) else { return nil }
            return Array(zip(raw, stream).map { $0 ^ $1 }[skip..<(skip + count)])
        }
        guard let head = read(0, 0x50), le(head, 0, 8) == 0x50 else { return nil }
        let dirMeta = le(head, 0x18, 8), fileMeta = le(head, 0x38, 8), fileMetaSize = le(head, 0x40, 8), data = le(head, 0x48, 8)
        guard fileMetaSize > 0, fileMetaSize <= 1 << 20, let root = read(dirMeta, 0x18), let files = read(fileMeta, Int(fileMetaSize)) else { return nil }
        var next = le(root, 0xC, 4)   // the root's first file, then each file's sibling
        var seen = 0
        while next != 0xFFFF_FFFF, seen < 4096 {
            seen += 1
            let e = Int(next)
            guard files.count >= 0x20, e <= files.count - 0x20 else { return nil }
            let length = Int(le(files, e + 0x1C, 4))
            guard length <= files.count - 0x20 - e else { return nil }
            if String(decoding: files[(e + 0x20)..<(e + 0x20 + length)], as: UTF8.self) == "control.nacp" {
                let size = le(files, e + 0x10, 8)
                guard size > 0, size <= 0x10000, let nacpOffset = add(data, le(files, e + 8, 8)),
                      let nacp = read(nacpOffset, Int(size)) else { return nil }
                return Data(nacp)
            }
            next = le(files, e + 4, 4)
        }
        return nil
    }

    // MARK: Bytes

    static func add(_ a: UInt64, _ b: UInt64) -> UInt64? {
        let (r, o) = a.addingReportingOverflow(b)
        return o ? nil : r
    }

    static func le(_ b: [UInt8], _ o: Int, _ n: Int) -> UInt64 {
        guard o >= 0, o + n <= b.count else { return 0 }
        return (0..<n).reduce(UInt64(0)) { $0 | UInt64(b[o + $1]) << (8 * UInt64($1)) }
    }

    static func be(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(v >> (8 * UInt64(7 - $0)) & 0xFF) } }
}
