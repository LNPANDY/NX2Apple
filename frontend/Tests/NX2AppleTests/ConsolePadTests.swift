import XCTest
import SwiftUI
import Combine
@testable import NX2Apple
@testable import NXCore
import NXModel
@testable import NXLauncher

/// The player-mode setting's plumbing and the controller path into console mode (the same LauncherGamepad.perform
/// closure the desktop launcher and the onboarding use). A real controller still needs a manual check.
@MainActor final class ConsolePadTests: IsolatedDefaultsTestCase {
    private func freshDefaults() -> UserDefaults { TestDefaults.make("ConsolePadTests") }

    func testPadMergeIsOffByDefaultAndPassesNothing() {
        let layout = ControlLayout(defaults: freshDefaults())
        XCTAssertFalse(layout.padMerge)
        XCTAssertNil(layout.environment["DM_PAD_MERGE"])
        XCTAssertTrue(layout.environment.isEmpty)
    }

    func testPadMergeReachesTheGameEnvironmentAndIsSaved() {
        let defaults = freshDefaults()
        let layout = ControlLayout(defaults: defaults)
        layout.padMerge = true
        XCTAssertEqual(layout.environment["DM_PAD_MERGE"], "1")
        // not a layout change: the Controls row, its reset and isDefault ignore it
        XCTAssertTrue(layout.isDefault)
        XCTAssertEqual(layout.changeCount, 0)
        let game = LibraryGame(titleID: "0100000000000000", name: "Demo")
        let env = game.startEnvironment(controls: layout.environment, settings: [], mods: [])
        XCTAssertEqual(env["DM_PAD_MERGE"], "1")
        XCTAssertEqual(env["DM_LAUNCHER"], "0")
        XCTAssertTrue(ControlLayout(defaults: defaults).padMerge, "saved in UserDefaults")
        layout.padMerge = false
        XCTAssertNil(game.startEnvironment(controls: layout.environment, settings: [], mods: [])["DM_PAD_MERGE"])
    }

    @MainActor func testLauncherDriverMirrorsAndWritesTheSetting() {
        let layout = ControlLayout(defaults: freshDefaults())
        let driver = AnyConsoleDriver(LauncherControllerDriver(layout: layout))
        XCTAssertFalse(driver.state.padMerge)
        driver.setPadMerge(true)
        XCTAssertTrue(layout.padMerge)
        XCTAssertEqual(layout.environment["DM_PAD_MERGE"], "1")
        layout.padMerge = false
        XCTAssertFalse(driver.state.padMerge)
        XCTAssertNil(layout.environment["DM_PAD_MERGE"])
    }

    /// An edit to the Custom layout is kept at once; going back to the layout the page opened with does not undo it, so leaving
    /// still asks to save or discard it.
    @MainActor func testACustomEditStillAsksAfterGoingBackToStandard() {
        let driver = MockConsoleDriver(scenario: .full, animated: false)
        driver.openMenu(); driver.openMapping()
        XCTAssertFalse(driver.state.mappingChanged)
        driver.setPadMode(.custom)
        driver.setPadSends(button: "A", to: "B")
        driver.setPadMode(.standard)
        XCTAssertTrue(driver.state.mappingChanged, "the Custom buttons differ from when the page opened")
        driver.back()
        XCTAssertEqual(driver.state.presentedSheet, .confirmMapping)
    }

    func testGamepadActionsMapToConsoleInputs() {
        let expected: [(LauncherGamepad.Action, ConsoleInput?)] = [
            (.left, .left), (.right, .right), (.up, .up), (.down, .down), (.a, .activate), (.b, .back),
            (.y, .options), (.x, .play), (.plus, .menu), (.select, .quickMenu), (.l, .previousTab), (.r, .nextTab)]
        for (action, input) in expected { XCTAssertEqual(ConsoleInput(action), input, "\(action)") }
    }

    /// Hosts the console view and drives it only through `gamepad.perform`, as Gamepad.swift does on a button edge.
    @MainActor func testControllerDrivesConsoleView() {
        let driver = MockConsoleDriver(scenario: .full, animated: false)
                let gamepad = LauncherGamepad()
        let host = NSHostingView(rootView: ConsoleView(driver: driver, gamepad: gamepad).frame(width: 1280, height: 800))
        let window = OffscreenWindow(size: NSSize(width: 1280, height: 800), styleMask: [.borderless])
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)); host.layoutSubtreeIfNeeded() }
        settle()
        XCTAssertEqual(driver.state.focusedGameID, "demo.0")
        gamepad.perform(.right); settle()
        XCTAssertEqual(driver.state.focusedGameID, "demo.1", "D-pad right moves focus")
        gamepad.perform(.left); settle()
        XCTAssertEqual(driver.state.focusedGameID, "demo.0")
        gamepad.perform(.y); settle()
        XCTAssertEqual(driver.state.presentedSheet, .options("demo.0"), "Y opens the game's options")
        gamepad.perform(.y); settle()
        XCTAssertNil(driver.state.presentedSheet, "Y again closes them")
        gamepad.perform(.y); settle()
        gamepad.perform(.b); settle()
        XCTAssertNil(driver.state.presentedSheet, "B closes the sheet")
        gamepad.perform(.plus); settle()
        XCTAssertEqual(driver.state.presentedSheet, .menu, "the menu button opens the menu")
        gamepad.perform(.a); settle()
        XCTAssertEqual(driver.state.presentedSheet, .allGames, "the menu's first row is All games (#816)")
        gamepad.perform(.b); settle()
        XCTAssertEqual(driver.state.presentedSheet, .menu, "B goes back to the menu")
        gamepad.perform(.plus); settle()
        XCTAssertNil(driver.state.presentedSheet, "the menu button again closes the menu")
        // Up from a game goes to the row above at the same place, up from the first row to Search in the top bar, right to the menu
        // button. A opens the menu from there, and closing it with the menu button puts the focus back on the button, not on a game.
        gamepad.perform(.up); settle()
        XCTAssertEqual(driver.state.focusedGameID, "demo.2", "up goes to the Continue playing row, the game played last")
        gamepad.perform(.up); settle()
        gamepad.perform(.a); settle()
        XCTAssertEqual(driver.state.presentedSheet, .search, "up from the first row reaches Search")
        gamepad.perform(.b); settle()
        gamepad.perform(.right); settle()
        gamepad.perform(.a); settle()
        XCTAssertEqual(driver.state.presentedSheet, .menu, "A on the menu button opens the menu")
        gamepad.perform(.down); settle()
        gamepad.perform(.plus); settle()
        XCTAssertNil(driver.state.presentedSheet)
        gamepad.perform(.a); settle()
        XCTAssertEqual(driver.state.presentedSheet, .menu, "the focus came back to the menu button")
        XCTAssertNil(driver.state.startingGameID, "and not to a game")
        gamepad.perform(.b); settle()
        XCTAssertNil(driver.state.presentedSheet)
        // Down from the top bar goes back to the focused game. A opens its page, L and R switch its tabs (stopping at the ends).
        gamepad.perform(.down); settle()
        gamepad.perform(.a); settle()
        XCTAssertEqual(driver.state.presentedSheet, .gamePage("demo.2"), "A on a tile opens the game's page")
        gamepad.perform(.r); settle()
        XCTAssertEqual(driver.state.gameTab, .saves)
        gamepad.perform(.l); gamepad.perform(.l); settle()
        XCTAssertEqual(driver.state.gameTab, .overview, "the tabs stop at the ends")
        gamepad.perform(.b); settle()
        XCTAssertNil(driver.state.presentedSheet)
        gamepad.perform(.select); settle()
        XCTAssertEqual(driver.state.presentedSheet, .quickMenu, "− opens the quick menu")
        gamepad.perform(.select); settle()
        XCTAssertNil(driver.state.presentedSheet, "and closes it")
        gamepad.perform(.b); settle()
        XCTAssertEqual(driver.state.presentedSheet, .confirmExit, "B from Home asks before leaving")
        XCTAssertFalse(driver.state.exited)
        gamepad.perform(.b); settle()
        XCTAssertNil(driver.state.presentedSheet, "B again stays in console mode")
        gamepad.perform(.b); settle()
        gamepad.perform(.a); settle()
        XCTAssertNil(driver.state.presentedSheet, "the focus starts on Cancel: A by habit stays in console mode")
        XCTAssertFalse(driver.state.exited)
        gamepad.perform(.b); settle()
        gamepad.perform(.right); settle()
        gamepad.perform(.a); settle()
        XCTAssertTrue(driver.state.exited, "A on Leave exits to the desktop")
    }

    /// A slider takes left and right only after A picks it, and B lets it go before it closes the sheet. A game's controller settings
    /// hold its rumble rows and the way to its own button mapping, which starts as all games' and goes back to it on Reset.
    @MainActor func testSliderIsPickedFirstAndGameControllerSettings() {
        let driver = MockConsoleDriver(scenario: .full, animated: false)
                let gamepad = LauncherGamepad()
        let host = NSHostingView(rootView: ConsoleView(driver: driver, gamepad: gamepad).frame(width: 1280, height: 800))
        let window = OffscreenWindow(size: NSSize(width: 1280, height: 800), styleMask: [.borderless])
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)); host.layoutSubtreeIfNeeded() }
        func scale() -> String? { driver.state.games.first { $0.id == "demo.0" }?.values["DM_RENDER_SCALE"] }
        settle()
        gamepad.perform(.y); settle()
        XCTAssertEqual(driver.state.presentedSheet, .options("demo.0"))
        let game = driver.state.games.first { $0.id == "demo.0" }
        XCTAssertEqual(game?.basicSettings.map(\.env), ["DM_RENDER_SCALE", "DM_FPS_TARGET", "DM_LANG"], "rumble is not among the options")
        XCTAssertEqual(game?.controllerSettings.map(\.env), ["DM_RUMBLE", "DM_RUMBLE_GAIN"])
        let before = scale()
        gamepad.perform(.right); settle()
        XCTAssertEqual(scale(), before, "a slider not picked ignores left and right")
        gamepad.perform(.a); settle()
        gamepad.perform(.right); settle()
        XCTAssertNotEqual(scale(), before, "picked with A, it moves")
        gamepad.perform(.b); settle()
        XCTAssertEqual(driver.state.presentedSheet, .options("demo.0"), "B lets the slider go first")
        let after = scale()
        gamepad.perform(.right); settle()
        XCTAssertEqual(scale(), after, "let go, it ignores left and right again")

        driver.openGamePad("demo.0")
        XCTAssertEqual(driver.state.presentedSheet, .gamePad("demo.0"))
        driver.setPadMode(.byLabel)   // ignored over a game: only all games' mapping has layouts
        driver.openGameMapping("demo.0")
        XCTAssertEqual(driver.state.mappingGameID, "demo.0")
        XCTAssertEqual(driver.state.padLayout.gameTitle, game?.title)
        XCTAssertTrue(driver.state.padLayout.isDefault, "it starts as all games'")
        driver.setPadSends(button: "ZR", to: "none")
        XCTAssertTrue(driver.state.padLayout.changed("ZR"))
        XCTAssertFalse(driver.state.padLayout.isDefault)
        driver.resetPadMapping()
        XCTAssertTrue(driver.state.padLayout.isDefault, "Reset: the same as all games again")
        driver.back()
        XCTAssertEqual(driver.state.presentedSheet, .gamePad("demo.0"))
        XCTAssertNil(driver.state.mappingGameID)
        XCTAssertNil(driver.state.padLayout.gameTitle, "all games' mapping is shown again")
        var notMapped = driver.state
        notMapped.back(); notMapped.back()
        notMapped.openMapping(game: "demo.3")
        XCTAssertNotEqual(notMapped.presentedSheet, .mapping, "a game whose build keeps no mapping of its own has none")
    }

    /// The menu's Settings page opens the Language page, which lists the display languages, the one in use first in focus, and A hands
    /// the one picked to the launcher.
    @MainActor func testSettingsPagePicksTheDisplayLanguage() {
        let driver = MockConsoleDriver(scenario: .full, animated: false)
                let gamepad = LauncherGamepad()
        var picked: [String] = []
        let host = NSHostingView(rootView: ConsoleView(driver: driver, gamepad: gamepad, chooseLanguage: { picked.append($0) }).frame(width: 1280, height: 800))
        let window = OffscreenWindow(size: NSSize(width: 1280, height: 800), styleMask: [.borderless])
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)); host.layoutSubtreeIfNeeded() }
        settle()
        driver.openMenu(); settle()
        driver.openSettings(); settle()
        XCTAssertEqual(driver.state.presentedSheet, .settings)
        gamepad.perform(.a); settle()
        XCTAssertEqual(driver.state.presentedSheet, .language, "A on Language opens its list")
        let codes = AppCard.languageCodes
        let current = codes.firstIndex(of: Lang.saved?.code ?? "") ?? 0
        let next = codes[min(current + 1, codes.count - 1)]
        gamepad.perform(.down); settle()
        gamepad.perform(.a); settle()
        XCTAssertEqual(picked, [next], "A picks the language below the one in use")
        gamepad.perform(.b); settle()
        XCTAssertEqual(driver.state.presentedSheet, .settings, "B goes back to Settings")
    }

    /// The button mapping keeps its changes only on Save: leaving after a change asks first, B goes on editing, Discard puts the
    /// layout and Swap A and B in menus back, and the swap in menus applies only once saved.
    @MainActor func testMappingChangesWaitForSave() {
        let driver = MockConsoleDriver(scenario: .full, animated: false)
        driver.openMenu(); driver.openMapping()
        driver.back()
        XCTAssertEqual(driver.state.presentedSheet, .menu, "nothing changed: no question")
        driver.openMapping()
        driver.setMenuSwapAB(true)
        driver.setPadSends(button: "ZR", to: "none")
        XCTAssertFalse(driver.state.menuSwapAB, "the menus keep their buttons while the page is open")
        XCTAssertTrue(driver.state.shownMenuSwapAB)
        driver.back()
        XCTAssertEqual(driver.state.presentedSheet, .confirmMapping, "leaving after a change asks first")
        driver.back()
        XCTAssertEqual(driver.state.presentedSheet, .mapping, "B goes on editing")
        driver.back()
        driver.finishMapping(save: false)
        XCTAssertEqual(driver.state.presentedSheet, .menu, "Discard closes the page")
        XCTAssertFalse(driver.state.menuSwapAB)
        XCTAssertEqual(driver.state.padLayout.output("ZR"), "ZR", "Discard puts the button back")
        driver.openMapping()
        driver.setMenuSwapAB(true)
        driver.back()
        driver.finishMapping(save: true)
        XCTAssertEqual(driver.state.presentedSheet, .menu)
        XCTAssertTrue(driver.state.menuSwapAB, "Save applies the swap in menus")
        XCTAssertNil(driver.state.mappingOrigin)
    }

    /// A game's options bring the desktop's over: the common options on the page and the rest behind Advanced, mods and cheats
    /// switched here, Reset asked first. The Settings page's switches and the app's update ask before installing.
    @MainActor func testGameOptionsAndSettingsFromTheDesktop() {
        let driver = MockConsoleDriver(scenario: .full, animated: false)
        driver.openOptions("demo.0")
        var game = driver.state.games.first { $0.id == "demo.0" }!
        XCTAssertTrue(game.basicSettings.contains { $0.env == "DM_RENDER_SCALE" })
        XCTAssertEqual(game.advancedSettings.map(\.env), ["DM_VSYNC", "DM_AUDIO_LATENCY"], "the rest are behind Advanced")
        XCTAssertEqual(ConsoleGameOptionsList<MockConsoleDriver>.firstTarget(game), "console.option.DM_RENDER_SCALE")
        XCTAssertEqual(game.mods.count, 2)
        driver.setMod(gameID: "demo.0", name: game.mods[1].name, on: true)
        XCTAssertFalse(driver.state.games.first { $0.id == "demo.0" }!.mods[1].on, "a mod that changes code cannot be switched on")
        driver.setMod(gameID: "demo.0", name: game.mods[0].name, on: false)
        XCTAssertFalse(driver.state.games.first { $0.id == "demo.0" }!.mods[0].on)
        driver.setCheat(gameID: "demo.0", key: "c2", on: true)
        driver.setCheatsMaster(gameID: "demo.0", on: false)
        game = driver.state.games.first { $0.id == "demo.0" }!
        XCTAssertEqual(game.cheats?.items.first { $0.key == "c2" }?.on, true)
        XCTAssertEqual(game.cheats?.masterOn, false)
        driver.openAdvanced("demo.0")
        XCTAssertEqual(driver.state.presentedSheet, .advanced("demo.0"))
        driver.back()
        driver.setOption(gameID: "demo.0", setting: "DM_VSYNC", value: "0")
        driver.askResetOptions("demo.0")
        XCTAssertEqual(driver.state.presentedSheet, .confirmReset("demo.0"), "Reset asks first")
        driver.resetOptions("demo.0")
        XCTAssertEqual(driver.state.presentedSheet, .options("demo.0"))
        XCTAssertTrue(driver.state.games.first { $0.id == "demo.0" }!.values.isEmpty, "the options are back to the defaults")
        driver.back()
        driver.openMenu(); driver.openSettings()
        XCTAssertFalse(driver.state.prefs[.startInConsole])
        driver.setPref(.startInConsole, on: true)
        XCTAssertTrue(driver.state.prefs[.startInConsole])
        driver.appUpdateAction()
        XCTAssertEqual(driver.state.presentedSheet, .confirmUpdate, "updating asks first")
        driver.confirmAppUpdate()
        XCTAssertEqual(driver.state.prefs.update, .ready)
        XCTAssertEqual(driver.state.presentedSheet, .settings)
    }

    /// Console mode's own buttons go by their printed letters, whatever the games' mapping: A confirms, B goes back, Y opens a game's
    /// options, X plays, L and R switch tabs, − opens the quick menu (#816). Swap A and B in menus makes B confirm, as on a Switch.
    func testConsoleButtonsGoByTheirLabels() {
        let usual = ConsoleButtons.bindings()
        XCTAssertEqual(usual[.a], .activate, "A confirms, as printed on Xbox and PlayStation controllers")
        XCTAssertEqual(usual[.b], .back)
        XCTAssertEqual(usual[.y], .options, "a game's options: the button printed Y")
        XCTAssertEqual(usual[.x], .play, "X plays the focused game")
        XCTAssertEqual(usual[.l], .previousTab)
        XCTAssertEqual(usual[.r], .nextTab)
        XCTAssertEqual(usual[.plus], .menu)
        XCTAssertEqual(usual[.select], .quickMenu, "− opens the quick menu, + the menu")
        let swapped = ConsoleButtons.bindings(swapAB: true)
        XCTAssertEqual(swapped[.b], .activate, "swapped: B confirms, as on a Switch")
        XCTAssertEqual(swapped[.a], .back)
        XCTAssertEqual(swapped[.y], .options)
        XCTAssertEqual(ConsoleButtons.button(for: .activate), .a)
        XCTAssertEqual(ConsoleButtons.button(for: .activate, swapAB: true), .b)
        XCTAssertEqual(ConsoleButtons.button(for: .menu), .plus, "+ before − for the menu's hint")
        XCTAssertEqual(ConsoleButtons.input(.left, swapAB: true), .left, "the D-pad moves whatever the swap")
        XCTAssertEqual(ConsoleGlyphs(family: .xbox).glyph(for: .activate, on: .a), .symbol("a.circle"), "the hint shows the button that confirms")
        XCTAssertEqual(ConsoleGlyphs.keyboard.glyph(for: .activate, on: .b), .keySymbol("return"), "the keyboard keeps its keys")
    }

    /// Opt-in: the four screens of the PR description, offscreen, with covers from this checkout's docs/images.
    @MainActor func testCapturePRScreens() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_CONSOLE_SHOTS_DIR"] else { throw XCTSkip("Set NX_CONSOLE_SHOTS_DIR") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        let repo = RepoLayout.find()
        for (sizeName, width, height) in [("1920", CGFloat(1920), CGFloat(1080)), ("compact", 390, 844)] {
            for (name, scenario, family) in [("home", MockConsoleDriver.Scenario.full, ConsoleGlyphs.Family.xbox), ("home-dualsense", .full, .playStation), ("home-keyboard", .full, .keyboard),
                                             ("controllers", .controllersMixed, .xbox), ("home-4pads", .controllersMixed, .xbox), ("controllers-wired", .controllers, .xbox), ("options", .full, .xbox), ("empty", .empty, .xbox), ("starting", .starting, .xbox),
                                             ("menu", .full, .xbox), ("library", .full, .xbox), ("general", .full, .xbox), ("update", .full, .xbox), ("leave", .full, .xbox),
                                             ("mapping", .full, .xbox), ("mapping-button", .full, .xbox), ("mapping-save", .full, .xbox),
                                             ("game-controller", .full, .xbox), ("game-mapping", .full, .xbox), ("advanced", .full, .xbox),
                                             ("reset", .full, .xbox), ("cloud-saves", .full, .xbox), ("not-built", .full, .xbox), ("supported", .full, .xbox), ("game-page", .full, .xbox), ("search", .full, .xbox)] {
                let driver = MockConsoleDriver(scenario: scenario, lang: .en, animated: false, artworkRepo: repo.isEmpty ? nil : repo)
                if name == "options" { driver.openOptions("demo.0") }
                if name == "home-4pads" { driver.back() }
                switch name {
                case "menu": driver.openMenu()
                case "library": driver.openMenu(); driver.openLibrary()
                case "general": driver.openMenu(); driver.openSettings()
                case "update": driver.openMenu(); driver.openSettings(); driver.appUpdateAction()
                case "leave": driver.back()
                case "mapping": driver.openMenu(); driver.openMapping()
                case "mapping-button": driver.openMenu(); driver.openMapping(); driver.setPadSends(button: "A", to: "B"); driver.openMappingRow("A")
                case "mapping-save": driver.openMenu(); driver.openMapping(); driver.setPadSends(button: "ZR", to: "none"); driver.back()
                case "game-controller": driver.openOptions("demo.0"); driver.openGamePad("demo.0")
                case "game-mapping": driver.openOptions("demo.0"); driver.openGamePad("demo.0"); driver.openGameMapping("demo.0"); driver.setPadSends(button: "ZR", to: "none")
                case "advanced": driver.openOptions("demo.0"); driver.openAdvanced("demo.0")
                case "reset": driver.openOptions("demo.0"); driver.setOption(gameID: "demo.0", setting: "DM_VSYNC", value: "0"); driver.askResetOptions("demo.0")
                case "cloud-saves": driver.openMenu(); driver.openLibrary(); driver.openCloudSaves()
                case "supported": driver.openMenu(); driver.openLibrary(); driver.openSupportedGames()
                case "game-page": driver.openGamePage("demo.0")
                case "search": driver.openSearch(); driver.typeSearch("z")
                case "not-built": driver.focus("demo.3"); driver.play("demo.3")
                default: break
                }
                let host = NSHostingView(rootView: ConsoleView(driver: driver, lang: .en, glyphs: .init(family: family)).transaction { $0.disablesAnimations = true }.frame(width: width, height: height))
                let window = OffscreenWindow(size: NSSize(width: width, height: height), styleMask: [.borderless])
                window.contentView = host
                window.orderBack(nil)
                RunLoop.main.run(until: Date().addingTimeInterval(0.25))
                host.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(name)-\(sizeName).png"))
                window.orderOut(nil); window.contentView = nil; window.close()
            }
        }
    }

    func testGlyphFamiliesFromCategory() {
        let cases: [(String?, ConsoleGlyphs.Family)] = [
            ("DualSense", .playStation), ("DualShock 4", .playStation), ("Xbox One", .xbox), ("Xbox Series X", .xbox),
            ("Switch Pro Controller", .nintendo), ("Nintendo Switch JoyCon (L/R)", .nintendo), ("Nintendo Switch Joy-Con (L/R)", .nintendo),
            ("Generic", .neutral), (nil, .neutral)]
        for (category, family) in cases { XCTAssertEqual(ConsoleGlyphs.Family(category: category), family, category ?? "nil") }
    }

    /// Actions resolve to GameController's elements (A confirms, B backs out, Y opens a game's options, menu opens the console's menu), then to
    /// what the controller prints there. On a DualSense A is the cross, B the circle and Y the triangle.
    func testGlyphsFollowTheControllerInUse() {
        XCTAssertEqual(ConsoleGlyphs.Role.activate.element, .a)
        XCTAssertEqual(ConsoleGlyphs.Role.back.element, .b)
        XCTAssertEqual(ConsoleGlyphs.Role.options.element, .y)
        XCTAssertEqual(ConsoleGlyphs.Role.menu.element, .menu)
        let xbox = ConsoleGlyphs(family: .xbox)
        XCTAssertEqual(xbox.glyph(for: .activate), .symbol("a.circle"))
        XCTAssertEqual(xbox.glyph(for: .back), .symbol("b.circle"))
        XCTAssertEqual(xbox.glyph(for: .options), .symbol("y.circle"))
        let ps = ConsoleGlyphs(family: .playStation)
        XCTAssertEqual(ps.glyph(for: .activate), .symbol("xmark.circle"), "Play is the cross")
        XCTAssertEqual(ps.glyph(for: .back), .symbol("circle.circle"), "Back is the circle")
        XCTAssertEqual(ps.glyph(for: .options), .symbol("triangle.circle"), "a game's options are the triangle")
        let nintendo = ConsoleGlyphs(family: .nintendo)
        XCTAssertEqual(nintendo.glyph(for: .activate), .symbol("a.circle"))
        XCTAssertEqual(nintendo.glyph(for: .options), .symbol("y.circle"))
        XCTAssertEqual(nintendo.glyph(for: .menu), .symbol("plus.circle"))
    }

    func testReportedSymbolWinsAndFallbacksAreNeutral() {
        let reported = ConsoleGlyphs(family: .xbox, reported: [.a: "a.circle.fill"])
        XCTAssertEqual(reported.glyph(for: .activate), .symbol("a.circle.fill"))
        XCTAssertEqual(ConsoleGlyphs(family: .xbox, reported: [.a: "custom.symbol"]).glyph(for: .activate), .symbol("a.circle"),
                       "a name this macOS does not have falls back to the family's")
        XCTAssertEqual(reported.glyph(for: .back), .symbol("b.circle"), "an element it does not report uses the family table")
        XCTAssertEqual(ConsoleGlyphs.neutral.glyph(for: .activate), .letter("A"))
        XCTAssertEqual(ConsoleGlyphs.neutral.glyph(for: .menu), .letter("+"))
        XCTAssertEqual(ConsoleGlyphs.keyboard.glyph(for: .activate), .keySymbol("return"))
        XCTAssertEqual(ConsoleGlyphs.keyboard.glyph(for: .back), .keySymbol("escape"))
        XCTAssertEqual(ConsoleGlyphs.keyboard.glyph(for: .options), .key("Y"))
        XCTAssertEqual(ConsoleGlyphs.keyboard.glyph(for: .menu), .key("M"))
        XCTAssertEqual(ConsoleGlyphs(family: .keyboard, reported: [.a: "x"]).glyph(for: .activate), .keySymbol("return"))
    }

    /// One mapping serves every family: GameController reports Xbox and PlayStation buttons by position (A is the bottom button,
    /// the cross) and a Nintendo-layout controller by its printed label (A on the right). The glyph is that same element.
    func testConfirmAndBackFollowTheLabelOnEveryFamily() {
        XCTAssertEqual(LauncherGamepad.face(for: .a), .a)
        XCTAssertEqual(LauncherGamepad.face(for: .b), .b)
        XCTAssertEqual(LauncherGamepad.face(for: .x), .x)
        XCTAssertEqual(LauncherGamepad.face(for: .y), .y)
        XCTAssertNil(LauncherGamepad.face(for: .left))
        XCTAssertNil(LauncherGamepad.face(for: .l))
        for family in [ConsoleGlyphs.Family.xbox, .playStation, .nintendo] {
            let glyphs = ConsoleGlyphs(family: family)
            guard case .symbol(let confirm) = glyphs.glyph(for: .activate), case .symbol(let back) = glyphs.glyph(for: .back) else { return XCTFail("\(family)") }
            XCTAssertEqual(confirm, ConsoleGlyphs.table(family)[.a], "\(family)")
            XCTAssertEqual(back, ConsoleGlyphs.table(family)[.b], "\(family)")
        }
        // Nintendo layout: Play shows A and Back shows B (not B and A)
        XCTAssertEqual(ConsoleGlyphs(family: .nintendo).glyph(for: .activate), .symbol("a.circle"))
        XCTAssertEqual(ConsoleGlyphs(family: .nintendo).glyph(for: .back), .symbol("b.circle"))
    }

    func testSplitJoyConSidewaysMenuMappingAndToggleSuppression() {
        XCTAssertTrue(LauncherGamepad.isJoyCon(category: "Switch Joy-Con (L/R)"))
        XCTAssertTrue(LauncherGamepad.isJoyCon(category: "Gamepad", vendorName: "Joy-Con (L)"))
        XCTAssertFalse(LauncherGamepad.isJoyCon(category: "Nintendo Switch Pro Controller"))

        var edges = LauncherGamepad.Edges()
        func fire(_ raw: LauncherGamepad.RawPadInput, split: Bool) -> [(String, [LauncherGamepad.Action])] {
            let groups = LauncherGamepad.states(controller: "jc", input: raw, splitJoyCon: split)
            if edges.syncSplitMode(baseController: "jc", split: split, groups: groups) { return [] }
            return groups.compactMap { g in
                let (p, _) = edges.changes(controller: g.controller, state: g.state)
                return p.isEmpty ? nil : (g.controller, p)
            }
        }

        // Left Joy-Con sideways (90° CCW): physical right (+X) -> .up, physical down (-Y) -> .right; D-pad Down -> .a, Left -> .b
        XCTAssertEqual(fire(.init(leftStickX: 0.9), split: true).first?.1, [.up])
        _ = fire(.init(), split: true)
        XCTAssertEqual(fire(.init(leftStickY: -0.9), split: true).first?.1, [.right])
        _ = fire(.init(), split: true)
        let leftFace = fire(.init(dpadX: -0.9, dpadY: -0.9), split: true)
        XCTAssertEqual(leftFace.first?.0, "jc.L")
        XCTAssertEqual(leftFace.first?.1, [.a, .b])
        _ = fire(.init(), split: true)

        // Right Joy-Con sideways (90° CW): physical left (-X) -> .up, physical up (+Y) -> .right; X -> .a, A -> .b
        XCTAssertEqual(fire(.init(rightStickX: -0.9), split: true).first?.1, [.up])
        _ = fire(.init(), split: true)
        XCTAssertEqual(fire(.init(rightStickY: 0.9), split: true).first?.1, [.right])
        _ = fire(.init(), split: true)
        let rightFace = fire(.init(a: true, x: true), split: true)
        XCTAssertEqual(rightFace.first?.0, "jc.R")
        XCTAssertEqual(rightFace.first?.1, [.a, .b])
        _ = fire(.init(), split: true)

        // Holding A while toggling split off->on must not re-fire as .b on the next frame before release
        _ = fire(.init(), split: false)
        XCTAssertEqual(fire(.init(a: true), split: false).first?.1, [.a])
        XCTAssertTrue(fire(.init(a: true), split: true).isEmpty, "button held across split toggle must not re-fire under its rotated role")
        _ = fire(.init(), split: true)
        XCTAssertEqual(fire(.init(a: true), split: true).first?.1, [.b], "fires normally once released and pressed again")
    }

    /// Opt-in: the desktop top bar with the entry button and the controller strip, and the connect prompt.
    @MainActor func testCaptureDesktopEntry() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_CONSOLE_SHOTS_DIR"] else { throw XCTSkip("Set NX_CONSOLE_SHOTS_DIR") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        func shot(_ view: AnyView, _ name: String, _ width: CGFloat, _ height: CGFloat) throws {
            // a titled window, as the launcher's own screenshots use: the launcher draws under its transparent title bar
            let host = NSHostingView(rootView: view)
            let window = OffscreenWindow(size: NSSize(width: width, height: height))
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
            window.orderOut(nil); window.contentView = nil; window.close()
        }
        ConsolePrompt.didShow()   // the desktop shots must not show the prompt a connected controller would raise
        let library = GameLibrary(file: output.appendingPathComponent("unused-library.json"))
        // the bottom right shows the Home hint and the Console mode button while a controller is connected (this Mac's, when one is)
        for width: CGFloat in [1280, 900] {
            try shot(AnyView(LauncherView(stores: LauncherStores(defaults: testDefaults), library: library, performStartupChecks: false, enterConsole: {})), "desktop-bar-\(Int(width))", width, 720)
        }
        try shot(AnyView(LauncherView(stores: LauncherStores(defaults: testDefaults), library: library, performStartupChecks: false, enterConsole: {}, qaPrompt: true)), "prompt-windowed", 1000, 720)
        for lang in [Lang.en, .zh] {
            try shot(AnyView(ConsoleConnectionPrompt(lang: lang, enterConsole: {}, dismissPrompt: {}).environmentObject(PadFocus()).preferredColorScheme(.dark)), "prompt-\(lang.code)", 900, 500)
        }
    }

}
