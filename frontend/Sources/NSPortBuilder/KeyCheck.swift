import SwiftUI
import CommonCrypto

// Checks prod.keys against the chosen game files before a build starts (issue #63). A build with keys
// that are too old for the game, or a header_key that does not open it, used to fail minutes in, in
// the extraction step, with LibHac's message in the log. The same answer is in the first kilobyte of
// each NCA: its header, encrypted with header_key, names the key generation the content needs.
//
// What is read: the PFS0 table of an NSP or NSZ and the first 0x400 bytes of each NCA (an NCZ keeps
// its NCA header as it was, uncompressed). An XCI's NCAs sit in nested HFS0 partitions behind a card
// header, so it is reported as not checkable here rather than guessed at. Key values are never
// printed, logged or shown: only key names appear in the messages.

enum KeyCheck {
    enum Part: String, Sendable { case base, update, dlc }

    enum Outcome: Equatable, Sendable {
        case fits
        case unreadableKeys
        case noHeaderKey
        /// header_key decrypts none of the file's NCA headers to an NCA magic.
        case wrongHeaderKey(file: String)
        /// The newest generation a file needs and a key of it the file lacks (its name, never its value).
        case tooOld(part: Part, generation: Int, missing: String)
        case cannotCheck(file: String)
    }

    /// What the check depends on: it runs again whenever one of these changes.
    struct Inputs: Hashable, Sendable {
        var keys: String
        var files: [String]   // base, update, then the add-on content; "" for an empty slot
    }

    /// The firmware that brought each master key revision (hactool's table), for telling someone what to dump the keys from.
    static let firmware = ["1.0.0", "3.0.0", "3.0.1", "4.0.0", "5.0.0", "6.0.0", "6.2.0", "7.0.0", "8.1.0", "9.0.0",
                           "9.1.0", "12.1.0", "13.0.0", "14.0.0", "15.0.0", "16.0.0", "17.0.0", "18.0.0", "19.0.0", "20.0.0"]

    // MARK: prod.keys

    /// `name = hex` lines, names lowercased; anything else (comments, blank lines, a value that is not hex) is skipped.
    static func parseKeys(_ text: String) -> [String: [UInt8]] {
        var keys: [String: [UInt8]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            if let value = hex(parts[1].trimmingCharacters(in: .whitespaces)), !name.isEmpty { keys[name] = value }
        }
        return keys
    }

    static func hex(_ s: String) -> [UInt8]? {
        let chars = Array(s.utf8)
        guard !chars.isEmpty, chars.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x41...0x46: return c - 0x41 + 10
        case 0x61...0x66: return c - 0x61 + 10
        default: return nil
        }
    }

    // MARK: AES-XTS

    /// AES-128-XTS over whole sectors, as Nintendo uses it for NCA headers: the 32-byte key is the data key then the
    /// tweak key, and the tweak is the sector number big-endian (IEEE 1619 has it little-endian). CommonCrypto has no
    /// XTS mode, so it is built on ECB: the blocks of a sector are independent once each is masked with its tweak.
    static func xts(_ data: [UInt8], key: [UInt8], sector: UInt64 = 0, sectorSize: Int = 0x200, encrypt: Bool) -> [UInt8]? {
        guard key.count == 32, sectorSize > 0, sectorSize % 16 == 0, data.count % sectorSize == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        for (i, start) in stride(from: 0, to: data.count, by: sectorSize).enumerated() {
            var tweak = [UInt8](repeating: 0, count: 16)
            var n = sector + UInt64(i)
            for b in (8..<16).reversed() { tweak[b] = UInt8(n & 0xFF); n >>= 8 }
            guard let s = xtsSector(Array(data[start..<start + sectorSize]), dataKey: Array(key[0..<16]), tweakKey: Array(key[16..<32]),
                                    tweak: tweak, encrypt: encrypt) else { return nil }
            out += s
        }
        return out
    }

    /// One sector with a given 16-byte tweak block (the tests feed it IEEE 1619's own vectors).
    static func xtsSector(_ data: [UInt8], dataKey: [UInt8], tweakKey: [UInt8], tweak: [UInt8], encrypt: Bool) -> [UInt8]? {
        guard data.count % 16 == 0, var t = ecb(tweak, key: tweakKey, encrypt: true) else { return nil }
        var masks: [UInt8] = []
        masks.reserveCapacity(data.count)
        for _ in 0..<(data.count / 16) {
            masks += t
            // multiply by x in GF(2^128), the bytes little-endian
            var carry: UInt8 = 0
            for j in 0..<16 { let c = t[j] >> 7; t[j] = t[j] << 1 | carry; carry = c }
            if carry != 0 { t[0] ^= 0x87 }
        }
        guard let y = ecb(zip(data, masks).map { $0 ^ $1 }, key: dataKey, encrypt: encrypt) else { return nil }
        return zip(y, masks).map { $0 ^ $1 }
    }

    private static func ecb(_ data: [UInt8], key: [UInt8], encrypt: Bool) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let status = CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                             key, key.count, nil, data, data.count, &out, out.count, &moved)
        return status == kCCSuccess && moved == data.count ? out : nil
    }

    // MARK: NCA headers

    /// The bytes of the header that matter here: the magic at 0x200, both key generation fields and the rights ID
    /// (0x200...0x23F, sector 1). Two sectors are decrypted because XTS needs whole ones.
    static let headerBytes = 0x400

    /// The key a decrypted NCA header needs, and its master key revision. nil when it is not an NCA header (wrong key).
    /// The revision is the larger of the two key generation fields (0x206 for the oldest firmware, 0x220 since 3.0.1),
    /// minus one when not zero, as LibHac (which the build's extractor uses) and hactool derive it. Content with a
    /// rights ID is opened through its ticket's title key, which titlekek_XX decrypts; content without one carries its
    /// keys in the key area, under key_area_key_<application|ocean|system>_XX (the index at 0x207).
    static func needs(header h: [UInt8]) -> (revision: Int, key: String)? {
        guard h.count >= headerBytes else { return nil }
        let magic = String(bytes: h[0x200..<0x204], encoding: .ascii) ?? ""
        guard ["NCA3", "NCA2"].contains(magic) else { return nil }
        let generation = Int(max(h[0x206], h[0x220]))
        let revision = generation == 0 ? 0 : generation - 1
        let suffix = String(format: "%02x", revision)
        if h[0x230..<0x240].contains(where: { $0 != 0 }) { return (revision, "titlekek_" + suffix) }
        let area = ["application", "ocean", "system"]
        guard Int(h[0x207]) < area.count else { return nil }
        return (revision, "key_area_key_\(area[Int(h[0x207])])_" + suffix)
    }

    /// A derived key counts when it is in the file or its master key is: LibHac derives titlekek and the key area
    /// keys from master_key_XX with the sources it carries, and some key dumps list only the master keys.
    static func has(_ key: String, in keys: [String: [UInt8]]) -> Bool {
        if keys[key]?.count == 16 { return true }
        guard let suffix = key.split(separator: "_").last else { return false }
        return keys["master_key_" + suffix]?.count == 16
    }

    enum Container {
        /// The encrypted headers of the package's NCAs, each with whether it is an NCZ (whose layout is taken on trust).
        case pfs0([(header: [UInt8], ncz: Bool)])
        case unsupported
    }

    /// The NCA headers of an NSP or NSZ (a PFS0); anything else, an XCI among them, is `unsupported`.
    static func readContainer(_ path: String) -> Container {
        guard let f = FileHandle(forReadingAtPath: path) else { return .unsupported }
        defer { try? f.close() }
        func read(_ offset: UInt64, _ count: Int) -> [UInt8]? {
            guard (try? f.seek(toOffset: offset)) != nil, let d = try? f.read(upToCount: count), d.count == count else { return nil }
            return [UInt8](d)
        }
        func u32(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 }
        func u64(_ b: [UInt8], _ o: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[o + $1]) << (8 * $1) } }
        guard let head = read(0, 0x10), head[0..<4].elementsEqual("PFS0".utf8) else { return .unsupported }
        let count = u32(head, 4), names = u32(head, 8)
        guard count > 0, count <= 4096, names <= 1 << 20, let table = read(0x10, count * 0x18 + names) else { return .unsupported }
        let dataStart = UInt64(0x10 + count * 0x18 + names)
        var headers: [(header: [UInt8], ncz: Bool)] = []
        for i in 0..<count {
            let e = i * 0x18
            let offset = u64(table, e), size = u64(table, e + 8), nameAt = count * 0x18 + u32(table, e + 0x10)
            guard nameAt < table.count else { continue }
            let name = String(decoding: table[nameAt...].prefix { $0 != 0 }, as: UTF8.self).lowercased()
            let ncz = name.hasSuffix(".ncz")
            guard name.hasSuffix(".nca") || ncz, size >= UInt64(headerBytes),
                  offset <= UInt64.max - dataStart, let h = read(dataStart + offset, headerBytes) else { continue }
            headers.append((h, ncz))
        }
        return .pfs0(headers)
    }

    // MARK: The check

    /// The check for the Builds page, off the main thread; nil (no line) until both the base game and prod.keys are chosen.
    static func runDetached(_ inputs: Inputs) async -> Outcome? {
        guard !inputs.keys.isEmpty, inputs.files.first.map({ !$0.isEmpty }) == true else { return nil }
        return await Task.detached(priority: .userInitiated) { run(inputs) }.value
    }

    /// Every chosen file against the keys; the worst finding wins (a key that opens nothing, then the newest missing
    /// generation, then a file that cannot be checked). Reads a few kilobytes per file, so it is quick, but it reads
    /// files: run it off the main thread.
    static func run(_ inputs: Inputs) -> Outcome {
        guard let data = FileManager.default.contents(atPath: inputs.keys),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return .unreadableKeys }
        let parts: [Part] = [.base, .update] + Array(repeating: .dlc, count: max(0, inputs.files.count - 2))
        let files = zip(parts, inputs.files).filter { !$0.1.isEmpty }.map { (part: $0.0, path: $0.1, container: readContainer($0.1)) }
        return check(keys: parseKeys(text), files: files.map { ($0.part, ($0.path as NSString).lastPathComponent, $0.container) })
    }

    static func check(keys: [String: [UInt8]], files: [(part: Part, name: String, container: Container)]) -> Outcome {
        guard let headerKey = keys["header_key"] else { return .noHeaderKey }
        var tooOld: (part: Part, revision: Int, key: String)?
        var unchecked: String?
        for file in files {
            guard case let .pfs0(ncas) = file.container, !ncas.isEmpty else { unchecked = unchecked ?? file.name; continue }
            // A damaged NCA among good ones is the file's problem, not the keys': only a key that opens none is wrong.
            let opened = ncas.compactMap { nca -> (revision: Int, key: String)? in
                guard headerKey.count == 32, let plain = xts(nca.header, key: headerKey, encrypt: false) else { return nil }
                return needs(header: plain)
            }
            if opened.isEmpty {
                // An NCZ's header is expected to be the NCA's own, still encrypted; if it is not, that is not the key's fault.
                if ncas.allSatisfy(\.ncz) { unchecked = unchecked ?? file.name; continue }
                return .wrongHeaderKey(file: file.name)
            }
            for need in opened where !has(need.key, in: keys) && need.revision > (tooOld?.revision ?? -1) {
                tooOld = (file.part, need.revision, need.key)
            }
        }
        if let tooOld { return .tooOld(part: tooOld.part, generation: tooOld.revision + 1, missing: tooOld.key) }
        if let unchecked { return .cannotCheck(file: unchecked) }
        return .fits
    }

    /// The line under the prod.keys row.
    static func message(_ o: Outcome, _ t: (String) -> String) -> String {
        switch o {
        case .fits: return t("keycheck.fits")
        case .unreadableKeys: return t("keycheck.unreadable")
        case .noHeaderKey: return t("keycheck.noHeaderKey")
        case .wrongHeaderKey(let file): return String(format: t("keycheck.wrongHeaderKey"), file)
        case .cannotCheck(let file): return String(format: t("keycheck.cannotCheck"), file)
        case let .tooOld(part, generation, missing):
            var s = String(format: t("keycheck.tooOld"), t("keycheck.part." + part.rawValue), missing)   // the key's name carries the generation, in hex
            if generation - 1 < firmware.count { s += " " + String(format: t("keycheck.firmware"), firmware[generation - 1]) }
            return s
        }
    }
}

/// The key check's result, set in under the prod.keys row it is about.
struct KeyCheckLine: View {
    let outcome: KeyCheck.Outcome
    let t: (String) -> String

    var body: some View {
        let (symbol, color): (String, Color) = {
            switch outcome {
            case .fits: return ("checkmark.circle.fill", LauncherPalette.ready)
            case .cannotCheck: return ("questionmark.circle", .secondary)
            default: return ("exclamationmark.triangle.fill", LauncherPalette.building)
            }
        }()
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            Text(KeyCheck.message(outcome, t)).font(.manrope(12.5)).foregroundStyle(outcome == .fits ? Color.secondary : color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        // under the row's title: past its padding and its dot's place
        .padding(.leading, 37).padding(.trailing, 18).padding(.top, -6).padding(.bottom, 13)
    }
}
