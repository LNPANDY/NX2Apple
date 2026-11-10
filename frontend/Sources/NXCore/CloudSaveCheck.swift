import CryptoKit
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
    package struct Save: Equatable {
        package var hash: String?
        package var saved: Date?
        package var device: String?
        package init(hash: String?, saved: Date? = nil, device: String? = nil) { self.hash = hash; self.saved = saved; self.device = device }
        package static let empty = Save(hash: nil)
    }

    /// What the check found, and so what happens before the start.
    package enum Outcome: Equatable {
        case same                 // both the same (or no save anywhere): the game starts
        case onlyCloudChanged     // the cloud's changed since the last sync, or this Mac has none: the game starts, the engine brings it in
        case onlyLocalChanged     // this Mac's changed since the last sync: the game starts, the engine sends it
        case noCloudSave          // the cloud has none: the game starts, the engine sends this Mac's
        case bothChanged          // both changed, or this Mac never synced and both have a save: the player chooses
        case unreadable           // the cloud's file could not be read: the player chooses

        /// The player is asked before the start.
        package var asks: Bool { self == .bothChanged || self == .unreadable }
    }

    /// The comparison of `ss_decide`, with the launcher's rule for asking: only when both changed. When one side is still the one
    /// last synced, the other is the only change and the way is clear (#957, the open question).
    package static func decide(local: Save, base: String?, cloud: Save?) -> Outcome {
        guard let cloud else { return .unreadable }
        let l = local.hash ?? "", r = cloud.hash ?? "", b = base ?? ""
        if r.isEmpty { return l.isEmpty ? .same : .noCloudSave }
        if l == r { return .same }
        if l.isEmpty { return .onlyCloudChanged }
        if !b.isEmpty && l == b { return .onlyCloudChanged }
        if !b.isEmpty && r == b { return .onlyLocalChanged }
        return .bothChanged
    }

    /// The player's answer to the question.
    package enum Choice: Equatable {
        case cloud        // bring in the cloud's save: this Mac's is kept in its backups
        case local        // this Mac's replaces the cloud's: the cloud's is kept in this Mac's backups
        case offline      // the cloud could not be read: play with this Mac's, send nothing until compared
    }

    /// `DM_SAVE_SYNC_CHOICE` for the engine (save_sync.c, read_choice): the choice names the cloud save it was made on, so a cloud save
    /// that changes between this check and the game's first save mount is not replaced.
    package static func environment(_ choice: Choice, cloud: Save?) -> [String: String] {
        let key = "DM_SAVE_SYNC_CHOICE"
        switch choice {
        case .offline: return [key: "offline"]
        case .cloud: return cloud?.hash.map { [key: "cloud:" + $0] } ?? [:]
        case .local: return [key: "local:" + (cloud?.hash ?? "none")]
        }
    }

    // MARK: - Reading the three saves

    /// The hash last synced, from `<save>.sync`: nil when there is none.
    package static func base(save: URL) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: save.path + ".sync")) else { return nil }
        var found: String?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("base\t") {
            let hash = line.dropFirst(5).prefix(hashDigits)
            if hash.count == hashDigits, hash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) { found = String(hash) }
        }
        return found
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
            guard hasEntries(dir) else { continue }
            guard walk(dir, folder, { abs, rel, st in
                let file = (st.st_mode & S_IFMT) == S_IFREG
                var guest = [UInt8](repeating: 0, count: 1024)
                var gl = getxattr(abs, "org.d2rmobile.guest-name", &guest, guest.count, 0, XATTR_NOFOLLOW)
                if gl < 0 { gl = 0 }
                let path = Array(rel.utf8)
                guard path.count <= Int(UInt16.max) else { return false }
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

    private static func put<T: FixedWidthInteger>(_ value: T, into bytes: inout [UInt8], at offset: Int) {
        withUnsafeBytes(of: value.littleEndian) { for (i, b) in $0.enumerated() { bytes[offset + i] = b } }
    }

    /// A folder's names in byte order, without . and ..; nil when it cannot be read.
    private static func names(_ dir: String) -> [String]? {
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

    private static func hasEntries(_ dir: String) -> Bool { (names(dir) ?? []).contains { $0 != ".DS_Store" } }

    private static func walk(_ abs: String, _ rel: String, _ visit: (String, String, stat) -> Bool) -> Bool {
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
