import CryptoKit
import Darwin
import Foundation

/// Bidirectional `DMSYNC1` archive packing, verified unpacking, atomic `.nosync` cloud writes,
/// and `<DM_SAVE>-backups` rotation matching `engine/dm/host/save_sync.c` and iOS `CloudSaveSyncCheck`.
package enum CloudSaveArchive {
    package static let keepBackups = 10
    package static let maxArchiveEntries = 10_000
    package static let maxArchiveBytes: UInt64 = 512 * 1024 * 1024

    private static let headerBytes = 8 + 4 + 4 + CloudSaveCheck.hashDigits + 8 + 24 + 64
    private static let entryHeaderBytes = 24
    private static let chunkBytes = 1 << 16
    private static let magic = Array("DMSYNC1\n".utf8)
    private static let endMarker = Array("DMSYNCE\n".utf8)
    private static let guestAttr = "org.d2rmobile.guest-name"
    private static let saveFolders = ["save", "save_device"]

    package struct ArchiveResult: Equatable, Sendable {
        package var save: CloudSaveCheck.Save
        package var titleID: String?
        package var files: Int
        package var bytes: UInt64

        package init(save: CloudSaveCheck.Save, titleID: String? = nil, files: Int, bytes: UInt64) {
            self.save = save
            self.titleID = titleID
            self.files = files
            self.bytes = bytes
        }
    }

    // MARK: - Packing & atomic `.nosync` cloud write

    /// Packs `save` (`DM_SAVE`) and its `_device` sibling into a `DMSYNC1` archive matching `ss_pack` in `save_sync.c`.
    @discardableResult
    package static func packSave(
        save: URL,
        titleID: String,
        device: String = CloudSaveCheck.currentDeviceModel(),
        to destination: URL,
        fileManager fm: FileManager = .default
    ) -> ArchiveResult? {
        try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: destination)
        guard fm.createFile(atPath: destination.path, contents: nil),
              let out = try? FileHandle(forWritingTo: destination) else {
            return nil
        }

        var sha = SHA256()
        var entries: UInt32 = 0
        var files = 0
        var totalBytes: UInt64 = 0
        var newest: Int64 = 0
        var failed = false

        do {
            try out.write(contentsOf: Data(repeating: 0, count: headerBytes))
            for (index, folder) in saveFolders.enumerated() {
                let dir = index == 0 ? save.path : save.path + "_device"
                guard let has = CloudSaveCheck.hasEntriesChecked(dir) else {
                    failed = true
                    break
                }
                guard has else { continue }
                let ok = CloudSaveCheck.walk(dir, folder) { abs, rel, st in
                    guard entries < UInt32(maxArchiveEntries) else { return false }
                    let isFile = (st.st_mode & S_IFMT) == S_IFREG
                    var guest = [UInt8](repeating: 0, count: 1024)
                    var gl = getxattr(abs, guestAttr, &guest, guest.count, 0, XATTR_NOFOLLOW)
                    if gl < 0 { gl = 0 }
                    let pathBytes = Array(rel.utf8)
                    guard pathBytes.count <= Int(UInt16.max), gl <= Int(UInt16.max) else { return false }
                    let size = isFile ? UInt64(max(0, st.st_size)) : 0
                    guard size <= maxArchiveBytes - totalBytes else { return false }
                    let mt = Int64(st.st_mtimespec.tv_sec)

                    var h = [UInt8](repeating: 0, count: entryHeaderBytes)
                    h[0] = isFile ? 2 : 1
                    CloudSaveCheck.put(UInt16(pathBytes.count), into: &h, at: 2)
                    CloudSaveCheck.put(UInt16(gl), into: &h, at: 4)
                    CloudSaveCheck.put(size, into: &h, at: 8)
                    CloudSaveCheck.put(mt, into: &h, at: 16)

                    sha.update(data: h.prefix(16))
                    sha.update(data: pathBytes)
                    sha.update(data: guest.prefix(gl))

                    do {
                        try out.write(contentsOf: Data(h))
                        try out.write(contentsOf: Data(pathBytes))
                        if gl > 0 { try out.write(contentsOf: Data(guest.prefix(gl))) }
                    } catch {
                        return false
                    }
                    entries += 1
                    guard isFile else { return true }

                    guard let stream = InputStream(fileAtPath: abs) else { return false }
                    stream.open()
                    defer { stream.close() }
                    var remaining = size
                    var buffer = [UInt8](repeating: 0, count: chunkBytes)
                    while remaining > 0 {
                        let chunkLen = Int(min(UInt64(buffer.count), remaining))
                        let got = stream.read(&buffer, maxLength: chunkLen)
                        if got <= 0 { return false }
                        sha.update(data: buffer.prefix(got))
                        do {
                            try out.write(contentsOf: Data(buffer.prefix(got)))
                        } catch {
                            return false
                        }
                        remaining -= UInt64(got)
                    }
                    totalBytes += size
                    files += 1
                    newest = max(newest, mt)
                    return true
                }
                if !ok {
                    failed = true
                    break
                }
            }
            if !failed {
                try out.write(contentsOf: Data(endMarker))
                let digest = sha.finalize()
                let hash = files > 0 ? digest.prefix(CloudSaveCheck.hashDigits / 2).map { String(format: "%02x", $0) }.joined() : ""
                var hdr = [UInt8](repeating: 0, count: headerBytes)
                for (i, b) in magic.enumerated() { hdr[i] = b }
                CloudSaveCheck.put(UInt32(1), into: &hdr, at: 8)
                CloudSaveCheck.put(entries, into: &hdr, at: 12)
                writeFixedCString(hash, into: &hdr, range: 16..<48, nullTerminated: false)
                CloudSaveCheck.put(newest, into: &hdr, at: 48)
                writeFixedCString(titleID.uppercased(), into: &hdr, range: 56..<80, nullTerminated: true)
                writeFixedCString(device, into: &hdr, range: 80..<144, nullTerminated: true)
                try out.seek(toOffset: 0)
                try out.write(contentsOf: Data(hdr))
                try out.synchronize()
                try out.close()
                let save = CloudSaveCheck.Save(
                    hash: hash.isEmpty ? nil : hash,
                    saved: newest > 0 ? Date(timeIntervalSince1970: TimeInterval(newest)) : nil,
                    device: device.isEmpty ? nil : device
                )
                return ArchiveResult(save: save, titleID: titleID.uppercased(), files: files, bytes: totalBytes)
            }
        } catch {
            failed = true
        }
        try? out.close()
        try? fm.removeItem(at: destination)
        return nil
    }

    /// Writes `save.dmsync` to the cloud folder atomically via `<cloudFile>.<pid>.nosync` then `rename()`.
    @discardableResult
    package static func writeCloudAtomically(
        save: URL,
        titleID: String,
        device: String = CloudSaveCheck.currentDeviceModel(),
        to cloudFile: URL,
        fileManager fm: FileManager = .default
    ) -> ArchiveResult? {
        let dir = cloudFile.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let tempURL = URL(fileURLWithPath: "\(cloudFile.path).\(getpid()).nosync")
        guard let packed = packSave(save: save, titleID: titleID, device: device, to: tempURL, fileManager: fm) else {
            return nil
        }
        if rename(tempURL.path, cloudFile.path) != 0 {
            unlink(tempURL.path)
            return nil
        }
        return packed
    }

    // MARK: - Verified reading & bounded unpacking (`ss_read`)

    /// Verifies every entry, path, checksum, quota, and strict EOF of a `DMSYNC1` archive.
    /// When `targetRoot` is provided, unpacks `save/` and `save_device/` inside it and cleans them up on any failure.
    package static func readArchive(
        at bundleURL: URL,
        into targetRoot: URL?,
        fileManager fm: FileManager = .default
    ) -> ArchiveResult? {
        guard let handle = try? FileHandle(forReadingFrom: bundleURL) else { return nil }
        defer { try? handle.close() }

        func fail() -> ArchiveResult? {
            if let targetRoot {
                for folder in saveFolders {
                    try? fm.removeItem(at: targetRoot.appendingPathComponent(folder, isDirectory: true))
                }
            }
            return nil
        }

        guard let hdr = readExact(handle, count: headerBytes),
              Array(hdr.prefix(8)) == magic else { return fail() }
        let version = loadLE(UInt32.self, from: hdr, at: 8)
        let entryCount = loadLE(UInt32.self, from: hdr, at: 12)
        guard version == 1, entryCount <= UInt32(maxArchiveEntries) else { return fail() }

        let wantHash = readCString(hdr, range: 16..<48)
        let savedSec = loadLE(Int64.self, from: hdr, at: 48)
        let packedTitle = readCString(hdr, range: 56..<80)
        let device = readCString(hdr, range: 80..<144)

        if !wantHash.isEmpty {
            guard wantHash.count == CloudSaveCheck.hashDigits, CloudSaveCheck.isLowerHexString(wantHash) else {
                return fail()
            }
        }

        var sha = SHA256()
        var files = 0
        var usedBytes: UInt64 = 0

        for _ in 0..<entryCount {
            guard let eh = readExact(handle, count: entryHeaderBytes) else { return fail() }
            let kind = eh[0]
            let pathLen = Int(loadLE(UInt16.self, from: eh, at: 2))
            let guestLen = Int(loadLE(UInt16.self, from: eh, at: 4))
            let size = loadLE(UInt64.self, from: eh, at: 8)
            let mtime = loadLE(Int64.self, from: eh, at: 16)

            guard (kind == 1 || kind == 2),
                  pathLen > 0, pathLen < Int(PATH_MAX),
                  guestLen <= 1024,
                  (kind == 2 || size == 0),
                  size <= maxArchiveBytes - usedBytes else {
                return fail()
            }
            usedBytes += size

            guard let pathData = readExact(handle, count: pathLen),
                  let guestData = readExact(handle, count: guestLen),
                  !pathData.contains(0),
                  let relPath = String(bytes: pathData, encoding: .utf8),
                  isSafeArchivePath(relPath) else {
                return fail()
            }

            sha.update(data: eh.prefix(16))
            sha.update(data: pathData)
            sha.update(data: guestData)

            var outFD: Int32 = -1
            defer {
                if outFD >= 0 { close(outFD) }
            }

            if let targetRoot {
                let targetURL = targetRoot.appendingPathComponent(relPath, isDirectory: kind == 1)
                let targetPath = targetURL.path
                guard !hasSymlinkComponent(relPath: relPath, under: targetRoot) else { return fail() }
                if kind == 1 {
                    do {
                        try fm.createDirectory(at: targetURL, withIntermediateDirectories: true)
                    } catch {
                        return fail()
                    }
                } else {
                    do {
                        try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    } catch {
                        return fail()
                    }
                    outFD = open(targetPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
                    if outFD < 0 { return fail() }
                }
                if guestLen > 0 {
                    let rc = guestData.withUnsafeBytes { raw -> Int32 in
                        guard let base = raw.baseAddress else { return -1 }
                        return setxattr(targetPath, guestAttr, base, guestLen, 0, XATTR_NOFOLLOW)
                    }
                    if rc != 0 { return fail() }
                }
            }

            var remaining = size
            while remaining > 0 {
                let step = Int(min(UInt64(chunkBytes), remaining))
                guard let chunk = readExact(handle, count: step) else { return fail() }
                sha.update(data: chunk)
                if outFD >= 0 {
                    let wroteOK = chunk.withUnsafeBytes { raw -> Bool in
                        guard let base = raw.baseAddress else { return true }
                        return writeAll(fd: outFD, ptr: base, count: step)
                    }
                    if !wroteOK { return fail() }
                }
                remaining -= UInt64(step)
            }

            if outFD >= 0 {
                var times = [timespec(tv_sec: time_t(mtime), tv_nsec: 0), timespec(tv_sec: time_t(mtime), tv_nsec: 0)]
                _ = futimens(outFD, &times)
                let closeRC = close(outFD)
                outFD = -1
                if closeRC != 0 { return fail() }
            }

            if kind == 2 {
                files += 1
            }
        }

        guard let tail = readExact(handle, count: endMarker.count),
              Array(tail) == endMarker else {
            return fail()
        }
        // Refuse trailing garbage bytes just as `fgetc(f) != EOF` does in `save_sync.c`.
        do {
            if let extra = try handle.read(upToCount: 1), !extra.isEmpty {
                return fail()
            }
        } catch {
            return fail()
        }

        let computed = files > 0 ? sha.finalize().prefix(CloudSaveCheck.hashDigits / 2).map { String(format: "%02x", $0) }.joined() : ""
        guard computed == wantHash else { return fail() }

        let save = CloudSaveCheck.Save(
            hash: computed.isEmpty ? nil : computed,
            saved: savedSec > 0 ? Date(timeIntervalSince1970: TimeInterval(savedSec)) : nil,
            device: device.isEmpty ? nil : device
        )
        return ArchiveResult(save: save, titleID: packedTitle.isEmpty ? nil : packedTitle, files: files, bytes: usedBytes)
    }

    static func isSafeArchivePath(_ path: String) -> Bool {
        guard path.hasPrefix("save/") || path.hasPrefix("save_device/") else { return false }
        if path.contains("\\") || path.contains(":") || path.hasSuffix("/") { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        for part in parts {
            if part.isEmpty || part == "." || part == ".." { return false }
        }
        return true
    }

    private static func hasSymlinkComponent(relPath: String, under root: URL) -> Bool {
        var cur = root
        for part in relPath.split(separator: "/") {
            cur = cur.appendingPathComponent(String(part))
            var st = stat()
            if lstat(cur.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK {
                return true
            }
        }
        return false
    }

    // MARK: - Backups & atomic save replacement

    package static func backupsRoot(for save: URL) -> URL {
        URL(fileURLWithPath: save.path + "-backups", isDirectory: true)
    }

    package static func targetFolder(_ folder: String, save: URL) -> URL {
        folder == "save" ? save : URL(fileURLWithPath: save.path + "_device", isDirectory: true)
    }

    package static func hasLocalSaveEntries(save: URL) -> Bool {
        saveFolders.contains { CloudSaveCheck.hasEntries(targetFolder($0, save: save).path) }
    }

    /// Copies the current local `save` and `save_device` into `<save>-backups/YYYY-MM-DD HH.MM.SS local`.
    /// Pruning can be deferred until after atomic swap succeeds so failed pulls never discard older backups.
    @discardableResult
    package static func backupLocalSave(
        save: URL,
        now: Date = Date(),
        side: String = "local",
        prune: Bool = true,
        protectedNames: Set<String> = [],
        fileManager fm: FileManager = .default
    ) throws -> URL {
        let backupDir = try makeBackupDirectory(for: save, side: side, now: now, prune: prune, protectedNames: protectedNames, fileManager: fm)
        do {
            for folder in saveFolders {
                let src = targetFolder(folder, save: save)
                if CloudSaveCheck.hasEntries(src.path) {
                    try fm.copyItem(at: src, to: backupDir.appendingPathComponent(folder, isDirectory: true))
                }
            }
            return backupDir
        } catch {
            try? fm.removeItem(at: backupDir)
            throw error
        }
    }

    /// Backs up the cloud archive before replacing it with local (`save-backups/YYYY-MM-DD HH.MM.SS cloud`).
    @discardableResult
    package static func backupCloudArchive(
        cloudFile: URL,
        save: URL,
        now: Date = Date(),
        fileManager fm: FileManager = .default
    ) throws -> URL {
        let staging = URL(fileURLWithPath: save.path + ".cloud-backup-stage-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let backupDir = try makeBackupDirectory(for: save, side: "cloud", now: now, prune: true, fileManager: fm)
        do {
            if readArchive(at: cloudFile, into: staging, fileManager: fm) != nil {
                for folder in saveFolders {
                    let src = staging.appendingPathComponent(folder, isDirectory: true)
                    if fm.fileExists(atPath: src.path) {
                        try fm.moveItem(at: src, to: backupDir.appendingPathComponent(folder, isDirectory: true))
                    }
                }
            } else {
                try fm.copyItem(at: cloudFile, to: backupDir.appendingPathComponent("save.dmsync", isDirectory: false))
            }
            return backupDir
        } catch {
            try? fm.removeItem(at: backupDir)
            throw error
        }
    }

    /// Atomically replaces `save` and `save_device` from `stagedRoot/{save,save_device}` on the same volume.
    /// On any failure, unconditionally removes half-written target directories first and then restores prior backups.
    package static func replaceSaveFolders(
        save: URL,
        from stagedRoot: URL,
        fileManager fm: FileManager = .default,
        faultHook: ((String) throws -> Void)? = nil
    ) throws {
        try fm.createDirectory(at: save.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rollbackRoot = URL(fileURLWithPath: save.path + ".rollback-\(UUID().uuidString)", isDirectory: true)
        var movedOld: [String] = []
        var swappedOK = false
        defer {
            if swappedOK {
                try? fm.removeItem(at: rollbackRoot)
            }
        }

        do {
            try fm.createDirectory(at: rollbackRoot, withIntermediateDirectories: true)
            for folder in saveFolders {
                let target = targetFolder(folder, save: save)
                if fm.fileExists(atPath: target.path) {
                    let backup = rollbackRoot.appendingPathComponent(folder, isDirectory: true)
                    try fm.moveItem(at: target, to: backup)
                    movedOld.append(folder)
                }
            }
            try faultHook?("afterMoveOld")
            for folder in saveFolders {
                let incoming = stagedRoot.appendingPathComponent(folder, isDirectory: true)
                let target = targetFolder(folder, save: save)
                if fm.fileExists(atPath: incoming.path) {
                    try fm.moveItem(at: incoming, to: target)
                }
            }
            try faultHook?("afterMoveIncoming")
            if !fm.fileExists(atPath: save.path) {
                try fm.createDirectory(at: save, withIntermediateDirectories: true)
            }
            swappedOK = true
        } catch {
            // Unconditionally clear partial target directories first before restoring any prior saves.
            for folder in saveFolders {
                try? fm.removeItem(at: targetFolder(folder, save: save))
            }
            var restoredAll = true
            for folder in movedOld {
                let backup = rollbackRoot.appendingPathComponent(folder, isDirectory: true)
                let target = targetFolder(folder, save: save)
                do {
                    try fm.moveItem(at: backup, to: target)
                } catch {
                    restoredAll = false
                }
            }
            // Only remove rollbackRoot once every backed-up folder is safely restored.
            if restoredAll {
                try? fm.removeItem(at: rollbackRoot)
            }
            throw error
        }
    }

    package static func pruneBackups(
        for save: URL,
        side: String,
        protectedNames: Set<String> = [],
        fileManager fm: FileManager = .default
    ) {
        let root = backupsRoot(for: save)
        guard let names = CloudSaveCheck.names(root.path) else { return }
        let candidates = names.filter { isAutoBackupName($0, side: side) && !protectedNames.contains($0) }
        let limit = protectedNames.isEmpty ? keepBackups : max(0, keepBackups - 1)
        guard candidates.count > limit else { return }
        let removeCount = candidates.count - limit
        for name in candidates.prefix(removeCount) {
            try? fm.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
        }
    }

    private static func makeBackupDirectory(
        for save: URL,
        side: String,
        now: Date,
        prune: Bool,
        protectedNames: Set<String> = [],
        fileManager fm: FileManager
    ) throws -> URL {
        let root = backupsRoot(for: save)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let stamp = backupTimestamp(now)
        var candidateName = "\(stamp) \(side)"
        var suffix = 2
        while fm.fileExists(atPath: root.appendingPathComponent(candidateName).path) {
            candidateName = "\(stamp) \(side) \(suffix)"
            suffix += 1
        }
        let created = root.appendingPathComponent(candidateName, isDirectory: true)
        try fm.createDirectory(at: created, withIntermediateDirectories: true)
        if prune {
            var keep = protectedNames
            keep.insert(candidateName)
            pruneBackups(for: save, side: side, protectedNames: keep, fileManager: fm)
        }
        return created
    }

    static func isAutoBackupName(_ name: String, side: String) -> Bool {
        let pattern = Array("0000-00-00 00.00.00 ".utf8)
        let bytes = Array(name.utf8)
        guard bytes.count > pattern.count else { return false }
        for (i, p) in pattern.enumerated() {
            if p == UInt8(ascii: "0") {
                guard bytes[i] >= UInt8(ascii: "0") && bytes[i] <= UInt8(ascii: "9") else { return false }
            } else {
                guard bytes[i] == p else { return false }
            }
        }
        let rest = String(decoding: bytes.dropFirst(pattern.count), as: UTF8.self)
        guard rest.hasPrefix(side) else { return false }
        let tail = rest.dropFirst(side.count)
        if tail.isEmpty { return true }
        guard tail.first == " " else { return false }
        let digits = tail.dropFirst()
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func backupTimestamp(_ date: Date) -> String {
        var sec = time_t(date.timeIntervalSince1970)
        var tmVal = tm()
        localtime_r(&sec, &tmVal)
        var buf = [CChar](repeating: 0, count: 32)
        let n = strftime(&buf, buf.count, "%Y-%m-%d %H.%M.%S", &tmVal)
        guard n > 0 else { return "1970-01-01 00.00.00" }
        return String(decoding: buf.prefix(n).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: - Low-level byte helpers

    private static func loadLE<T: FixedWidthInteger>(_ type: T.Type, from data: Data, at offset: Int) -> T {
        var value: T = 0
        _ = withUnsafeMutableBytes(of: &value) { dst in
            data.copyBytes(to: dst, from: offset..<(offset + MemoryLayout<T>.size))
        }
        return T(littleEndian: value)
    }

    private static func writeFixedCString(_ string: String, into bytes: inout [UInt8], range: Range<Int>, nullTerminated: Bool) {
        let maxCount = nullTerminated ? max(0, range.count - 1) : range.count
        let utf8 = Array(string.utf8.prefix(maxCount))
        for (i, b) in utf8.enumerated() {
            bytes[range.lowerBound + i] = b
        }
    }

    private static func readCString(_ data: Data, range: Range<Int>) -> String {
        let slice = data.subdata(in: range).prefix { $0 != 0 }
        return String(decoding: slice, as: UTF8.self)
    }

    private static func readExact(_ handle: FileHandle, count: Int) -> Data? {
        if count == 0 { return Data() }
        guard let data = try? handle.read(upToCount: count), data.count == count else { return nil }
        return data
    }

    private static func writeAll(fd: Int32, ptr: UnsafeRawPointer, count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let n = write(fd, ptr.advanced(by: offset), count - offset)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
}
