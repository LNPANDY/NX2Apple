import AppKit
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

/// DM_SCREEN in the launch environment (front_mac.m opens the game's window on that NSScreenNumber).
@MainActor final class GameStartScreenTests: IsolatedDefaultsTestCase {
    private func number(_ screen: NSScreen) -> NSNumber? { screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber }

    func testDisplaySelectionResolvesCurrentNumberAndFallsBack() {
        let screens: [(uuid: String, id: UInt32)] = [("saved-screen", 52), ("launcher-screen", 7)]
        XCTAssertEqual(GameDisplay.displayID(savedUUID: "saved-screen", launcherID: 7, available: screens), 52)
        XCTAssertEqual(GameDisplay.displayID(savedUUID: "", launcherID: 7, available: screens), 7)
        XCTAssertEqual(GameDisplay.displayID(savedUUID: "unplugged-screen", launcherID: 7, available: screens), 7)
        XCTAssertNil(GameDisplay.displayID(savedUUID: "unplugged-screen", launcherID: nil, available: screens))
        XCTAssertEqual(GameDisplay.displayID(savedUUID: "saved-screen", launcherID: 7, available: [("saved-screen", 81)]), 81)
    }

    func testDisplayIDIsTheScreenNumber() throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "needs a display")
        for screen in NSScreen.screens { XCTAssertEqual(GameStart.displayID(of: screen), number(screen)?.uint32Value) }
        XCTAssertNil(GameStart.displayID(of: nil))
    }

    func testLaunchEnvironmentCarriesTheScreenOfTheLauncher() throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "needs a display")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GameStartScreenTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = GameLibrary(file: dir.appendingPathComponent("library.json"))
        let layout = ControlLayout(defaults: TestDefaults.make("GameStartScreenTests"))
        let game = LibraryGame(titleID: "01001A9012345000", name: "X", appPath: dir.appendingPathComponent("X.app").path)
        func environment(_ screen: NSScreen?) -> [String: String] {
            GameStart.environment(for: game, library: library, controls: layout, repo: "", labels: { $0 }, screen: screen)
        }
        for screen in NSScreen.screens { XCTAssertEqual(environment(screen)["DM_SCREEN"], number(screen).map { String($0.uint32Value) }) }
        XCTAssertNil(environment(nil)["DM_SCREEN"], "no screen: the host keeps its default")
        // The default is the key window's screen, else the main one (no window is key in a test)
        XCTAssertEqual(GameStart.environment(for: game, library: library, controls: layout, repo: "", labels: { $0 })["DM_SCREEN"],
                       NSScreen.main.flatMap(number).map { String($0.uint32Value) })
    }

    func testSavedDisplayUUIDResolvesAtLaunchAndFallsBackWhenDisconnected() throws {
        guard let launcher = NSScreen.screens.first, let uuid = GameDisplay.uuid(of: launcher) else {
            throw XCTSkip("needs a display with a UUID")
        }
        let screens = NSScreen.screens
        XCTAssertEqual(GameDisplay.displayID(savedUUID: "", launcher: launcher, screens: screens), GameStart.displayID(of: launcher))
        XCTAssertEqual(GameDisplay.displayID(savedUUID: uuid, launcher: nil, screens: screens), GameStart.displayID(of: launcher))
        XCTAssertEqual(GameDisplay.displayID(savedUUID: uuid, launcher: launcher, screens: []), GameStart.displayID(of: launcher))
        XCTAssertEqual(GameDisplay.displayID(savedUUID: UUID().uuidString, launcher: launcher, screens: screens), GameStart.displayID(of: launcher))
        if let other = screens.dropFirst().first, let otherUUID = GameDisplay.uuid(of: other) {
            XCTAssertEqual(GameDisplay.displayID(savedUUID: otherUUID, launcher: launcher, screens: screens), GameStart.displayID(of: other))
        }
    }

    func testSavedDisplayIsPassedToGameEnvironment() throws {
        guard let screen = NSScreen.screens.first, let uuid = GameDisplay.uuid(of: screen) else {
            throw XCTSkip("needs a display with a UUID")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GameStartScreenTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = GameLibrary(file: dir.appendingPathComponent("library.json"))
        let layout = ControlLayout(defaults: testDefaults)
        let game = LibraryGame(titleID: "01001A9012345000", name: "X", appPath: dir.appendingPathComponent("X.app").path)
        testDefaults.set(uuid, forKey: GameDisplay.defaultsKey)
        XCTAssertEqual(GameStart.environment(for: game, library: library, controls: layout, repo: "", labels: { $0 },
                                             screen: nil, defaults: testDefaults)["DM_SCREEN"], String(GameStart.displayID(of: screen)!))
        testDefaults.set(UUID().uuidString, forKey: GameDisplay.defaultsKey)
        XCTAssertNil(GameStart.environment(for: game, library: library, controls: layout, repo: "", labels: { $0 },
                                          screen: nil, defaults: testDefaults)["DM_SCREEN"])
    }
}
