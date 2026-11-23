import CryptoKit
import Darwin
import Foundation

/// The check before a Mac game with cloud saves starts (#957): this Mac's save, the cloud's and the one last synced, compared the
/// way the engine compares them (dm/host/save_sync.c), so the player chooses before anything is replaced.
///
/// - This Mac's save is `DM_SAVE` and `DM_SAVE_device`, hashed as `ss_scan` hashes them: every entry in byte order of its name, a
///   folder before what it holds, Finder's `.DS_Store` and links left out; the hash runs over each entry's first 16 header bytes
///   (not its date), its path (`save/…`, `save_device/…`), its guest name (the `org.d2rmobile.guest-name` attribute) and its
///   contents. The first 16 bytes of the SHA-256, in hex. No files: no save, no hash.
/// - The cloud's is the header of `save.dmsync` (`ss_pack`): its hash, save time, title ID and device.
/// - The last synced is the `base` line of `<DM_SAVE>.sync` (`read_base`).
package enum CloudSaveCheck {
    /// One side's save: nil hash for no save.
    package struct Save: Equatable, Sendable {
        package var hash: String?
        package var saved: Date?
        package var device: String?
        package init(hash: String?, saved: Date? = nil, device: String? = nil) { self.hash = hash; self.saved = saved; self.device = device }
        package static let empty = Save(hash: nil)
    }

    /// What the check found, and so what happens before the start.
    package enum Outcome: Equatable, Sendable {
        case same                 // both the same (or no save anywhere): the game starts
        case onlyCloudChanged     // the cloud's changed since the last sync, or this Mac has none: the game starts, the engine brings it in
        case onlyLocalChanged     // this Mac's changed since the last sync: the game starts, the engine sends it
        case noCloudSave          // the cloud has none and this Mac never synced: the game starts, the engine sends this Mac's
        case missingCloudSave     // the cloud has none though this Mac synced one before: the player chooses
        case bothChanged          // both changed, or this Mac never synced and both have a save: the player chooses
        case unreadable           // the cloud's file could not be read: the player chooses

        /// The player is asked before the start.
        package var asks: Bool { self == .bothChanged || self == .unreadable || self == .missingCloudSave }
    }

    /// The comparison of `ss_decide`, with the launcher's rule for asking: only when both changed. When one side is still the one
    /// last synced, the other is the only change and the way is clear (#957, the open question).
    package static func decide(local: Save, base: String?, cloud: Save?) -> Outcome {
        guard let cloud else { return .unreadable }
        let l = local.hash ?? "", r = cloud.hash ?? "", b = base ?? ""
        if r.isEmpty {
            if l.isEmpty { return .same }
            return b.isEmpty ? .noCloudSave : .missingCloudSave
        }
        if l == r { return .same }
        if l.isEmpty { return .onlyCloudChanged }
        if !b.isEmpty && l == b { return .onlyCloudChanged }
        if !b.isEmpty && r == b { return .onlyLocalChanged }
        return .bothChanged
    }

    /// Environment variable passed to the engine (`save_sync.c`, `read_choice`), or the engine's own `key` for it.
    package enum Choice: Equatable, Sendable {
        case cloud        // bring in the cloud's save: this Mac's is kept in its backups
        case local        // this Mac's replaces the cloud's: the cloud's is kept in this Mac's backups
        case offline      // the cloud could not be read: play with this Mac's, send nothing until compared
    }

    /// `DM_SAVE_SYNC_CHOICE` for the engine (save_sync.c, read_choice), or the engine's own `key` for it: the choice names the cloud
    /// save it was made on, so a cloud save that changes between this check and the game's first save mount is not replaced.
    package static func environment(_ choice: Choice, cloud: Save?, key: String = "DM_SAVE_SYNC_CHOICE") -> [String: String] {
        switch choice {
        case .offline: return [key: "offline"]
        case .cloud: return cloud?.hash.map { [key: "cloud:" + $0] } ?? [:]
        case .local: return [key: "local:" + (cloud?.hash ?? "none")]
        }
    }

    // MARK: - The engine's report

    /// What the check found, from the line an engine's `save_sync_report` prints (dm/host/save_sync.c, nxkit-host
    /// `--save-sync-report`): `sync=<0|1> cloud=<1|0|-1> local=<hash|-> saved=<secs> … chash=<hash|-> csaved=<secs> …
    /// cdevice=<model|-> sametitle=<0|1> conflict=<0|1> pull=<0|1>`. nil for a line without `sync=`. `local` is nil when
    /// sync is off, as for a save that cannot be read: the game then starts without a question.
    package struct Report: Equatable {
        package var outcome: Outcome
        package var local: Save?
        package var cloud: Save?
        /// Why the cloud's save could not be used.
        package var reason: String?
    }

    package static func report(_ line: String) -> Report? {
        var f: [String: String] = [:]
        for pair in line.split(whereSeparator: \.isWhitespace) {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            f[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
        }
        guard let sync = f["sync"] else { return nil }
        func hash(_ key: String) -> String? { f[key].flatMap { $0 == "-" || $0.isEmpty ? nil : $0 } }
        func date(_ key: String) -> Date? { f[key].flatMap(Int64.init).flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil } }
        let local = Save(hash: hash("local"), saved: date("saved"))
        let cloud = Save(hash: hash("chash"), saved: date("csaved"), device: hash("cdevice"))
        guard sync == "1" else { return Report(outcome: .same, local: nil, cloud: nil, reason: nil) }
        switch f["cloud"] {
        case "-1": return Report(outcome: .unreadable, local: local, cloud: nil, reason: "The file in the cloud did not come in time.")
        case "1" where f["sametitle"] == "0":
            return Report(outcome: .unreadable, local: local, cloud: nil, reason: "The file in the cloud is another game’s save.")
        case "1": break
        default:
            let outcome: Outcome = f["conflict"] == "1" ? .missingCloudSave : (local.hash == nil ? .same : .noCloudSave)
            return Report(outcome: outcome, local: local, cloud: .empty, reason: nil)
        }
        let outcome: Outcome
        if f["conflict"] == "1" { outcome = .bothChanged }
        else if cloud.hash == nil { outcome = local.hash == nil ? .same : .noCloudSave }
        else if cloud.hash == local.hash { outcome = .same }
        else if f["pull"] == "1" { outcome = .onlyCloudChanged }
        else { outcome = .onlyLocalChanged }
        return Report(outcome: outcome, local: local, cloud: cloud, reason: nil)
    }

    // MARK: - Reading the three saves

    /// The hash last synced, from `<save>.sync`: nil when there is none.
    package static func base(save: URL) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: save.path + ".sync")) else { return nil }
        var found: String?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("base\t") {
            let hash = line.dropFirst(5).prefix(hashDigits)
            if hash.count == hashDigits, isLowerHexString(hash) { found = String(hash) }
        }
        return found
    }

    /// Atomically updates `<save>.sync` to `hash` (`write_base` in `save_sync.c`).
    @discardableResult
    package static func writeBase(save: URL, hash: String) -> Bool {
        guard hash.count == hashDigits, isLowerHexString(hash) else { return false }
        let syncPath = save.path + ".sync"
        let tmpPath = "\(syncPath).\(getpid()).tmp"
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

    /// Removes `<save>.sync` so the next sync treats the local save as changed relative to the cloud.
    package static func clearBase(save: URL) {
        try? FileManager.default.removeItem(atPath: save.path + ".sync")
    }

    /// True when `<save>.pull` exists, meaning a prior in-game cloud pull was interrupted and must be recovered by launching the game once.
    package static func hasPendingPullJournal(save: URL, fm: FileManager = .default) -> Bool {
        fm.fileExists(atPath: save.path + ".pull")
    }

    /// Hardware model identifier matching `device_name` in `save_sync.c` (`sysctlbyname("hw.model")`).
    package static func currentDeviceModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 else { return "unknown" }
        let model = String(cString: buf)
        return model.isEmpty ? "unknown" : model
    }

    static func isLowerHexString<S: StringProtocol>(_ s: S) -> Bool {
        s.allSatisfy { ch in
            guard let ascii = ch.asciiValue else { return false }
            return (ascii >= UInt8(ascii: "0") && ascii <= UInt8(ascii: "9"))
                || (ascii >= UInt8(ascii: "a") && ascii <= UInt8(ascii: "f"))
        }
    }

    static let hashDigits = 32
    private static let header = 8 + 4 + 4 + hashDigits + 8 + 24 + 64
    private static let magic = Array("DMSYNC1\n".utf8), end = Array("DMSYNCE\n".utf8)

    /// The cloud file's header: nil when it is not a packed save (or one cut off: its end marker is missing).
    package static func cloudSave(file: URL) -> Save? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: header), head.count == header, Array(head.prefix(8)) == magic,
              head.subdata(in: 8..<12).withUnsafeBytes({ $0.loadUnaligned(as: UInt32.self) }).littleEndian == 1,
              let size = try? handle.seekToEnd(), size >= UInt64(header + end.count) else { return nil }
        try? handle.seek(toOffset: size - UInt64(end.count))
        guard let tail = try? handle.read(upToCount: end.count), Array(tail) == end else { return nil }
        func text(_ range: Range<Int>) -> String {
            String(decoding: head.subdata(in: range).prefix { $0 != 0 }, as: UTF8.self)
        }
        let hash = text(16..<48)
        let saved = head.subdata(in: 48..<56).withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }.littleEndian
        return Save(hash: hash.isEmpty ? nil : hash, saved: saved > 0 ? Date(timeIntervalSince1970: TimeInterval(saved)) : nil,
                    device: text(80..<144))
    }

    /// The title ID a cloud file was packed for, in capitals ("" when it cannot be read).
    package static func cloudTitle(file: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file), let head = try? handle.read(upToCount: header), head.count == header else { return "" }
        try? handle.close()
        return String(decoding: head.subdata(in: 56..<80).prefix { $0 != 0 }, as: UTF8.self)
    }

    /// This Mac's committed save (`save` and `save` + `_device`), hashed as the engine's `ss_scan`. nil when it cannot be read.
    package static func localSave(save: URL) -> Save? {
        var sha = SHA256(), files = 0, newest: Int64 = 0
        for (i, folder) in ["save", "save_device"].enumerated() {
            let dir = i == 0 ? save.path : save.path + "_device"
            guard let has = hasEntriesChecked(dir) else { return nil }
            guard has else { continue }
            guard walk(dir, folder, { abs, rel, st in
                let file = (st.st_mode & S_IFMT) == S_IFREG
                var guest = [UInt8](repeating: 0, count: 1024)
                var gl = getxattr(abs, "org.d2rmobile.guest-name", &guest, guest.count, 0, XATTR_NOFOLLOW)
                if gl < 0 { gl = 0 }
                let path = Array(rel.utf8)
                guard path.count <= Int(UInt16.max), gl <= Int(UInt16.max) else { return false }
                var h = [UInt8](repeating: 0, count: 16)
                h[0] = file ? 2 : 1
                put(UInt16(path.count), into: &h, at: 2); put(UInt16(gl), into: &h, at: 4)
                put(file ? UInt64(st.st_size) : 0, into: &h, at: 8)
                sha.update(data: h); sha.update(data: path); sha.update(data: guest.prefix(gl))
                guard file else { return true }
                guard let stream = InputStream(fileAtPath: abs) else { return false }
                stream.open(); defer { stream.close() }
                var left = Int64(st.st_size), buffer = [UInt8](repeating: 0, count: 1 << 16)
                while left > 0 {
                    let n = stream.read(&buffer, maxLength: Int(min(Int64(buffer.count), left)))
                    if n <= 0 { return false }
                    sha.update(data: buffer.prefix(n)); left -= Int64(n)
                }
                files += 1
                newest = max(newest, Int64(st.st_mtimespec.tv_sec))
                return true
            }) else { return nil }
        }
        guard files > 0 else { return Save.empty }
        let hash = sha.finalize().prefix(hashDigits / 2).map { String(format: "%02x", $0) }.joined()
        return Save(hash: hash, saved: Date(timeIntervalSince1970: TimeInterval(newest)))
    }

    static func put<T: FixedWidthInteger>(_ value: T, into bytes: inout [UInt8], at offset: Int) {
        withUnsafeBytes(of: value.littleEndian) { for (i, b) in $0.enumerated() { bytes[offset + i] = b } }
    }

    /// A folder's names in byte order, without . and ..; nil when it cannot be read.
    static func names(_ dir: String) -> [String]? {
        guard let d = opendir(dir) else { return nil }
        defer { closedir(d) }
        var out: [[UInt8]] = []
        while let e = readdir(d) {
            let name = withUnsafeBytes(of: e.pointee.d_name) { raw in Array(raw.prefix(Int(e.pointee.d_namlen))) }
            if name == [46] || name == [46, 46] { continue }
            out.append(name)
        }
        return out.sorted { $0.lexicographicallyPrecedes($1) }.map { String(decoding: $0, as: UTF8.self) }
    }

    static func hasEntries(_ dir: String) -> Bool { hasEntriesChecked(dir) == true }

    /// Returns `true` if `dir` holds non-`.DS_Store` entries, `false` if missing (`ENOENT`) or empty, `nil` if unreadable.
    static func hasEntriesChecked(_ dir: String) -> Bool? {
        if let list = names(dir) {
            return list.contains { $0 != ".DS_Store" }
        }
        return errno == ENOENT ? false : nil
    }

    static func walk(_ abs: String, _ rel: String, _ visit: (String, String, stat) -> Bool) -> Bool {
        guard let list = names(abs) else { return false }
        for name in list where name != ".DS_Store" {
            let a = abs + "/" + name, r = rel + "/" + name
            var st = stat()
            guard lstat(a, &st) == 0 else { return false }
            switch st.st_mode & S_IFMT {
            case S_IFDIR: guard visit(a, r, st), walk(a, r, visit) else { return false }
            case S_IFREG: guard visit(a, r, st) else { return false }
            default: continue
            }
        }
        return true
    }
}
