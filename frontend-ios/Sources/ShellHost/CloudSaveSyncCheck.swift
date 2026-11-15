import CryptoKit
import Darwin
import Foundation

/// Pre-launch cloud save inspection, backup creation and backup restoration for `ShellHost`, matching the binary format and
/// three-way comparison rules of `engine/dm/host/save_sync.c`.
public enum CloudSaveSyncCheck {
    public static let hashDigits = 32
    public static let keepBackups = 10
    public static let maxArchiveEntries = 10_000
    public static let maxArchiveBytes: UInt64 = 512 * 1024 * 1024

    private static let headerBytes = 8 + 4 + 4 + hashDigits + 8 + 24 + 64
    private static let entryHeaderBytes = 24
    private static let chunkBytes = 1 << 16
    private static let magic = Array("DMSYNC1\n".utf8)
    private static let endMarker = Array("DMSYNCE\n".utf8)
    private static let guestAttr = "org.d2rmobile.guest-name"
    private static let saveFolders = ["save", "save_device"]

    /// Metadata of one save snapshot (`hash == nil` means empty / no save files).
    public struct Save: Equatable, Sendable {
        public var hash: String?
        public var saved: Date?
        public var device: String?
        public var titleID: String?

        public init(hash: String?, saved: Date? = nil, device: String? = nil, titleID: String? = nil) {
            self.hash = hash
            self.saved = saved
            self.device = device
            self.titleID = titleID
        }

        public static let empty = Save(hash: nil)
    }

    /// Outcome of comparing local save, last-synced base hash and cloud archive before game launch.
    public enum Outcome: Equatable, Sendable {
        case same
        case onlyCloudChanged
        case onlyLocalChanged
        case noCloudSave
        case bothChanged
        case unreadable

        public var requiresPrompt: Bool {
            self == .bothChanged || self == .unreadable
        }
    }

    /// Player decision when `Outcome.requiresPrompt` is true.
    public enum Choice: Equatable, Sendable {
        case cloud
        case local
        case offline
    }

    /// Full pre-launch check report for one game.
    public struct Report: Equatable, Sendable {
        public var outcome: Outcome
        public var local: Save
        public var baseHash: String?
        public var cloud: Save?
        public var cloudFileURL: URL
        public var reason: String?

        public init(outcome: Outcome, local: Save, baseHash: String?, cloud: Save?, cloudFileURL: URL, reason: String? = nil) {
            self.outcome = outcome
            self.local = local
            self.baseHash = baseHash
            self.cloud = cloud
            self.cloudFileURL = cloudFileURL
            self.reason = reason
        }
    }

    /// One restorable backup directory under `<appFolder>/save-backups/`.
    public struct BackupInfo: Equatable, Sendable {
        public var url: URL
        public var name: String
        public var label: String

        public init(url: URL, name: String, label: String) {
            self.url = url
            self.name = name
            self.label = label
        }
    }

    // MARK: - Three-way decision (`ss_decide`)

    public static func decide(local: Save, base: String?, cloud: Save?) -> Outcome {
        guard let cloud else { return .unreadable }
        let l = local.hash ?? ""
        let r = cloud.hash ?? ""
        let b = base ?? ""
        if r.isEmpty { return l.isEmpty ? .same : .noCloudSave }
        if l == r { return .same }
        if l.isEmpty { return .onlyCloudChanged }
        if !b.isEmpty && l == b { return .onlyCloudChanged }
        if !b.isEmpty && r == b { return .onlyLocalChanged }
        return .bothChanged
    }

    /// Environment variable passed to the engine (`save_sync.c`, `read_choice`).
    /// When no conflict was found, `"ask"` tells the engine that a frontend owns conflict prompts so a race before mount will not overwrite either save.
    public static func nonInteractiveEnvironment() -> [String: String] {
        ["DM_SAVE_SYNC_CHOICE": "ask"]
    }

    public static func choiceEnvironment(_ choice: Choice, cloud: Save?) -> [String: String] {
        let key = "DM_SAVE_SYNC_CHOICE"
        switch choice {
        case .offline:
            return [key: "offline"]
        case .cloud:
            guard let hash = cloud?.hash, !hash.isEmpty else { return [:] }
            return [key: "cloud:\(hash)"]
        case .local:
            let hash = (cloud?.hash?.isEmpty == false) ? cloud!.hash! : "none"
            return [key: "local:\(hash)"]
        }
    }

    // MARK: - Paths & `.sync` base

    public static func saveURL(in appFolder: URL) -> URL {
        appFolder.appendingPathComponent("save", isDirectory: true)
    }

    public static func backupsRoot(in appFolder: URL) -> URL {
        appFolder.appendingPathComponent("save-backups", isDirectory: true)
    }

    /// Mirrors `cloud_file` in `save_sync.c`: `<folder>/save.dmsync` when `folder` is already named `<titleID>`, else `<folder>/<TITLEID>/save.dmsync`.
    public static func cloudFileURL(folder: URL, titleID: String) -> URL {
        let upper = titleID.uppercased()
        if folder.lastPathComponent.caseInsensitiveCompare(upper) == .orderedSame {
            return folder.appendingPathComponent("save.dmsync", isDirectory: false)
        }
        return folder.appendingPathComponent(upper, isDirectory: true)
            .appendingPathComponent("save.dmsync", isDirectory: false)
    }

    public static func base(save: URL) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: save.path + ".sync")) else { return nil }
        var found: String?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("base\t") {
            let hash = line.dropFirst(5).prefix(hashDigits)
            if hash.count == hashDigits, hash.allSatisfy({ isLowerHex($0) }) {
                found = String(hash)
            }
        }
        return found
    }

    @discardableResult
    public static func writeBase(save: URL, hash: String) -> Bool {
        guard hash.count == hashDigits, hash.allSatisfy({ isLowerHex($0) }) else { return false }
        let syncPath = save.path + ".sync"
        let tmpPath = syncPath + ".tmp"
        let parent = save.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let content = "# save sync (dm/host/save_sync.h): the save last known to be the same here and in the cloud\nbase\t\(hash)\n"
        do {
            try Data(content.utf8).write(to: URL(fileURLWithPath: tmpPath), options: [])
            if rename(tmpPath, syncPath) != 0 {
                unlink(tmpPath)
                return false
            }
            return true
        } catch {
            unlink(tmpPath)
            return false
        }
    }

    public static func clearBase(save: URL) {
        try? FileManager.default.removeItem(atPath: save.path + ".sync")
    }

    // MARK: - Pre-launch check

    /// Inspects the cloud folder and local save off the main actor. Triggers download of an undownloaded `.save.dmsync.icloud`
    /// placeholder with a bounded wait so launch never hangs indefinitely.
    public static func inspect(cloudFolder: URL, titleID: String, appFolder: URL,
                               downloadTimeout: TimeInterval = 4.0,
                               fileManager fm: FileManager = .default) -> Report {
        let save = saveURL(in: appFolder)
        let local = localSave(save: save) ?? .empty
        let baseHash = base(save: save)
        let cloudFile = cloudFileURL(folder: cloudFolder, titleID: titleID)

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: cloudFolder.path, isDirectory: &isDir), isDir.boolValue else {
            return Report(outcome: .unreadable, local: local, baseHash: baseHash, cloud: nil, cloudFileURL: cloudFile,
                          reason: hostText("The cloud saves folder could not be reached on this device."))
        }

        let placeholder = cloudFile.deletingLastPathComponent()
            .appendingPathComponent(".\(cloudFile.lastPathComponent).icloud", isDirectory: false)
        if !fm.fileExists(atPath: cloudFile.path), fm.fileExists(atPath: placeholder.path) {
            try? fm.startDownloadingUbiquitousItem(at: cloudFile)
            let deadline = Date().addingTimeInterval(max(0, downloadTimeout))
            while !fm.fileExists(atPath: cloudFile.path) && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if !fm.fileExists(atPath: cloudFile.path) {
                return Report(outcome: .unreadable, local: local, baseHash: baseHash, cloud: nil, cloudFileURL: cloudFile,
                              reason: hostText("The cloud saves folder could not be reached on this device."))
            }
        }

        guard fm.fileExists(atPath: cloudFile.path) else {
            let outcome = decide(local: local, base: baseHash, cloud: .empty)
            return Report(outcome: outcome, local: local, baseHash: baseHash, cloud: .empty, cloudFileURL: cloudFile)
        }

        guard let verified = readArchive(at: cloudFile, into: nil) else {
            return Report(outcome: .unreadable, local: local, baseHash: baseHash, cloud: nil, cloudFileURL: cloudFile,
                          reason: hostText("The save file in iCloud Drive is damaged or incomplete."))
        }

        if let packedTitle = verified.titleID,
           !packedTitle.isEmpty,
           packedTitle.caseInsensitiveCompare(titleID) != .orderedSame {
            return Report(outcome: .unreadable, local: local, baseHash: baseHash, cloud: nil, cloudFileURL: cloudFile,
                          reason: hostText("The save file in iCloud Drive belongs to another game."))
        }

        let outcome = decide(local: local, base: baseHash, cloud: verified)
        return Report(outcome: outcome, local: local, baseHash: baseHash, cloud: verified, cloudFileURL: cloudFile)
    }

    // MARK: - Applying conflict choices & backups

    /// Applies the player's conflict resolution before launching the engine:
    /// - `.cloud`: backs up any non-empty local save into `save-backups/<timestamp> local`, atomically unpacks the verified cloud
    ///   archive into `save` and `save_device`, writes `save.sync`, and returns `DM_SAVE_SYNC_CHOICE=cloud:<hash>`.
    /// - `.local`: unpacks the verified cloud archive into `save-backups/<timestamp> cloud` so it is never lost, updates `save.sync`
    ///   to the cloud hash so `save_sync.c` pushes local without duplicating the backup, and returns `DM_SAVE_SYNC_CHOICE=local:<hash>`.
    /// - `.offline`: leaves local and cloud untouched and returns `DM_SAVE_SYNC_CHOICE=offline`.
    public static func applyChoice(_ choice: Choice, report: Report, appFolder: URL, now: Date = Date(),
                                   fileManager fm: FileManager = .default) throws -> [String: String] {
        let save = saveURL(in: appFolder)
        switch choice {
        case .offline:
            return choiceEnvironment(.offline, cloud: nil)

        case .cloud:
            guard let cloud = report.cloud, let cloudHash = cloud.hash, !cloudHash.isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let staging = appFolder.appendingPathComponent("save.sync-stage-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: staging) }
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            guard let unpacked = readArchive(at: report.cloudFileURL, into: staging),
                  unpacked.hash == cloudHash else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if hasLocalSaveEntries(in: appFolder) {
                _ = try backupLocalSave(in: appFolder, now: now, fileManager: fm)
            }
            try replaceSaveFolders(in: appFolder, from: staging, fileManager: fm)
            _ = writeBase(save: save, hash: cloudHash)
            return choiceEnvironment(.cloud, cloud: cloud)

        case .local:
            if let cloud = report.cloud, let cloudHash = cloud.hash, !cloudHash.isEmpty,
               fm.fileExists(atPath: report.cloudFileURL.path) {
                let staging = appFolder.appendingPathComponent("save.sync-stage-\(UUID().uuidString)", isDirectory: true)
                defer { try? fm.removeItem(at: staging) }
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                guard let unpacked = readArchive(at: report.cloudFileURL, into: staging),
                      unpacked.hash == cloudHash else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let backupDir = try makeBackupDirectory(in: appFolder, side: "cloud", now: now, fileManager: fm)
                do {
                    for folder in saveFolders {
                        let src = staging.appendingPathComponent(folder, isDirectory: true)
                        if fm.fileExists(atPath: src.path) {
                            try fm.moveItem(at: src, to: backupDir.appendingPathComponent(folder, isDirectory: true))
                        }
                    }
                } catch {
                    try? fm.removeItem(at: backupDir)
                    throw error
                }
                _ = writeBase(save: save, hash: cloudHash)
            }
            return choiceEnvironment(.local, cloud: report.cloud)
        }
    }

    // MARK: - Local save scanning & packing (`ss_scan` / `ss_pack`)

    public static func localSave(save: URL) -> Save? {
        var sha = SHA256()
        var files = 0
        var newest: Int64 = 0
        for (index, folder) in saveFolders.enumerated() {
            let dir = index == 0 ? save.path : save.path + "_device"
            guard hasEntries(dir) else { continue }
            guard walk(dir, folder, { abs, rel, st in
                let isFile = (st.st_mode & S_IFMT) == S_IFREG
                var guest = [UInt8](repeating: 0, count: 1024)
                var gl = getxattr(abs, guestAttr, &guest, guest.count, 0, XATTR_NOFOLLOW)
                if gl < 0 { gl = 0 }
                let pathBytes = Array(rel.utf8)
                guard pathBytes.count <= Int(UInt16.max), gl <= Int(UInt16.max) else { return false }
                var h = [UInt8](repeating: 0, count: 16)
                h[0] = isFile ? 2 : 1
                putLE(UInt16(pathBytes.count), into: &h, at: 2)
                putLE(UInt16(gl), into: &h, at: 4)
                putLE(isFile ? UInt64(max(0, st.st_size)) : 0, into: &h, at: 8)
                sha.update(data: h)
                sha.update(data: pathBytes)
                sha.update(data: guest.prefix(gl))
                guard isFile else { return true }
                guard let stream = InputStream(fileAtPath: abs) else { return false }
                stream.open()
                defer { stream.close() }
                var remaining = Int64(st.st_size)
                var buffer = [UInt8](repeating: 0, count: chunkBytes)
                while remaining > 0 {
                    let count = stream.read(&buffer, maxLength: Int(min(Int64(buffer.count), remaining)))
                    if count <= 0 { return false }
                    sha.update(data: buffer.prefix(count))
                    remaining -= Int64(count)
                }
                files += 1
                newest = max(newest, Int64(st.st_mtimespec.tv_sec))
                return true
            }) else { return nil }
        }
        guard files > 0 else { return .empty }
        let digest = sha.finalize()
        let hash = digest.prefix(hashDigits / 2).map { String(format: "%02x", $0) }.joined()
        return Save(hash: hash, saved: newest > 0 ? Date(timeIntervalSince1970: TimeInterval(newest)) : nil)
    }

    /// Packs `<save>` and `<save>_device` into a `DMSYNC1` archive matching `ss_pack` in `save_sync.c`.
    @discardableResult
    public static func packSave(save: URL, titleID: String, device: String = "iPhone", to destination: URL,
                                fileManager fm: FileManager = .default) -> Save? {
        try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: destination)
        guard fm.createFile(atPath: destination.path, contents: nil),
              let out = try? FileHandle(forWritingTo: destination) else { return nil }

        var sha = SHA256()
        var entries: UInt32 = 0
        var files = 0
        var newest: Int64 = 0
        var failed = false

        do {
            try out.write(contentsOf: Data(repeating: 0, count: headerBytes))
            for (index, folder) in saveFolders.enumerated() {
                let dir = index == 0 ? save.path : save.path + "_device"
                guard hasEntries(dir) else { continue }
                let ok = walk(dir, folder) { abs, rel, st in
                    guard entries < UInt32(maxArchiveEntries) else { return false }
                    let isFile = (st.st_mode & S_IFMT) == S_IFREG
                    var guest = [UInt8](repeating: 0, count: 1024)
                    var gl = getxattr(abs, guestAttr, &guest, guest.count, 0, XATTR_NOFOLLOW)
                    if gl < 0 { gl = 0 }
                    let pathBytes = Array(rel.utf8)
                    guard pathBytes.count <= Int(UInt16.max), gl <= Int(UInt16.max) else { return false }
                    let size = isFile ? UInt64(max(0, st.st_size)) : 0
                    let mt = Int64(st.st_mtimespec.tv_sec)
                    var h = [UInt8](repeating: 0, count: entryHeaderBytes)
                    h[0] = isFile ? 2 : 1
                    putLE(UInt16(pathBytes.count), into: &h, at: 2)
                    putLE(UInt16(gl), into: &h, at: 4)
                    putLE(size, into: &h, at: 8)
                    putLE(mt, into: &h, at: 16)
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
                let hash = files > 0 ? digest.prefix(hashDigits / 2).map { String(format: "%02x", $0) }.joined() : ""
                var hdr = [UInt8](repeating: 0, count: headerBytes)
                for (i, b) in magic.enumerated() { hdr[i] = b }
                putLE(UInt32(1), into: &hdr, at: 8)
                putLE(entries, into: &hdr, at: 12)
                writeFixedCString(hash, into: &hdr, range: 16..<48, nullTerminated: false)
                putLE(newest, into: &hdr, at: 48)
                writeFixedCString(titleID.uppercased(), into: &hdr, range: 56..<80, nullTerminated: true)
                writeFixedCString(device, into: &hdr, range: 80..<144, nullTerminated: true)
                try out.seek(toOffset: 0)
                try out.write(contentsOf: Data(hdr))
                try out.synchronize()
                try out.close()
                return Save(hash: hash.isEmpty ? nil : hash,
                            saved: newest > 0 ? Date(timeIntervalSince1970: TimeInterval(newest)) : nil,
                            device: device,
                            titleID: titleID.uppercased())
            }
        } catch {
            failed = true
        }
        try? out.close()
        try? fm.removeItem(at: destination)
        return nil
    }

    // MARK: - Verified `DMSYNC1` archive reading & bounded extraction (`ss_read`)

    /// Verifies every entry, path, checksum and end marker of a `DMSYNC1` bundle, optionally unpacking into `targetRoot`.
    /// Cleans any partial files under `targetRoot` if verification or extraction fails.
    public static func readArchive(at bundleURL: URL, into targetRoot: URL?, fileManager fm: FileManager = .default) -> Save? {
        guard let handle = try? FileHandle(forReadingFrom: bundleURL) else { return nil }
        defer { try? handle.close() }

        func fail() -> Save? {
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
        let packedTitle = readCString(hdr, range: 56..<79)
        let device = readCString(hdr, range: 80..<143)

        if !wantHash.isEmpty {
            guard wantHash.count == hashDigits, wantHash.allSatisfy({ isLowerHex($0) }) else { return fail() }
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
                    outFD = open(targetPath, O_WRONLY | O_CREAT | O_EXCL, 0o644)
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

        let computed = files > 0 ? sha.finalize().prefix(hashDigits / 2).map { String(format: "%02x", $0) }.joined() : ""
        guard computed == wantHash else { return fail() }

        return Save(
            hash: computed.isEmpty ? nil : computed,
            saved: savedSec > 0 ? Date(timeIntervalSince1970: TimeInterval(savedSec)) : nil,
            device: device.isEmpty ? nil : device,
            titleID: packedTitle.isEmpty ? nil : packedTitle
        )
    }

    /// Validates an archive relative path: must start with `save/` or `save_device/`, with no leading slash, backslash, colon,
    /// empty segment, `.` or `..` segment.
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

    // MARK: - Local backup listing & restoration (`save-backups/`)

    /// Returns the newest restorable backup in `<appFolder>/save-backups/`, or nil when none exists.
    public static func latestBackup(in appFolder: URL, fileManager fm: FileManager = .default) -> BackupInfo? {
        listBackups(in: appFolder, fileManager: fm).first
    }

    /// Lists restorable backups under `<appFolder>/save-backups/` newest-first.
    public static func listBackups(in appFolder: URL, fileManager fm: FileManager = .default) -> [BackupInfo] {
        let root = backupsRoot(in: appFolder)
        guard let names = namesInByteOrder(root.path) else { return [] }
        var backups: [BackupInfo] = []
        for name in names where !name.hasPrefix(".") {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,
                  backupHasSavePayload(dir) else { continue }
            backups.append(BackupInfo(url: dir, name: name, label: displayLabel(forBackupName: name)))
        }
        return backups.reversed()
    }

    /// Restores the latest backup in `<appFolder>/save-backups/`:
    /// 1. Stages a clean copy of the chosen backup first (verifying it is readable before touching current saves).
    /// 2. Backs up any non-empty current local save into `save-backups/<timestamp> local` (protecting the source backup from pruning).
    /// 3. Atomically replaces `save` and `save_device` with full cleanup and rollback on any failure.
    /// 4. Clears `save.sync` so the next cloud launch compares fairly instead of letting cloud silently overwrite the restored save.
    public static func restoreLatestBackup(in appFolder: URL, now: Date = Date(),
                                           fileManager fm: FileManager = .default) throws -> BackupInfo {
        guard let chosen = latestBackup(in: appFolder, fileManager: fm) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try restoreBackup(chosen, in: appFolder, now: now, fileManager: fm)
        return chosen
    }

    public static func restoreBackup(_ backup: BackupInfo, in appFolder: URL, now: Date = Date(),
                                     fileManager fm: FileManager = .default) throws {
        guard backupHasSavePayload(backup.url) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let staging = appFolder.appendingPathComponent("save.restore-stage-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        for folder in saveFolders {
            let src = backup.url.appendingPathComponent(folder, isDirectory: true)
            if hasEntries(src.path) {
                try fm.copyItem(at: src, to: staging.appendingPathComponent(folder, isDirectory: true))
            }
        }
        if hasLocalSaveEntries(in: appFolder) {
            _ = try backupLocalSave(in: appFolder, now: now, protectedNames: [backup.name], fileManager: fm)
        }
        try replaceSaveFolders(in: appFolder, from: staging, fileManager: fm)
        clearBase(save: saveURL(in: appFolder))
    }

    // MARK: - Atomic folder swap & backup helpers

    private static func hasLocalSaveEntries(in appFolder: URL) -> Bool {
        saveFolders.contains { hasEntries(appFolder.appendingPathComponent($0, isDirectory: true).path) }
    }

    private static func backupHasSavePayload(_ dir: URL) -> Bool {
        saveFolders.contains { hasEntries(dir.appendingPathComponent($0, isDirectory: true).path) }
    }

    @discardableResult
    static func backupLocalSave(in appFolder: URL, now: Date, protectedNames: Set<String> = [],
                                fileManager fm: FileManager = .default) throws -> URL {
        let backupDir = try makeBackupDirectory(in: appFolder, side: "local", now: now,
                                                protectedNames: protectedNames, fileManager: fm)
        do {
            for folder in saveFolders {
                let src = appFolder.appendingPathComponent(folder, isDirectory: true)
                if hasEntries(src.path) {
                    try fm.copyItem(at: src, to: backupDir.appendingPathComponent(folder, isDirectory: true))
                }
            }
            return backupDir
        } catch {
            try? fm.removeItem(at: backupDir)
            throw error
        }
    }

    /// Replaces `appFolder/save` and `appFolder/save_device` from `stagedRoot` with unconditional partial-target cleanup and
    /// rollback on both initial install (no prior save) and overwrite (existing save).
    static func replaceSaveFolders(in appFolder: URL, from stagedRoot: URL, fileManager fm: FileManager = .default) throws {
        try fm.createDirectory(at: appFolder, withIntermediateDirectories: true)
        let rollbackRoot = appFolder.appendingPathComponent("save.rollback-\(UUID().uuidString)", isDirectory: true)
        var movedOld: [String] = []
        defer { try? fm.removeItem(at: rollbackRoot) }

        do {
            try fm.createDirectory(at: rollbackRoot, withIntermediateDirectories: true)
            for folder in saveFolders {
                let target = appFolder.appendingPathComponent(folder, isDirectory: true)
                if fm.fileExists(atPath: target.path) {
                    let backup = rollbackRoot.appendingPathComponent(folder, isDirectory: true)
                    try fm.moveItem(at: target, to: backup)
                    movedOld.append(folder)
                }
            }
            for folder in saveFolders {
                let incoming = stagedRoot.appendingPathComponent(folder, isDirectory: true)
                let target = appFolder.appendingPathComponent(folder, isDirectory: true)
                if fm.fileExists(atPath: incoming.path) {
                    try fm.moveItem(at: incoming, to: target)
                }
            }
            // Match engine folder invariant: `<appFolder>/save` exists even when only `save_device` had files.
            let mainSave = saveURL(in: appFolder)
            if !fm.fileExists(atPath: mainSave.path) {
                try fm.createDirectory(at: mainSave, withIntermediateDirectories: true)
            }
        } catch {
            // Unconditionally remove any half-moved target directories first, then restore prior folders when present.
            for folder in saveFolders {
                let target = appFolder.appendingPathComponent(folder, isDirectory: true)
                try? fm.removeItem(at: target)
            }
            for folder in movedOld {
                let backup = rollbackRoot.appendingPathComponent(folder, isDirectory: true)
                let target = appFolder.appendingPathComponent(folder, isDirectory: true)
                try? fm.moveItem(at: backup, to: target)
            }
            throw error
        }
    }

    private static func makeBackupDirectory(in appFolder: URL, side: String, now: Date,
                                            protectedNames: Set<String> = [],
                                            fileManager fm: FileManager) throws -> URL {
        let root = backupsRoot(in: appFolder)
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
        var keep = protectedNames
        keep.insert(candidateName)
        pruneBackups(in: root, side: side, protectedNames: keep, fileManager: fm)
        return created
    }

    private static func pruneBackups(in backupsRoot: URL, side: String, protectedNames: Set<String>, fileManager fm: FileManager) {
        guard let names = namesInByteOrder(backupsRoot.path) else { return }
        let candidates = names.filter { isAutoBackupName($0, side: side) && !protectedNames.contains($0) }
        guard candidates.count >= keepBackups else { return }
        let removeCount = candidates.count - (keepBackups - 1)
        for name in candidates.prefix(removeCount) {
            try? fm.removeItem(at: backupsRoot.appendingPathComponent(name, isDirectory: true))
        }
    }

    /// Matches `is_backup` in `save_sync.c`: `"YYYY-MM-DD HH.MM.SS <side>"` or `"YYYY-MM-DD HH.MM.SS <side> <k>"`.
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

    static func displayLabel(forBackupName name: String) -> String {
        // Convert `"2026-04-19 14.30.00 local"` into `"2026-04-19 14:30"` for readable UI text.
        let bytes = Array(name.utf8)
        if bytes.count >= 19,
           bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
           bytes[10] == UInt8(ascii: " "), bytes[13] == UInt8(ascii: "."), bytes[16] == UInt8(ascii: ".") {
            let datePart = String(decoding: bytes[0..<10], as: UTF8.self)
            let hh = String(decoding: bytes[11..<13], as: UTF8.self)
            let mm = String(decoding: bytes[14..<16], as: UTF8.self)
            return "\(datePart) \(hh):\(mm)"
        }
        return name
    }

    // MARK: - Low-level helpers

    private static func isLowerHex(_ ch: Character) -> Bool {
        guard let ascii = ch.asciiValue else { return false }
        return (ascii >= UInt8(ascii: "0") && ascii <= UInt8(ascii: "9"))
            || (ascii >= UInt8(ascii: "a") && ascii <= UInt8(ascii: "f"))
    }

    private static func putLE<T: FixedWidthInteger>(_ value: T, into bytes: inout [UInt8], at offset: Int) {
        withUnsafeBytes(of: value.littleEndian) { raw in
            for (i, b) in raw.enumerated() {
                bytes[offset + i] = b
            }
        }
    }

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

    private static func namesInByteOrder(_ dir: String) -> [String]? {
        guard let d = opendir(dir) else { return nil }
        defer { closedir(d) }
        var out: [[UInt8]] = []
        while let e = readdir(d) {
            let name = withUnsafeBytes(of: e.pointee.d_name) { raw in
                Array(raw.prefix(Int(e.pointee.d_namlen)))
            }
            if name == [46] || name == [46, 46] { continue }
            out.append(name)
        }
        return out.sorted { $0.lexicographicallyPrecedes($1) }.map { String(decoding: $0, as: UTF8.self) }
    }

    private static func hasEntries(_ dir: String) -> Bool {
        (namesInByteOrder(dir) ?? []).contains { $0 != ".DS_Store" }
    }

    private static func walk(_ abs: String, _ rel: String, _ visit: (String, String, stat) -> Bool) -> Bool {
        guard let list = namesInByteOrder(abs) else { return false }
        for name in list where name != ".DS_Store" {
            let a = abs + "/" + name
            let r = rel + "/" + name
            var st = stat()
            guard lstat(a, &st) == 0 else { return false }
            switch st.st_mode & S_IFMT {
            case S_IFDIR:
                guard visit(a, r, st), walk(a, r, visit) else { return false }
            case S_IFREG:
                guard visit(a, r, st) else { return false }
            default:
                continue
            }
        }
        return true
    }
}
