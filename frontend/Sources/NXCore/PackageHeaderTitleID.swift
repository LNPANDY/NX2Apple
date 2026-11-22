import Foundation
import CommonCrypto

/// Read-only NSP/NSZ/XCI/XCZ header title ID reader usable from `NXCore` and `NXModel` without importing app targets.
/// Reads only the container table and encrypted 0x400-byte NCA headers, decrypting with `header_key` from `prod.keys`
/// using AES-128-XTS to extract the meta NCA's program ID. Key values are never logged or returned.
package enum PackageHeaderTitleID {
    package static let supportedExtensions: Set<String> = ["nsp", "nsz", "xci", "xcz"]

    private static let headerBytes = 0x400
    private static let maxEntries = 4096
    private static let maxStringBytes = 1_048_576
    private static let hfs0HeaderBytes = 0x10
    private static let hfs0EntryBytes = 0x40

    package static func readHex16(path: String, keysPath: String) -> String? {
        guard let tid = read(path: path, keysPath: keysPath) else { return nil }
        return String(format: "%016llX", tid)
    }

    package static func read(path: String, keysPath: String) -> UInt64? {
        let ext = (path as NSString).pathExtension.lowercased()
        guard supportedExtensions.contains(ext),
              let headerKey = loadHeaderKey(keysPath: keysPath) else {
            return nil
        }
        return read(path: path, headerKey: headerKey)
    }

    package static func read(path: String, headerKey: [UInt8]) -> UInt64? {
        guard headerKey.count == 32 else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        let headers: [[UInt8]]
        if ext == "xci" || ext == "xcz" {
            guard let xci = readXCIHeaders(path), !xci.isEmpty else { return nil }
            headers = xci
        } else if ext == "nsp" || ext == "nsz" {
            guard let pfs = readPFS0Headers(path), !pfs.isEmpty else { return nil }
            headers = pfs
        } else {
            return nil
        }

        var metaIDs: [UInt64] = []
        for enc in headers {
            guard let plain = aesXTS(enc, key: headerKey, encrypt: false),
                  let found = programID(header: plain),
                  found.meta else { continue }
            metaIDs.append(found.id)
        }
        if let base = metaIDs.first(where: { $0 & 0x1FFF == 0 }) { return base }
        if let aligned = metaIDs.first(where: { $0 & 0xFFF == 0 }) { return aligned }
        return metaIDs.first
    }

    package static func loadHeaderKey(keysPath: String) -> [UInt8]? {
        guard !keysPath.isEmpty,
              let data = FileManager.default.contents(atPath: keysPath),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            guard name == "header_key" else { continue }
            if let value = decodeHex(parts[1].trimmingCharacters(in: .whitespaces)), value.count == 32 {
                return value
            }
        }
        return nil
    }

    package static func programID(header h: [UInt8]) -> (id: UInt64, meta: Bool)? {
        guard h.count >= 0x218 else { return nil }
        let magic = String(bytes: h[0x200..<0x204], encoding: .ascii) ?? ""
        guard magic == "NCA3" || magic == "NCA2" else { return nil }
        var id: UInt64 = 0
        for i in 0..<8 {
            id |= UInt64(h[0x210 + i]) << (8 * UInt64(i))
        }
        return id == 0 ? nil : (id, h[0x205] == 1)
    }

    package static func aesXTS(_ data: [UInt8], key: [UInt8], sector: UInt64 = 0, sectorSize: Int = 0x200, encrypt: Bool) -> [UInt8]? {
        guard key.count == 32, sectorSize > 0, sectorSize % 16 == 0, data.count % sectorSize == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        let dataKey = Array(key[0..<16])
        let tweakKey = Array(key[16..<32])
        for (i, start) in stride(from: 0, to: data.count, by: sectorSize).enumerated() {
            var tweak = [UInt8](repeating: 0, count: 16)
            var n = sector + UInt64(i)
            for b in (8..<16).reversed() {
                tweak[b] = UInt8(n & 0xFF)
                n >>= 8
            }
            guard let block = xtsSector(Array(data[start..<(start + sectorSize)]),
                                        dataKey: dataKey, tweakKey: tweakKey, tweak: tweak, encrypt: encrypt) else {
                return nil
            }
            out += block
        }
        return out
    }

    private static func xtsSector(_ data: [UInt8], dataKey: [UInt8], tweakKey: [UInt8], tweak: [UInt8], encrypt: Bool) -> [UInt8]? {
        guard data.count % 16 == 0, var t = aesECB(tweak, key: tweakKey, encrypt: true) else { return nil }
        var masks: [UInt8] = []
        masks.reserveCapacity(data.count)
        for _ in 0..<(data.count / 16) {
            masks += t
            var carry: UInt8 = 0
            for j in 0..<16 {
                let c = t[j] >> 7
                t[j] = (t[j] << 1) | carry
                carry = c
            }
            if carry != 0 { t[0] ^= 0x87 }
        }
        guard let y = aesECB(zip(data, masks).map(^), key: dataKey, encrypt: encrypt) else { return nil }
        return zip(y, masks).map(^)
    }

    private static func aesECB(_ data: [UInt8], key: [UInt8], encrypt: Bool) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let status = CCCrypt(
            CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionECBMode),
            key, key.count,
            nil,
            data, data.count,
            &out, out.count,
            &moved
        )
        return status == kCCSuccess && moved == data.count ? out : nil
    }

    private static func checkedAdd(_ a: UInt64, _ b: UInt64) -> UInt64? {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? nil : sum
    }

    private static func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset >= 0, offset <= bytes.count - 4 else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func le64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        guard offset >= 0, offset <= bytes.count - 8 else { return 0 }
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(bytes[offset + i]) << (8 * UInt64(i))
        }
        return value
    }

    private static func readBytes(_ handle: FileHandle, fileSize: UInt64, at offset: UInt64, count: Int) -> [UInt8]? {
        guard count >= 0, offset <= fileSize, UInt64(count) <= fileSize - offset else { return nil }
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: count), data.count == count else { return nil }
            return [UInt8](data)
        } catch {
            return nil
        }
    }

    private static func readPFS0Headers(_ path: String) -> [[UInt8]]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd() else { return nil }
        guard let head = readBytes(handle, fileSize: fileSize, at: 0, count: 0x10),
              head[0..<4].elementsEqual("PFS0".utf8) else { return nil }
        let count = Int(le32(head, 4))
        let stringBytes = Int(le32(head, 8))
        guard count > 0, count <= maxEntries, stringBytes <= maxStringBytes else { return nil }
        let entriesBytes = count * 0x18
        let tableBytes = entriesBytes + stringBytes
        guard let table = readBytes(handle, fileSize: fileSize, at: 0x10, count: tableBytes),
              let dataStart = checkedAdd(0x10, UInt64(tableBytes)),
              dataStart <= fileSize else { return nil }

        var headers: [[UInt8]] = []
        for i in 0..<count {
            let row = i * 0x18
            let relOffset = le64(table, row)
            let size = le64(table, row + 8)
            let nameOffset = Int(le32(table, row + 0x10))
            guard nameOffset >= 0, nameOffset < stringBytes else { continue }
            let strStart = entriesBytes + nameOffset
            let name = String(decoding: table[strStart..<tableBytes].prefix { $0 != 0 }, as: UTF8.self).lowercased()
            guard name.hasSuffix(".nca") || name.hasSuffix(".ncz"),
                  size >= UInt64(headerBytes),
                  let ncaOffset = checkedAdd(dataStart, relOffset),
                  let header = readBytes(handle, fileSize: fileSize, at: ncaOffset, count: headerBytes) else { continue }
            headers.append(header)
        }
        return headers
    }

    private static func readXCIHeaders(_ path: String) -> [[UInt8]]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd() else { return nil }

        func readHFS0(at offset: UInt64, limitEnd: UInt64) -> [(name: String, offset: UInt64, size: UInt64)]? {
            guard limitEnd <= fileSize,
                  offset <= limitEnd,
                  UInt64(hfs0HeaderBytes) <= limitEnd - offset,
                  let head = readBytes(handle, fileSize: fileSize, at: offset, count: hfs0HeaderBytes),
                  head[0..<4].elementsEqual("HFS0".utf8) else { return nil }
            let count = Int(le32(head, 4))
            let stringBytes = Int(le32(head, 8))
            guard count > 0, count <= maxEntries, stringBytes > 0, stringBytes <= maxStringBytes else { return nil }
            let entriesBytes = count * hfs0EntryBytes
            let tableBytes = entriesBytes + stringBytes
            guard let tableOffset = checkedAdd(offset, UInt64(hfs0HeaderBytes)),
                  let dataStart = checkedAdd(tableOffset, UInt64(tableBytes)),
                  dataStart <= limitEnd,
                  let table = readBytes(handle, fileSize: fileSize, at: tableOffset, count: tableBytes) else { return nil }
            var entries: [(name: String, offset: UInt64, size: UInt64)] = []
            entries.reserveCapacity(count)
            for i in 0..<count {
                let row = i * hfs0EntryBytes
                let relOffset = le64(table, row)
                let size = le64(table, row + 8)
                let nameOffset = Int(le32(table, row + 0x10))
                guard nameOffset >= 0, nameOffset < stringBytes,
                      let absOffset = checkedAdd(dataStart, relOffset), absOffset <= limitEnd else { continue }
                let strStart = entriesBytes + nameOffset
                let name = String(decoding: table[strStart..<tableBytes].prefix { $0 != 0 }, as: UTF8.self).lowercased()
                guard !name.isEmpty else { continue }
                entries.append((name, absOffset, size))
            }
            return entries
        }

        for cardBase: UInt64 in [0, 0x1000] {
            guard let card = readBytes(handle, fileSize: fileSize, at: cardBase, count: 0x140),
                  card[0x100..<0x104].elementsEqual("HEAD".utf8) else { continue }
            let rawRoot = le64(card, 0x130)
            var roots: [UInt64] = []
            if let rel = checkedAdd(cardBase, rawRoot) { roots.append(rel) }
            if cardBase > 0, rawRoot >= cardBase + 0x140, !roots.contains(rawRoot) { roots.append(rawRoot) }
            for rootOffset in roots {
                guard let rootEntries = readHFS0(at: rootOffset, limitEnd: fileSize),
                      let secure = rootEntries.first(where: { $0.name == "secure" }),
                      secure.size >= UInt64(hfs0HeaderBytes),
                      let secureEnd = checkedAdd(secure.offset, secure.size) else { continue }
                let secureLimit = min(fileSize, secureEnd)
                guard let secureEntries = readHFS0(at: secure.offset, limitEnd: secureLimit) else { continue }
                var headers: [[UInt8]] = []
                for entry in secureEntries {
                    guard entry.name.hasSuffix(".nca") || entry.name.hasSuffix(".ncz"),
                          entry.size >= UInt64(headerBytes),
                          entry.offset <= secureLimit,
                          UInt64(headerBytes) <= secureLimit - entry.offset,
                          let header = readBytes(handle, fileSize: fileSize, at: entry.offset, count: headerBytes) else { continue }
                    headers.append(header)
                }
                if !headers.isEmpty { return headers }
            }
        }
        return nil
    }

    private static func decodeHex(_ s: String) -> [UInt8]? {
        let chars = Array(s.utf8)
        guard !chars.isEmpty, chars.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let hi = hexNibble(chars[i]), let lo = hexNibble(chars[i + 1]) else { return nil }
            out.append((hi << 4) | lo)
        }
        return out
    }

    private static func hexNibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x41...0x46: return c - 0x41 + 10
        case 0x61...0x66: return c - 0x61 + 10
        default: return nil
        }
    }
}
