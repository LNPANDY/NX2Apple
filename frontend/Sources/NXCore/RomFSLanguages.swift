import Foundation

/// Languages a game's RomFS offers when the game was built without `control.nacp` (a dump folder or a NUP without control data,
/// LNPANDY/NX2Apple#668, seedds/nxnative#1208). Nintendo's first-party titles list their compiled region-language packs in
/// `System/RegionLangMask.txt` and ship one archive per pack under `Mals/<Tag>.Product.*`.
package enum RomFSLanguages {
    /// Horizon's 16 language codes and English labels in the order `dm/tools/nacp.py` (`LANGUAGES`) writes them.
    package static let table: [(code: String, label: String)] = [
        ("en-US", "American English"),
        ("en-GB", "British English"),
        ("ja", "Japanese"),
        ("fr", "French"),
        ("de", "German"),
        ("es-419", "Latin American Spanish"),
        ("es", "Spanish"),
        ("it", "Italian"),
        ("nl", "Dutch"),
        ("fr-CA", "Canadian French"),
        ("pt", "Portuguese"),
        ("ru", "Russian"),
        ("ko", "Korean"),
        ("zh-Hant", "Traditional Chinese"),
        ("zh-Hans", "Simplified Chinese"),
        ("pt-BR", "Brazilian Portuguese")
    ]

    /// Nintendo region-language tags (`System/RegionLangMask.txt`, `Mals/<Tag>.Product.*`) to Horizon language codes.
    package static let regionTags: [String: String] = [
        "USen": "en-US", "EUen": "en-GB", "JPja": "ja", "EUfr": "fr",
        "EUde": "de", "USes": "es-419", "EUes": "es", "EUit": "it",
        "EUnl": "nl", "USfr": "fr-CA", "EUpt": "pt", "EUru": "ru",
        "KRko": "ko", "TWzh": "zh-Hant", "CNzh": "zh-Hans", "USpt": "pt-BR"
    ]

    /// `[code, label]` pairs in `table` order for a set of Nintendo region-language tags.
    package static func options(forTags tags: some Sequence<String>) -> [[String]] {
        let codes = Set(tags.compactMap { regionTags[$0] })
        return table.filter { codes.contains($0.code) }.map { [$0.code, $0.label] }
    }

    /// Reads the `[code, label]` pairs from a RomFS image (`romfs.img`), a RomFS tree (`romfs/`), a folder holding either, or a
    /// `.app` bundle (`Contents/Resources/romfs.img` or `Contents/Resources/romfs`). Empty when fewer than two languages are found.
    package static func options(in path: String, fm: FileManager = .default) -> [[String]] {
        guard !path.isEmpty else { return [] }
        for candidate in candidates(for: path) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: candidate, isDirectory: &isDir) else { continue }
            let found = isDir.boolValue ? fromDirectory(candidate, fm: fm) : fromImage(candidate)
            if found.count > 1 { return found }
        }
        return []
    }

    /// The default language code for a Mac `.app`: its `DMLanguage` from `Contents/Info.plist` when the game offers it, else
    /// `en-US` when offered, else the first offered language.
    package static func defaultLanguage(forApp app: String, options: [[String]]) -> String {
        let codes = Set(options.compactMap(\.first))
        if let plist = NSDictionary(contentsOfFile: app + "/Contents/Info.plist"),
           let lang = plist["DMLanguage"] as? String, codes.contains(lang) {
            return lang
        }
        if codes.contains("en-US") { return "en-US" }
        return options.first?.first ?? "en-US"
    }

    /// Adds a `DM_LANG` row to `launcher.json` at `launcherPath` when the file has none and `romfs` offers more than one language.
    /// Used after packing a game's RomFS archive so a newly built iOS framework carries the row even before upstream merges #1208.
    @discardableResult
    package static func addToLauncherJSONIfMissing(at launcherPath: String, romfs: String, defaultLanguage: String = "en-US",
                                                   fm: FileManager = .default) -> Bool {
        guard let data = fm.contents(atPath: launcherPath),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var settings = root["settings"] as? [[String: Any]],
              !settings.contains(where: { ($0["env"] as? String) == "DM_LANG" }) else { return false }
        let opts = options(in: romfs, fm: fm)
        guard opts.count > 1 else { return false }
        let codes = Set(opts.compactMap(\.first))
        let def = codes.contains(defaultLanguage) ? defaultLanguage : (codes.contains("en-US") ? "en-US" : opts[0][0])
        let row: [String: Any] = [
            "env": "DM_LANG",
            "kind": "choice",
            "section": "Game",
            "label": "Game language",
            "note": "",
            "default": def,
            "level": "basic",
            "options": opts
        ]
        let after = settings.lastIndex { ($0["section"] as? String ?? "Game") == "Game" }.map { $0 + 1 } ?? 0
        settings.insert(row, at: after)
        root["settings"] = settings
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              (try? out.write(to: URL(fileURLWithPath: launcherPath), options: .atomic)) != nil else { return false }
        return true
    }

    private static func candidates(for path: String) -> [String] {
        [
            path + "/Contents/Resources/romfs.img",
            path + "/Contents/Resources/romfs",
            path + "/romfs.img",
            path + "/RomFS.img",
            path + "/romfs",
            path + "/RomFS",
            path
        ]
    }

    private static func tagsFromMask(_ text: String) -> [String] {
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("/") {
                return line.split(whereSeparator: \.isWhitespace).map(String.init)
            }
        }
        return []
    }

    private static func tagsFromMals(_ names: some Sequence<String>) -> [String] {
        names.compactMap { name -> String? in
            guard name.contains(".Product."), let dot = name.firstIndex(of: ".") else { return nil }
            return String(name[..<dot])
        }
    }

    private static func fromDirectory(_ dir: String, fm: FileManager) -> [[String]] {
        let maskPath = dir + "/System/RegionLangMask.txt"
        if let data = fm.contents(atPath: maskPath), let text = String(data: data, encoding: .utf8) {
            let opts = options(forTags: tagsFromMask(text))
            if opts.count > 1 { return opts }
        }
        if let names = try? fm.contentsOfDirectory(atPath: dir + "/Mals") {
            let opts = options(forTags: tagsFromMals(names))
            if opts.count > 1 { return opts }
        }
        return []
    }

    /// Reads `System/RegionLangMask.txt` or `Mals/` from a `DMROMFS1` image (`dm/tools/romfs.py`) by seeking to the index at the
    /// end of the file, without reading the multi-GB data region.
    private static func fromImage(_ path: String) -> [[String]] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), (try? handle.seek(toOffset: 0)) != nil,
              let headData = try? handle.read(upToCount: 32), headData.count == 32 else { return [] }
        let head = [UInt8](headData)
        func u64(_ bytes: [UInt8], _ o: Int) -> UInt64 {
            (0..<8).reduce(0) { $0 | UInt64(bytes[o + $1]) << (8 * UInt64($1)) }
        }
        func u32(_ bytes: [UInt8], _ o: Int) -> Int {
            Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24
        }
        func u16(_ bytes: [UInt8], _ o: Int) -> Int {
            Int(bytes[o]) | Int(bytes[o + 1]) << 8
        }
        guard head[0..<8].elementsEqual("DMROMFS1".utf8) else { return [] }
        let idxOff = u64(head, 8), idxSize = u64(head, 16), count = u64(head, 24)
        guard idxOff >= 32, idxOff <= fileSize, idxSize == fileSize - idxOff,
              idxSize <= 64 * 1024 * 1024, count >= 1, count <= idxSize / 24,
              (try? handle.seek(toOffset: idxOff)) != nil,
              let idxData = try? handle.read(upToCount: Int(idxSize)), idxData.count == Int(idxSize) else { return [] }
        let idx = [UInt8](idxData)
        let namesBase = Int(count) * 24

        struct Entry {
            var a: UInt64
            var b: UInt64
            var name: String
            var type: UInt8
        }
        func entry(_ i: Int) -> Entry? {
            guard i >= 0, i < Int(count) else { return nil }
            let o = i * 24
            let nOff = namesBase + u32(idx, o + 16), nLen = u16(idx, o + 20)
            guard nOff >= namesBase, nOff + nLen <= idx.count else { return nil }
            let name = String(decoding: idx[nOff..<(nOff + nLen)], as: UTF8.self)
            return Entry(a: u64(idx, o), b: u64(idx, o + 8), name: name, type: idx[o + 22])
        }
        func children(of dirIndex: Int) -> [Int] {
            guard let dir = entry(dirIndex), dir.type == 0,   // the writer (romfs_image.py) stores a directory as type 0 and a file as type 1
                  dir.a <= count, dir.b <= count - dir.a else { return [] }
            return Array(Int(dir.a)..<Int(dir.a + dir.b))
        }
        func findChild(in dirIndex: Int, named target: String) -> Int? {
            children(of: dirIndex).first { entry($0)?.name == target }
        }

        if let sys = findChild(in: 0, named: "System"),
           let maskIdx = findChild(in: sys, named: "RegionLangMask.txt"),
           let mask = entry(maskIdx), mask.type == 1, mask.b > 0, mask.b <= 65536,
           mask.a >= 32, mask.b <= idxOff, mask.a <= idxOff - mask.b,
           (try? handle.seek(toOffset: mask.a)) != nil,
           let maskData = try? handle.read(upToCount: Int(mask.b)),
           let text = String(data: maskData, encoding: .utf8) {
            let opts = options(forTags: tagsFromMask(text))
            if opts.count > 1 { return opts }
        }
        if let mals = findChild(in: 0, named: "Mals") {
            let names = children(of: mals).compactMap { entry($0)?.name }
            let opts = options(forTags: tagsFromMals(names))
            if opts.count > 1 { return opts }
        }
        return []
    }
}
