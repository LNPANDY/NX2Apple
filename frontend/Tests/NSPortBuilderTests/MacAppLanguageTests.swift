import XCTest
@testable import NSPortBuilder

/// A mac-app's launcher.json as seedds/nxnative writes it, and the Game language row it gives the Launch options sheet (LNPANDY/NX2Apple#109).
///
/// The fixture is real output, not hand-written: dm/games/settings.py of seedds/nxnative main (3950976) run as build_ipa_from_nsp.py
/// runs it for --platform mac-app (GFXAPI=nvn SETTINGS_PLATFORM=mac DM_LANG=zh-Hans) for profile 01008CF01BAAC000 (Zelda: Echoes of
/// Wisdom) over a control.nacp built for the test (no game files): only the SupportedLanguageFlag at 0x302C, set to en-US, ja, fr, de,
/// es, it, pt, ru, ko, zh-Hant and zh-Hans. Regenerate it the same way when settings.py or settings.tsv changes the rows.
final class MacAppLanguageTests: XCTestCase {
    private var temporary: URL!
    private let titleID = "01008CF01BAAC000"
    private var bundleID: String { "org.nxnative.frontendtests.lang." + temporary.lastPathComponent }
    private let languages = ["en-US", "ja", "fr", "de", "es", "it", "pt", "ru", "ko", "zh-Hant", "zh-Hans"]

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-lang-" + UUID().uuidString)
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
