import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

/// The structure of Settings (#678), the options sheet (#675) and the appearance (#683).
final class SettingsAndOptionsStructureTests: IsolatedDefaultsTestCase {
    func testSettingsCategoriesAreInTheSpecifiedOrder() {
        XCTAssertEqual(SettingsCategory.allCases.map(\.rawValue), ["general", "library", "controls", "tools"])
    }

    func testOptionsCategoriesAreInTheSpecifiedOrder() {
        XCTAssertEqual(LaunchCategory.allCases.map(\.rawValue), ["game", "performance", "mods", "saves"])
    }

    private func setting(_ env: String, section: String? = nil) -> LaunchSetting {
        LaunchSetting(env: env, kind: "toggle", label: env, note: "", def: "0", section: section, options: nil, min: nil, max: nil, step: nil, on: nil, off: nil)
    }

    func testEachSettingGoesToOnePart() {
        for env in ["DM_LANG", "DM_FULLSCREEN", "DM_RUMBLE", "DM_RUMBLE_GAIN", "DM_PICTURE_FIT"] { XCTAssertEqual(LaunchCategory.of(setting(env)), .game, env) }
        for env in ["DM_FPS_TARGET", "DM_RENDER_SCALE", "DM_OPMODE", "DM_PRESENT_UPSCALE", "DM_PSO_PREBUILD", "DM_NVN_TEX_MIP_SKIP"] { XCTAssertEqual(LaunchCategory.of(setting(env)), .performance, env) }
        XCTAssertEqual(LaunchCategory.of(setting("DM_NEW", section: "Performance")), .performance, "a setting this table does not know follows its section")
        XCTAssertEqual(LaunchCategory.of(setting("DM_NEW", section: "Controls")), .game)
        XCTAssertEqual(LaunchCategory.of(setting("DM_NEW")), .game)
    }

    func testDestinationDecidesWhatTheSheetOffers() {
        var game = LibraryGame(titleID: "0100000000000001", name: "A")
        XCTAssertEqual(LaunchDestination(game), .none)
        XCTAssertEqual(LaunchDestination.none.categories, [], "one explanation and Build this game…")
        game.iosAppPath = "/nonexistent.app"
        game.ipaPath = "/nonexistent.ipa"
        XCTAssertEqual(LaunchDestination(game), .none, "an IPA that is gone is no build")
        XCTAssertEqual(LaunchDestination.ios.categories, [.mods, .saves], "from the Mac an iPhone build has cheats and saves, no Mac-only settings")
        XCTAssertEqual(LaunchDestination.mac.categories, LaunchCategory.allCases)
    }

    func testSheetsStayWithinTheScreen() {
        XCTAssertEqual(LauncherSheet.maxHeight(screen: 1600), 720)
        XCTAssertEqual(LauncherSheet.maxHeight(screen: 700), 620)
        XCTAssertEqual(LauncherSheet.width, 680)
    }

    func testConsoleKeepsItsOwnDarkSurface() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/NX2Apple")
        for file in ["ConsoleView.swift"] {
            XCTAssertTrue(try String(contentsOf: root.appendingPathComponent(file)).contains(".consoleDarkAppearance()"), file)
        }
    }
}
