import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

/// A mac-app's launcher.json as seedds/nxnative writes it, and the Game language row it gives the Launch options sheet (LNPANDY/NX2Apple#109).
///
/// The fixture is real output, not hand-written: dm/games/settings.py of seedds/nxnative main (3950976) run as build_ipa_from_nsp.py
/// runs it for --platform mac-app (GFXAPI=nvn SETTINGS_PLATFORM=mac DM_LANG=zh-Hans) for profile 01008CF01BAAC000 (Zelda: Echoes of
/// Wisdom) over a control.nacp built for the test (no game files): only the SupportedLanguageFlag at 0x302C, set to en-US, ja, fr, de,
/// es, it, pt, ru, ko, zh-Hant and zh-Hans. Regenerate it the same way when settings.py or settings.tsv changes the rows.
final class MacAppLanguageTests: IsolatedDefaultsTestCase {
    private var temporary: URL!
    private let titleID = "01008CF01BAAC000"
    private var bundleID: String { TestPreferences.domain(in: temporary, "lang") }
    private let languages = ["en-US", "ja", "fr", "de", "es", "it", "pt", "ru", "ko", "zh-Hant", "zh-Hans"]

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-lang-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        CFPreferencesAppSynchronize(bundleID as CFString)
        try FileManager.default.removeItem(at: temporary)
    }

    /// The app pack_app.py makes: launcher.json under Contents/Resources/dm, and Info.plist with the bundle ID, DMLanguage (the DM_LANG
    /// row's default) and DMSettings (settings_rules: the values or range each row takes, which launcher.c checks a saved choice against).
    private func macApp() throws -> (path: String, rules: [[String: Any]]) {
        let app = temporary.appendingPathComponent("Zelda.app")
        let dm = app.appendingPathComponent("Contents/Resources/dm")
        try FileManager.default.createDirectory(at: dm, withIntermediateDirectories: true)
        try Data(Self.launcherJSON.utf8).write(to: dm.appendingPathComponent("launcher.json"))
        let rows = try XCTUnwrap(LaunchList.parse(Data(Self.launcherJSON.utf8))).settings
        let rules: [[String: Any]] = rows.map { s in
            switch s.kind {
            case "range": return ["env": s.env, "min": s.min ?? 0, "max": s.max ?? 0]
            case "choice": return ["env": s.env, "values": (s.options ?? []).map { $0[0] }]
            default: return ["env": s.env, "values": [s.on ?? "1", s.off ?? "0"]]
            }
        }
        let info: [String: Any] = ["CFBundleIdentifier": bundleID, "DMTitleID": titleID, "DMLanguage": "zh-Hans", "DMSettings": rules]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        return (app.path, rules)
    }

    func testTheGameLanguageRowIsDrawnWithTheGamesLanguages() throws {
        let app = try macApp().path
        let list = try XCTUnwrap(LaunchSetting.forMac(app: app, titleID: titleID, repo: "", labels: { $0 }))
        let lang = try XCTUnwrap(list.first { $0.env == "DM_LANG" }, "the sheet has a Game language row")
        XCTAssertEqual(lang.label, "Game language")
        XCTAssertEqual(lang.kind, "choice")
        XCTAssertEqual(lang.sectionTitle, "Game")
        XCTAssertTrue(lang.isBasic, "shown first, not under Advanced settings")
        XCTAssertTrue(lang.storeBacked, "a saved choice, which the app's launcher reads itself")
        XCTAssertEqual(lang.options?.map { $0[0] }, languages)
        XCTAssertTrue(lang.options?.contains { $0 == ["zh-Hans", "Simplified Chinese"] } ?? false)
        XCTAssertTrue(lang.options?.contains { $0 == ["zh-Hant", "Traditional Chinese"] } ?? false)
        XCTAssertEqual(lang.def, "zh-Hans", "the build's --lang is the row's default")
        XCTAssertFalse(list.contains { $0.env == "DM_SHOW_FPS" }, "the iPhone's own rows are not in a mac-app's list")
        XCTAssertEqual(list.filter { $0.env == "DM_FULLSCREEN" }.count, 1, "the list's own Display mode row; the launcher adds none")
    }

    func testPickingALanguageStoresLauncherDMLangInTheAppsDomainAndLauncherCAcceptsIt() throws {
        let (app, rules) = try macApp()
        let lang = try XCTUnwrap(LaunchSetting.read(app: app)?.first { $0.env == "DM_LANG" })
        let store = SavedChoices(app: app, titleID: titleID)
        XCTAssertEqual(store.domain, bundleID, "the domain is the app's bundle ID")
        XCTAssertEqual(SavedChoices.key("DM_LANG"), "launcher.DM_LANG")
        let rule = try XCTUnwrap(rules.first { $0["env"] as? String == "DM_LANG" })
        for code in languages where code != "zh-Hans" {   // zh-Hans is the default: picking it removes the key
            store.set(lang, code)
            let stored = CFPreferencesCopyAppValue("launcher.DM_LANG" as CFString, bundleID as CFString) as? String
            XCTAssertEqual(stored, code, "a string under launcher.DM_LANG in \(bundleID)")
            XCTAssertTrue(SavedChoicesTests.launcherCAccepts(rule, code), "launcher.c accepts DM_LANG=\(code)")
            XCTAssertEqual(store.current(lang), code)
        }
        store.set(lang, "zh-Hans")
        XCTAssertNil(store.raw("DM_LANG"), "the default removes the key; the app's DMLanguage (zh-Hans) applies")
        // What the game does not offer is neither stored nor accepted by launcher.c
        store.set(lang, "es-419")
        XCTAssertNil(store.raw("DM_LANG"))
        XCTAssertFalse(SavedChoicesTests.launcherCAccepts(rule, "es-419"))
        XCTAssertFalse(SavedChoicesTests.launcherCAccepts(rule, "zh-hans"), "case matters, as in launcher.c")
    }

    func testPlayDoesNotPutTheLanguageInTheEnvironment() throws {
        let (app, _) = try macApp()
        let settings = try XCTUnwrap(LaunchSetting.forMac(app: app, titleID: titleID, repo: "", labels: { $0 }))
        let lang = try XCTUnwrap(settings.first { $0.env == "DM_LANG" })
        SavedChoices(app: app, titleID: titleID).set(lang, "ja")
        let game = LibraryGame(titleID: titleID, name: "Zelda", appPath: app)
        let env = game.startEnvironment(controls: [:], settings: settings, mods: [], store: SavedChoices(app: app, titleID: titleID),
                                        appReadsStore: SavedChoices.appReadsStore(app: app))
        XCTAssertNil(env["DM_LANG"], "launcher.c applies the saved choice (after env.txt, before DMLanguage); a value here would override env.txt")
        XCTAssertEqual(env["DM_LAUNCHER"], "0")
    }

    /// A dump or NACP-less game whose launcher.json has no DM_LANG row gets one from its RomFS (System/RegionLangMask.txt or Mals/, #668).
    func testRomFSLanguagesSupplyTheRowWhenLauncherJSONHasNone() throws {
        let app = temporary.appendingPathComponent("Bananza.app")
        let dm = app.appendingPathComponent("Contents/Resources/dm")
        try FileManager.default.createDirectory(at: dm, withIntermediateDirectories: true)
        let noLangJSON = #"{"schema": 1, "game": "040074A01BF12000", "settings": [{"env": "DM_OPMODE", "kind": "choice", "section": "Game", "label": "Console mode", "note": "", "default": "1", "level": "basic", "options": [["1", "Docked"], ["0", "Handheld"]]}]}"#
        try Data(noLangJSON.utf8).write(to: dm.appendingPathComponent("launcher.json"))
        let info: [String: Any] = ["CFBundleIdentifier": bundleID, "DMTitleID": "040074A01BF12000", "DMLanguage": "en-US"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))

        let imgURL = app.appendingPathComponent("Contents/Resources/romfs.img")
        try Self.makeDMROMFSImage(mask: "JPja USen CNzh TWzh EUfr\n01111\n").write(to: imgURL)

        let list = try XCTUnwrap(LaunchSetting.forMac(app: app.path, titleID: "040074A01BF12000", repo: "", labels: { L10n.string($0, .en) }))
        let lang = try XCTUnwrap(list.first { $0.env == "DM_LANG" })
        XCTAssertFalse(lang.storeBacked, "the app's Info.plist has no DMSettings rule for DM_LANG, so the launcher keeps and passes the choice")
        XCTAssertEqual(lang.def, "en-US")
        XCTAssertEqual(lang.options?.map { $0[0] }, ["en-US", "ja", "fr", "zh-Hant", "zh-Hans"])

        var game = LibraryGame(titleID: "040074A01BF12000", name: "Donkey Kong Bananza", appPath: app.path)
        XCTAssertNil(game.launchEnvironment(list)["DM_LANG"], "at the default language the variable stays unset so env.txt still works")
        game.launchOptions["DM_LANG"] = "zh-Hans"
        XCTAssertEqual(game.launchEnvironment(list)["DM_LANG"], "zh-Hans")

        // The archive step also adds the row to an iOS framework's launcher.json when it lacks one.
        let fwLauncher = temporary.appendingPathComponent("DmGame040074A01BF12000.framework/dm/launcher.json")
        try FileManager.default.createDirectory(at: fwLauncher.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(noLangJSON.utf8).write(to: fwLauncher)
        XCTAssertTrue(RomFSLanguages.applyToLauncherJSON(at: fwLauncher.path, romfs: imgURL.path))
        let parsed = try XCTUnwrap(LaunchList.parse(Data(contentsOf: fwLauncher)))
        XCTAssertEqual(parsed.settings.first { $0.env == "DM_LANG" }?.options?.map { $0[0] }, ["en-US", "ja", "fr", "zh-Hant", "zh-Hans"])
    }

    /// The DM_LANG row `dm/games/settings.py` of seedds/nxnative 777a5f6 (aafe01d) writes for 040074A01BF12000 over a control.nacp that does
    /// not exist (a dump has none): every language and a note. Regenerate it with `SETTINGS_PLATFORM=mac GFXAPI=nvn DM_LANG=en-US python3
    /// dm/games/settings.py 040074A01BF12000 <dir with an empty main.fixups.tsv> /nonexistent/control.nacp out.json`.
    private static let fallbackLangRow = ###"{"env":"DM_LANG","kind":"choice","section":"Game","label":"Game language","note":"This game's files do not list its languages, so some of these may not be in the game. It may then show another one.","default":"en-US","level":"basic","options":[["en-US","American English"],["en-GB","British English"],["ja","Japanese"],["fr","French"],["de","German"],["es-419","Latin American Spanish"],["es","Spanish"],["it","Italian"],["nl","Dutch"],["fr-CA","Canadian French"],["pt","Portuguese"],["ru","Russian"],["ko","Korean"],["zh-Hant","Traditional Chinese"],["zh-Hans","Simplified Chinese"],["pt-BR","Brazilian Portuguese"]]}"###

    /// A Mac app of 040074A01BF12000 with the given DM_LANG row (nil: none) in its launcher.json and a RomFS image naming `mask`.
    private func appWithLangRow(_ row: String?, mask: String) throws -> (app: URL, image: URL) {
        let app = temporary.appendingPathComponent("Game-\(UUID().uuidString).app")
        let dm = app.appendingPathComponent("Contents/Resources/dm")
        try FileManager.default.createDirectory(at: dm, withIntermediateDirectories: true)
        let opmode = #"{"env": "DM_OPMODE", "kind": "choice", "section": "Game", "label": "Console mode", "note": "", "default": "1", "level": "basic", "options": [["1", "Docked"], ["0", "Handheld"]]}"#
        try Data(#"{"schema": 1, "game": "040074A01BF12000", "settings": [\#([opmode, row].compactMap { $0 }.joined(separator: ","))]}"#.utf8)
            .write(to: dm.appendingPathComponent("launcher.json"))
        let info: [String: Any] = ["CFBundleIdentifier": bundleID, "DMTitleID": "040074A01BF12000", "DMLanguage": "en-US"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let image = app.appendingPathComponent("Contents/Resources/romfs.img")
        try Self.makeDMROMFSImage(mask: mask).write(to: image)
        return (app, image)
    }

    /// Since seedds/nxnative aafe01d a game with no language list gets every language and a note. The RomFS names the real ones (#668).
    func testRomFSNarrowsTheAllLanguagesRowOfAGameWithNoLanguageList() throws {
        let (app, _) = try appWithLangRow(Self.fallbackLangRow, mask: "JPja USen CNzh TWzh EUfr\n01111\n")
        let list = try XCTUnwrap(LaunchSetting.forMac(app: app.path, titleID: "040074A01BF12000", repo: "", labels: { L10n.string($0, .en) }))
        let lang = try XCTUnwrap(list.first { $0.env == "DM_LANG" })
        XCTAssertEqual(list.filter { $0.env == "DM_LANG" }.count, 1)
        XCTAssertEqual(lang.options?.map { $0[0] }, ["en-US", "ja", "fr", "zh-Hant", "zh-Hans"], "the row's own order, only what the RomFS has")
        XCTAssertEqual(lang.options?.first { $0[0] == "zh-Hans" }, ["zh-Hans", "Simplified Chinese"])
        XCTAssertEqual(lang.note, "", "the list is right now: nothing may be missing from the game")
        XCTAssertEqual(lang.def, "en-US")
        XCTAssertTrue(lang.storeBacked, "the engine's own row stays a saved choice, which the app's launcher reads")
    }

    /// Unlike the copied fixtures, this follows the pin: a changed engine row must still parse and narrow (#698).
    func testPinnedEngineFallbackRowIsRecognizedAndNarrowedWithoutRewritingTheApp() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let output = temporary.appendingPathComponent("engine-launcher.json")
        try Data().write(to: temporary.appendingPathComponent("main.fixups.tsv"))
        let result = SystemProcessRunner().capture(ProcessLaunch(
            executable: "/usr/bin/env",
            arguments: ["python3", root.appendingPathComponent("engine/dm/games/settings.py").path,
                        "040074A01BF12000", temporary.path, temporary.appendingPathComponent("missing-control.nacp").path, output.path],
            environment: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                          "SETTINGS_PLATFORM": "mac", "GFXAPI": "nvn", "DM_LANG": "en-US",
                          "PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1"], mergesErrors: true, timeout: 10))
        XCTAssertTrue(result.ok, "Run python3 tools/engine.py sync before testing: \(result.out)")
        let generated = try Data(contentsOf: output)
        let emitted = try XCTUnwrap(LaunchList.parse(generated)?.settings.first { $0.env == "DM_LANG" })
        XCTAssertEqual(emitted.kind, "choice")
        XCTAssertTrue(RomFSLanguages.isFallbackRow(options: emitted.options, note: emitted.note))

        let (app, _) = try appWithLangRow(nil, mask: "JPja USen CNzh TWzh EUfr\n01111\n")
        let launcher = app.appendingPathComponent("Contents/Resources/dm/launcher.json")
        try generated.write(to: launcher)
        let language = try XCTUnwrap(LaunchSetting.forMac(app: app.path, titleID: "040074A01BF12000", repo: "", labels: { $0 })?
            .first { $0.env == "DM_LANG" })
        XCTAssertEqual(language.options?.map { $0[0] }, ["en-US", "ja", "fr", "zh-Hant", "zh-Hans"])
        XCTAssertEqual(language.def, "en-US")
        XCTAssertEqual(language.note, "")
        // Reading options must not mutate resources inside a signed Mac app.
        XCTAssertEqual(try Data(contentsOf: launcher), generated)
    }

    /// The row is left alone when the RomFS cannot say: no list, one language, or the packed default is not among them.
    func testTheAllLanguagesRowStaysWhenTheRomFSCannotNarrowIt() throws {
        for mask in ["Hello\n", "USen\n", "JPja EUfr\n"] {   // no tag, one language, no American English (the packed default)
            let (app, _) = try appWithLangRow(Self.fallbackLangRow, mask: mask)
            let lang = try XCTUnwrap(LaunchSetting.forMac(app: app.path, titleID: "040074A01BF12000", repo: "", labels: { L10n.string($0, .en) })?
                .first { $0.env == "DM_LANG" })
            XCTAssertEqual(lang.options?.count, 16, mask)
            XCTAssertFalse(lang.note.isEmpty, mask)
        }
    }

    /// A game whose control data lists languages has no note and its list is the game's own: the RomFS does not touch it.
    func testARowWithoutTheNoteIsNeverNarrowed() throws {
        let exact = Self.fallbackLangRow.replacingOccurrences(of: #""note":"This game's files do not list its languages, so some of these may not be in the game. It may then show another one.""#, with: #""note":"""#)
        let (app, _) = try appWithLangRow(exact, mask: "JPja USen\n01\n")
        let lang = try XCTUnwrap(LaunchSetting.forMac(app: app.path, titleID: "040074A01BF12000", repo: "", labels: { L10n.string($0, .en) })?
            .first { $0.env == "DM_LANG" })
        XCTAssertEqual(lang.options?.count, 16)
    }

    /// The engine may add languages to its table later (seedds/nxnative#1231 asks for Thai and Polish). The row is still recognised, and a
    /// language this launcher cannot name from a RomFS tag is kept, not dropped with the ones the RomFS lacks.
    func testALanguageTheLauncherDoesNotKnowIsKept() throws {
        let extended = Self.fallbackLangRow.replacingOccurrences(of: #"["pt-BR","Brazilian Portuguese"]]"#, with: #"["pt-BR","Brazilian Portuguese"],["th","Thai"],["pl","Polish"]]"#)
        XCTAssertTrue(extended.contains(#"["th","Thai"]"#))
        let (app, _) = try appWithLangRow(extended, mask: "JPja USen CNzh\n011\n")
        let lang = try XCTUnwrap(LaunchSetting.forMac(app: app.path, titleID: "040074A01BF12000", repo: "", labels: { L10n.string($0, .en) })?
            .first { $0.env == "DM_LANG" })
        XCTAssertEqual(lang.options?.map { $0[0] }, ["en-US", "ja", "zh-Hans", "th", "pl"])
        XCTAssertEqual(lang.note, "")
    }

    /// A copy that is cut off, finished later or replaced is read again: only a list is kept, and by size and date.
    func testAnImageThatChangesIsReadAgain() throws {
        let path = temporary.appendingPathComponent("changing.img")
        let two = Self.makeDMROMFSImage(mask: "USen JPja\n")
        try two.prefix(two.count - 10).write(to: path)   // cut off: no list
        XCTAssertEqual(RomFSLanguages.options(in: path.path), [])
        try two.write(to: path)   // the copy finished
        XCTAssertEqual(RomFSLanguages.options(in: path.path).map { $0[0] }, ["en-US", "ja"])
        try Self.makeDMROMFSImage(mask: "USen JPja EUfr\n").write(to: path)   // replaced by another version
        XCTAssertEqual(RomFSLanguages.options(in: path.path).map { $0[0] }, ["en-US", "ja", "fr"])
    }

    /// The archive step makes a newly built iOS framework's launcher.json right too.
    func testTheArchiveStepNarrowsTheAllLanguagesRowOfAFrameworkLauncherJSON() throws {
        let (app, image) = try appWithLangRow(Self.fallbackLangRow, mask: "JPja USen CNzh TWzh EUfr\n01111\n")
        let json = app.appendingPathComponent("Contents/Resources/dm/launcher.json")
        XCTAssertTrue(RomFSLanguages.applyToLauncherJSON(at: json.path, romfs: image.path))
        let lang = try XCTUnwrap(LaunchList.parse(Data(contentsOf: json))?.settings.first { $0.env == "DM_LANG" })
        XCTAssertEqual(lang.options?.map { $0[0] }, ["en-US", "ja", "fr", "zh-Hant", "zh-Hans"])
        XCTAssertEqual(lang.note, "")
        XCTAssertFalse(RomFSLanguages.applyToLauncherJSON(at: json.path, romfs: image.path), "narrowed already: nothing more to change")
    }

    private func writeImage(_ data: Data) throws -> String {
        let url = temporary.appendingPathComponent("img-\(UUID().uuidString).img")
        try data.write(to: url)
        return url.path
    }

    func testRomFSImageWithFewerThanTwoKnownLanguagesGivesNoRow() throws {
        XCTAssertEqual(RomFSLanguages.options(in: try writeImage(Self.makeDMROMFSImage(mask: "USen\n"))), [])
        XCTAssertEqual(RomFSLanguages.options(in: try writeImage(Self.makeDMROMFSImage(mask: "USen ZZxx QQqq\n"))), [])
        XCTAssertEqual(RomFSLanguages.options(in: try writeImage(Self.makeDMROMFSImage(mask: "USen JPja\n"))).map { $0[0] }, ["en-US", "ja"])
    }

    func testRomFSImageWithBadMagicOrCutOffGivesNoRow() throws {
        var bad = Self.makeDMROMFSImage(mask: "USen JPja\n")
        bad[0] = UInt8(ascii: "X")
        XCTAssertEqual(RomFSLanguages.options(in: try writeImage(bad)), [])
        let good = Self.makeDMROMFSImage(mask: "USen JPja\n")
        XCTAssertEqual(RomFSLanguages.options(in: try writeImage(good.prefix(good.count - 10))), [], "the index must end at the end of the file")
        XCTAssertEqual(RomFSLanguages.options(in: try writeImage(good.prefix(20))), [])
        XCTAssertEqual(RomFSLanguages.options(in: try writeImage(Data())), [])
    }

    func testRomFSImageWithCraftedHeaderDoesNotTrap() throws {
        func patched(at offset: Int, _ value: UInt64) -> Data {
            var d = Self.makeDMROMFSImage(mask: "USen JPja\n")
            for i in 0..<8 { d[offset + i] = UInt8((value >> (8 * UInt64(i))) & 0xff) }
            return d
        }
        XCTAssertEqual(RomFSLanguages.options(in: try writeImage(patched(at: 24, UInt64.max))), [], "a huge entry count must not overflow count * 24")
        XCTAssertEqual(RomFSLanguages.options(in: try writeImage(patched(at: 24, UInt64.max / 24 + 1))), [])
        XCTAssertEqual(RomFSLanguages.options(in: try writeImage(patched(at: 8, UInt64.max))), [])
        XCTAssertEqual(RomFSLanguages.options(in: try writeImage(patched(at: 16, UInt64.max))), [])
        // The mask file's size field is the second u64 of entry 2, which starts 48 bytes into the index.
        var d = Self.makeDMROMFSImage(mask: "USen JPja\n")
        let idxOff = Int(d[8]) | Int(d[9]) << 8
        for i in 0..<8 { d[idxOff + 48 + 8 + i] = i == 7 ? 0x7f : 0xff }
        XCTAssertEqual(RomFSLanguages.options(in: try writeImage(d)), [])
        // A mask offset near UInt64.max must not overflow offset + size.
        var e = Self.makeDMROMFSImage(mask: "USen JPja\n")
        for i in 0..<8 { e[idxOff + 48 + i] = 0xff }
        XCTAssertEqual(RomFSLanguages.options(in: try writeImage(e)), [])
    }

    /// DMROMFS1 image with `/System/RegionLangMask.txt` containing `mask`, laid out as `dm/tools/romfs_image.py` writes it
    /// (header, data, then 24-byte entries and one name pool, breadth-first, a directory is type 0 and a file is type 1).
    private static func makeDMROMFSImage(mask: String) -> Data {
        let payload = [UInt8](mask.utf8)
        let dataOff: UInt64 = 32
        let idxOff = dataOff + UInt64(payload.count)
        let names = [UInt8]("SystemRegionLangMask.txt".utf8)
        func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xff) } }
        func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xff) } }
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
        func entry(_ a: UInt64, _ b: UInt64, _ nOff: UInt32, _ nLen: UInt16, _ type: UInt8) -> [UInt8] {
            le64(a) + le64(b) + le32(nOff) + le16(nLen) + [type, 0]
        }
        let entries = entry(1, 1, 0, 0, 0)
            + entry(2, 1, 0, 6, 0)
            + entry(dataOff, UInt64(payload.count), 6, 18, 1)
        let idx = entries + names
        let head = [UInt8]("DMROMFS1".utf8) + le64(idxOff) + le64(UInt64(idx.count)) + le64(3)
        return Data(head + payload + idx)
    }

    /// settings.py output, as described above.
    private static let launcherJSON = ###"""
{
 "schema": 1,
 "game": "01008CF01BAAC000",
 "settings": [
  {
   "env": "DM_OPMODE",
   "kind": "choice",
   "section": "Game",
   "label": "Console mode",
   "note": "",
   "default": "1",
   "level": "basic",
   "options": [
    [
     "1",
     "Docked"
    ],
    [
     "0",
     "Handheld"
    ]
   ]
  },
  {
   "env": "DM_PRESENT_UPSCALE",
   "kind": "choice",
   "section": "Game",
   "label": "Upscaling",
   "note": "Uses more GPU time and can increase heat.",
   "default": "off",
   "options": [
    [
     "off",
     "Standard"
    ],
    [
     "metalfx",
     "MetalFX"
    ]
   ]
  },
  {
   "env": "DM_LANG",
   "kind": "choice",
   "section": "Game",
   "label": "Game language",
   "note": "",
   "default": "zh-Hans",
   "level": "basic",
   "options": [
    [
     "en-US",
     "American English"
    ],
    [
     "ja",
     "Japanese"
    ],
    [
     "fr",
     "French"
    ],
    [
     "de",
     "German"
    ],
    [
     "es",
     "Spanish"
    ],
    [
     "it",
     "Italian"
    ],
    [
     "pt",
     "Portuguese"
    ],
    [
     "ru",
     "Russian"
    ],
    [
     "ko",
     "Korean"
    ],
    [
     "zh-Hant",
     "Traditional Chinese"
    ],
    [
     "zh-Hans",
     "Simplified Chinese"
    ]
   ]
  },
  {
   "env": "DM_FULLSCREEN",
   "kind": "choice",
   "section": "Game",
   "label": "Display mode",
   "note": "",
   "default": "0",
   "level": "basic",
   "options": [
    [
     "0",
     "Window"
    ],
    [
     "1",
     "Fullscreen"
    ]
   ]
  },
  {
   "env": "DM_RUMBLE",
   "kind": "toggle",
   "section": "Controls",
   "label": "Game rumble",
   "note": "",
   "default": "1",
   "level": "basic",
   "on": "1",
   "off": "0"
  },
  {
   "env": "DM_RUMBLE_GAIN",
   "kind": "range",
   "section": "Controls",
   "label": "Rumble strength",
   "note": "",
   "default": "1.0",
   "needs": "DM_RUMBLE=1",
   "min": 0.0,
   "max": 3.0,
   "step": 0.1
  },
  {
   "env": "DM_RUMBLE_MIN",
   "kind": "range",
   "section": "Controls",
   "label": "Rumble cutoff",
   "note": "",
   "default": "0",
   "min": 0.0,
   "max": 0.9,
   "step": 0.05
  },
  {
   "env": "DM_PRESENT_SNAP",
   "kind": "toggle",
   "section": "Performance",
   "label": "Frame buffering",
   "note": "Up to one frame more display latency.",
   "default": "0",
   "on": "1",
   "off": "0"
  },
  {
   "env": "DM_PSO_MTL4",
   "kind": "toggle",
   "section": "Performance",
   "label": "Metal 4 pipelines",
   "note": "Keeps a pipeline archive; uses more memory.",
   "default": "1",
   "on": "1",
   "off": "0"
  },
  {
   "env": "DM_PSO_PREBUILD",
   "kind": "toggle",
   "section": "Performance",
   "label": "Pipeline prebuild",
   "note": "The first start waits a few minutes for it, once.",
   "default": "1",
   "on": "1",
   "off": "0"
  },
  {
   "env": "DM_NVN_ENC_THREAD",
   "kind": "toggle",
   "section": "Performance",
   "label": "Encode thread",
   "note": "",
   "default": "0",
   "on": "1",
   "off": "0"
  },
  {
   "env": "DM_METAL_HUD",
   "kind": "toggle",
   "section": "Performance",
   "label": "Performance HUD",
   "note": "",
   "default": "0",
   "on": "1",
   "off": "0"
  }
 ]
}
"""###
}
