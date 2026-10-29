import XCTest
import SwiftUI
import Combine
@testable import NSPortBuilder

/// The player-mode setting's plumbing and the controller path into console mode (the same LauncherGamepad.perform
/// closure the desktop launcher and the onboarding use). A real controller still needs a manual check.
final class ConsolePadTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "ConsolePadTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

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
    }

    func testGamepadActionsMapToConsoleInputs() {
        let expected: [(LauncherGamepad.Action, ConsoleInput?)] = [
            (.left, .left), (.right, .right), (.up, .up), (.down, .down), (.a, .activate), (.b, .back),
            (.plus, .options), (.x, .options), (.y, .controllers), (.l, nil), (.r, nil)]
        for (action, input) in expected { XCTAssertEqual(ConsoleInput(action), input, "\(action)") }
    }

    /// Hosts the console view and drives it only through `gamepad.perform`, as Gamepad.swift does on a button edge.
    @MainActor func testControllerDrivesConsoleView() {
        let driver = MockConsoleDriver(scenario: .full, animated: false)
        let gamepad = LauncherGamepad()
        let host = NSHostingView(rootView: ConsoleView(driver: driver, gamepad: gamepad).frame(width: 1280, height: 800))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 1280, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
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
        gamepad.perform(.plus); settle()
        XCTAssertEqual(driver.state.presentedSheet, .options("demo.0"), "+ opens options")
        gamepad.perform(.b); settle()
        XCTAssertNil(driver.state.presentedSheet, "B closes the sheet")
        gamepad.perform(.y); settle()
        XCTAssertEqual(driver.state.presentedSheet, .controllers, "Y opens Controllers")
        gamepad.perform(.b); settle()
        XCTAssertNil(driver.state.presentedSheet)
        gamepad.perform(.l); gamepad.perform(.r); settle()
        XCTAssertNil(driver.state.presentedSheet, "L and R do nothing")
        gamepad.perform(.b); settle()
        XCTAssertTrue(driver.state.exited, "B from Home exits to the desktop")
    }

    /// Opt-in: the four screens of the PR description, offscreen, with covers from this checkout's docs/images.
    @MainActor func testCapturePRScreens() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_CONSOLE_SHOTS_DIR"] else { throw XCTSkip("Set NX_CONSOLE_SHOTS_DIR") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        let repo = BuildModel.findRepo()
        for (sizeName, width, height) in [("1920", CGFloat(1920), CGFloat(1080)), ("compact", 390, 844)] {
            for (name, scenario, family) in [("home", MockConsoleDriver.Scenario.full, ConsoleGlyphs.Family.xbox), ("home-dualsense", .full, .playStation), ("home-keyboard", .full, .keyboard),
                                             ("controllers", .controllersMixed, .xbox), ("home-4pads", .controllersMixed, .xbox), ("controllers-wired", .controllers, .xbox), ("options", .full, .xbox), ("empty", .empty, .xbox), ("starting", .starting, .xbox)] {
                let driver = MockConsoleDriver(scenario: scenario, lang: .en, animated: false, artworkRepo: repo.isEmpty ? nil : repo)
                if name == "options" { driver.openOptions("demo.0") }
                if name == "home-4pads" { driver.back() }
                let host = NSHostingView(rootView: ConsoleView(driver: driver, lang: .en, glyphs: .init(family: family)).transaction { $0.disablesAnimations = true }.frame(width: width, height: height))
                let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
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

    /// Actions resolve to GameController's elements (A confirms, B backs out, Y opens Controllers, menu opens options), then to
    /// what the controller prints there. On a DualSense A is the cross, B the circle and Y the triangle.
    func testGlyphsFollowTheControllerInUse() {
        XCTAssertEqual(ConsoleGlyphs.Role.activate.element, .a)
        XCTAssertEqual(ConsoleGlyphs.Role.back.element, .b)
        XCTAssertEqual(ConsoleGlyphs.Role.options.element, .menu)
        XCTAssertEqual(ConsoleGlyphs.Role.controllers.element, .y)
        let xbox = ConsoleGlyphs(family: .xbox)
        XCTAssertEqual(xbox.glyph(for: .activate), .symbol("a.circle"))
        XCTAssertEqual(xbox.glyph(for: .back), .symbol("b.circle"))
        XCTAssertEqual(xbox.glyph(for: .controllers), .symbol("y.circle"))
        let ps = ConsoleGlyphs(family: .playStation)
        XCTAssertEqual(ps.glyph(for: .activate), .symbol("xmark.circle"), "Play is the cross")
        XCTAssertEqual(ps.glyph(for: .back), .symbol("circle.circle"), "Back is the circle")
        XCTAssertEqual(ps.glyph(for: .controllers), .symbol("triangle.circle"), "Controllers is the triangle")
        let nintendo = ConsoleGlyphs(family: .nintendo)
        XCTAssertEqual(nintendo.glyph(for: .activate), .symbol("a.circle"))
        XCTAssertEqual(nintendo.glyph(for: .controllers), .symbol("y.circle"))
        XCTAssertEqual(nintendo.glyph(for: .options), .symbol("plus.circle"))
    }

    func testReportedSymbolWinsAndFallbacksAreNeutral() {
        let reported = ConsoleGlyphs(family: .xbox, reported: [.a: "custom.symbol"])
        XCTAssertEqual(reported.glyph(for: .activate), .symbol("custom.symbol"))
        XCTAssertEqual(reported.glyph(for: .back), .symbol("b.circle"), "an element it does not report uses the family table")
        XCTAssertEqual(ConsoleGlyphs.neutral.glyph(for: .activate), .letter("A"))
        XCTAssertEqual(ConsoleGlyphs.neutral.glyph(for: .options), .letter("+"))
        XCTAssertEqual(ConsoleGlyphs.keyboard.glyph(for: .activate), .keySymbol("return"))
        XCTAssertEqual(ConsoleGlyphs.keyboard.glyph(for: .back), .keySymbol("escape"))
        XCTAssertEqual(ConsoleGlyphs.keyboard.glyph(for: .options), .key("O"))
        XCTAssertEqual(ConsoleGlyphs.keyboard.glyph(for: .controllers), .key("Y"))
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

    /// Opt-in: the desktop top bar with the entry button and the controller strip, and the connect prompt.
    @MainActor func testCaptureDesktopEntry() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_CONSOLE_SHOTS_DIR"] else { throw XCTSkip("Set NX_CONSOLE_SHOTS_DIR") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        func shot(_ view: AnyView, _ name: String, _ width: CGFloat, _ height: CGFloat) throws {
            // a titled window, as the launcher's own screenshots use: the launcher draws under its transparent title bar
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
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
            try shot(AnyView(ContentView(model: BuildModel(), library: library, performStartupChecks: false, enterConsole: {})), "desktop-bar-\(Int(width))", width, 720)
        }
        try shot(AnyView(ContentView(model: BuildModel(), library: library, performStartupChecks: false, enterConsole: {}, qaPrompt: true)), "prompt-windowed", 1000, 720)
        for lang in [Lang.en, .zh] {
            try shot(AnyView(ConsoleConnectionPrompt(lang: lang, enterConsole: {}, dismissPrompt: {}).environmentObject(PadFocus()).preferredColorScheme(.dark)), "prompt-\(lang.rawValue)", 900, 500)
        }
    }

}
