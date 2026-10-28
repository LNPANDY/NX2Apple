import XCTest
@testable import NSPortBuilder

/// The launch options as saved choices in the app's own preferences domain, and launcher.json schema 1. Every app here has a
/// bundle ID of this run, so nothing touches a real game's domain; tearDown removes it.
final class SavedChoicesTests: XCTestCase {
    private var temporary: URL!
    private let titleID = "01007EF00011E000"
    private var bundleID: String { "org.nxnative.frontendtests.saved." + temporary.lastPathComponent }

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-saved-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        let domain = bundleID as CFString
        for key in (CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]) ?? [] {
            CFPreferencesSetAppValue(key as CFString, nil, domain)
        }
        CFPreferencesAppSynchronize(domain)
        try FileManager.default.removeItem(at: temporary)
    }

    private let fps = #"{"env": "DM_FPS_TARGET", "kind": "choice", "section": "Game", "label": "Frame rate", "note": "", "default": "30", "options": [["30", "30 fps"], ["60", "60 fps"]]}"#
    private let scale = #"{"env": "DM_RENDER_SCALE", "kind": "range", "section": "Game", "label": "Render scale", "note": "", "default": "1.0", "min": 0.5, "max": 1.0, "step": 0.05}"#
    private let hold = #"{"env": "DM_FPS_HOLD", "kind": "toggle", "section": "Performance", "label": "Hold", "note": "", "default": "on", "on": "on", "off": "off"}"#

    private func app(_ rows: [String], schema: Int? = 1, bundle: Bool = true, dmSettings: Bool = false) throws -> String {
        let app = temporary.appendingPathComponent("Game.app")
        let dm = app.appendingPathComponent("Contents/Resources/dm")
        try FileManager.default.createDirectory(at: dm, withIntermediateDirectories: true)
        let head = schema.map { "\"schema\": \($0), " } ?? ""
        try Data(#"{\#(head)"game": "\#(titleID)", "settings": [\#(rows.joined(separator: ","))]}"#.utf8).write(to: dm.appendingPathComponent("launcher.json"))
        var info: [String: Any] = ["DMTitleID": titleID]
        if bundle { info["CFBundleIdentifier"] = bundleID }
        if dmSettings { info["DMSettings"] = Self.rules(rows) }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app.path
    }

    func testDomainIsTheBundleIDElseThePackersDefault() throws {
        let path = try app([fps])
        XCTAssertEqual(SavedChoices(app: path, titleID: titleID).domain, bundleID)
        let plain = try app([fps], bundle: false)
        XCTAssertEqual(SavedChoices(app: plain, titleID: titleID).domain, "org.nxnative.01007ef00011e000")
    }

    func testWriteReadAndRemoveKeepOnlyNonDefaults() throws {
        let list = try XCTUnwrap(LaunchSetting.read(app: try app([fps, scale, hold])))
        let store = SavedChoices(domain: bundleID)
        XCTAssertEqual(list.map(store.current), ["30", "1.0", "on"])
        store.set(list[0], "60")
        store.set(list[1], "0.75")
        store.set(list[2], "off")
        XCTAssertEqual(store.raw("DM_FPS_TARGET") as? String, "60", "a string under launcher.<VAR>")
        XCTAssertEqual(list.map(store.current), ["60", "0.75", "off"])
        store.set(list[0], "30")   // the default: the key goes
        store.set(list[1], "1.00")   // a slider's spelling of the default
        XCTAssertNil(store.raw("DM_FPS_TARGET"))
        XCTAssertNil(store.raw("DM_RENDER_SCALE"))
        XCTAssertTrue(store.hasChoices(list))
        store.reset(list)
        XCTAssertFalse(store.hasChoices(list))
        XCTAssertNil(store.raw("DM_FPS_HOLD"))
    }

    func testValidationIsLauncherCs() throws {
        let list = try XCTUnwrap(LaunchSetting.read(app: try app([fps, scale, hold])))
        let store = SavedChoices(domain: bundleID)
        func put(_ env: String, _ v: Any) { CFPreferencesSetAppValue(SavedChoices.key(env) as CFString, v as CFPropertyList, bundleID as CFString) }
        put("DM_FPS_TARGET", "120"); put("DM_FPS_HOLD", "maybe"); put("DM_RENDER_SCALE", "2")
        XCTAssertEqual(list.map(store.current), ["30", "1.0", "on"],"values the build does not offer are ignored")
        for bad in ["0x1", " 0.8", "nan", "", "0.4", "1.01", "1e0x"] { put("DM_RENDER_SCALE", bad); XCTAssertNil(store.value(list[1]), bad) }
        for good in ["0.5", "1", "1.0", "0.85"] { put("DM_RENDER_SCALE", good); XCTAssertEqual(store.value(list[1]), good) }
        put("DM_FPS_TARGET", 60 as NSNumber)   // not a string
        XCTAssertNil(store.value(list[0]))
        put("DM_FPS_TARGET", "60"); put("DM_FPS_HOLD", "off")
        XCTAssertEqual(store.value(list[0]), "60"); XCTAssertEqual(store.value(list[2]), "off")
    }

    func testMigrationMovesLegacyOptionsOnceAndOnlyWhereTheDomainHasNone() throws {
        let path = try app([fps, scale, hold])
        let file = temporary.appendingPathComponent("library.json")
        var game = LibraryGame(titleID: titleID, name: "Zelda", appPath: path)
        game.launchOptions = ["DM_FPS_TARGET": "60", "DM_RENDER_SCALE": "9", "DM_FPS_HOLD": "off", "DM_FULLSCREEN": "1", "DM_OLD": "x"]
        try JSONEncoder().encode([game]).write(to: file)
        let library = GameLibrary(file: file)
        let store = SavedChoices(domain: bundleID)
        CFPreferencesSetAppValue(SavedChoices.key("DM_FPS_HOLD") as CFString, "on" as CFString, bundleID as CFString)   // already chosen in the app's window
        library.migrateLaunchOptions()
        XCTAssertEqual(store.raw("DM_FPS_TARGET") as? String, "60")
        XCTAssertNil(store.raw("DM_RENDER_SCALE"), "an invalid value is dropped, not written")
        XCTAssertEqual(store.raw("DM_FPS_HOLD") as? String, "on", "the domain's own value wins")
        XCTAssertEqual(library.games[0].launchOptions, ["DM_FULLSCREEN": "1", "DM_OLD": "x"], "what the store has no row for stays")
        XCTAssertEqual(GameLibrary(file: file).games[0].launchOptions, library.games[0].launchOptions, "and it is saved")
        store.set(try XCTUnwrap(LaunchSetting.read(app: path)).first!, "30")
        library.migrateLaunchOptions()
        XCTAssertNil(store.raw("DM_FPS_TARGET"), "once: a second run does not bring the old value back")
        // An old library file still loads
        try Data(#"[{"id": "\#(UUID().uuidString)", "titleID": "\#(titleID)", "name": "Z", "launchOptions": {"DM_FPS_TARGET": "60"}}]"#.utf8).write(to: file)
        XCTAssertEqual(GameLibrary(file: file).games[0].launchOptions, ["DM_FPS_TARGET": "60"])
    }

    func testNeedsShowsASubSettingOnlyWhileTheParentHasTheValue() throws {
        let rumble = #"{"env": "DM_RUMBLE", "kind": "toggle", "section": "Game", "label": "Rumble", "note": "", "default": "1", "on": "1", "off": "0"}"#
        let strength = #"{"env": "DM_RUMBLE_GAIN", "kind": "range", "section": "Game", "label": "Strength", "note": "", "default": "1.0", "min": 0, "max": 1, "step": 0.1, "needs": "DM_RUMBLE=1"}"#
        let orphan = #"{"env": "DM_X", "kind": "toggle", "section": "Game", "label": "X", "note": "", "default": "0", "on": "1", "off": "0", "needs": "DM_NOT_IN_LIST=1"}"#
        let list = try XCTUnwrap(LaunchSetting.read(app: try app([rumble, strength, orphan])))
        func shown(_ rumbleValue: String) -> [String] {
            list.filter { $0.isShown(in: list) { $0.env == "DM_RUMBLE" ? rumbleValue : $0.def } }.map(\.env)
        }
        XCTAssertEqual(shown("1"), ["DM_RUMBLE", "DM_RUMBLE_GAIN", "DM_X"])
        XCTAssertEqual(shown("0"), ["DM_RUMBLE", "DM_X"], "a row naming a variable the list lacks stays shown")
    }

    func testAnUnknownSectionComesAfterTheKnownOnesInListOrder() throws {
        func row(_ env: String, _ section: String) -> String {
            #"{"env": "\#(env)", "kind": "toggle", "section": "\#(section)", "label": "L", "note": "", "default": "0", "on": "1", "off": "0"}"#
        }
        let list = try XCTUnwrap(LaunchSetting.read(app: try app([row("DM_A", "Picture"), row("DM_B", "Game"), row("DM_C", "Audio"), row("DM_D", "Performance"), row("DM_E", "Picture")])))
        XCTAssertEqual(LaunchSetting.orderedSections(list), ["Game", "Performance", "Picture", "Audio"])
    }

    func testARangeTakesItsBoundsFromTheRowAndPictureIsDrawn() throws {
        let wide = #"{"env": "DM_RENDER_SCALE", "kind": "range", "section": "Picture", "label": "Render scale", "note": "", "default": "1.0", "min": 0.5, "max": 1.35, "step": 0.05, "base": {"docked": [1600, 900], "handheld": [1280, 720]}}"#
        let list = try XCTUnwrap(LaunchSetting.read(app: try app([fps, wide])))
        let s = list[1]
        XCTAssertEqual(s.max, 1.35)
        XCTAssertTrue(s.accepts("1.35")); XCTAssertFalse(s.accepts("1.4"))
        XCTAssertEqual(s.pixels(scale: 1.35, docked: true), "2160×1215", "no ceiling of 1.0 in the pixel display")
        let store = SavedChoices(domain: bundleID)
        store.set(s, "1.35")
        XCTAssertEqual(store.current(s), "1.35")
        XCTAssertEqual(LaunchSetting.orderedSections(list), ["Game", "Picture"])
    }

    func testTheRowsBaseWinsOverTheProfilesRenderBase() throws {
        let withBase = scale.dropLast() + #", "base": {"docked": [1920, 1080], "handheld": [1280, 720]}}"#
        let path = try app([String(withBase)])
        let profile = temporary.appendingPathComponent("repo/dm/games/\(titleID)")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try "title_id\t\(titleID)\nrender_base\t1600x900 1280x720\n".write(to: profile.appendingPathComponent("game.tsv"), atomically: true, encoding: .utf8)
        let s = try XCTUnwrap(LaunchSetting.forMac(app: path, titleID: titleID, repo: temporary.appendingPathComponent("repo").path, labels: { $0 })?.first)
        XCTAssertEqual(s.pixels(scale: 1, docked: true), "1920×1080")
        // Without a base in the row the profile's still applies
        let plain = try app([scale])
        let p = try XCTUnwrap(LaunchSetting.forMac(app: plain, titleID: titleID, repo: temporary.appendingPathComponent("repo").path, labels: { $0 })?.first)
        XCTAssertEqual(p.pixels(scale: 1, docked: true), "1600×900")
    }

    func testAHigherSchemaIsReadAsFarAsItCanBeAndLogged() throws {
        let future = #"{"env": "DM_Z", "kind": "dial", "section": "Game", "label": "Z", "note": "", "default": "0"}"#
        let data = Data(#"{"schema": 2, "game": "\#(titleID)", "settings": [\#(fps), \#(future), {"broken": true}]}"#.utf8)
        var logged: [String] = []
        let parsed = try XCTUnwrap(LaunchList.parse(data) { logged.append($0) })
        XCTAssertEqual(parsed.schema, 2)
        XCTAssertEqual(parsed.settings.map(\.env), ["DM_FPS_TARGET"], "a kind it cannot draw and a row it cannot read are left out")
        XCTAssertEqual(logged.count, 1)
        var none: [String] = []
        XCTAssertEqual(LaunchList.parse(Data(#"{"game": "\#(titleID)", "settings": []}"#.utf8)) { none.append($0) }?.schema, 1)
        XCTAssertTrue(none.isEmpty)
    }

    func testStartEnvironmentSkipsTheAppsWindowAndPassesOnlyOverrides() throws {
        let path = try app([fps, scale])
        let settings = try XCTUnwrap(LaunchSetting.forMac(app: path, titleID: titleID, repo: "", labels: { $0 }))
        var game = LibraryGame(titleID: titleID, name: "Zelda", appPath: path)
        let store = SavedChoices(domain: bundleID)
        store.set(settings[0], "60")
        var env = game.startEnvironment(controls: ["DM_KEYMAP": "a=b"], settings: settings, mods: [])
        XCTAssertEqual(env, ["DM_LAUNCHER": "0", "DM_KEYMAP": "a=b"], "saved choices are not in the environment, where they would override the store")
        game.launchOptions["DM_FULLSCREEN"] = "1"
        env = game.startEnvironment(controls: [:], settings: settings, mods: [])
        XCTAssertEqual(env, ["DM_LAUNCHER": "0", "DM_FULLSCREEN": "1"], "a launcher-only setting is an override, never written to the store")
        XCTAssertNil(store.raw("DM_FULLSCREEN"))
    }

    /// DMSettings as seedds/nxnative's dm/mac/pack_app.py settings_rules writes it.
    private static func rules(_ rows: [String]) -> [[String: Any]] {
        rows.compactMap { row in
            guard let s = try? JSONDecoder().decode(LaunchSetting.self, from: Data(row.utf8)) else { return nil }
            switch s.kind {
            case "range": return ["env": s.env, "min": s.min ?? 0, "max": s.max ?? 0]
            case "choice": return ["env": s.env, "values": (s.options ?? []).map { $0[0] }]
            default: return ["env": s.env, "values": [s.on ?? "1", s.off ?? "0"]]
            }
        }
    }

    /// dm/mac/launcher.c's saved_accepted, line for line: one of the rule's values, else a number from min to max.
    static func launcherCAccepts(_ rule: [String: Any], _ v: String) -> Bool {
        if let values = rule["values"] as? [String] { return values.contains(v) }
        guard let lo = rule["min"] as? Double, let hi = rule["max"] as? Double else { return false }
        return v.withCString { c -> Bool in
            var end: UnsafeMutablePointer<CChar>?
            let x = strtod(c, &end)
            let space = isspace(Int32(UInt8(bitPattern: c.pointee))) != 0
            return c.pointee != 0 && !space && strpbrk(c, "xX") == nil && end?.pointee == 0 && x == x && x >= lo && x <= hi
        }
    }

    func testWhatIsWrittenPassesTheRulesLauncherCChecks() throws {
        let wide = #"{"env": "DM_RENDER_SCALE", "kind": "range", "section": "Picture", "label": "Render scale", "note": "", "default": "1.0", "min": 0.5, "max": 1.35, "step": 0.05}"#
        let rows = [fps, wide, hold]
        let path = try app(rows, dmSettings: true)
        let list = try XCTUnwrap(LaunchSetting.read(app: path))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path + "/Contents/Info.plist")), format: nil) as? [String: Any])
        let rules = try XCTUnwrap(info["DMSettings"] as? [[String: Any]])
        let store = SavedChoices(domain: bundleID)
        // What the sheet writes: a slider's "%.2f" at every step, the options, on and off
        var written: [(LaunchSetting, String)] = []
        for n in stride(from: 0.5, through: 1.35, by: 0.05) { written.append((list[1], String(format: "%.2f", n))) }
        written += [(list[0], "60"), (list[2], "off")]
        for (s, v) in written where !s.isDefault(v) {
            store.set(s, v)
            let stored = try XCTUnwrap(store.raw(s.env) as? String, "\(s.env)=\(v) is kept")
            let rule = try XCTUnwrap(rules.first { $0["env"] as? String == s.env })
            XCTAssertTrue(Self.launcherCAccepts(rule, stored), "launcher.c accepts \(s.env)=\(stored)")
            XCTAssertTrue(s.accepts(stored))
        }
        // The two readers agree on what they refuse
        let rule = try XCTUnwrap(rules.first { $0["env"] as? String == "DM_RENDER_SCALE" })
        for v in ["0x1", " 0.8", "nan", "", "0.4", "1.36", "1e0x", "1", "1.", "+1", "0.5", "1.35", "1e0", "inf"] {
            XCTAssertEqual(Self.launcherCAccepts(rule, v), list[1].accepts(v), "range value '\(v)'")
        }
    }

    func testAppReadsTheStoreOnlyWithDMSettings() throws {
        let withRules = try app([fps, scale, hold], dmSettings: true)
        XCTAssertTrue(SavedChoices.appReadsStore(app: withRules))
        let older = try app([fps, scale, hold])
        XCTAssertFalse(SavedChoices.appReadsStore(app: older))
        let store = SavedChoices(domain: bundleID)
        let list = try XCTUnwrap(LaunchSetting.read(app: older))
        store.set(list[0], "60"); store.set(list[1], "0.75")
        let game = LibraryGame(titleID: titleID, name: "Z", appPath: older)
        XCTAssertEqual(game.startEnvironment(controls: [:], settings: list, mods: [], store: store, appReadsStore: true),
                       ["DM_LAUNCHER": "0"], "the app reads the store itself: nothing for the rows")
        XCTAssertEqual(game.startEnvironment(controls: [:], settings: list, mods: [], store: store, appReadsStore: false),
                       ["DM_LAUNCHER": "0", "DM_FPS_TARGET": "60", "DM_RENDER_SCALE": "0.75"],
                       "an older launcher.c: the saved non-default choices go in the environment, defaults stay out")
    }
}
