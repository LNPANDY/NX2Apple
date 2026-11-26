import Compression
import Darwin
import Foundation

/// Pure-Swift ZIP Central Directory preflight, bounded streaming extractor, and standard ZIP writer for iOS saves.
/// Pre-validates every entry path, symlink attribute, and quota before extracting any payload bytes.
enum SaveZipCodec {
    static let maxEntries = 10_000
    static let maxTotalBytes: UInt64 = 512 * 1024 * 1024
    private static let maxCentralDirectoryBytes = 16 * 1024 * 1024
    private static let chunkBytes = 1 << 16

    struct CentralEntry: Equatable, Sendable {
        let rawName: String
        let method: UInt16
        let crc32: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
        let isDirectory: Bool
        let isSymlink: Bool
        let modDate: UInt16
        let modTime: UInt16
    }

    struct WriteItem {
        let archivePath: String
        let fileURL: URL?
        let data: Data?
        let modDate: Date
    }

    // MARK: - Central Directory Preflight

    static func parseCentralDirectory(handle: FileHandle) throws -> [CentralEntry] {
        let fileSize = try handle.seekToEnd()
        guard fileSize >= 22 else {
            throw SaveArchiveFailure.invalidArchive("File is too small to be a ZIP archive.")
        }

        let tailCount = Int(min(fileSize, 65_557))
        let tailOffset = fileSize - UInt64(tailCount)
        try handle.seek(toOffset: tailOffset)
        guard let tailData = try handle.read(upToCount: tailCount), tailData.count == tailCount else {
            throw SaveArchiveFailure.invalidArchive("Unable to read ZIP footer.")
        }

        var eocdPos: Int?
        if tailCount >= 22 {
            var idx = tailCount - 22
            while idx >= 0 {
                if readLE32(tailData, at: idx) == 0x0605_4b50 {
                    let commentLen = Int(readLE16(tailData, at: idx + 20))
                    if idx + 22 + commentLen == tailCount {
                        eocdPos = idx
                        break
                    }
                }
                if idx == 0 { break }
                idx -= 1
            }
        }
        guard let eocdIdx = eocdPos else {
            throw SaveArchiveFailure.invalidArchive("Missing ZIP End of Central Directory.")
        }

        let disk = readLE16(tailData, at: eocdIdx + 4)
        let cdDisk = readLE16(tailData, at: eocdIdx + 6)
        let entriesOnDisk = readLE16(tailData, at: eocdIdx + 8)
        let totalEntries16 = readLE16(tailData, at: eocdIdx + 10)
        let cdSize32 = readLE32(tailData, at: eocdIdx + 12)
        let cdOffset32 = readLE32(tailData, at: eocdIdx + 16)

        guard disk == 0 && cdDisk == 0 && entriesOnDisk == totalEntries16 else {
            throw SaveArchiveFailure.invalidArchive("Multi-disk ZIP archives are not supported.")
        }
        guard totalEntries16 != 0xFFFF && cdSize32 != 0xFFFF_FFFF && cdOffset32 != 0xFFFF_FFFF else {
            throw SaveArchiveFailure.quotaExceeded
        }

        let totalEntries = Int(totalEntries16)
        guard totalEntries <= maxEntries else { throw SaveArchiveFailure.quotaExceeded }

        let cdSize = Int(cdSize32)
        let cdOffset = UInt64(cdOffset32)
        let eocdAbsOffset = tailOffset + UInt64(eocdIdx)
        guard cdSize <= maxCentralDirectoryBytes, cdOffset + UInt64(cdSize) <= eocdAbsOffset else {
            throw SaveArchiveFailure.invalidArchive("Invalid ZIP Central Directory bounds.")
        }

        try handle.seek(toOffset: cdOffset)
        guard let cdData = try handle.read(upToCount: cdSize), cdData.count == cdSize else {
            throw SaveArchiveFailure.invalidArchive("Truncated ZIP Central Directory.")
        }

        var entries: [CentralEntry] = []
        entries.reserveCapacity(totalEntries)
        var cursor = 0
        var declaredPayloadBytes: UInt64 = 0

        for _ in 0..<totalEntries {
            guard cursor + 46 <= cdSize, readLE32(cdData, at: cursor) == 0x0201_4b50 else {
                throw SaveArchiveFailure.invalidArchive("Corrupt Central Directory header.")
            }
            let flags = readLE16(cdData, at: cursor + 8)
            let method = readLE16(cdData, at: cursor + 10)
            let modTime = readLE16(cdData, at: cursor + 12)
            let modDate = readLE16(cdData, at: cursor + 14)
            let crc32 = readLE32(cdData, at: cursor + 16)
            let compSize = UInt64(readLE32(cdData, at: cursor + 20))
            let uncompSize = UInt64(readLE32(cdData, at: cursor + 24))
            let nameLen = Int(readLE16(cdData, at: cursor + 28))
            let extraLen = Int(readLE16(cdData, at: cursor + 30))
            let commentLen = Int(readLE16(cdData, at: cursor + 32))
            let extAttrs = readLE32(cdData, at: cursor + 38)
            let localOffset = UInt64(readLE32(cdData, at: cursor + 42))

            let headerEnd = cursor + 46 + nameLen + extraLen + commentLen
            guard headerEnd <= cdSize else {
                throw SaveArchiveFailure.invalidArchive("Truncated Central Directory entry.")
            }
            let nameData = cdData.subdata(in: (cursor + 46)..<(cursor + 46 + nameLen))
            guard !nameData.contains(0), let rawName = String(bytes: nameData, encoding: .utf8) else {
                throw SaveArchiveFailure.unsafePath("<invalid-utf8>")
            }

            let unixMode = (extAttrs >> 16) & UInt32(S_IFMT)
            let isSymlink = ((extAttrs >> 16) != 0) && (unixMode == UInt32(S_IFLNK))
            if isSymlink {
                throw SaveArchiveFailure.symlinkNotAllowed(rawName)
            }
            guard isSafePath(rawName) else {
                throw SaveArchiveFailure.unsafePath(rawName)
            }

            let isDirectory = rawName.hasSuffix("/") || (((extAttrs >> 16) != 0) && unixMode == UInt32(S_IFDIR))
            if !isDirectory {
                guard flags & 0x0001 == 0 else {
                    throw SaveArchiveFailure.invalidArchive("Encrypted ZIP archives are not supported.")
                }
                guard method == 0 || method == 8 else {
                    throw SaveArchiveFailure.invalidArchive("Unsupported ZIP compression method (\(method)).")
                }
                guard compSize != 0xFFFF_FFFF && uncompSize != 0xFFFF_FFFF,
                      uncompSize <= maxTotalBytes - declaredPayloadBytes else {
                    throw SaveArchiveFailure.quotaExceeded
                }
                declaredPayloadBytes += uncompSize
            }
            guard localOffset + 30 <= cdOffset else {
                throw SaveArchiveFailure.invalidArchive("ZIP entry offset out of bounds.")
            }

            entries.append(CentralEntry(
                rawName: rawName,
                method: method,
                crc32: crc32,
                compressedSize: compSize,
                uncompressedSize: uncompSize,
                localHeaderOffset: localOffset,
                isDirectory: isDirectory,
                isSymlink: isSymlink,
                modDate: modDate,
                modTime: modTime
            ))
            cursor = headerEnd
        }
        return entries
    }

    static func isSafePath(_ path: String) -> Bool {
        if path.isEmpty || path.hasPrefix("/") || path.hasPrefix("\\") || path.contains("\\") || path.contains(":") {
            return false
        }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard !trimmed.isEmpty else { return false }
        for part in trimmed.split(separator: "/", omittingEmptySubsequences: false) {
            if part.isEmpty || part == "." || part == ".." { return false }
        }
        return true
    }

    // MARK: - Streaming Extractor

    static func extractData(handle: FileHandle, entry: CentralEntry, remainingBudget: inout UInt64) throws -> Data {
        var out = Data()
        try streamDecompress(handle: handle, entry: entry, remainingBudget: &remainingBudget) { chunk in
            out.append(chunk)
        }
        return out
    }

    static func extractToFile(
        handle: FileHandle,
        entry: CentralEntry,
        destination: URL,
        remainingBudget: inout UInt64
    ) throws {
        let fd = open(destination.path, O_WRONLY | O_TRUNC | O_NOFOLLOW, 0o644)
        guard fd >= 0 else {
            throw SaveArchiveFailure.invalidArchive("Unable to open extracted file for writing.")
        }
        defer { close(fd) }

        try streamDecompress(handle: handle, entry: entry, remainingBudget: &remainingBudget) { chunk in
            let ok = chunk.withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return true }
                var offset = 0
                while offset < chunk.count {
                    let n = write(fd, base.advanced(by: offset), chunk.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { return false }
                    offset += n
                }
                return true
            }
            if !ok {
                throw SaveArchiveFailure.invalidArchive("Disk write failed during extraction.")
            }
        }
        var times = dosTimespec(date: entry.modDate, time: entry.modTime)
        _ = futimens(fd, &times)
    }

    private static func seekToEntryPayload(handle: FileHandle, entry: CentralEntry) throws {
        try handle.seek(toOffset: entry.localHeaderOffset)
        guard let lfh = try handle.read(upToCount: 30), lfh.count == 30,
              readLE32(lfh, at: 0) == 0x0403_4b50 else {
            throw SaveArchiveFailure.invalidArchive("Corrupt local file header for \(entry.rawName).")
        }
        let nameLen = UInt64(readLE16(lfh, at: 26))
        let extraLen = UInt64(readLE16(lfh, at: 28))
        try handle.seek(toOffset: entry.localHeaderOffset + 30 + nameLen + extraLen)
    }

    private static func streamDecompress(
        handle: FileHandle,
        entry: CentralEntry,
        remainingBudget: inout UInt64,
        onChunk: (Data) throws -> Void
    ) throws {
        try seekToEntryPayload(handle: handle, entry: entry)

        var crc: UInt32 = 0xFFFF_FFFF
        var produced: UInt64 = 0

        if entry.method == 0 {
            guard entry.compressedSize == entry.uncompressedSize else {
                throw SaveArchiveFailure.invalidArchive("Stored entry size mismatch for \(entry.rawName).")
            }
            var left = entry.compressedSize
            while left > 0 {
                let step = Int(min(UInt64(chunkBytes), left))
                guard let chunk = try handle.read(upToCount: step), chunk.count == step else {
                    throw SaveArchiveFailure.invalidArchive("Truncated ZIP payload for \(entry.rawName).")
                }
                guard UInt64(step) <= remainingBudget else { throw SaveArchiveFailure.quotaExceeded }
                remainingBudget -= UInt64(step)
                produced += UInt64(step)
                crc = updateCRC32(crc, data: chunk)
                try onChunk(chunk)
                left -= UInt64(step)
            }
        } else {
            let dummy = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
            defer { dummy.deallocate() }
            var stream = compression_stream(
                dst_ptr: dummy, dst_size: 0,
                src_ptr: UnsafePointer(dummy), src_size: 0,
                state: nil
            )
            guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
                throw SaveArchiveFailure.invalidArchive("Failed to initialize deflate decoder.")
            }
            defer { compression_stream_destroy(&stream) }

            let dstBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkBytes)
            defer { dstBuf.deallocate() }

            var compLeft = entry.compressedSize
            var inputData = Data()
            var inputOffset = 0
            var finished = false

            while !finished {
                if inputOffset >= inputData.count && compLeft > 0 {
                    let readLen = Int(min(UInt64(chunkBytes), compLeft))
                    guard let next = try handle.read(upToCount: readLen), next.count == readLen else {
                        throw SaveArchiveFailure.invalidArchive("Truncated deflate stream for \(entry.rawName).")
                    }
                    inputData = next
                    inputOffset = 0
                    compLeft -= UInt64(readLen)
                }

                let flags: Int32 = compLeft == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                var producedThisStep = 0
                var availThisStep = 0
                let status: compression_status = try inputData.withUnsafeBytes { rawIn -> compression_status in
                    let baseIn = rawIn.bindMemory(to: UInt8.self).baseAddress
                    let availIn = inputData.count - inputOffset
                    availThisStep = availIn
                    stream.src_ptr = (availIn > 0 && baseIn != nil) ? baseIn!.advanced(by: inputOffset) : UnsafePointer(dummy)
                    stream.src_size = availIn
                    stream.dst_ptr = dstBuf
                    stream.dst_size = chunkBytes

                    let st = compression_stream_process(&stream, flags)
                    let consumed = availIn - stream.src_size
                    inputOffset += consumed
                    let outLen = chunkBytes - stream.dst_size
                    producedThisStep = outLen
                    if outLen > 0 {
                        guard UInt64(outLen) <= remainingBudget else { throw SaveArchiveFailure.quotaExceeded }
                        remainingBudget -= UInt64(outLen)
                        produced += UInt64(outLen)
                        guard produced <= entry.uncompressedSize else {
                            throw SaveArchiveFailure.quotaExceeded
                        }
                        let outData = Data(bytes: dstBuf, count: outLen)
                        crc = updateCRC32(crc, data: outData)
                        try onChunk(outData)
                    }
                    return st
                }

                switch status {
                case COMPRESSION_STATUS_OK:
                    if compLeft == 0 && availThisStep == 0 && producedThisStep == 0 {
                        throw SaveArchiveFailure.invalidArchive("Unexpected end of deflate stream in \(entry.rawName).")
                    }
                    continue
                case COMPRESSION_STATUS_END:
                    finished = true
                default:
                    throw SaveArchiveFailure.invalidArchive("Corrupt deflate data in \(entry.rawName).")
                }
            }
        }

        let finalCRC = crc ^ 0xFFFF_FFFF
        guard produced == entry.uncompressedSize, finalCRC == entry.crc32 else {
            throw SaveArchiveFailure.invalidArchive("CRC or size verification failed for \(entry.rawName).")
        }
    }

    // MARK: - ZIP Writer

    private struct WrittenRecord {
        let nameBytes: [UInt8]
        let method: UInt16
        let crc32: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let dosTime: UInt16
        let dosDate: UInt16
        let localOffset: UInt32
    }

    static func writeZip(items: [WriteItem], to destination: URL, fileManager fm: FileManager) throws {
        guard items.count <= maxEntries else { throw SaveArchiveFailure.quotaExceeded }
        guard fm.createFile(atPath: destination.path, contents: nil),
              let out = try? FileHandle(forWritingTo: destination) else {
            throw SaveArchiveFailure.invalidArchive("Cannot create output ZIP file.")
        }
        defer { try? out.close() }

        var records: [WrittenRecord] = []
        records.reserveCapacity(items.count)
        var offset: UInt64 = 0
        var totalRawBytes: UInt64 = 0

        for item in items {
            try autoreleasepool {
                let rawData: Data
                if let inline = item.data {
                    rawData = inline
                } else if let url = item.fileURL {
                    rawData = try Data(contentsOf: url)
                } else {
                    rawData = Data()
                }

                let size64 = UInt64(rawData.count)
                guard size64 <= UInt64(UInt32.max),
                      size64 <= maxTotalBytes - totalRawBytes else {
                    throw SaveArchiveFailure.quotaExceeded
                }
                totalRawBytes += size64

                let crc = computeCRC32(rawData)
                let compressed = deflateRaw(rawData)
                let useDeflate = compressed != nil && compressed!.count < rawData.count
                let payload = useDeflate ? compressed! : rawData
                let method: UInt16 = useDeflate ? 8 : 0
                let nameBytes = Array(item.archivePath.utf8)
                let (dosDate, dosTime) = toDOSDateTime(item.modDate)

                guard offset <= UInt64(UInt32.max) else { throw SaveArchiveFailure.quotaExceeded }
                let localOffset = UInt32(offset)

                var lfh = [UInt8](repeating: 0, count: 30)
                putLE32(0x0403_4b50, into: &lfh, at: 0)
                putLE16(20, into: &lfh, at: 4)
                putLE16(0x0800, into: &lfh, at: 6)
                putLE16(method, into: &lfh, at: 8)
                putLE16(dosTime, into: &lfh, at: 10)
                putLE16(dosDate, into: &lfh, at: 12)
                putLE32(crc, into: &lfh, at: 14)
                putLE32(UInt32(payload.count), into: &lfh, at: 18)
                putLE32(UInt32(rawData.count), into: &lfh, at: 22)
                putLE16(UInt16(nameBytes.count), into: &lfh, at: 26)

                try out.write(contentsOf: Data(lfh))
                try out.write(contentsOf: Data(nameBytes))
                try out.write(contentsOf: payload)

                offset += UInt64(30 + nameBytes.count + payload.count)
                records.append(WrittenRecord(
                    nameBytes: nameBytes,
                    method: method,
                    crc32: crc,
                    compressedSize: UInt32(payload.count),
                    uncompressedSize: UInt32(rawData.count),
                    dosTime: dosTime,
                    dosDate: dosDate,
                    localOffset: localOffset
                ))
            }
        }

        guard offset <= UInt64(UInt32.max) else { throw SaveArchiveFailure.quotaExceeded }
        let cdOffset = UInt32(offset)
        var cdSize: UInt32 = 0

        for rec in records {
            var cdh = [UInt8](repeating: 0, count: 46)
            putLE32(0x0201_4b50, into: &cdh, at: 0)
            putLE16(0x031E, into: &cdh, at: 4)
            putLE16(20, into: &cdh, at: 6)
            putLE16(0x0800, into: &cdh, at: 8)
            putLE16(rec.method, into: &cdh, at: 10)
            putLE16(rec.dosTime, into: &cdh, at: 12)
            putLE16(rec.dosDate, into: &cdh, at: 14)
            putLE32(rec.crc32, into: &cdh, at: 16)
            putLE32(rec.compressedSize, into: &cdh, at: 20)
            putLE32(rec.uncompressedSize, into: &cdh, at: 24)
            putLE16(UInt16(rec.nameBytes.count), into: &cdh, at: 28)
            putLE32(UInt32(0o100644 << 16), into: &cdh, at: 38)
            putLE32(rec.localOffset, into: &cdh, at: 42)

            try out.write(contentsOf: Data(cdh))
            try out.write(contentsOf: Data(rec.nameBytes))
            cdSize += UInt32(46 + rec.nameBytes.count)
        }

        var eocd = [UInt8](repeating: 0, count: 22)
        putLE32(0x0605_4b50, into: &eocd, at: 0)
        putLE16(UInt16(records.count), into: &eocd, at: 8)
        putLE16(UInt16(records.count), into: &eocd, at: 10)
        putLE32(cdSize, into: &eocd, at: 12)
        putLE32(cdOffset, into: &eocd, at: 16)
        try out.write(contentsOf: Data(eocd))
        try out.synchronize()
    }

    private static func deflateRaw(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        let cap = max(64, data.count + 128)
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        defer { dst.deallocate() }
        let outLen = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(dst, cap, base, data.count, nil, COMPRESSION_ZLIB)
        }
        guard outLen > 0 else { return nil }
        return Data(bytes: dst, count: outLen)
    }

    // MARK: - CRC32 & DOS Date/Time

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    private static func computeCRC32(_ data: Data) -> UInt32 {
        updateCRC32(0xFFFF_FFFF, data: data) ^ 0xFFFF_FFFF
    }

    private static func updateCRC32(_ initial: UInt32, data: Data) -> UInt32 {
        var crc = initial
        for b in data {
            crc = crcTable[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8)
        }
        return crc
    }

    private static func toDOSDateTime(_ date: Date) -> (date: UInt16, time: UInt16) {
        var t = time_t(date.timeIntervalSince1970)
        var tmVal = tm()
        localtime_r(&t, &tmVal)
        let year = max(1980, Int(tmVal.tm_year) + 1900) - 1980
        let mon = max(1, min(12, Int(tmVal.tm_mon) + 1))
        let day = max(1, min(31, Int(tmVal.tm_mday)))
        let hour = max(0, min(23, Int(tmVal.tm_hour)))
        let minVal = max(0, min(59, Int(tmVal.tm_min)))
        let sec = max(0, min(59, Int(tmVal.tm_sec))) / 2
        return (UInt16((year << 9) | (mon << 5) | day), UInt16((hour << 11) | (minVal << 5) | sec))
    }

    private static func dosTimespec(date: UInt16, time: UInt16) -> [timespec] {
        var tmVal = tm()
        tmVal.tm_year = Int32(((date >> 9) & 0x7F) + 1980 - 1900)
        tmVal.tm_mon = Int32(max(1, Int((date >> 5) & 0x0F)) - 1)
        tmVal.tm_mday = Int32(max(1, Int(date & 0x1F)))
        tmVal.tm_hour = Int32((time >> 11) & 0x1F)
        tmVal.tm_min = Int32((time >> 5) & 0x3F)
        tmVal.tm_sec = Int32((time & 0x1F) * 2)
        tmVal.tm_isdst = -1
        let sec = max(0, mktime(&tmVal))
        return [timespec(tv_sec: sec, tv_nsec: 0), timespec(tv_sec: sec, tv_nsec: 0)]
    }

    private static func readLE16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readLE32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func putLE16(_ value: UInt16, into buf: inout [UInt8], at offset: Int) {
        buf[offset] = UInt8(value & 0xFF)
        buf[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    private static func putLE32(_ value: UInt32, into buf: inout [UInt8], at offset: Int) {
        buf[offset] = UInt8(value & 0xFF)
        buf[offset + 1] = UInt8((value >> 8) & 0xFF)
        buf[offset + 2] = UInt8((value >> 16) & 0xFF)
        buf[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
}
