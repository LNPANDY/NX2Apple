import Foundation

/// Languages a game's RomFS offers when its `launcher.json` has no `DM_LANG` row (a game built from a dump folder or a NUP without
/// `control.nacp`, LNPANDY/NX2Apple#668, seedds/nxnative#1208). Reads `System/RegionLangMask.txt` or `Mals/<Tag>.Product.*` from the
/// game's `romfs.img` (`DMROMFS1` index at the end of the file) or `romfs/` folder.
enum RomfsLanguages {
    static let table: [(code: String, label: String)] = [
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

    static let regionTags: [String: String] = [
        "USen": "en-US", "EUen": "en-GB", "JPja": "ja", "EUfr": "fr",
        "EUde": "de", "USes": "es-419", "EUes": "es", "EUit": "it",
        "EUnl": "nl", "USfr": "fr-CA", "EUpt": "pt", "EUru": "ru",
        "KRko": "ko", "TWzh": "zh-Hant", "CNzh": "zh-Hans", "USpt": "pt-BR"
    ]

    static func options(forTags tags: some Sequence<String>) -> [[String]] {
        let codes = Set(tags.compactMap { regionTags[$0] })
        return table.filter { codes.contains($0.code) }.map { [$0.code, $0.label] }
    }

    static func options(in url: URL, fm: FileManager = .default) -> [[String]] {
        let candidates = [
            url.appendingPathComponent("romfs.img"),
            url.appendingPathComponent("RomFS.img"),
            url.appendingPathComponent("romfs", isDirectory: true),
            url.appendingPathComponent("RomFS", isDirectory: true),
            url
        ]
        for candidate in candidates {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: candidate.path, isDirectory: &isDir) else { continue }
            let found = isDir.boolValue ? fromDirectory(candidate, fm: fm) : fromImage(candidate)
            if found.count > 1 { return found }
        }
        return []
    }

    static func withLanguageIfMissing(_ profile: LauncherProfile, options: [[String]]) -> LauncherProfile {
        guard options.count > 1, !profile.settings.contains(where: { $0.env == "DM_LANG" }) else { return profile }
        let def = options.contains(where: { $0.first == "en-US" }) ? "en-US" : (options.first?.first ?? "en-US")
        let row = LauncherSetting(
            env: "DM_LANG", kind: "choice", section: "Game", label: "Game language", note: "", def: def,
            needs: nil, level: "basic", options: options, min: nil, max: nil, step: nil, on: nil, off: nil)
        var updated = profile
        let idx = updated.settings.lastIndex { $0.sectionTitle == "Game" }.map { $0 + 1 } ?? 0
        updated.settings.insert(row, at: idx)
        return updated
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

    private static func fromDirectory(_ dir: URL, fm: FileManager) -> [[String]] {
        let maskURL = dir.appendingPathComponent("System/RegionLangMask.txt")
        if let data = fm.contents(atPath: maskURL.path), let text = String(data: data, encoding: .utf8) {
            let opts = options(forTags: tagsFromMask(text))
            if opts.count > 1 { return opts }
        }
        if let names = try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent("Mals").path) {
            let opts = options(forTags: tagsFromMals(names))
            if opts.count > 1 { return opts }
        }
        return []
    }

    private static func fromImage(_ url: URL) -> [[String]] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
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
