import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
import NXLauncher

/// The launch options of an app nxkit built (`nxb build`): its own list in `Contents/Resources/nxkit/launcher.json`, drawn as it is.
/// `Tests/Fixtures/nxkit_launcher.json` is the list nxkit writes for a handheld title (nxkit's crates/nxb-build/src/standalone/launcher.rs
/// from the table in crates/nxkit-abi/src/launch.rs). The host reads the saved choices `launcher.<VAR>` itself, so none of them is in
/// the environment, and it reads none of the DM_* variables, so the launcher adds no row of its own.
final class NxkitLaunchOptionsTests: IsolatedDefaultsTestCase {
    private var temporary: URL!
    private let titleID = "0100346017304000"
    private var bundleID: String { TestPreferences.domain(in: temporary, "nxkit") }
    private static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/nxkit_launcher.json")

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-nxkit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        CFPreferencesAppSynchronize(bundleID as CFString)
        try FileManager.default.removeItem(at: temporary)
    }

    /// An app as nxb builds it: `nxkit-host` as the program and the run folder `Contents/Resources/nxkit` with the list. A real one has
    /// the bundle ID `org.nxkit.game.<title ID>`. Here it is a path in the test's folder (TestPreferences) with the title ID in DMTitleID,
    /// which MacGameBundle also reads for nxkit, so nothing touches a real game's domain.
    private func nxkitApp(name: String = "Game", withList: Bool = true) throws -> String {
        let app = temporary.appendingPathComponent(name + ".app")
        let macos = app.appendingPathComponent("Contents/MacOS")
        let run = app.appendingPathComponent("Contents/Resources/nxkit")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let host = macos.appendingPathComponent(NxkitBuilder.hostName)
        try Data("#!/bin/sh\n".utf8).write(to: host)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: host.path)
        if withList { try FileManager.default.copyItem(at: Self.fixture, to: run.appendingPathComponent("launcher.json")) }
        let info: [String: Any] = ["CFBundleExecutable": NxkitBuilder.hostName, "CFBundleIdentifier": bundleID, "CFBundlePackageType": "APPL",
                                   "CFBundleName": "Game", "DMTitleID": titleID]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app.path
    }

    /// A dm app with the same list in dm's place, for the comparison.
    private func dmApp() throws -> String {
        let app = temporary.appendingPathComponent("Dm.app")
        let dm = app.appendingPathComponent("Contents/Resources/dm")
        try FileManager.default.createDirectory(at: dm, withIntermediateDirectories: true)
        let opmode = #"{"env": "DM_OPMODE", "kind": "choice", "label": "Console mode", "note": "", "default": "1", "section": "Game", "options": [["1", "Docked"], ["0", "Handheld"]]}"#
        try #"{"schema": 1, "game": "\#(titleID)", "settings": [\#(opmode)]}"#.write(to: dm.appendingPathComponent("launcher.json"), atomically: true, encoding: .utf8)
        return app.path
    }

    private func rows(_ app: String, _ lang: Lang = .en) throws -> [LaunchSetting] {
        try XCTUnwrap(LaunchSetting.forMac(app: app, titleID: titleID, repo: temporary.path, labels: { L10n.string($0, lang) }))
    }

    func testAnNxkitAppGetsExactlyTheRowsOfItsOwnList() throws {
        let app = try nxkitApp()
        XCTAssertTrue(NxkitLaunch.isNxkit(app: app))
        XCTAssertEqual(LaunchSetting.listURL(app: app).path, app + "/Contents/Resources/nxkit/launcher.json")
        let list = try rows(app)
        XCTAssertEqual(list.map(\.env), ["NXKIT_OP_MODE", "NXKIT_FULLSCREEN", "NXKIT_PAUSE_UNFOCUSED", "NXKIT_HOME_MENU", "NXKIT_HOME_QUIT"],
                       "no Display mode, game language, macOS Game Mode or other row of dm's")
        XCTAssertTrue(list.allSatisfy(\.storeBacked), "every row is a saved choice")
        XCTAssertTrue(list.allSatisfy { $0.base == nil && $0.macLanguage == nil && $0.packedDefault == nil })
        let mode = list[0]
        XCTAssertEqual([mode.kind, mode.def, mode.sectionTitle], ["choice", "handheld", "Game"], "the default is the title module's mode")
        XCTAssertEqual(mode.options ?? [], [["docked", "TV (docked)"], ["handheld", "Handheld"]])
        XCTAssertEqual(list.filter(\.isBasic).map(\.env), ["NXKIT_OP_MODE", "NXKIT_FULLSCREEN"], "the list's level decides")
        XCTAssertEqual(list.filter { $0.sectionTitle == "Controls" }.map(\.env), ["NXKIT_HOME_MENU", "NXKIT_HOME_QUIT"])
    }

    func testAnNxkitAppWithoutAListHasNoneAndDmsPlaceIsNotRead() throws {
        let app = try nxkitApp(withList: false)
        let dm = URL(fileURLWithPath: app).appendingPathComponent("Contents/Resources/dm")
        try FileManager.default.createDirectory(at: dm, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.fixture, to: dm.appendingPathComponent("launcher.json"))
        XCTAssertNil(LaunchSetting.read(app: app))
        XCTAssertNil(LaunchSetting.forMac(app: app, titleID: titleID, repo: "", labels: { $0 }))
    }

    func testADmAppIsUnchanged() throws {
        let app = try dmApp()
        XCTAssertFalse(NxkitLaunch.isNxkit(app: app))
        XCTAssertEqual(LaunchSetting.listURL(app: app).path, app + "/Contents/Resources/dm/launcher.json")
        XCTAssertEqual(try rows(app).map(\.env), ["DM_FULLSCREEN", "DM_OPMODE"], "dm's list still gets the Display mode row")
    }

    func testTheRowsAreInTheLaunchersLanguageWithTheBuildsEnglish() throws {
        let list = try JSONDecoder().decode(NxkitList.self, from: Data(contentsOf: Self.fixture)).settings
        for row in list {
            XCTAssertEqual(L10n.string("launch.set." + row.env, .en), row.label, row.env)
            XCTAssertEqual(L10n.string("launch.set.\(row.env).note", .en), row.note, row.env)
            for option in row.options ?? [] { XCTAssertEqual(L10n.string("launch.opt.\(row.env).\(option[0])", .en), option[1], row.env) }
        }
        let de = try rows(try nxkitApp(), .de)
        XCTAssertEqual(de[0].label, "Konsolenmodus")
        XCTAssertEqual(de[0].options ?? [], [["docked", "TV (angedockt)"], ["handheld", "Handheld"]], "the values stay, the labels change")
        XCTAssertEqual(de[1].label, "Vollbild")
    }

    func testChoicesAreSavedInTheAppsDomainAndNeverPassedInTheEnvironment() throws {
        let app = try nxkitApp()
        let list = try rows(app)
        let store = SavedChoices(app: app, titleID: titleID)
        XCTAssertEqual(store.domain, bundleID, "the app's CFBundleIdentifier, as the host reads it")
        let mode = list[0], full = list[1]
        store.set(mode, "docked")
        store.set(full, "1")
        XCTAssertEqual(store.raw("NXKIT_OP_MODE") as? String, "docked")
        XCTAssertEqual(store.current(full), "1")
        store.set(full, "0")
        XCTAssertNil(store.raw("NXKIT_FULLSCREEN"), "the default removes the key")
        store.set(mode, "tv")
        XCTAssertNil(store.raw("NXKIT_OP_MODE"), "a value the row does not accept is not kept")
        store.set(full, "1")
        XCTAssertTrue(SavedChoices.appReadsStore(app: app), "nxkit's host reads launcher.<VAR> without DMSettings")
        let game = LibraryGame(titleID: titleID, name: "Game", appPath: app)
        let env = game.startEnvironment(controls: [:], settings: list, mods: [], store: store, appReadsStore: SavedChoices.appReadsStore(app: app))
        XCTAssertEqual(env, ["DM_LAUNCHER": "0"], "no row is in the environment, where it would override the saved choice")
        XCTAssertTrue(game.launchEnvironment(list).isEmpty)
        store.reset(list)
        XCTAssertNil(store.raw("NXKIT_FULLSCREEN"))
    }

    func testARealNxkitBundleIDIsTheDomain() throws {
        let app = temporary.appendingPathComponent("Real.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "org.nxkit.game." + titleID.lowercased(), "CFBundleExecutable": NxkitBuilder.hostName]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(SavedChoices.domain(app: app.path, titleID: titleID), "org.nxkit.game.0100346017304000")
    }

    func testPersonalDisplayModeIsNotGivenToAnNxkitApp() throws {
        let app = try nxkitApp()
        let library = GameLibrary(file: temporary.appendingPathComponent("library.json"))
        library.games = [LibraryGame(titleID: titleID, name: "Game", appPath: app)]
        library.applyPersonalDefaults(PersonalDefaults(values: ["DM_FULLSCREEN": "1"]))
        XCTAssertNil(library.games[0].launchOptions["DM_FULLSCREEN"])
        XCTAssertTrue(library.games[0].defaultsApplied)
    }

    /// The Launch options sheet of an nxkit app, for visual QA (NX_LAUNCHER_CAPTURE_DIR, NX_CAPTURE_LANG). "before" is the app without
    /// a list where dm keeps one, which is what the launcher saw before it read `Contents/Resources/nxkit/launcher.json`.
    @MainActor func testCaptureTheLaunchOptionsOfAnNxkitApp() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        let lang = Lang(ProcessInfo.processInfo.environment["NX_CAPTURE_LANG"] ?? "en")
        func capture(_ name: String, app: String) throws {
            var game = LibraryGame(titleID: titleID, name: "[Game]")
            game.appPath = app
            struct Snapshot: Codable { let games: [LibraryGame]; let folder: String }
            let file = temporary.appendingPathComponent(name + ".json")
            try JSONEncoder().encode(Snapshot(games: [game], folder: temporary.path)).write(to: file)
            let library = GameLibrary(file: file)
            let stores = LauncherStores(defaults: testDefaults)
            stores.build.lang = lang
            stores.localizer.lang = lang
            let view = LaunchOptionsView(m: stores.build, library: library, gameID: library.games[0].id)
                .environmentObject(PadFocus()).environmentObject(stores.localizer).frame(width: 760, height: 560)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 760, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderBack(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("nxkit-launch-options-\(name)-\(lang.code).png"))
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        try capture("before", app: try nxkitApp(name: "Before", withList: false))
        try capture("after", app: try nxkitApp(name: "After"))
    }

    private struct NxkitList: Decodable { let settings: [LaunchSetting] }
}
