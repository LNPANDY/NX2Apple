import XCTest
@testable import NSPortBuilder

/// Launch options beyond the app's own list: Display mode, the basic / advanced split, the render scale in pixels, and mods.
final class LaunchOptionsTests: XCTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-launch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    /// A Mac app with a launcher.json of the given rows, and a repository with a profile for its title ID.
    private func app(_ rows: String, renderBase: String? = nil) throws -> (app: String, repo: String) {
        let app = temporary.appendingPathComponent("Game.app")
        let dm = app.appendingPathComponent("Contents/Resources/dm")
        try FileManager.default.createDirectory(at: dm, withIntermediateDirectories: true)
        try #"{"game": "01007EF00011E000", "settings": [\#(rows)]}"#.write(to: dm.appendingPathComponent("launcher.json"), atomically: true, encoding: .utf8)
        let profile = temporary.appendingPathComponent("repo/dm/games/01007EF00011E000")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try "title_id\t01007EF00011E000\n\(renderBase.map { "render_base\t\($0)\n" } ?? "")".write(to: profile.appendingPathComponent("game.tsv"), atomically: true, encoding: .utf8)
        return (app.path, temporary.appendingPathComponent("repo").path)
    }

    private let scale = #"{"env": "DM_RENDER_SCALE", "kind": "range", "label": "Render scale", "note": "", "default": "1.0", "section": "Game", "min": 0.5, "max": 1.0, "step": 0.05}"#
    private let opmode = #"{"env": "DM_OPMODE", "kind": "choice", "label": "Console mode", "note": "", "default": "1", "section": "Game", "options": [["1", "Docked"], ["0", "Handheld"]]}"#
    private let hud = #"{"env": "DM_METAL_HUD", "kind": "toggle", "label": "Metal HUD", "note": "", "default": "0", "section": "Performance", "on": "1", "off": "0"}"#

    func testTheBuildsEnglishRowsAreShownInTheLaunchersLanguage() throws {
        let unknown = #"{"env": "DM_NEW", "kind": "choice", "label": "New setting", "note": "A note", "default": "a", "section": "Game", "options": [["a", "Alpha"]]}"#
        let (app, repo) = try app([opmode, unknown].joined(separator: ","))
        let sv = try XCTUnwrap(LaunchSetting.forMac(app: app, titleID: "01007EF00011E000", repo: repo, labels: { L10n.string($0, .sv) }))
        let mode = try XCTUnwrap(sv.first { $0.env == "DM_OPMODE" })
        XCTAssertEqual(mode.label, "Konsolläge")
        XCTAssertEqual(mode.options ?? [], [["1", "Dockad"], ["0", "Handhållen"]], "the values stay, the labels change")
        let new = try XCTUnwrap(sv.first { $0.env == "DM_NEW" })
        XCTAssertEqual([new.label, new.note], ["New setting", "A note"], "a row the table does not know keeps the build's text")
        XCTAssertEqual(new.options ?? [], [["a", "Alpha"]])
        let zh = try XCTUnwrap(LaunchSetting.forMac(app: app, titleID: "01007EF00011E000", repo: repo, labels: { L10n.string($0, .zh) }))
        XCTAssertEqual(zh.first { $0.env == "DM_OPMODE" }?.label, "主机模式")
    }

    /// Every row of dm/games/settings.tsv and every language of dm/tools/nacp.py has its launch.set or launch.opt entry, with the same
    /// English, so a row added there is translated here too.
    func testEveryPlayerFacingSettingHasItsEntries() throws {
        let tsv = try String(contentsOf: BuildFailureTests.engine.appendingPathComponent("dm/games/settings.tsv"), encoding: .utf8)
        for line in tsv.split(separator: "\n") where !line.hasPrefix("#") {
            let c = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard c.count > 6 else { continue }
            XCTAssertEqual(L10n.string("launch.set." + c[0], .en), c[6], c[0])
            // DM_PSO_MTL4's note is written without the semicolon settings.tsv has; the table follows the text rules.
            if c.count > 7, !c[7].isEmpty, c[0] != "DM_PSO_MTL4" { XCTAssertEqual(L10n.string("launch.set.\(c[0]).note", .en), c[7], c[0]) }
            if c[1] == "choice", c[2] != "languages" {
                for pair in c[2].split(separator: ",") {
                    let v = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    XCTAssertEqual(L10n.string("launch.opt.\(c[0]).\(v[0])", .en), v[1], c[0])
                }
            }
        }
        let nacp = try String(contentsOf: BuildFailureTests.engine.appendingPathComponent("dm/tools/nacp.py"), encoding: .utf8)
        let re = try NSRegularExpression(pattern: #"\('([A-Za-z-0-9]+)', '([^']+)'\)"#)
        let langs = re.matches(in: nacp, range: NSRange(nacp.startIndex..., in: nacp)).map { m in
            (String(nacp[Range(m.range(at: 1), in: nacp)!]), String(nacp[Range(m.range(at: 2), in: nacp)!]))
        }
        XCTAssertEqual(langs.count, 16)
        for (code, name) in langs { XCTAssertEqual(L10n.string("launch.opt.DM_LANG." + code, .en), name, code) }
    }

    func testDisplayModeComesAfterTheRenderScaleAndWindowLeavesTheVariableUnset() throws {
        let (app, repo) = try app([scale, opmode].joined(separator: ","))
        let list = try XCTUnwrap(LaunchSetting.forMac(app: app, titleID: "01007EF00011E000", repo: repo, labels: { $0 }))
        XCTAssertEqual(list.map(\.env), ["DM_RENDER_SCALE", "DM_FULLSCREEN", "DM_OPMODE"])
        var game = LibraryGame(titleID: "01007EF00011E000", name: "Zelda")
        XCTAssertNil(game.launchEnvironment(list)["DM_FULLSCREEN"], "the host starts fullscreen when the variable is set at all")
        game.launchOptions["DM_FULLSCREEN"] = "1"
        XCTAssertEqual(game.launchEnvironment(list)["DM_FULLSCREEN"], "1")
    }

    func testBasicRowsFirstTheRestAdvancedUnlessTheListSaysOtherwise() throws {
        let leveled = #"{"env": "DM_METAL_HUD", "kind": "toggle", "label": "Metal HUD", "note": "", "default": "0", "section": "Performance", "on": "1", "off": "0", "level": "basic"}"#
        let (app, repo) = try app([scale, hud].joined(separator: ","))
        let list = try XCTUnwrap(LaunchSetting.forMac(app: app, titleID: "01007EF00011E000", repo: repo, labels: { $0 }))
        XCTAssertEqual(list.filter(\.isBasic).map(\.env), ["DM_RENDER_SCALE", "DM_FULLSCREEN"])
        XCTAssertEqual(list.filter { !$0.isBasic }.map(\.env), ["DM_METAL_HUD"])
        let (app2, _) = try self.app(leveled)
        XCTAssertTrue(try XCTUnwrap(LaunchSetting.read(app: app2)).first!.isBasic, "a level in launcher.json wins over the default split")
    }

    func testRenderScaleInPixelsFromTheProfile() throws {
        let (app, repo) = try app(scale, renderBase: "1600x900 1280x720")
        let s = try XCTUnwrap(LaunchSetting.forMac(app: app, titleID: "01007EF00011E000", repo: repo, labels: { $0 })?.first)
        XCTAssertEqual(s.pixels(scale: 0.5, docked: true), "800×450")
        XCTAssertEqual(s.pixels(scale: 0.75, docked: false), "960×540")
        let (plain, repo2) = try self.app(scale)
        XCTAssertNil(try XCTUnwrap(LaunchSetting.forMac(app: plain, titleID: "01007EF00011E000", repo: repo2, labels: { $0 })?.first).pixels(scale: 1, docked: true),
                     "without render_base the row stays in percent")
    }

    func testModsAreFoundInTheirLayoutsAndPassedInListOrder() throws {
        var game = LibraryGame(titleID: "01007EF00011E000", name: "Zelda")
        let folder = GameMod.folder(for: game, library: temporary.path)
        let fm = FileManager.default
        for path in ["B Plain/Actor/x.bin", "A Romfs/romfs/Actor/y.bin", "C Atmosphere/atmosphere/contents/01007EF00011E000/romfs/z.bin", "D Code/exefs/main.npdm"] {
            let file = folder.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: file)
        }
        let mods = GameMod.list(in: folder, titleID: game.titleID)
        XCTAssertEqual(mods.map(\.name), ["A Romfs", "B Plain", "C Atmosphere", "D Code"])
        XCTAssertEqual(mods.map(\.usable), [true, true, true, false])
        XCTAssertEqual(game.modEnvironment(mods), [:])
        game.mods = ["C Atmosphere", "D Code", "A Romfs"]
        XCTAssertEqual(game.modEnvironment(mods)["DM_ROMFS_OVERLAY"],
                       [folder.appendingPathComponent("A Romfs/romfs").path,
                        folder.appendingPathComponent("C Atmosphere/atmosphere/contents/01007EF00011E000/romfs").path].joined(separator: ":"),
                       "the list's order (higher wins), and a code-only mod left out")
    }

    func testShortChoicesAreSegmentedAndTheGameLanguageIsAlwaysAMenu() {
        func segmented(_ env: String, _ labels: [String]) -> Bool { LaunchControl.isSegmented(env: env, labels: labels) }
        XCTAssertTrue(segmented("DM_FPS_TARGET", ["30 fps", "60 fps"]))
        XCTAssertTrue(segmented("DM_OPMODE", ["Docked", "Handheld"]))
        XCTAssertTrue(segmented("DM_FULLSCREEN", ["Window", "Fullscreen"]))
        XCTAssertTrue(segmented("DM_PRESENT_UPSCALE", ["Standard", "MetalFX"]))
        XCTAssertTrue(segmented("DM_FULLSCREEN", ["Fenster", "Vollbild"]))
        XCTAssertTrue(segmented("DM_FULLSCREEN", ["窗口", "全屏"]))
        XCTAssertFalse(segmented("DM_LANG", ["English", "Japanese"]), "the game language is a menu, as on the iPhone")
        XCTAssertFalse(segmented("DM_LANG", ["en", "ja", "de"]))
        XCTAssertFalse(segmented("DM_X", ["American English", "Japanese"]), "a label that does not fit its segment")
        XCTAssertFalse(segmented("DM_X", ["One", "Two", "Seven tens"]), "three segments are narrower than two")
        XCTAssertFalse(segmented("DM_X", ["A", "B", "C", "D"]), "four or more are a menu")
    }
}
