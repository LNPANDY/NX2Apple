import Foundation

/// A game's cheat files, as the host reads them (dm/host/hle_cheats.c, and docs/frontends.md "Cheats", the contract for front
/// ends): Atmosphere-format `<build ID>.txt` files in a folder, and the player's switches beside them in `<build ID>.enabled`.
/// This file holds the logic only (where the folder is, which build the game is, how a cheat file reads, importing, the switches,
/// the copy to a device), so the sheet (CheatsView.swift) stays a view and the tests need no window.
///
/// The folder: `DM_CHEATS`, else `<DM_ROOT>/cheats`. The Mac app's launcher (dm/mac/launcher.c) sets DM_ROOT to
/// ~/Library/Application Support/nxnative/<title ID> whatever the library folder is, so the files live in
/// `<that>/cheats`. The iPhone app's `main.m` (fork patch ios-game-data-folder) sets DM_CHEATS to
/// `Documents/games/<title ID>/cheats`, next to the game's data, which is where the copy to the device goes.
struct CheatFiles {
    let titleID: String   // upper case
    let folder: URL       // the game's cheats folder on this Mac

    /// A cheat file found in the folder.
    struct Found: Equatable, Identifiable {
        let buildID: String   // 16 hex digits, upper case
        let url: URL
        var id: String { buildID }
    }

    /// One entry of a cheat file, the way the host parses it (parse_file).
    struct Cheat: Equatable, Identifiable {
        enum Kind: Equatable { case cheat, master, label }
        var name: String
        var key: String          // the name in `.enabled`: `Name`, `Name #2` for the second entry of that name
        var kind: Kind
        var section = ""
        var broken = false       // a malformed line: the host keeps the cheat off
        var once = false         // runs one pass, set from the game window (the meta file): never in `.enabled`
        var pairOff = false      // the off half of an on / off pair: the on half carries the switch
        var id: String { key }
        /// Does it get a switch here: a plain cheat that the host would save as on.
        var switchable: Bool { kind == .cheat && !broken && !once && !pairOff }
    }

    init(titleID: String, folder: URL) {
        self.titleID = titleID.uppercased()
        self.folder = folder
    }

    init(titleID: String, support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) {
        self.init(titleID: titleID, folder: Self.macFolder(titleID: titleID, support: support))
    }

    // ---- where things are ----

    /// The Mac app's cheats folder: DM_ROOT/cheats with DM_ROOT as dm/mac/launcher.c sets it.
    static func macFolder(titleID: String, support: URL) -> URL {
        support.appendingPathComponent("nxnative").appendingPathComponent(titleID.uppercased()).appendingPathComponent("cheats")
    }

    /// The folder in the iPhone app's data container, where main.m points DM_CHEATS.
    static func deviceFolder(titleID: String) -> String { "Documents/games/\(titleID.uppercased())/cheats" }

    /// The build ID the cheat files are named by: the first 16 hex digits of the main NSO's build ID, upper case. The packed app
    /// records the whole ID in `dm/main.fixups.tsv` (`# BUILD_ID <hex>`): the Mac app under Contents/Resources, the iOS app at its root.
    static func buildID(appPath: String, iosAppPath: String) -> String? {
        let candidates = [appPath.isEmpty ? nil : appPath + "/Contents/Resources/dm/main.fixups.tsv",
                          iosAppPath.isEmpty ? nil : iosAppPath + "/dm/main.fixups.tsv"]
        for path in candidates.compactMap({ $0 }) {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8), let id = buildID(fixups: text) else { continue }
            return id
        }
        return nil
    }

    static func buildID(fixups text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("#") {
            let fields = line.dropFirst().split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, fields[0] == "BUILD_ID", fields[1].count >= 16, isHex(fields[1].prefix(16)) else { continue }
            return fields[1].prefix(16).uppercased()
        }
        return nil
    }

    static func isHex<S: StringProtocol>(_ s: S) -> Bool { !s.isEmpty && s.allSatisfy(\.isHexDigit) }

    /// The folders the host scans for `<build ID>.txt`, in its order (scan_dirs): the flat folder, the Atmosphere tree under it,
    /// and the tree with the folder itself as the "atmosphere" half.
    var scanFolders: [URL] {
        [folder,
         folder.appendingPathComponent("atmosphere/contents/\(titleID)/cheats"),
         folder.appendingPathComponent("contents/\(titleID)/cheats")]
    }

    func enabledFile(_ buildID: String) -> URL { folder.appendingPathComponent(buildID.uppercased() + ".enabled") }
    func metaFile(_ buildID: String) -> URL { folder.appendingPathComponent(buildID.uppercased() + ".meta.tsv") }
    /// The master switch: while this file exists no cheat of the game runs, the switches kept.
    var masterOffFile: URL { folder.appendingPathComponent(".cheats-off-\(titleID)") }
    /// The host's own safe-mode flag (Mac only): a front end leaves it alone, and may say what it means.
    var runningFlag: URL { folder.appendingPathComponent(".cheats-running-\(titleID)") }

    // ---- the files ----

    /// The cheat files in the folder, one per build, in the host's order (the first of a build wins), by build ID. A file counts when
    /// its name starts with 16 hex digits and ends in .txt (collect_dir, name_hex16).
    func found() -> [Found] {
        var seen = Set<String>(), out: [Found] = []
        for dir in scanFolders {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
            for name in names where name.count >= 5 && name.lowercased().hasSuffix(".txt") && Self.isHex(name.prefix(16)) && name.count >= 16 {
                let id = name.prefix(16).uppercased()
                guard seen.insert(id).inserted else { continue }
                out.append(Found(buildID: id, url: dir.appendingPathComponent(name)))
            }
        }
        return out.sorted { $0.buildID < $1.buildID }
    }

    /// The cheats of a build's file with the meta file applied, nil when the file cannot be read.
    func cheats(of file: Found) -> [Cheat]? {
        guard let data = try? Data(contentsOf: file.url) else { return nil }
        let metaURL = file.url.deletingPathExtension().appendingPathExtension("meta.tsv")
        let meta = (try? String(contentsOf: metaURL, encoding: .utf8)) ?? (try? String(contentsOf: metaFile(file.buildID), encoding: .utf8))
        return Self.parse(data, meta: meta)
    }

    // ---- the switches ----

    /// `<build ID>.enabled`: one key per line. Missing or unreadable: nothing is on.
    func enabled(_ buildID: String) -> Set<String> {
        guard let text = try? String(contentsOf: enabledFile(buildID), encoding: .utf8) else { return [] }
        return Self.parseEnabled(text)
    }

    static func parseEnabled(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: \.isNewline).map(String.init))   // "\r\n" is one Character in Swift: isNewline, not == "\n"
    }

    /// The file's text for the switches that are on: the keys of the plain cheats in the file's own order, as the host writes it
    /// (masters are always on, labels never run, one-pass cheats and the off half of a pair are never listed).
    static func enabledText(_ cheats: [Cheat], on: Set<String>) -> String {
        cheats.filter { $0.switchable && on.contains($0.key) }.map { $0.key + "\n" }.joined()
    }

    /// Writes `<build ID>.enabled` with the keys that are on, through a temporary file that replaces the old one, so it is never half
    /// written. The folder is made when it is missing.
    func writeEnabled(_ buildID: String, cheats: [Cheat], on: Set<String>) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(Self.enabledText(cheats, on: on).utf8).write(to: enabledFile(buildID), options: .atomic)
    }

    var masterOn: Bool { !FileManager.default.fileExists(atPath: masterOffFile.path) }

    func setMaster(_ on: Bool) throws {
        if on { if !masterOn { try FileManager.default.removeItem(at: masterOffFile) } }
        else {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: masterOffFile)
        }
    }

    /// The last run ended with cheats on and without a clean exit: the game starts with every cheat off until its panel restores them.
    var safeMode: Bool { FileManager.default.fileExists(atPath: runningFlag.path) }

    // ---- reading a cheat file (parse_file) ----

    private struct Entry { var cheat: Cheat; var words = 0; var junk = false; var pairName = ""; var offByMeta = false; var nd = false }

    private static let nameMax = 127   // characters of a [Name] header the host keeps (NAME_MAX 128 with its terminator)
    private static let cheatMax = 256  // cheats in one file: the host skips the rest

    /// Entries as the host parses them: `[Name]` and `{Name}` start one, 8-digit hex words are its code, and a header glued to a
    /// word ("00000008[Next]") is split off. An entry without code words is a label (credits, an EdiZon section marker that sets
    /// the section of the entries after it). A line mixing words with other text, or a hex token that is not whole words, keeps
    /// its cheat off (broken). The meta file of scripts/cheat_anchor.py then marks one-pass cheats and on / off pairs.
    static func parse(_ data: Data, meta: String? = nil) -> [Cheat] {
        let raw = [UInt8](data)
        func ws(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }
        func hex(_ c: UInt8) -> Bool { (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66) }
        var text: [UInt8] = []
        text.reserveCapacity(raw.count * 2)
        for (i, c) in raw.enumerated() {
            if (c == 0x5B || c == 0x7B) && i >= 8, raw[(i - 8)..<i].allSatisfy(hex), i == 8 || ws(raw[i - 9]) { text.append(0x0B) }
            text.append(c)
        }

        var entries: [Entry] = []
        var section = ""
        for piece in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == 0x0A || $0 == 0x0B }) {
            var p = piece[...]
            while let f = p.first, f == 0x20 || f == 0x09 { p = p.dropFirst() }
            var rest = p
            if let f = p.first, f == 0x5B || f == 0x7B {
                let end: UInt8 = f == 0x5B ? 0x5D : 0x7D
                guard let q = p.dropFirst().firstIndex(of: end), q > p.startIndex + 1, entries.count < cheatMax else {
                    // an unclosed or empty header, or past the limit: the entry is skipped, and its lines belong to nothing
                    entries.append(Entry(cheat: Cheat(name: "", key: "", kind: .label), words: -1))
                    continue
                }
                var keep = min(q - (p.startIndex + 1), nameMax)
                while keep > 0, (p[p.startIndex + 1 + keep] & 0xC0) == 0x80 { keep -= 1 }
                let name = String(decoding: p[(p.startIndex + 1)..<(p.startIndex + 1 + keep)], as: UTF8.self)
                var cheat = Cheat(name: name, key: name, kind: f == 0x7B ? .master : .cheat)
                let mark = sectionMarker(name)
                if let m = mark, m.start { section = m.name }
                cheat.section = section
                if let m = mark, !m.start { section = "" }
                let earlier = entries.filter { $0.words >= 0 && $0.cheat.name == name }.count
                if earlier > 0 { cheat.key = "\(name) #\(earlier + 1)" }
                entries.append(Entry(cheat: cheat))
                rest = p[(q + 1)...]
                while let r = rest.first, r == 0x20 || r == 0x09 || r == 0x0D { rest = rest.dropFirst() }
                if rest.isEmpty { continue }
            }
            guard var current = entries.last, current.words >= 0 else { continue }   // words before any header, or after a skipped one
            var ngot = 0, prose = false, oddhex = false
            for token in rest.split(whereSeparator: { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) {
                if !token.allSatisfy(hex) { prose = true; continue }
                if token.count % 8 != 0 { oddhex = true; continue }
                ngot += token.count / 8
            }
            if ngot == 0 && !prose && !oddhex { continue }
            if prose && ngot == 0 && !oddhex { current.junk = true }
            else if prose || oddhex { current.cheat.broken = true }
            else { current.words += ngot }
            entries[entries.count - 1] = current
        }
        entries.removeAll { $0.words < 0 }

        for i in entries.indices where !entries[i].cheat.broken {
            if entries[i].words == 0 && entries[i].junk { entries[i].cheat.broken = true }
            else if entries[i].words == 0 { entries[i].cheat.kind = .label }
        }
        if let meta { applyMeta(meta, to: &entries) }
        return entries.map(\.cheat)
    }


    private static func applyMeta(_ meta: String, to entries: inout [Entry]) {
        var head: [String: Int]?
        var cursor = 0
        for line in meta.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) where !line.hasPrefix("#") && !line.isEmpty {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let h = head else {
                var map: [String: Int] = [:]
                for (i, n) in f.enumerated() { map[n] = i }
                if map["name"] == nil { return }
                head = map
                continue
            }
            func col(_ n: String) -> String { h[n].flatMap { $0 < f.count ? f[$0] : nil } ?? "" }
            let kind = col("kind")
            if kind == "unresolved" { continue }
            var j = cursor
            while j < entries.count && entries[j].cheat.name != col("name") { j += 1 }
            if j >= entries.count { continue }
            cursor = j + 1
            if !col("section").isEmpty && entries[j].cheat.section.isEmpty { entries[j].cheat.section = col("section") }
            if col("once") == "1" { entries[j].cheat.once = true }
            if kind == "patch-off" { entries[j].offByMeta = true }
            entries[j].pairName = col("pair")
            // a typed address held by name only (no code words): the host runs it as a never-decrease cheat, not a label
            let address = col("address"), type = col("type")
            if col("action") == "never-decrease", entries[j].words == 0, !type.isEmpty, let colon = address.firstIndex(of: ":"),
               (Int(address[..<colon]) ?? 0) <= 1 {
                entries[j].nd = true
                entries[j].cheat.kind = .cheat
            }
        }
        linkPairs(&entries)
    }

    private static func linkPairs(_ entries: inout [Entry]) {
        var pair = [Int?](repeating: nil, count: entries.count)
        func plain(_ e: Entry) -> Bool { e.cheat.kind == .cheat && !e.nd && !e.cheat.broken }
        for i in entries.indices where !entries[i].pairName.isEmpty && pair[i] == nil && plain(entries[i]) {
            guard let j = entries.indices.first(where: { $0 != i && pair[$0] == nil && plain(entries[$0]) && entries[$0].cheat.name == entries[i].pairName }) else { continue }
            pair[i] = j; pair[j] = i
        }
        for i in entries.indices where pair[i] == nil && plain(entries[i]) {
            guard let a = onOffSplit(entries[i].cheat.name) else { continue }
            for j in (i + 1)..<max(entries.count, i + 1) where pair[j] == nil && plain(entries[j]) {
                guard let b = onOffSplit(entries[j].cheat.name), a.off != b.off, a.base.lowercased() == b.base.lowercased() else { continue }
                pair[i] = j; pair[j] = i
                entries[i].offByMeta = a.off; entries[j].offByMeta = b.off
                break
            }
        }
        for i in entries.indices where pair[i] != nil && entries[i].offByMeta { entries[i].cheat.pairOff = true }
    }

    /// `[--SectionStart:Name--]` and `[--SectionEnd:Name--]`, EdiZon's markers.
    private static func sectionMarker(_ name: String) -> (start: Bool, name: String)? {
        guard name.count >= 4, name.hasSuffix("--") else { return nil }
        for (prefix, start) in [("--SectionStart:", true), ("--SectionEnd:", false)] where name.hasPrefix(prefix) {
            return (start, String(name.dropFirst(prefix.count).dropLast(2)))
        }
        return nil
    }

    /// "X - on" / "X - off" (also "X on", "X: off", "X (off)"): the base name and which half, nil when the name has no such form
    /// (onoff_split).
    private static func onOffSplit(_ name: String) -> (base: String, off: Bool)? {
        var s = Substring(name)
        while let l = s.last, l.isWhitespace { s = s.dropLast() }
        if let l = s.last, l == ")" || l == "]" { s = s.dropLast() }
        let off: Bool
        if s.count >= 3, s.suffix(3).lowercased() == "off" { off = true; s = s.dropLast(3) }
        else if s.count >= 2, s.suffix(2).lowercased() == "on" { off = false; s = s.dropLast(2) }
        else { return nil }
        var sep = false
        while let l = s.last, " -:_([".contains(l) { s = s.dropLast(); sep = true }
        guard sep, !s.isEmpty else { return nil }
        return (String(s), off)
    }

    // ---- importing ----

    struct ImportResult: Equatable {
        var imported: [String] = []   // build IDs of the files now in the folder
        var skipped: [String] = []    // file names that carry no build ID, so no version of the game to match
    }

    /// The build ID a cheat file's name carries: `<16 hex>.txt`, or the 32 digits a build ID is written with elsewhere (cut to 16,
    /// the way cheat sites and Atmosphere name the file). Nil for any other name.
    static func buildID(ofFileNamed name: String) -> String? {
        guard name.lowercased().hasSuffix(".txt") else { return nil }
        let stem = String(name.dropLast(4))
        guard isHex(stem), stem.count == 16 || stem.count == 32 else { return nil }
        return stem.prefix(16).uppercased()
    }

    /// The cheat files under the picked items: files as they are, folders searched (a Ryujinx folder, or an SD card's
    /// `atmosphere/contents/<title ID>/cheats`, or the card itself). Inside a folder, a file under another game's title ID is not
    /// this game's and stays out; hidden files and the folder's own state files are not cheat files.
    func candidates(in urls: [URL]) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            guard isDir.boolValue else { out.append(url); continue }
            guard let walk = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let file as URL in walk {
                guard file.pathExtension.lowercased() == "txt", (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let below = file.deletingLastPathComponent().pathComponents.dropFirst(url.pathComponents.count)
                let ids = below.filter { $0.count == 16 && Self.isHex($0) }.map { $0.uppercased() }
                if ids.contains(where: { $0 != titleID }) { continue }
                out.append(file)
            }
        }
        return out
    }

    /// Copies the cheat files among the picked items into the folder as `<build ID>.txt` (upper case), replacing an older file of that
    /// build, with the `.meta.tsv` of scripts/cheat_anchor.py beside it when the source has one (a meta file describes its own
    /// `.txt`, so one left from the file just replaced goes). Switches in `.enabled` stay.
    func importFiles(from urls: [URL]) throws -> ImportResult {
        let fm = FileManager.default
        var result = ImportResult()
        for source in candidates(in: urls) {
            guard let id = Self.buildID(ofFileNamed: source.lastPathComponent) else {
                if !source.lastPathComponent.lowercased().hasSuffix(".meta.tsv") { result.skipped.append(source.lastPathComponent) }
                continue
            }
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(id + ".txt")
            if source.standardizedFileURL != target.standardizedFileURL { try Data(contentsOf: source).write(to: target, options: .atomic) }
            let sourceMeta = source.deletingPathExtension().appendingPathExtension("meta.tsv")
            if fm.fileExists(atPath: sourceMeta.path) {
                if sourceMeta.standardizedFileURL != metaFile(id).standardizedFileURL { try Data(contentsOf: sourceMeta).write(to: metaFile(id), options: .atomic) }
            } else { try? fm.removeItem(at: metaFile(id)) }
            // the same build's file in the Atmosphere tree would win over a flat one only when the flat is missing: the flat one is picked first
            if !result.imported.contains(id) { result.imported.append(id) }
        }
        return result
    }
}

/// The folder copied to the iPhone or iPad the launcher installed the game on, the way the Saves sheet copies saves
/// (SaveTransfer: `devicectl device copy to` with the app's data container). The Mac's files are merged into the device's folder
/// and nothing is deleted there, so a file the Mac no longer has can stay (#250: devicectl's wipe flag deletes the siblings).
struct CheatTransfer {
    let files: CheatFiles
    let device: String    // the device's UDID
    let bundle: String    // the installed app's bundle ID
    let devicectl: DeviceControl
    var scratch = FileManager.default.temporaryDirectory

    enum Failure: Error, Equatable {
        case noFiles
        case device(String)   // devicectl's last line
    }

    var destination: String { CheatFiles.deviceFolder(titleID: files.titleID) }

    /// What goes: the folder's files without the host's safe-mode flag (a Mac-only state) and half-written temporaries.
    func stage() throws -> URL {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: files.folder.path)) ?? []).filter { !$0.hasPrefix(".cheats-running-") && !$0.hasSuffix(".tmp") }
        guard names.contains(where: { $0.lowercased().hasSuffix(".txt") }) || fm.fileExists(atPath: files.folder.appendingPathComponent("atmosphere").path) else { throw Failure.noFiles }
        let dir = scratch.appendingPathComponent("nxnative-cheats-\(UUID().uuidString)").appendingPathComponent("cheats")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for n in names { try fm.copyItem(at: files.folder.appendingPathComponent(n), to: dir.appendingPathComponent(n)) }
        return dir
    }

    func toDevice() throws {
        let staged = try stage()
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        let r = devicectl.run(Self.copyCommand(device: device, bundle: bundle, source: staged.path, destination: destination))
        guard r.ok else { throw Failure.device(SaveTransfer.lastLine(r.output)) }
    }

    /// The save transfer's copy-to-device command: the destination is the folder itself, merged into without deleting anything (a file the Mac no longer has can stay).
    static func copyCommand(device: String, bundle: String, source: String, destination: String) -> [String] {
        SaveTransfer.copyToCommand(device: device, bundle: bundle, source: source, destination: destination)
    }
}
