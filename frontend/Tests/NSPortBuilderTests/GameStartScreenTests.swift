import AppKit
import XCTest
@testable import NSPortBuilder

/// DM_SCREEN in the launch environment (front_mac.m opens the game's window on that NSScreenNumber).
@MainActor final class GameStartScreenTests: XCTestCase {
    private func number(_ screen: NSScreen) -> NSNumber? { screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber }

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
        let layout = ControlLayout(defaults: UserDefaults(suiteName: "GameStartScreenTests-" + UUID().uuidString)!)
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
}
