import XCTest
import AppKit
@testable import NX2Apple
@testable import NXCore

@MainActor final class ControllerLaunchTests: IsolatedDefaultsTestCase {
    private var temporary: URL!
    private var domain: String { TestPreferences.domain(in: temporary, "controller") }
    private let titleID = "0100000000000000"
    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        _ = SystemControllerPreferences(domain: domain).synchronize()
        try FileManager.default.removeItem(at: temporary)
    }
    private func game(marker: Any? = 1) throws -> LibraryGame {
        let app = temporary.appendingPathComponent("Game.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources/dm"), withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": domain, "DMSettings": [], "DMTitleID": titleID]
        info["DMControllerMappings"] = marker
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        return LibraryGame(titleID: titleID, name: "Controller test", appPath: app.path)
    }
    private func start(_ game: LibraryGame, _ layout: ControlLayout) -> [String: String] {
        GameStart.environment(for: game, library: GameLibrary(file: temporary.appendingPathComponent("library.json")), controls: layout, repo: "", labels: { $0 }, screen: nil)
    }
    func testActualLaunchImportsOnceAndResetIsNotReseeded() throws {
        let game = try game()
        testDefaults.set(true, forKey: "joyconSplit")   // legacy setting from older builds must not pass DM_JOYCON_SPLIT
        let layout = ControlLayout(defaults: testDefaults)
        layout.assign(ControlLayout.functions.first { $0.id == "A" }!, key: 40)
        layout.setSends("A", "B")
        layout.padMerge = true
        let storage = SystemControllerPreferences(domain: domain)
        storage.write("launcher.DM_PAD_MAP", value: "A=Shake")
        storage.write("launcher.DM_FPS_TARGET", value: "60")
        _ = storage.synchronize()
        let env = start(game, layout)
        XCTAssertNil(env["DM_KEYMAP"])
        XCTAssertNil(env["DM_PAD_MAP"])
        XCTAssertEqual(env["DM_PAD_MERGE"], "1")
        XCTAssertNil(env["DM_JOYCON_SPLIT"])
        XCTAssertEqual(storage.read("launcher.DM_KEYMAP") as? String, "A=40,B=none")
        XCTAssertEqual(storage.read("launcher.DM_PAD_MAP") as? String, "A=Shake")
        XCTAssertEqual(storage.read("launcher.DM_FPS_TARGET") as? String, "60")
        _ = game.controllerPreferences().setMap("DM_PAD_MAP", value: nil)
        _ = start(game, layout)
        XCTAssertNil(storage.read("launcher.DM_PAD_MAP"))
    }
    func testOldAppsNeedExplicitCapabilityAndKeepLegacyEnvironment() throws {
        let layout = ControlLayout(defaults: testDefaults)
        layout.setSends("A", "B")
        let markers: [Any?] = [nil, 0, 1.5, "1"]
        for marker in markers {
            let game = try game(marker: marker)
            XCTAssertFalse(SavedChoices.appReadsControllerMappings(app: game.appPath))
            XCTAssertEqual(start(game, layout)["DM_PAD_MAP"], "A=B")
            XCTAssertNil(SystemControllerPreferences(domain: domain).read(ControllerPreferences.importedKey))
        }
    }
    func testAppEnvDisableAndManualOverridesAreHonored() throws {
        var game = try game()
        let layout = ControlLayout(defaults: testDefaults)
        layout.setSends("A", "B")
        let file = URL(fileURLWithPath: game.appPath).appendingPathComponent("Contents/Resources/dm/env.txt")
        try "DM_SAVED_CHOICES=0\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(start(game, layout)["DM_PAD_MAP"], "A=B")
        let storage = SystemControllerPreferences(domain: domain)
        XCTAssertNil(storage.read(ControllerPreferences.importedKey))
        XCTAssertNil(storage.read("launcher.DM_PAD_MAP"))
        game.launchOptions = ["DM_SAVED_CHOICES": "1", "DM_PAD_MAP": "A=Shake", "DM_KEYMAP": "A=0"]
        let env = start(game, layout)
        XCTAssertEqual(env["DM_PAD_MAP"], "A=Shake")
        XCTAssertEqual(env["DM_KEYMAP"], "A=0")
        XCTAssertEqual(storage.read("launcher.DM_PAD_MAP") as? String, "A=B", "only the global layout is seeded, manual overrides stay temporary")
    }
    func testPlayerEnvTakesPrecedenceOverAppEnvWithoutTouchingPreferences() throws {
        let game = try game()
        let support = temporary.appendingPathComponent("support")
        let folder = support.appendingPathComponent("nxnative").appendingPathComponent(titleID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "DM_SAVED_CHOICES=0".write(to: folder.appendingPathComponent("env.txt"), atomically: true, encoding: .utf8)
        var mismatched = game
        mismatched.titleID = "different-library-value"
        XCTAssertFalse(mismatched.controllerSavingEnabled(environment: [:], support: support), "the host uses the packed title ID for env.txt")
        XCTAssertFalse(game.controllerSavingEnabled(environment: [:], support: support))
        XCTAssertTrue(game.controllerSavingEnabled(environment: ["DM_SAVED_CHOICES": "1"], support: support))
    }
    func testPerGameLayoutRoundtripPreservesShakeAndDoesNotWriteGlobalDefaults() {
        var maps: [String: String] = [:]
        let before = testDefaults.dictionaryRepresentation()
        let layout = ControlLayout(keyMap: "a=40", padMap: "a=sHaKe") { maps[$0] = $1 }
        XCTAssertEqual(layout.sends("A"), "Shake")
        XCTAssertNil(layout.key(ControlLayout.functions.first { $0.id == "B" }!))
        layout.setSends("B", "Shake")
        XCTAssertEqual(maps["DM_PAD_MAP"], "A=Shake,B=Shake")
        layout.assign(ControlLayout.functions.first { $0.id == "X" }!, key: 40)
        XCTAssertNil(layout.key(ControlLayout.functions.first { $0.id == "A" }!))
        XCTAssertEqual(NSDictionary(dictionary: testDefaults.dictionaryRepresentation()), NSDictionary(dictionary: before))
    }
}
