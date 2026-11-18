import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

/// What console mode shows of its buttons (#1129): − (quick menu) on the home screen and a game's page, X and Y on a game's page, B in a
/// search Back leaves without editing, the keyboard retains Delete, and Swap A and B works on the Controllers page.
@MainActor final class ConsoleHintsReachabilityTests: XCTestCase {
    private var window: OffscreenWindow?
    override func tearDown() { window?.orderOut(nil); window?.contentView = nil; window?.close(); window = nil; super.tearDown() }

    private func host(_ driver: MockConsoleDriver, _ pad: PadFocus, _ gamepad: LauncherGamepad, width: CGFloat = 1280) {
        let host = NSHostingView(rootView: ConsoleView(driver: driver, gamepad: gamepad, padFocus: pad).frame(width: width, height: 800))
        let window = OffscreenWindow(size: NSSize(width: width, height: 800), styleMask: [.borderless])
        window.contentView = host
        window.orderBack(nil)
        self.window = window
        settle()
    }
    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
    private func ids(_ pad: PadFocus, _ scope: String) -> Set<String> { Set((pad.frames[scope] ?? []).map(\.id)) }

    func testOnlyPrimaryPlayIsVisibleAndXStillLaunchesAcrossWidths() throws {
        for width: CGFloat in [640, 1280, 1920] {
            window?.orderOut(nil); window?.contentView = nil; window?.close(); window = nil
            let driver = MockConsoleDriver(scenario: .full, animated: false), pad = PadFocus(), gamepad = LauncherGamepad()
            let id = try XCTUnwrap(driver.state.games.first?.id)
            driver.state.games[0].status = .ready; driver.state.focusedGameID = id
            host(driver, pad, gamepad, width: width)
            XCTAssertTrue(ids(pad, "console").contains("console.open"))
            XCTAssertFalse(ids(pad, "console").contains("console.play"))
            pad.show(default: "console.game." + id); pad.focused = "console.game." + id
            gamepad.perform(.x); settle()
            XCTAssertEqual(driver.state.startingGameID, id)
            driver.back(); settle()
            pad.show(default: "console.open"); pad.focused = "console.open"
            gamepad.perform(.a); settle()
            XCTAssertEqual(driver.state.startingGameID, id)
        }
    }

    func testCompletionExpiresWhileQueueIsOpenWithoutRestoringDeadFocus() throws {
        let driver = MockConsoleDriver(scenario: .full, animated: false), pad = PadFocus(), gamepad = LauncherGamepad()
        driver.state.builds = ConsoleBuilds(queue: [.init(id: UUID(), name: "Finished", statusKey: "queue.status.done", outcome: .success)])
        host(driver, pad, gamepad)
        pad.show(default: "console.build.activity"); pad.focused = "console.build.activity"
        gamepad.perform(.a); settle()
        XCTAssertEqual(driver.state.presentedSheet, .builds)
        RunLoop.main.run(until: Date().addingTimeInterval(10.1))
        gamepad.perform(.b); settle()
        XCTAssertNil(driver.state.presentedSheet)
        XCTAssertFalse(ids(pad, "console").contains("console.build.activity"))
        XCTAssertEqual(pad.focused, "console.searchButton")
    }

    func testFailedBuildExpiresEvenWithWaitingGames() {
        let driver = MockConsoleDriver(scenario: .full, animated: false), pad = PadFocus(), gamepad = LauncherGamepad()
        driver.state.builds = ConsoleBuilds(queue: [
            .init(id: UUID(), name: "Failed", statusKey: "queue.status.failed", outcome: .failure, progress: 0.63),
            .init(id: UUID(), name: "Next", statusKey: "queue.status.queued")
        ])
        host(driver, pad, gamepad)
        XCTAssertTrue(ids(pad, "console").contains("console.build.activity"))
        RunLoop.main.run(until: Date().addingTimeInterval(10.1))
        XCTAssertFalse(ids(pad, "console").contains("console.build.activity"))
        XCTAssertEqual(driver.state.builds.queue.count, 2)
        XCTAssertEqual(driver.state.builds.queue[0].outcome, .failure)
    }

    func testBuildIndicatorFitsClockGutterAndHidesOnlyInQueue() throws {
        let driver = MockConsoleDriver(scenario: .full, animated: false), pad = PadFocus(), gamepad = LauncherGamepad()
        driver.state.builds = ConsoleBuilds(running: true, queue: [.init(id: UUID(), name: "Building game", statusKey: "queue.status.running", active: true, progress: 0.63)])
        host(driver, pad, gamepad)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let selection = driver.state.focusedGame?.id
        let id = "console.build.activity"
        let frame = try XCTUnwrap(pad.frames["console"]?.first { $0.id == id }?.frame)
        XCTAssertEqual(frame.minX, 0, accuracy: 1)
        XCTAssertEqual(frame.height, 60, accuracy: 1)
        let clock = NSHostingView(rootView: ConsoleClock(time: driver.state.time, compact: false).padding(.leading, 70))
        XCTAssertEqual(frame.width, clock.fittingSize.width, accuracy: 1)
        XCTAssertEqual(frame.minY, 50 + clock.fittingSize.height + 19, accuracy: 1)
        driver.state.time = Calendar.current.date(bySettingHour: 11, minute: 59, second: 0, of: driver.state.time)!
        settle()
        let changedClock = NSHostingView(rootView: ConsoleClock(time: driver.state.time, compact: false).padding(.leading, 70))
        XCTAssertEqual(pad.frames["console"]?.first { $0.id == id }?.frame.width ?? 0, changedClock.fittingSize.width, accuracy: 1)
        driver.state.time = Calendar.current.date(bySettingHour: 3, minute: 49, second: 0, of: driver.state.time)!
        settle()
        let currentWidth = pad.frames["console"]?.first { $0.id == id }?.frame.width
        driver.state.builds.queue[0].progress = 1; settle()
        XCTAssertEqual(pad.frames["console"]?.first { $0.id == id }?.frame.width, currentWidth)
        pad.show(default: id); pad.focused = id
        gamepad.perform(.a); settle()
        XCTAssertEqual(driver.state.presentedSheet, .builds)
        XCTAssertFalse(ids(pad, "console").contains(id))
        gamepad.perform(.b); settle()
        XCTAssertNil(driver.state.presentedSheet)
        XCTAssertTrue(ids(pad, "console").contains(id))
        XCTAssertEqual(pad.focused, id)
        XCTAssertEqual(driver.state.focusedGame?.id, selection)
        driver.state.builds.running = false
        driver.state.builds.queue[0].active = false
        driver.state.builds.queue[0].outcome = .success
        settle()
        XCTAssertTrue(ids(pad, "console").contains(id), "completed results stay available")
        driver.state.builds.queue = []; settle()
        XCTAssertFalse(ids(pad, "console").contains(id))
        XCTAssertNotEqual(pad.focused, id)
    }

    func testFormerFullScreenDestinationsKeepPanelFocusAndBackRestoration() throws {
        let driver = MockConsoleDriver(scenario: .full, animated: false), pad = PadFocus(), gamepad = LauncherGamepad()
        host(driver, pad, gamepad)
        driver.openMenu(); settle()
        for (open, scope, close) in [
            ({ driver.openAllGames() }, "console.allGames", "console.allGames.close"),
            ({ driver.openSearch() }, "console.search", "console.search.close"),
            ({ driver.openBuilds() }, "console.builds", "console.builds.close"),
            ({ driver.openSupportedGames() }, "console.supported", "console.supported.close")
        ] {
            open(); settle()
            XCTAssertEqual(pad.scope, scope)
            let target = try XCTUnwrap(pad.frames[scope]?.first { $0.id == close })
            XCTAssertGreaterThanOrEqual(target.frame.minX, 0)
            XCTAssertLessThanOrEqual(target.frame.width, 740, "Back is sized to the side panel")
            XCTAssertTrue(ids(pad, scope).contains(close))
            gamepad.perform(.b); settle()
            XCTAssertEqual(driver.state.presentedSheet, .menu)
            XCTAssertEqual(pad.scope, "console.menu")
        }
    }

    func testBuildQueueMenuEntryIsConditionalOnActivityOrRetainedResults() {
        let driver = MockConsoleDriver(scenario: .full, animated: false), pad = PadFocus(), gamepad = LauncherGamepad()
        driver.state.builds = ConsoleBuilds()
        host(driver, pad, gamepad)
        driver.openMenu(); settle()
        XCTAssertFalse(ids(pad, "console.menu").contains("console.menu.builds"))
        driver.state.builds.running = true; settle()
        XCTAssertTrue(ids(pad, "console.menu").contains("console.menu.builds"))
        pad.focused = "console.menu.builds"
        driver.state.builds.running = false; settle()
        XCTAssertEqual(pad.focused, "console.menu.allGames")
        driver.state.builds.queue = [.init(id: UUID(), name: "Done", statusKey: "queue.status.done", outcome: .success)]
        settle()
        XCTAssertTrue(ids(pad, "console.menu").contains("console.menu.builds"))
    }

    func testPanelKeyboardsFillAvailableWidthWithoutClipping() throws {
        let driver = MockConsoleDriver(scenario: .full, animated: false), pad = PadFocus(), gamepad = LauncherGamepad()
        host(driver, pad, gamepad)
        for (open, scope, prefix) in [({ driver.openSearch() }, "console.search", "console.key."),
                                    ({ driver.openSupportedGames() }, "console.supported", "console.supported.key.")] {
            open(); settle()
            let first = try XCTUnwrap(pad.frames[scope]?.first { $0.id == prefix + "1" })
            let last = try XCTUnwrap(pad.frames[scope]?.first { $0.id == prefix + "0" })
            XCTAssertGreaterThan(first.frame.width, 40)
            XCTAssertEqual(first.frame.height, 56, accuracy: 1)
            XCTAssertEqual(first.frame.minX, 40, accuracy: 1)
            XCTAssertLessThanOrEqual(last.frame.maxX, 1280 * 0.54 - 39)
            driver.back(); settle()
        }
    }

    func testQueueRowsScrollWithControllerAndReturnToPanelBack() throws {
        let driver = MockConsoleDriver(scenario: .full, animated: false), pad = PadFocus(), gamepad = LauncherGamepad()
        driver.state.builds.queue = (0..<12).map { .init(id: UUID(), name: "Game \($0)", statusKey: "queue.status.done", platformKey: "library.section.mac", outcome: .success) }
        host(driver, pad, gamepad)
        driver.openBuilds(); settle()
        let rows = driver.state.builds.orderedQueue
        pad.focused = "console.builds.queue." + rows[0].id.uuidString; settle()
        for _ in 1..<rows.count { gamepad.perform(.down); settle() }
        let lastID = "console.builds.queue." + rows.last!.id.uuidString
        XCTAssertEqual(pad.focused, lastID)
        let last = try XCTUnwrap(pad.frames[pad.scope]?.first { $0.id == lastID })
        XCTAssertGreaterThan(last.frame.minY, 90)
        XCTAssertLessThan(last.frame.maxY, 700)
        gamepad.perform(.down); settle()
        XCTAssertEqual(pad.focused, "console.builds.close")
        gamepad.perform(.a); settle()
        XCTAssertNil(driver.state.presentedSheet)
    }

    func testTileActivationLaunchesAndUnavailableTileOpensCombinedOptions() throws {
        let driver = MockConsoleDriver(scenario: .full, animated: false), pad = PadFocus(), gamepad = LauncherGamepad()
        host(driver, pad, gamepad)
        let game = try XCTUnwrap(driver.state.games.first { $0.status == .ready })
        driver.focus(game.id); pad.focused = "console.game." + game.id; settle()
        gamepad.perform(.a); settle()
        XCTAssertEqual(driver.state.startingGameID, game.id)
        XCTAssertNil(driver.state.presentedSheet)
        driver.state.startingGameID = nil
        let unavailable = try XCTUnwrap(driver.state.games.first { $0.status != .ready })
        driver.focus(unavailable.id); pad.focused = "console.game." + unavailable.id; settle()
        gamepad.perform(.a); settle()
        XCTAssertEqual(driver.state.presentedSheet, .options(unavailable.id))
        XCTAssertTrue(ids(pad, "console.options").isSuperset(of: ["console.options.details", "console.options.saves", "console.options.manage", "console.sheet.close"]))
        XCTAssertFalse(ids(pad, "console.options").contains("console.options.play"))
    }

    func testPendingLaunchBackHasItsOwnFocusScopeAndCancelsWithB() throws {
        let driver = MockConsoleDriver(scenario: .full, animated: false), pad = PadFocus(), gamepad = LauncherGamepad()
        host(driver, pad, gamepad)
        let game = try XCTUnwrap(driver.state.games.first { $0.status == .ready })
        driver.play(game.id); driver.state.launchCancellable = true; settle()
        XCTAssertEqual(pad.scope, "console.launch")
        XCTAssertTrue(ids(pad, "console.launch").contains("console.launch.back"))
        gamepad.perform(.b); settle()
        XCTAssertNil(driver.state.startingGameID)
        XCTAssertEqual(pad.scope, "console")
        XCTAssertEqual(pad.focused, "console.game." + game.id)
    }

    func testCloudWaitActionsUseLaunchFocusAndCanBeNavigated() throws {
        let driver = MockConsoleDriver(scenario: .full, animated: false), pad = PadFocus(), gamepad = LauncherGamepad()
        host(driver, pad, gamepad)
        let game = try XCTUnwrap(driver.state.games.first { $0.status == .ready })
        driver.play(game.id); driver.state.starting = .cloudSave(long: true); settle()
        XCTAssertTrue(ids(pad, "console.launch").isSuperset(of: ["console.launch.back", "console.cloudSave.offline", "console.cloudSave.cancel"]))
        gamepad.perform(.down); settle()
        XCTAssertEqual(pad.focused, "console.cloudSave.offline")
        gamepad.perform(.right); settle()
        XCTAssertEqual(pad.focused, "console.cloudSave.cancel")
        gamepad.perform(.a); settle()
        XCTAssertNil(driver.state.startingGameID)
        XCTAssertEqual(pad.scope, "console")
    }

    func testBackAfterSimulatedLoadingLetsAnotherGameLaunch() throws {
        let driver = MockConsoleDriver(scenario: .full, animated: false), pad = PadFocus(), gamepad = LauncherGamepad()
        host(driver, pad, gamepad)
        let games = driver.state.games.filter { $0.status == .ready }
        let first = try XCTUnwrap(games.first), second = try XCTUnwrap(games.dropFirst().first)
        driver.play(first.id); driver.state.starting = .opening; settle()
        XCTAssertTrue(ids(pad, "console.launch").contains("console.launch.back"))
        gamepad.perform(.b); settle()
        XCTAssertNil(driver.state.startingGameID)
        XCTAssertEqual(pad.scope, "console")
        driver.focus(second.id); pad.focused = "console.game." + second.id; settle()
        gamepad.perform(.a); settle()
        XCTAssertEqual(driver.state.startingGameID, second.id)
    }

    func testBackDuringArtworkHandoffAllowsImmediateRetry() throws {
        let driver = MockConsoleDriver(scenario: .full, animated: false), pad = PadFocus(), gamepad = LauncherGamepad()
        host(driver, pad, gamepad)
        let games = driver.state.games.filter { $0.status == .ready }
        let first = try XCTUnwrap(games.first), second = try XCTUnwrap(games.dropFirst().first)
        driver.focus(first.id); pad.focused = "console.game." + first.id; settle()
        gamepad.perform(.a); settle()
        gamepad.perform(.b); settle()
        driver.focus(second.id); pad.focused = "console.game." + second.id; settle()
        gamepad.perform(.a)
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        XCTAssertEqual(driver.state.startingGameID, second.id)
        XCTAssertEqual(pad.scope, "console.launch")
        XCTAssertTrue(ids(pad, "console.launch").contains("console.launch.back"))
        gamepad.perform(.b); settle()
        XCTAssertNil(driver.state.startingGameID)
        XCTAssertEqual(pad.focused, "console.game." + second.id)
    }

    func testNestedGameSettingsRemainInSidebarWithBackTargets() throws {
        let driver = MockConsoleDriver(scenario: .full, animated: false), pad = PadFocus(), gamepad = LauncherGamepad()
        host(driver, pad, gamepad)
        driver.openOptions("demo.0"); settle()
        driver.openGamePad("demo.0"); settle()
        XCTAssertFalse(try XCTUnwrap(driver.state.presentedSheet).isFullScreen)
        let back = try XCTUnwrap(pad.frames["console.gamePad"]?.first { $0.id == "console.gamePad.close" }?.frame)
        XCTAssertGreaterThan(back.minX, 500)
        XCTAssertGreaterThan(back.width, 500)
        XCTAssertLessThanOrEqual(back.maxY, 800)
        driver.openGameMapping("demo.0"); settle()
        XCTAssertFalse(try XCTUnwrap(driver.state.presentedSheet).isFullScreen)
        XCTAssertTrue(ids(pad, "console.mapping").contains("console.map.close"))
        gamepad.perform(.b); settle()
        XCTAssertEqual(driver.state.presentedSheet, .gamePad("demo.0"))
        gamepad.perform(.b); settle()
        XCTAssertEqual(driver.state.presentedSheet, .options("demo.0"))
    }

    func testMainAndQuickMenusRetainAllActionsAndBack() throws {
        let driver = MockConsoleDriver(scenario: .full, animated: false), pad = PadFocus(), gamepad = LauncherGamepad()
        host(driver, pad, gamepad)
        driver.openMenu(); settle()
        XCTAssertTrue(ids(pad, "console.menu").isSuperset(of: ["console.menu.allGames", "console.menu.search", "console.menu.builds", "console.menu.library", "console.menu.controllers", "console.menu.settings", "console.menu.exit", "console.sheet.close"]))
        gamepad.perform(.b); settle()
        XCTAssertNil(driver.state.presentedSheet)
        driver.openQuickMenu(); settle()
        XCTAssertTrue(ids(pad, "console.quickMenu").isSuperset(of: ["console.quick.controllers", "console.sheet.close"]))
        gamepad.perform(.b); settle()
        XCTAssertNil(driver.state.presentedSheet)
    }

    func testHomeUpReachesHeaderAndDownReturnsToGame() throws {
        let driver = MockConsoleDriver(scenario: .full, animated: false), pad = PadFocus(), gamepad = LauncherGamepad()
        host(driver, pad, gamepad)
        let first = try XCTUnwrap(driver.state.homeSections.first?.gameIDs.first)
        driver.focus(first); pad.focused = "console.game." + first; settle()
        gamepad.perform(.up); settle()
        XCTAssertEqual(pad.focused, "console.searchButton")
        gamepad.perform(.left); settle()
        XCTAssertEqual(pad.focused, "console.chip.controllers")
        gamepad.perform(.down); settle()
        XCTAssertEqual(pad.focused, "console.game." + first)
    }

    func testHomeShowsTheQuickMenuAndAGamesPageShowsItsButtons() {
        let driver = MockConsoleDriver(scenario: .full, animated: false), pad = PadFocus(), gamepad = LauncherGamepad()
        host(driver, pad, gamepad)
        XCTAssertTrue(ids(pad, "console").isSuperset(of: ["console.quickMenuHint", "console.searchButton"]), "\(ids(pad, "console"))")
        driver.openGamePage("demo.0"); settle()
        let game = try! XCTUnwrap(driver.state.games.first { $0.id == "demo.0" })
        XCTAssertEqual(game.status, .ready)
        XCTAssertTrue(ids(pad, "console.gamePage").isSuperset(of: ConsoleGamePage<MockConsoleDriver>.hintIDs(game, embedded: true)), "\(ids(pad, "console.gamePage"))")
        XCTAssertTrue(ConsoleGamePage<MockConsoleDriver>.hintIDs(game, embedded: true).contains("console.gamePage.hint.options"))
        gamepad.perform(.select); settle()
        XCTAssertEqual(driver.state.presentedSheet, .quickMenu, "− opens the quick menu from a game's page too")
    }

    func testQueueCompletionPreservesFocusedRowAndMovesOnlyRemovedStopFocusToBack() {
        let driver = MockConsoleDriver(scenario: .full, animated: false), pad = PadFocus(), gamepad = LauncherGamepad()
        let id = UUID()
        driver.state.builds = ConsoleBuilds(running: true, queue: [.init(id: id, name: "Game", statusKey: "queue.status.running", active: true, progress: 0.9)])
        host(driver, pad, gamepad)
        driver.openBuilds(); settle()
        let rowID = "console.builds.queue." + id.uuidString
        pad.focused = rowID
        driver.state.builds.queue[0].active = false
        driver.state.builds.queue[0].outcome = .success
        driver.state.builds.running = false; settle()
        XCTAssertEqual(pad.focused, rowID)
        driver.state.builds.running = true; settle()
        pad.focused = "console.builds.stop"
        driver.state.builds.running = false; settle()
        XCTAssertEqual(pad.focused, "console.builds.close")
    }

    func testConsoleToggleRowsMatchLanguageHeight() throws {
        let driver = MockConsoleDriver(scenario: .full, animated: false), pad = PadFocus(), gamepad = LauncherGamepad()
        host(driver, pad, gamepad)
        driver.openMenu(); driver.openSettings(); settle()
        let rows = try XCTUnwrap(pad.frames["console.settings"])
        let language = try XCTUnwrap(rows.first { $0.id == "console.settings.language" })
        let toggle = try XCTUnwrap(rows.first { $0.id == "console.pref.returnAfterPlay" })
        XCTAssertEqual(toggle.frame.height, language.frame.height, accuracy: 1)
        XCTAssertGreaterThanOrEqual(toggle.frame.height, 84)
        pad.focused = "console.pref.returnAfterPlay"; pad.activate(); settle()
        XCTAssertFalse(driver.state.prefs[.returnAfterPlay])
    }

    func testSubmenuTitleRetainsItsImmediateParent() {
        let driver = MockConsoleDriver(scenario: .full, animated: false)
        driver.state.sheets = [.menu, .controllers, .mapping]
        XCTAssertEqual(driver.state.titleParent(of: .mapping), .controllers)
        XCTAssertNil(driver.state.titleParent(of: .controllers))
        driver.state.sheets.append(.confirmMapping)
        XCTAssertEqual(driver.state.titleParent(of: .mapping), .controllers)
        driver.state.sheets = [.menu, .settings, .language]
        XCTAssertEqual(driver.state.titleParent(of: .language), .settings)
        driver.state.sheets = [.mapping]
        XCTAssertNil(driver.state.titleParent(of: .mapping))
    }

    func testSearchDoneKeepsKeyboardVisibleAndUpReturnsFocus() throws {
        let driver = MockConsoleDriver(scenario: .full, animated: false), pad = PadFocus(), gamepad = LauncherGamepad()
        host(driver, pad, gamepad)
        driver.openSearch(); driver.typeSearch("h"); settle()
        XCTAssertFalse(ids(pad, "console.search").contains("console.search.hint.play"))
        let firstID = try XCTUnwrap(driver.state.searchResults.first)
        pad.focused = "console.key.done"; pad.activate(); settle()
        XCTAssertEqual(pad.focused, "console.result." + firstID)
        XCTAssertTrue(ids(pad, "console.search").contains("console.search.hint.play"))
        let key = try XCTUnwrap(pad.frames["console.search"]?.first { $0.id == "console.key.done" })
        let game = try XCTUnwrap(pad.frames["console.search"]?.first { $0.id == "console.result." + firstID })
        XCTAssertGreaterThan(key.frame.minY, 0)
        XCTAssertLessThan(key.frame.maxY, game.frame.minY)
        gamepad.perform(.up); settle()
        XCTAssertTrue(pad.focused?.hasPrefix("console.key.") == true, "\(pad.focused ?? "nil")")
        XCTAssertFalse(ids(pad, "console.search").contains("console.search.hint.play"))
    }

    func testSearchBackLeavesWithoutDeletingAndDedicatedDeleteStillWorks() {
        let driver = MockConsoleDriver(scenario: .full, animated: false), pad = PadFocus(), gamepad = LauncherGamepad()
        host(driver, pad, gamepad)
        driver.openSearch(); driver.typeSearch("a"); driver.typeSearch("b"); settle()
        XCTAssertFalse(ids(pad, "console.search").contains("console.search.hint.back"), "shared sheet Back is the only Back control")
        gamepad.perform(.y); settle()
        XCTAssertEqual(driver.state.searchText, "ab", "Y does not delete")
        pad.focused = "console.key.delete"; pad.activate(); settle()
        XCTAssertEqual(driver.state.searchText, "a")
        gamepad.perform(.b); settle()
        XCTAssertNil(driver.state.presentedSheet)
        XCTAssertEqual(driver.state.searchText, "a", "Back leaves without editing the query")

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
