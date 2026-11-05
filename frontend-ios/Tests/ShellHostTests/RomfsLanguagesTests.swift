import Foundation
import Testing
@testable import ShellHost

/// `RomfsLanguages` reads the `DMROMFS1` index a game's `romfs.img` ends with (LNPANDY/NX2Apple#668).
@Suite struct RomfsLanguagesTests {
    /// A node of a RomFS tree: a directory (children) or a file (bytes).
    private indirect enum Node {
        case dir([String: Node])
        case file([UInt8])
    }

    /// Packs `root` the way `dm/tools/romfs_image.py` does: a 32-byte header, the file data, then 24-byte entries and one name pool.
    /// Entry 0 is the root, children are consecutive and sorted by name bytes, directories are numbered breadth-first,
    /// a directory has type 0 and a file type 1.
    private static func image(_ root: Node) -> Data {
        struct Item { var name: [UInt8]; var node: Node; var a: UInt64 = 0; var b: UInt64 = 0 }
        var items = [Item(name: [], node: root)]
        var i = 0
        while i < items.count {
            if case .dir(let kids) = items[i].node {
                let sorted = kids.map { (Array($0.key.utf8), $0.value) }.sorted { $0.0.lexicographicallyPrecedes($1.0) }
                items[i].a = UInt64(items.count)
                items[i].b = UInt64(sorted.count)
                items.append(contentsOf: sorted.map { Item(name: $0.0, node: $0.1) })
            }
            i += 1
        }
        var data = [UInt8](), offset: UInt64 = 32
        for k in items.indices {
            if case .file(let bytes) = items[k].node {
                items[k].a = offset
                items[k].b = UInt64(bytes.count)
                offset += UInt64(bytes.count)
                data += bytes
            }
        }
        func le(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> (8 * UInt64($0))) & 0xff) } }
        var idx = [UInt8](), pool = [UInt8]()
        for item in items {
            let isDir: Bool
            if case .dir = item.node { isDir = true } else { isDir = false }
            idx += le(item.a, 8) + le(item.b, 8) + le(UInt64(pool.count), 4) + le(UInt64(item.name.count), 2) + [isDir ? 0 : 1, 0]
            pool += item.name
        }
        let head = [UInt8]("DMROMFS1".utf8) + le(offset, 8) + le(UInt64(idx.count + pool.count), 8) + le(UInt64(items.count), 8)
        return Data(head + data + idx + pool)
    }

    private func folder(with img: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("romfs-lang-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try img.write(to: dir.appendingPathComponent("romfs.img"))
        return dir
    }

    private func codes(_ img: Data) throws -> [String] {
        RomfsLanguages.options(in: try folder(with: img)).map { $0[0] }
    }

    private func mask(_ text: String) -> Node {
        .dir(["System": .dir(["RegionLangMask.txt": .file(Array(text.utf8))]), "Other": .file([1, 2, 3])])
    }

    @Test func aRealLayoutImageGivesTheMaskLanguages() throws {
        #expect(try codes(Self.image(mask("JPja USen CNzh TWzh EUfr\n01111\n"))) == ["en-US", "ja", "fr", "zh-Hant", "zh-Hans"])
    }

    @Test func theMalsFolderIsUsedWhenThereIsNoMask() throws {
        let tree = Node.dir(["Mals": .dir(["USen.Product.100.sarc.zs": .file([0]), "JPja.Product.100.sarc.zs": .file([0]),
                                           "Readme.txt": .file([0])])])
        #expect(try codes(Self.image(tree)) == ["en-US", "ja"])
    }

    @Test func aSingleLanguageGivesNoRow() throws {
        #expect(try codes(Self.image(mask("USen\n"))) == [])
    }

    @Test func unknownTagsAreIgnored() throws {
        #expect(try codes(Self.image(mask("ZZxx QQqq USen\n"))) == [])
        #expect(try codes(Self.image(mask("ZZxx USen JPja\n"))) == ["en-US", "ja"])
    }

    @Test func aBadMagicGivesNoRow() throws {
        var img = Self.image(mask("USen JPja\n"))
        img[0] = UInt8(ascii: "X")
        #expect(try codes(img) == [])
    }

    @Test func aTruncatedFileGivesNoRow() throws {
        let img = Self.image(mask("USen JPja\n"))
        #expect(try codes(img.prefix(img.count - 10)) == [])
        #expect(try codes(img.prefix(20)) == [])
        #expect(try codes(Data()) == [])
    }

    @Test func aCraftedHeaderDoesNotTrap() throws {
        func patched(_ offset: Int, _ value: UInt64, in base: Data? = nil) -> Data {
            var d = base ?? Self.image(mask("USen JPja\n"))
            for i in 0..<8 { d[offset + i] = UInt8((value >> (8 * UInt64(i))) & 0xff) }
            return d
        }
        #expect(try codes(patched(24, .max)) == [], "a huge entry count must not overflow count * 24")
        #expect(try codes(patched(24, UInt64.max / 24 + 1)) == [])
        #expect(try codes(patched(8, .max)) == [])
        #expect(try codes(patched(16, .max)) == [])
        let img = Self.image(mask("USen JPja\n"))
        let idxOff = Int(img[8]) | Int(img[9]) << 8
        // Entries sorted by name: Other is entry 1 and System entry 2, whose child RegionLangMask.txt is entry 3.
        #expect(try codes(patched(idxOff + 3 * 24, .max, in: img)) == [], "a mask offset near UInt64.max must not overflow offset + size")
        #expect(try codes(patched(idxOff + 3 * 24 + 8, .max, in: img)) == [])
    }

    // MARK: The all-languages row of a game with no language list (seedds/nxnative aafe01d)

    /// The row `dm/games/settings.py` of seedds/nxnative 777a5f6 writes for 040074A01BF12000 over a control.nacp that does not exist.
    private static let fallbackRowJSON = """
    {"env":"DM_LANG","kind":"choice","section":"Game","label":"Game language","note":"This game's files do not list its languages, so some of these may not be in the game. It may then show another one.","default":"en-US","level":"basic","options":[["en-US","American English"],["en-GB","British English"],["ja","Japanese"],["fr","French"],["de","German"],["es-419","Latin American Spanish"],["es","Spanish"],["it","Italian"],["nl","Dutch"],["fr-CA","Canadian French"],["pt","Portuguese"],["ru","Russian"],["ko","Korean"],["zh-Hant","Traditional Chinese"],["zh-Hans","Simplified Chinese"],["pt-BR","Brazilian Portuguese"]]}
    """

    private func profile(row: String?) throws -> LauncherProfile {
        let opmode = #"{"env":"DM_OPMODE","kind":"choice","section":"Game","label":"Console mode","note":"","default":"1","options":[["1","Docked"],["0","Handheld"]]}"#
        let rows = [opmode, row].compactMap { $0 }.joined(separator: ",")
        return try LauncherProfile.parse(Data(#"{"schema":1,"game":"040074A01BF12000","settings":[\#(rows)]}"#.utf8))
    }

    private func langRow(_ p: LauncherProfile) -> LauncherSetting? { p.settings.first { $0.env == "DM_LANG" } }

    @Test func theAllLanguagesRowIsNarrowedToTheRomFS() throws {
        let p = try profile(row: Self.fallbackRowJSON)
        let img = Self.image(mask("JPja USen CNzh TWzh EUfr\n01111\n"))
        let narrowed = RomfsLanguages.applying(to: p, options: RomfsLanguages.options(in: try folder(with: img)))
        let row = try #require(langRow(narrowed))
        #expect(narrowed.settings.filter { $0.env == "DM_LANG" }.count == 1)
        #expect(row.options?.map { $0[0] } == ["en-US", "ja", "fr", "zh-Hant", "zh-Hans"])
        #expect(row.options?.first { $0[0] == "zh-Hans" } == ["zh-Hans", "Simplified Chinese"])
        #expect(row.note == "")
        #expect(row.def == "en-US")
        #expect(row.accepts("zh-Hans") && !row.accepts("pt-BR"), "a saved choice the game does not have reads as the default")
    }

    #if os(macOS)
    /// Generate the row from the pinned engine, rather than trusting the copied JSON fixture (#698).
    @Test func thePinnedEnginesFallbackRowIsRecognizedAndNarrowed() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let dir = try folder(with: Self.image(mask("JPja USen CNzh TWzh EUfr\n01111\n")))
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("main.fixups.tsv"))
        let output = dir.appendingPathComponent("launcher.json")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", root.appendingPathComponent("engine/dm/games/settings.py").path,
                             "040074A01BF12000", dir.path, dir.appendingPathComponent("missing-control.nacp").path, output.path]
        process.environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                               "SETTINGS_PLATFORM": "ios", "GFXAPI": "nvn", "DM_LANG": "en-US",
                               "PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let diagnostic = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "Run python3 tools/engine.py sync before testing: \(diagnostic)")

        let profile = try LauncherProfile.parse(Data(contentsOf: output))
        let emitted = try #require(langRow(profile))
        #expect(emitted.kind == "choice")
        #expect(RomfsLanguages.isFallbackRow(emitted))
        let narrowed = RomfsLanguages.applying(to: profile, options: RomfsLanguages.options(in: dir))
        let language = try #require(langRow(narrowed))
        #expect(language.options?.map { $0[0] } == ["en-US", "ja", "fr", "zh-Hant", "zh-Hans"])
        #expect(language.def == "en-US")
        #expect(language.note == "")
        #expect(language.accepts("zh-Hans") && !language.accepts("pt-BR"))
    }
    #endif

    @Test func theRowStaysWhenTheRomFSCannotNarrowIt() throws {
        let p = try profile(row: Self.fallbackRowJSON)
        for text in ["Hello\n", "USen\n", "JPja EUfr\n"] {   // no tag, one language, no American English (the packed default)
            let opts = RomfsLanguages.options(in: try folder(with: Self.image(mask(text))))
            #expect(RomfsLanguages.applying(to: p, options: opts) == p, "\(text)")
        }
    }

    @Test func aRowWithoutTheNoteIsTheGamesOwnListAndStays() throws {
        let exact = Self.fallbackRowJSON.replacingOccurrences(of: #""note":"This game's files do not list its languages, so some of these may not be in the game. It may then show another one.""#, with: #""note":"""#)
        let p = try profile(row: exact)
        let opts = RomfsLanguages.options(in: try folder(with: Self.image(mask("JPja USen\n01\n"))))
        #expect(RomfsLanguages.applying(to: p, options: opts) == p)
        #expect(RomfsLanguages.isFallbackRow(try #require(langRow(try profile(row: Self.fallbackRowJSON)))))
        #expect(!RomfsLanguages.isFallbackRow(try #require(langRow(p))))
    }

    /// The engine may add languages to its table later (seedds/nxnative#1231 asks for Thai and Polish). The row is still recognised, and a
    /// language this app cannot name from a RomFS tag is kept, not dropped with the ones the RomFS lacks.
    @Test func aLanguageTheAppDoesNotKnowIsKept() throws {
        let extended = Self.fallbackRowJSON.replacingOccurrences(of: #"["pt-BR","Brazilian Portuguese"]]"#, with: #"["pt-BR","Brazilian Portuguese"],["th","Thai"],["pl","Polish"]]"#)
        let p = try profile(row: extended)
        #expect(RomfsLanguages.isFallbackRow(try #require(langRow(p))))
        let opts = RomfsLanguages.options(in: try folder(with: Self.image(mask("JPja USen CNzh\n011\n"))))
        let row = try #require(langRow(RomfsLanguages.applying(to: p, options: opts)))
        #expect(row.options?.map { $0[0] } == ["en-US", "ja", "zh-Hans", "th", "pl"])
        #expect(row.note == "")
    }

    /// A copy that is cut off, finished later or replaced is read again: only a list is kept, and by size and date.
    @Test func anImageThatChangesIsReadAgain() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("romfs-change-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("romfs.img")
        let two = Self.image(mask("USen JPja\n"))
        try two.prefix(two.count - 10).write(to: path)
        #expect(RomfsLanguages.options(in: dir) == [])
        try two.write(to: path)
        #expect(RomfsLanguages.options(in: dir).map { $0[0] } == ["en-US", "ja"])
        try Self.image(mask("USen JPja EUfr\n")).write(to: path)
        #expect(RomfsLanguages.options(in: dir).map { $0[0] } == ["en-US", "ja", "fr"])
    }

    @Test func aRowThatIsNotAllLanguagesIsNotTheFallback() throws {
        let some = #"{"env":"DM_LANG","kind":"choice","section":"Game","label":"Game language","note":"A note","default":"en-US","options":[["en-US","American English"],["ja","Japanese"]]}"#
        let p = try profile(row: some)
        #expect(!RomfsLanguages.isFallbackRow(try #require(langRow(p))))
    }
}
