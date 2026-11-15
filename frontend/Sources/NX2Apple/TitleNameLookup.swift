import Foundation
import NXCore

/// The game's names for a library entry whose app carries no `DMTitleNames` (packed before the engine wrote the key, or not built yet),
/// so no game has to be built again for its name to follow the launcher's language (LNPANDY/NX2Apple#895). From the game's own
/// control data, offline, in this order:
/// 1. a `control.nacp` an earlier build left in its build folder (`<title ID>_build/extract/v<version>/`, the NSP script's),
/// 2. the base game's package (NSP, NSZ, XCI, XCZ) with the game folder's keys or the saved keys: `PackageControl` reads the control data alone, a few
///    kilobytes, where an extraction takes minutes. No engine tool is needed.
/// A game with neither (the package deleted, no keys or keys too old for it) keeps showing the bundle name. Blocking: call it off the main thread.
enum TitleNameLookup {
    /// The names from the game's control data, nil when none could be read.
    static func names(for game: LibraryGame, fallbackKeys: String = "", fm: FileManager = .default) -> [String: String]? {
        if let leftover = leftoverControl(for: game, fm: fm), let data = try? Data(contentsOf: leftover) {
            let names = GameTitleNames.names(nacp: data)
            if !names.isEmpty { return names }
        }
        if let nup = nupFile(of: game, fm: fm), let data = readNupControl(at: nup, fm: fm) {
            let names = GameTitleNames.names(nacp: data)
            if !names.isEmpty { return names }
        }
        guard let package = packageFile(of: game, fm: fm) else { return nil }
        let tid = UInt64(game.titleID, radix: 16)
        for keys in candidateKeys(of: game, fallbackKeys: fallbackKeys, fm: fm) {
            guard let data = PackageControl.read(package: package, keysFile: keys, titleID: tid) else { continue }
            let names = GameTitleNames.names(nacp: data)
            if !names.isEmpty { return names }
        }
        return nil
    }

    /// The human-readable display version of an unbuilt game's highest available package (`control.nacp` at `0x3060..<0x3070`),
    /// falling back to a local unmounted iOS bundle/IPA Info.plist when no readable source control data is present.
    static func sourceVersion(for game: LibraryGame, fallbackKeys: String = "", fm: FileManager = .default) -> String? {
        if let leftover = leftoverControl(for: game, fm: fm), let data = try? Data(contentsOf: leftover),
           let v = GameTitleNames.displayVersion(nacp: data) {
            return v
        }
        let tid = UInt64(game.titleID, radix: 16)
        let updateTID = tid.map { $0 | 0x800 }
        let keysList = candidateKeys(of: game, fallbackKeys: fallbackKeys, fm: fm)
        for updatePkg in updatePackages(of: game, fm: fm) {
            for keys in keysList {
                if let data = PackageControl.read(package: updatePkg, keysFile: keys, titleID: updateTID),
                   let v = GameTitleNames.displayVersion(nacp: data) {
                    return v
                }
            }
        }
        if let nup = nupFile(of: game, fm: fm), let data = readNupControl(at: nup, fm: fm),
           let v = GameTitleNames.displayVersion(nacp: data) {
            return v
        }
        if let basePkg = packageFile(of: game, fm: fm) {
            for keys in keysList {
                // Multi-NCA XCIs bundle both Base and Update Control NCAs: prefer the Update Control NCA when present.
                if let data = PackageControl.read(package: basePkg, keysFile: keys, titleID: updateTID),
                   let v = GameTitleNames.displayVersion(nacp: data) {
                    return v
                }
            }
        }
        for builtIOS in [game.iosAppPath, game.ipaPath] where !builtIOS.isEmpty && fm.fileExists(atPath: builtIOS) {
            let v = LiveConsoleDriver.version(at: builtIOS)
            if !v.isEmpty { return v }
        }
        return nil
    }

    /// The control data a build of this game left in its build folder: beside the base package (the NSP script's default), in the
    /// output folder or in the game's folder. The highest version's, as the build reads it.
    static func leftoverControl(for game: LibraryGame, fm: FileManager = .default) -> URL? {
        var folders: [String] = [game.outputDirectory, game.sourceFolder, (game.appPath as NSString).deletingLastPathComponent]
        folders += (game.inputs["base"] ?? []).map { ($0 as NSString).deletingLastPathComponent }
        for folder in folders where !folder.isEmpty {
            let extract = URL(fileURLWithPath: folder).appendingPathComponent(game.titleID + "_build/extract", isDirectory: true)
            guard let versions = try? fm.contentsOfDirectory(atPath: extract.path) else { continue }
            let found = versions.filter { $0.hasPrefix("v") }
                .sorted { (Int($0.dropFirst()) ?? -1) > (Int($1.dropFirst()) ?? -1) }
                .map { extract.appendingPathComponent($0 + "/control.nacp") }
                .first { fm.fileExists(atPath: $0.path) }
            if let found { return found }
        }
        return nil
    }

    /// The keys file and the base game's package when both are files on disk. A game folder (a Switch 2 game's) or a NUP has no package to read.
    static func packageInputs(of game: LibraryGame, fallbackKeys: String = "", fm: FileManager = .default) -> (keys: String, package: String)? {
        guard let package = packageFile(of: game, fm: fm),
              let keys = candidateKeys(of: game, fallbackKeys: fallbackKeys, fm: fm).first else { return nil }
        return (keys, package)
    }

    static func packageFile(of game: LibraryGame, fm: FileManager = .default) -> String? {
        guard let package = game.inputs["base"]?.first, !package.isEmpty,
              ["nsp", "nsz", "xci", "xcz"].contains((package as NSString).pathExtension.lowercased()) else { return nil }
        var dir: ObjCBool = false
        guard fm.fileExists(atPath: package, isDirectory: &dir), !dir.boolValue else { return nil }
        return package
    }

    static func updatePackages(of game: LibraryGame, fm: FileManager = .default) -> [String] {
        let raw = game.inputs["update"] ?? []
        let valid = raw.filter { path in
            guard !path.isEmpty, ["nsp", "nsz", "xci", "xcz"].contains((path as NSString).pathExtension.lowercased()) else { return false }
            var dir: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &dir) && !dir.boolValue
        }
        return valid.sorted { a, b in
            let va = versionHint(in: a), vb = versionHint(in: b)
            if va != vb { return va > vb }
            return a > b
        }
    }

    private static func versionHint(in path: String) -> Int {
        let name = (path as NSString).lastPathComponent
        guard let r = name.range(of: #"\[v(\d+)\]"#, options: [.regularExpression, .caseInsensitive]) else { return -1 }
        let digits = name[r].dropFirst(2).dropLast()
        return Int(digits) ?? -1
    }

    static func nupFile(of game: LibraryGame, fm: FileManager = .default) -> String? {
        let candidates = (game.inputs["base"] ?? []) + (game.inputs[GameLibrary.folderInput] ?? [])
        for candidate in candidates where !candidate.isEmpty {
            var dir: ObjCBool = false
            guard fm.fileExists(atPath: candidate, isDirectory: &dir) else { continue }
            if !dir.boolValue && (candidate as NSString).pathExtension.lowercased() == "nup" { return candidate }
            if dir.boolValue, let entries = try? fm.contentsOfDirectory(atPath: candidate) {
                let nups = entries.filter { ($0 as NSString).pathExtension.lowercased() == "nup" }.sorted()
                if nups.count == 1 {
                    let full = (candidate as NSString).appendingPathComponent(nups[0])
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue { return full }
                }
            }
        }
        return nil
    }

    /// Reads `T_NACP` (`type == 2`) from the highest-version update (or base) package's `meta` block in a v1 `.nup` container (`scripts/pack_nup.py`).
    static func readNupControl(at path: String, fm: FileManager = .default) -> Data? {
        guard fm.fileExists(atPath: path), let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let actualSize = try? handle.seekToEnd(), actualSize >= 0x80 else { return nil }
        try? handle.seek(toOffset: 0)
        guard let superData = try? handle.read(upToCount: 0x80), superData.count == 0x80 else { return nil }
        let sb = [UInt8](superData)
        guard sb[0] == 0x4E, sb[1] == 0x55, sb[2] == 0x50, sb[3] == 0x01 else { return nil }   // "NUP\x01"
        func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | (UInt16(b[o + 1]) << 8) }
        func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
            UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
        }
        func u64(_ b: [UInt8], _ o: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(b[o + i]) << (i * 8) }
            return v
        }
        let hsize = u16(sb, 4)
        let tocOff = u64(sb, 8)
        let tocSize = u64(sb, 16)
        let blob = u64(sb, 56)
        let fsize = u64(sb, 64)
        let npkg = u32(sb, 72)
        let flags = u32(sb, 76)
        guard hsize >= 0x80, tocOff == UInt64(hsize), flags == 0, fsize == actualSize,
              tocSize >= 0x30, tocSize <= 32 << 20,
              !tocOff.addingReportingOverflow(tocSize).overflow,
              tocOff + tocSize <= blob, blob <= actualSize,
              npkg > 0, npkg <= 4096 else { return nil }

        try? handle.seek(toOffset: tocOff)
        guard let tocData = try? handle.read(upToCount: Int(tocSize)), tocData.count == Int(tocSize) else { return nil }
        let toc = [UInt8](tocData)
        guard toc[0] == 0x54, toc[1] == 0x4F, toc[2] == 0x43, toc[3] == 0x01,   // "TOC\x01"
              u32(toc, 4) == npkg else { return nil }
        let pkgBytes = Int(npkg) * 0x40
        guard pkgBytes <= toc.count - 0x30 else { return nil }

        struct MetaRef { let kind: UInt8; let version: UInt32; let off: UInt64; let size: UInt32 }
        var metas: [MetaRef] = []
        for i in 0..<Int(npkg) {
            let base = 0x30 + i * 0x40
            let version = u32(toc, base + 20)
            let kind = toc[base + 24]
            let metaOff = u64(toc, base + 32)
            let metaSize = u32(toc, base + 40)
            guard (kind == 0 || kind == 1), metaSize >= 8, metaSize <= 4 << 20,
                  !metaOff.addingReportingOverflow(UInt64(metaSize)).overflow,
                  metaOff + UInt64(metaSize) <= actualSize else { continue }
            metas.append(MetaRef(kind: kind, version: version, off: metaOff, size: metaSize))
        }
        metas.sort { a, b in
            if a.kind != b.kind { return a.kind > b.kind }   // update (1) ahead of base (0)
            return a.version > b.version
        }
        for m in metas {
            try? handle.seek(toOffset: m.off)
            guard let rawMeta = try? handle.read(upToCount: Int(m.size)), rawMeta.count == Int(m.size) else { continue }
            let bytes = [UInt8](rawMeta)
            var p = 0
            while p <= bytes.count - 8 {
                let t = u16(bytes, p)
                let n = Int(u32(bytes, p + 4))
                p += 8
                guard n >= 0, n <= bytes.count - p else { break }
                if t == 2 { return Data(bytes[p..<(p + n)]) }   // T_NACP
                p += n
            }
        }
        return nil
    }

    static func candidateKeys(of game: LibraryGame, fallbackKeys: String = "", fm: FileManager = .default) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for candidate in [(game.inputs["keys"]?.first ?? ""), fallbackKeys] where !candidate.isEmpty {
            var dir: ObjCBool = false
            guard fm.fileExists(atPath: candidate, isDirectory: &dir), !dir.boolValue else { continue }
            let canonical = URL(fileURLWithPath: candidate).standardizedFileURL.path
            if seen.insert(canonical).inserted { result.append(candidate) }
        }
        return result
    }

    /// Fingerprint of the inputs that affect a control-data lookup, so configuring `prod.keys`, adding an update or finishing a package copy retries automatically.
    static func attemptSignature(for game: LibraryGame, fallbackKeys: String = "", fm: FileManager = .default) -> String {
        let leftover = leftoverControl(for: game, fm: fm)?.path ?? ""
        let localKeys = game.inputs["keys"]?.first ?? ""
        let package = nupFile(of: game, fm: fm) ?? (game.inputs["base"]?.first ?? "")
        let updates = (game.inputs["update"] ?? []).map { fileSignature($0, fm: fm) }.joined(separator: ",")
        let iosPlist = game.iosAppPath.isEmpty ? "" : (game.iosAppPath + "/Info.plist")
        return [
            game.titleID.uppercased(),
            fileSignature(leftover, fm: fm),
            fileSignature(localKeys, fm: fm),
            fileSignature(fallbackKeys, fm: fm),
            fileSignature(package, fm: fm),
            updates,
            fileSignature(iosPlist, fm: fm),
            fileSignature(game.ipaPath, fm: fm),
        ].joined(separator: "\n")
    }

    private static func fileSignature(_ path: String, fm: FileManager) -> String {
        guard !path.isEmpty else { return "" }
        var dir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &dir), !dir.boolValue,
              let attr = try? fm.attributesOfItem(atPath: path) else { return "" }
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        let inode = attr[.systemFileNumber] as? UInt64 ?? 0
        let size = attr[.size] as? UInt64 ?? 0
        let mtime = (attr[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(canonical)|\(inode)|\(size)|\(String(format: "%.6f", mtime))"
    }
}

extension GameLibrary {
    /// Looks up the names and unbuilt package version of games off the main thread, one game at a time, and keeps what it finds.
    /// Each input state is tried once: configuring keys, adding an update or replacing an incomplete package changes the signature
    /// and allows a fresh lookup.
    func fillMissingTitleNames() {
        let fallbackKeys = keysFile()
        let wanted: [(game: LibraryGame, signature: String)] = games.compactMap { game in
            guard !game.titleID.hasPrefix("/"),
                  (game.titleNames.isEmpty || game.primary == .build) else { return nil }
            let sig = TitleNameLookup.attemptSignature(for: game, fallbackKeys: fallbackKeys)
            guard TitleNameAttempts.shared.begin(sig) else { return nil }
            return (game, sig)
        }
        guard !wanted.isEmpty else { return }
        TitleNameAttempts.queue.async { [weak self] in
            for item in wanted {
                let currentSig = TitleNameLookup.attemptSignature(for: item.game, fallbackKeys: fallbackKeys)
                let names = item.game.titleNames.isEmpty ? TitleNameLookup.names(for: item.game, fallbackKeys: fallbackKeys) : nil
                let version = item.game.primary == .build ? TitleNameLookup.sourceVersion(for: item.game, fallbackKeys: fallbackKeys) : nil
                TitleNameAttempts.shared.finish(item.signature, recordCompleted: currentSig == item.signature)
                guard names != nil || version != nil else { continue }
                DispatchQueue.main.async {
                    guard let self,
                          let existing = self.games.first(where: { $0.id == item.game.id }),
                          existing.titleID == item.game.titleID else { return }
                    let latestSig = TitleNameLookup.attemptSignature(for: existing, fallbackKeys: self.keysFile())
                    guard latestSig == currentSig else { return }
                    self.setPackageMetadata(names: names, sourceVersion: version, for: item.game.id)
                }
            }
        }
    }
}

/// Input signatures looked up this launch, and the serial queue the lookups run on one after another.
enum TitleNameAttempts {
    static let queue = DispatchQueue(label: "nx2apple.title-names", qos: .utility)
    static let shared = LockedSet()

    final class LockedSet: @unchecked Sendable {
        private let lock = NSLock()
        private var completed: Set<String> = []
        private var inFlight: Set<String> = []

        func contains(_ signature: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return completed.contains(signature) || inFlight.contains(signature)
        }

        func insert(_ signature: String) {
            lock.lock()
            completed.insert(signature)
            lock.unlock()
        }

        func begin(_ signature: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !completed.contains(signature), !inFlight.contains(signature) else { return false }
            inFlight.insert(signature)
            return true
        }

        func finish(_ signature: String, recordCompleted: Bool = true) {
            lock.lock()
            inFlight.remove(signature)
            if recordCompleted { completed.insert(signature) }
            lock.unlock()
        }

        func reset() {
            lock.lock()
            completed.removeAll()
            inFlight.removeAll()
            lock.unlock()
        }
    }
}
