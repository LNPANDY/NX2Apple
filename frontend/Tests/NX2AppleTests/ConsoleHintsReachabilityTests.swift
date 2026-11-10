import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

/// What console mode shows of its buttons (#1129): − (quick menu) on the home screen and a game's page, X and Y on a game's page, B in a
/// search deletes a letter before it leaves, Y no longer deletes, and Swap A and B on the Controllers page.
@MainActor final class ConsoleHintsReachabilityTests: XCTestCase {
    private var window: OffscreenWindow?
    override func tearDown() { window?.orderOut(nil); window?.contentView = nil; window?.close(); window = nil; super.tearDown() }

    private func host(_ driver: MockConsoleDriver, _ pad: PadFocus, _ gamepad: LauncherGamepad) {
        let host = NSHostingView(rootView: ConsoleView(driver: driver, gamepad: gamepad, padFocus: pad).frame(width: 1280, height: 800))
        let window = OffscreenWindow(size: NSSize(width: 1280, height: 800), styleMask: [.borderless])
        window.contentView = host
        window.orderBack(nil)
        self.window = window
        settle()
    }
    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
    private func ids(_ pad: PadFocus, _ scope: String) -> Set<String> { Set((pad.frames[scope] ?? []).map(\.id)) }

    func testHomeShowsTheQuickMenuAndAGamesPageShowsItsButtons() {
        let driver = MockConsoleDriver(scenario: .full, animated: false), pad = PadFocus(), gamepad = LauncherGamepad()
        host(driver, pad, gamepad)
        XCTAssertTrue(ids(pad, "console").isSuperset(of: ["console.quickMenuHint", "console.searchButton"]), "\(ids(pad, "console"))")
        driver.openGamePage("demo.0"); settle()
        let game = try! XCTUnwrap(driver.state.games.first { $0.id == "demo.0" })
        XCTAssertEqual(game.status, .ready)
        XCTAssertTrue(ids(pad, "console.gamePage").isSuperset(of: ConsoleGamePage<MockConsoleDriver>.hintIDs(game)), "\(ids(pad, "console.gamePage"))")
        XCTAssertTrue(ConsoleGamePage<MockConsoleDriver>.hintIDs(game).contains("console.gamePage.hint.options"))
        gamepad.perform(.select); settle()
        XCTAssertEqual(driver.state.presentedSheet, .quickMenu, "− opens the quick menu from a game's page too")
    }

    func testBInASearchDeletesALetterThenLeavesAndYTypesNothingAway() {
        let driver = MockConsoleDriver(scenario: .full, animated: false), pad = PadFocus(), gamepad = LauncherGamepad()
        host(driver, pad, gamepad)
        driver.openSearch(); driver.typeSearch("a"); driver.typeSearch("b"); settle()
        XCTAssertTrue(ids(pad, "console.search").contains("console.search.hint.back"))
        gamepad.perform(.y); settle()
        XCTAssertEqual(driver.state.searchText, "ab", "Y does not delete")
        gamepad.perform(.b); settle()
        XCTAssertEqual(driver.state.searchText, "a")
        XCTAssertEqual(driver.state.presentedSheet, .search)
        XCTAssertEqual(ConsoleSearchBack.labelKey(driver.state.searchText), "console.search.deleteLetter")
        gamepad.perform(.b); settle()
        XCTAssertEqual(driver.state.presentedSheet, .search, "the last letter goes first")
        XCTAssertEqual(ConsoleSearchBack.labelKey(driver.state.searchText), "console.back")
        gamepad.perform(.b); settle()
        XCTAssertNil(driver.state.presentedSheet, "an empty search leaves")

        driver.openMenu(); driver.openLibrary(); driver.openSupportedGames(); driver.typeSupported("x"); settle()
        gamepad.perform(.b); settle()
        XCTAssertEqual(driver.state.supportedText, "")
        XCTAssertEqual(driver.state.presentedSheet, .supportedGames)
        gamepad.perform(.b); settle()
        XCTAssertEqual(driver.state.presentedSheet, .library)
    }

    func testControllersPageSwapsAAndBAtOnce() {
        let driver = MockConsoleDriver(scenario: .full, animated: false), pad = PadFocus(), gamepad = LauncherGamepad()
        host(driver, pad, gamepad)
        driver.openMenu(); driver.openControllers(); settle()
        XCTAssertTrue(ids(pad, "console.controllers").contains("console.controller.menuSwap"), "\(ids(pad, "console.controllers"))")
        pad.focused = "console.controller.menuSwap"; pad.activate(); settle()
        XCTAssertTrue(driver.state.menuSwapAB)
    }
}
