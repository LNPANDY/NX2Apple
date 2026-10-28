import XCTest
import SwiftUI
@testable import NSPortBuilder

/// The live console driver over a real GameLibrary in a temporary folder, with fake controllers and a fake launch call.
@MainActor final class ConsoleLiveTests: XCTestCase {
    private var temporary: URL!
    private let titleID = "01001A9012345000"
    private let bundleID = "org.nxnative.consolelivetests"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ConsoleLiveTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: temporary)
        for key in ["launcher.DM_FPS_TARGET"] { CFPreferencesSetAppValue(key as CFString, nil, bundleID as CFString) }
        CFPreferencesAppSynchronize(bundleID as CFString)
    }

    private func makeApp(name: String = "Hades") throws -> URL {
        let app = temporary.appendingPathComponent(name + ".app")
        let macos = app.appendingPathComponent("Contents/MacOS"), dm = app.appendingPathComponent("Contents/Resources/dm")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dm, withIntermediateDirectories: true)
        for exe in ["nxnative", "dmhost"] { try FileManager.default.createSymbolicLink(at: macos.appendingPathComponent(exe), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true")) }
        let info: [String: Any] = ["DMTitleID": titleID, "CFBundleDisplayName": name, "CFBundleExecutable": "nxnative", "CFBundleIdentifier": bundleID,
                                   "CFBundleShortVersionString": "1.2.3"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let list = #"{"schema":1,"settings":[{"env":"DM_FPS_TARGET","kind":"choice","label":"Frame rate","note":"","default":"60","section":"Game","options":[["30","30 fps"],["60","60 fps"]]}]}"#
        try Data(list.utf8).write(to: dm.appendingPathComponent("launcher.json"))
        return app
    }

    private struct Launch { var game: LibraryGame; var environment: [String: String] }

    private func makeDriver(controls: ControlLayout? = nil, pads: [ConsolePadSnapshot] = [], launched: @escaping (Launch) -> Void = { _ in }) throws
        -> (LiveConsoleDriver, GameLibrary, ControlLayout) {
        let library = GameLibrary(file: temporary.appendingPathComponent("library.json"))
        _ = try library.addApp(try makeApp())
        let layout = controls ?? ControlLayout(defaults: UserDefaults(suiteName: "ConsoleLiveTests-" + UUID().uuidString)!)
        let driver = LiveConsoleDriver(library: library, controls: layout, repo: { "" }, lang: { .en }, labels: { L10n.string($0, .en) },
                                       pads: { pads }, launch: { game, env, done in launched(Launch(game: game, environment: env)); done(4242, nil) },
                                       artwork: { _, _ in nil }, startingTimeout: 0.2, observeSystem: false)
        return (driver, library, layout)
    }

    func testLibraryEntriesBecomeConsoleGames() throws {
        let (driver, library, _) = try makeDriver()
        let game = try XCTUnwrap(driver.state.games.first)
        XCTAssertEqual(library.games.count, 1)
        XCTAssertEqual(game.title, "Hades")
        XCTAssertEqual(game.version, "1.2.3")
        XCTAssertEqual(game.status, .ready)
        XCTAssertEqual(game.platforms, [.mac])
        XCTAssertTrue(game.settings.map(\.env).contains("DM_FPS_TARGET"))
        XCTAssertEqual(game.values["DM_FPS_TARGET"], "60")
        XCTAssertEqual(driver.state.focusedGameID, game.id)
    }

    func testStatusAndPlatformsPerLibraryEntry() {
        let broken = LibraryGame(titleID: titleID, name: "A", appPath: "/gone/A.app")
        XCTAssertEqual(LiveConsoleDriver.status(of: broken, brokenMessage: "x"), .broken("x"))
        XCTAssertEqual(LiveConsoleDriver.status(of: LibraryGame(titleID: titleID, name: "B"), brokenMessage: "x"), .needsData)
        var chosen = LibraryGame(titleID: titleID, name: "C")
        chosen.inputs = ["keys": ["/k"]]
        XCTAssertEqual(LiveConsoleDriver.status(of: chosen, brokenMessage: "x"), .needsBuild)
        XCTAssertEqual(LiveConsoleDriver.platforms(of: broken), [.mac])
    }

    func testPlayRoutesToTheLaunchWithTheDesktopEnvironment() throws {
        var launches: [Launch] = []
        let (driver, _, layout) = try makeDriver { launches.append($0) }
        layout.padMerge = true
        let id = try XCTUnwrap(driver.state.games.first?.id)
        driver.play(id)
        XCTAssertEqual(launches.count, 1)
        XCTAssertEqual(launches.first?.environment["DM_PAD_MERGE"], "1")
        XCTAssertEqual(launches.first?.environment["DM_LAUNCHER"], "0")
        XCTAssertEqual(launches.first?.game.titleID, titleID)
        let expected = launches.first.map { GameStart.environment(for: $0.game, library: GameLibrary(file: temporary.appendingPathComponent("other.json")), controls: layout, repo: "", labels: { $0 }) }
        XCTAssertEqual(launches.first?.environment, expected, "the same function the desktop Play uses")
    }

    func testStartingEndsWhenTheGameQuits() async throws {
        let (driver, _, _) = try makeDriver()
        let id = try XCTUnwrap(driver.state.games.first?.id)
        driver.play(id)
        for _ in 0..<50 where driver.state.starting != .opening { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(driver.state.startingGameID, id)
        XCTAssertEqual(driver.state.starting, .opening)
        driver.gameDidTerminate(pid: 1)
        XCTAssertEqual(driver.state.startingGameID, id, "another process changes nothing")
        driver.gameDidTerminate(pid: 4242)
        XCTAssertNil(driver.state.startingGameID)
        XCTAssertFalse(driver.state.exited)
        XCTAssertEqual(driver.state.focusedGameID, id, "the selected game is kept")
    }

    func testOptionsRoundTripThroughSavedChoices() throws {
        let (driver, library, _) = try makeDriver()
        let game = try XCTUnwrap(library.games.first)
        let id = game.id.uuidString
        driver.setOption(gameID: id, setting: "DM_FPS_TARGET", value: "30")
        XCTAssertEqual(driver.state.games.first?.values["DM_FPS_TARGET"], "30")
        let setting = try XCTUnwrap(driver.state.games.first?.settings.first { $0.env == "DM_FPS_TARGET" })
        XCTAssertEqual(SavedChoices(app: game.appPath, titleID: game.titleID).current(setting), "30", "the same store LaunchOptionsView reads")
        driver.refresh()
        XCTAssertEqual(driver.state.games.first?.values["DM_FPS_TARGET"], "30")
        driver.setOption(gameID: id, setting: "DM_FPS_TARGET", value: "60")
        XCTAssertNil(SavedChoices(app: game.appPath, titleID: game.titleID).value(setting), "the default removes the saved choice")
        driver.setOption(gameID: id, setting: "DM_FPS_TARGET", value: "999")
        XCTAssertEqual(driver.state.games.first?.values["DM_FPS_TARGET"], "60", "a value the build does not offer is refused")
    }

    func testControllerSnapshotMapping() {
        let xbox = ConsolePadSnapshot(id: "a", name: "Wireless Controller", category: "Xbox One", playerIndex: 2, battery: 0.76, charging: false).controller
        XCTAssertEqual(xbox.kind, .xbox)
        XCTAssertEqual(xbox.player, 2)
        XCTAssertEqual(xbox.batteryPercent, 76)
        XCTAssertEqual(ConsolePadSnapshot(id: "b", name: "p", category: "Switch Pro Controller", playerIndex: nil).controller.kind, .fullSize)
        XCTAssertEqual(ConsolePadSnapshot(id: "c", name: "j", category: "Nintendo Switch JoyCon (L/R)", playerIndex: 1).controller.kind, .paired)
        let ps = ConsolePadSnapshot(id: "d", name: "DualSense", category: "DualSense", playerIndex: 4, battery: 0.1, charging: true).controller
        XCTAssertEqual(ps.kind, .gamepad)
        XCTAssertTrue(ps.charging)
        XCTAssertNil(ConsolePadSnapshot(id: "e", name: "x", category: nil, playerIndex: nil).controller.battery)
    }

    func testDriverShowsFakeControllersAndTheSharedPlayerMode() throws {
        let pads = [ConsolePadSnapshot(id: "a", name: "Pad", category: "Xbox One", playerIndex: 1, battery: 0.5)]
        let (driver, _, layout) = try makeDriver(pads: pads)
        XCTAssertEqual(driver.state.controllers.map(\.id), ["a"])
        driver.setPadMerge(true)
        XCTAssertTrue(layout.padMerge)
        XCTAssertTrue(driver.state.padMerge)
        driver.disconnect(controllerID: "a")
        XCTAssertNotNil(driver.state.toast, "a Bluetooth controller cannot be dropped by an app: the toast says where")
    }

    func testEnteringAndLeavingConsoleModeRestoresTheWindow() {
        var calls: [Bool] = []
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let coordinator = ConsoleCoordinator(window: { window }, setFullScreen: { _, on in calls.append(on) })
        coordinator.enter()
        XCTAssertFalse(coordinator.active, "not while the guided setup shows")
        coordinator.available = true
        coordinator.enter()
        XCTAssertTrue(coordinator.active)
        XCTAssertEqual(calls, [true])
        coordinator.enter()
        XCTAssertEqual(calls, [true], "entering twice does nothing")
        coordinator.exit()
        XCTAssertFalse(coordinator.active)
        coordinator.toggle()
        XCTAssertTrue(coordinator.active)
    }

    func testControllerPromptOncePerSessionAndSetting() {
        XCTAssertTrue(ConsolePrompt.shouldShow(enabled: true, shown: false))
        XCTAssertFalse(ConsolePrompt.shouldShow(enabled: true, shown: true))
        XCTAssertFalse(ConsolePrompt.shouldShow(enabled: false, shown: false))
    }

    func testBatteryFillFraction() {
        XCTAssertEqual(BatteryIcon.fillFraction(0.76), 0.76)
        XCTAssertEqual(BatteryIcon.fillFraction(0), 0)
        XCTAssertEqual(BatteryIcon.fillFraction(1.4), 1)
        XCTAssertEqual(BatteryIcon.fillFraction(-1), 0)
        XCTAssertEqual(BatteryIcon.fillFraction(.nan), 0)
        XCTAssertEqual(BatteryIcon.fillFraction(nil), 0)
        XCTAssertTrue(BatteryIcon.isLow(0.2))
        XCTAssertTrue(BatteryIcon.isLow(0.12))
        XCTAssertFalse(BatteryIcon.isLow(0.21))
        XCTAssertFalse(BatteryIcon.isLow(nil))
    }

    func testPlayersAreAssignedAutomaticallyInOrder() {
        func pad(_ id: String, _ player: Int?) -> ConsolePadSnapshot { ConsolePadSnapshot(id: id, name: id, category: nil, playerIndex: player) }
        let result = LiveConsoleDriver.autoAssigned([pad("a", nil), pad("b", 1), pad("c", nil), pad("d", nil)])
        XCTAssertEqual(result.map(\.playerIndex), [2, 1, 3, 4], "the next free players, never one already taken")
        let full = LiveConsoleDriver.autoAssigned([pad("a", 1), pad("b", 2), pad("c", 3), pad("d", 4), pad("e", nil)])
        XCTAssertNil(full.last?.playerIndex, "a fifth controller has no free player")
        XCTAssertEqual(LiveConsoleDriver.autoAssigned([pad("a", 3)]).map(\.playerIndex), [3], "an assigned one keeps its player")
    }

    func testDriverListsFakeControllersWithPlayers() throws {
        let pads = [ConsolePadSnapshot(id: "a", name: "Pad", category: "Xbox One", playerIndex: nil)]
        let (driver, _, _) = try makeDriver(pads: pads)
        XCTAssertEqual(driver.state.controllers.first?.player, 1, "never shown as unassigned")
    }

    func testIPhoneOnlyAndNotBuiltStatuses() throws {
        var ios = LibraryGame(titleID: titleID, name: "A")
        ios.iosAppPath = temporary.path   // any folder with an Info.plist counts as an iOS app
        try Data([0]).write(to: temporary.appendingPathComponent("Info.plist"))
        XCTAssertEqual(LiveConsoleDriver.status(of: ios, brokenMessage: "x"), .iphoneOnly)
        XCTAssertEqual(LiveConsoleDriver.platforms(of: ios), [.iphone])
        XCTAssertEqual(LiveConsoleDriver.status(of: LibraryGame(titleID: titleID, name: "B"), brokenMessage: "x"), .needsData)
        XCTAssertEqual(ConsoleGame.Status.iphoneOnly.labelKey, "console.iphoneOnly")
        XCTAssertEqual(ConsoleGame.Status.needsBuild.labelKey, "console.notBuilt")
        XCTAssertEqual(ConsoleGame.Status.needsData.labelKey, "console.needsDataBadge")
    }

    func testVersionFromMacAppIOSAppAndPlist() throws {
        XCTAssertEqual(LiveConsoleDriver.version(plist: try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "1.2.3"], format: .xml, options: 0)), "1.2.3")
        XCTAssertEqual(LiveConsoleDriver.version(plist: try PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion": "7"], format: .xml, options: 0)), "7")
        XCTAssertEqual(LiveConsoleDriver.version(plist: Data([0])), "")
        let ios = temporary.appendingPathComponent("ios.app")
        try FileManager.default.createDirectory(at: ios, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "2.0.1"], format: .xml, options: 0).write(to: ios.appendingPathComponent("Info.plist"))
        XCTAssertEqual(LiveConsoleDriver.version(at: ios.path), "2.0.1")
        XCTAssertEqual(LiveConsoleDriver.version(at: temporary.appendingPathComponent("none.app").path), "")
    }
}
