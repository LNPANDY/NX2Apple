import Foundation

// Read-only cartridge header and HFS0 reader for renamed .xci and .xcz files without a Title ID in the file name.
// Mirrors engine/scripts/build_ipa_from_nsp.py: card header magic "HEAD" at +0x100 (at file offset 0 for trimmed
// images or 0x1000 when the initial key area is prepended), root HFS0 offset at +0x130, "secure" HFS0 entry inside
// the root partition, then the first 0x400 encrypted header bytes of each .nca or .ncz entry.

extension PackageTitleID {
    private static let maxHFS0Entries = 4096
    private static let maxHFS0StringBytes = 1_048_576
    private static let hfs0HeaderBytes = 0x10
    private static let hfs0EntryBytes = 0x40

    struct HFS0Entry {
        let name: String
        let offset: UInt64
        let size: UInt64
    }

    static func checkedAdd(_ a: UInt64, _ b: UInt64) -> UInt64? {
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
        for index in 0..<8 {
            value |= UInt64(bytes[offset + index]) << (8 * UInt64(index))
        }
        return value
    }

    /// Reads the encrypted 0x400-byte NCA headers from the secure HFS0 partition of an XCI or XCZ cartridge image.
    /// Returns nil when the file is missing, truncated, malformed, or carries no readable NCA headers in secure/.
    static func readXCIContainer(_ path: String) -> [(header: [UInt8], ncz: Bool)]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        let fileSize: UInt64
        do {
            fileSize = try handle.seekToEnd()
        } catch {
            return nil
        }

        func readBytes(at offset: UInt64, count: Int) -> [UInt8]? {
            guard count >= 0, offset <= fileSize, UInt64(count) <= fileSize - offset else { return nil }
            do {
                try handle.seek(toOffset: offset)
                guard let data = try handle.read(upToCount: count), data.count == count else { return nil }
                return [UInt8](data)
            } catch {
                return nil
            }
        }

        func readHFS0(at partitionOffset: UInt64, limitEnd: UInt64) -> [HFS0Entry]? {
            guard limitEnd <= fileSize,
                  partitionOffset <= limitEnd,
                  UInt64(hfs0HeaderBytes) <= limitEnd - partitionOffset,
                  let head = readBytes(at: partitionOffset, count: hfs0HeaderBytes),
                  head[0..<4].elementsEqual("HFS0".utf8) else { return nil }

            let entryCount = Int(le32(head, 4))
            let stringTableBytes = Int(le32(head, 8))
            guard entryCount > 0,
                  entryCount <= maxHFS0Entries,
                  stringTableBytes > 0,
                  stringTableBytes <= maxHFS0StringBytes else { return nil }

            let entriesBytes = entryCount * hfs0EntryBytes
            let tableBytes = entriesBytes + stringTableBytes
            guard let tableOffset = checkedAdd(partitionOffset, UInt64(hfs0HeaderBytes)),
                  let dataStart = checkedAdd(tableOffset, UInt64(tableBytes)),
                  dataStart <= limitEnd,
                  let table = readBytes(at: tableOffset, count: tableBytes) else { return nil }

            var entries: [HFS0Entry] = []
            entries.reserveCapacity(entryCount)
            for index in 0..<entryCount {
                let row = index * hfs0EntryBytes
                let relOffset = le64(table, row)
                let size = le64(table, row + 0x08)
                let nameOffset = Int(le32(table, row + 0x10))
                guard nameOffset >= 0, nameOffset < stringTableBytes else { continue }
                guard let absOffset = checkedAdd(dataStart, relOffset), absOffset <= limitEnd else { continue }
                let strStart = entriesBytes + nameOffset
                let rawName = table[strStart..<tableBytes].prefix { $0 != 0 }
                let name = String(decoding: rawName, as: UTF8.self).lowercased()
                guard !name.isEmpty else { continue }
                entries.append(HFS0Entry(name: name, offset: absOffset, size: size))
            }
            return entries
        }

        for cardBase: UInt64 in [0, 0x1000] {
            guard let card = readBytes(at: cardBase, count: 0x140),
                  card[0x100..<0x104].elementsEqual("HEAD".utf8) else { continue }
            let rawRootOffset = le64(card, 0x130)
            var rootCandidates: [UInt64] = []
            if let relRoot = checkedAdd(cardBase, rawRootOffset) {
                rootCandidates.append(relRoot)
            }
            if cardBase > 0, rawRootOffset >= cardBase + 0x140, !rootCandidates.contains(rawRootOffset) {
                rootCandidates.append(rawRootOffset)
            }

            for rootOffset in rootCandidates {
                guard let rootEntries = readHFS0(at: rootOffset, limitEnd: fileSize),
                      let secure = rootEntries.first(where: { $0.name == "secure" }),
                      secure.size >= UInt64(hfs0HeaderBytes),
                      let secureEnd = checkedAdd(secure.offset, secure.size) else { continue }
                let secureLimit = min(fileSize, secureEnd)
                guard let secureEntries = readHFS0(at: secure.offset, limitEnd: secureLimit) else { continue }

                var headers: [(header: [UInt8], ncz: Bool)] = []
                for entry in secureEntries {
                    let isNCZ = entry.name.hasSuffix(".ncz")
                    guard entry.name.hasSuffix(".nca") || isNCZ,
                          entry.size >= UInt64(KeyCheck.headerBytes),
                          entry.offset <= secureLimit,
                          UInt64(KeyCheck.headerBytes) <= secureLimit - entry.offset,
                          let header = readBytes(at: entry.offset, count: KeyCheck.headerBytes) else { continue }
                    headers.append((header: header, ncz: isNCZ))
                }
                if !headers.isEmpty {
                    return headers
                }
            }
        }
        return nil
    }

    /// True when the package file has a readable container with at least one NCA or NCZ header.
    static func hasReadableContainer(_ path: String) -> Bool {
        if case let .pfs0(ncas) = KeyCheck.readContainer(path) {
            return !ncas.isEmpty
        }
        return false
    }
}
