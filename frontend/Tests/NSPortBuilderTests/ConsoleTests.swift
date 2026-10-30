import XCTest
import SwiftUI
import Combine
@testable import NSPortBuilder

final class ConsoleTests: XCTestCase {
    @MainActor func testScenariosAndBoundedFocus() {
        let driver = MockConsoleDriver(animated: false)
        XCTAssertEqual(driver.state.games.count, 12)
        XCTAssertTrue(driver.state.games.allSatisfy { $0.artwork == nil }, "Without a repository the covers are generated placeholders, never bundled artwork")
        driver.focus("demo.2")
        XCTAssertEqual(driver.state.focusedGameID, "demo.2")
        driver.focus("missing")
        XCTAssertEqual(driver.state.focusedGameID, "demo.2")
        var state = driver.state
        state.moveFocus(-100)
        XCTAssertEqual(state.focusedGame?.id, "demo.0")
        state.moveFocus(100)
        XCTAssertEqual(state.focusedGame?.id, "demo.11")
        XCTAssertEqual(MockConsoleDriver(scenario: .few, animated: false).state.games.count, 2)
        var empty = MockConsoleDriver(scenario: .empty, animated: false).state
        empty.moveFocus(1)
        XCTAssertNil(empty.focusedGame)
        XCTAssertNil(MockConsoleDriver.Scenario(rawValue: "unknown"))
        XCTAssertNotNil(MockConsoleDriver(scenario: .starting, animated: false).state.startingGame)
    }

    @MainActor func testPlayExplainsEachUnavailableStatus() {
        for (id, key) in [("demo.3", "console.needsBuild"), ("demo.5", "console.needsData"), ("demo.7", "console.broken"), ("demo.9", "console.iphoneOnlyNote")] {
            let driver = MockConsoleDriver(animated: false)
            driver.focus(id)
            driver.play(id)
            XCTAssertNil(driver.state.startingGameID)
            XCTAssertEqual(driver.state.presentedSheet, .explanation(id))
            XCTAssertEqual(driver.state.focusedGame?.status.explanationKey, key)
            driver.play(id) // repeated input must not stack duplicate explanations
            XCTAssertEqual(driver.state.sheets.count, 1)
        }
        let driver = MockConsoleDriver(animated: false)
        driver.play("unknown")
        XCTAssertNil(driver.state.startingGameID)
        driver.play("demo.0")
        XCTAssertEqual(driver.state.startingGameID, "demo.0")
        driver.back() // Starting ends only through the driver, not a second launch or a timeout
        driver.play("demo.1")
        XCTAssertEqual(driver.state.startingGameID, "demo.0")
        driver.returnFromGame()
        XCTAssertNil(driver.state.startingGameID)
        XCTAssertEqual(driver.state.focusedGameID, "demo.0")
    }

    @MainActor func testSheetStackAndBackExitRestoration() {
        let driver = MockConsoleDriver(animated: false)
        driver.focus("demo.5")
        driver.openOptions("demo.5")
        driver.openOptions("demo.5")
        XCTAssertEqual(driver.state.sheets.count, 1)
        driver.openControllers()
        driver.focus("demo.0")
        XCTAssertEqual(driver.state.focusedGameID, "demo.5")
        driver.back()
        XCTAssertEqual(driver.state.presentedSheet, .options("demo.5"))
        driver.play("demo.5")
        XCTAssertEqual(driver.state.presentedSheet, .explanation("demo.5"))
        driver.back()
        XCTAssertEqual(driver.state.presentedSheet, .options("demo.5"))
        driver.back()
        XCTAssertNil(driver.state.presentedSheet)
        XCTAssertFalse(driver.state.exited)
        driver.back()
        XCTAssertTrue(driver.state.exited)
        driver.openOptions("demo.0"); driver.openControllers(); driver.play("demo.0")
        XCTAssertNil(driver.state.presentedSheet)
        XCTAssertNil(driver.state.startingGameID)
        driver.returnFromGame()
        XCTAssertFalse(driver.state.exited)
        XCTAssertEqual(driver.state.focusedGameID, "demo.5")
        driver.openControllers()
        driver.exitToDesktop()
        XCTAssertTrue(driver.state.sheets.isEmpty)
    }

    @MainActor func testOptionsUseLaunchSettingValidationAndDependencies() throws {
        let driver = MockConsoleDriver(animated: false)
        driver.setOption(gameID: "demo.0", setting: "DM_FPS_TARGET", value: "120")
        XCTAssertNil(driver.state.games[0].values["DM_FPS_TARGET"])
        driver.setOption(gameID: "demo.0", setting: "DM_FPS_TARGET", value: "30")
        XCTAssertEqual(driver.state.games[0].values["DM_FPS_TARGET"], "30")
        let scale = try XCTUnwrap(driver.state.games[0].settings.first { $0.kind == "range" })
        XCTAssertEqual(ConsoleOption.stepped(scale, value: "2", by: 1), "2")
        XCTAssertEqual(ConsoleOption.stepped(scale, value: "0.5", by: -1), "0.5")
        XCTAssertEqual(ConsoleOption.stepped(scale, value: "1", by: 1), "1.25")
        let choice = try XCTUnwrap(driver.state.games[0].settings.first { $0.kind == "choice" })
        XCTAssertEqual(ConsoleOption.stepped(choice, value: "60", by: 1), "30")
        XCTAssertEqual(ConsoleOption.stepped(choice, value: "30", by: -1), "60")
        let toggle = try XCTUnwrap(driver.state.games[0].settings.first { $0.kind == "toggle" })
        XCTAssertEqual(ConsoleOption.stepped(toggle, value: "1", by: 1), "0")
        var child = toggle
        child.needs = "DM_FPS_TARGET=60"
        var game = driver.state.games[0]
        game.settings = [choice, child]
        game.values = ["DM_FPS_TARGET": "30"]
        XCTAssertEqual(game.visibleSettings.count, 1)
        game.values["DM_FPS_TARGET"] = "60"
        XCTAssertEqual(game.visibleSettings.count, 2)
        driver.setOption(gameID: "demo.0", setting: "DM_RENDER_SCALE", value: "nan")
        XCTAssertNil(driver.state.games[0].values["DM_RENDER_SCALE"])
        driver.setOption(gameID: "missing", setting: "DM_LANG", value: "en")
    }

    @MainActor func testControllerAssignmentIsUniqueAndScoped() {
        let driver = MockConsoleDriver(scenario: .controllers, animated: false)
        XCTAssertEqual(driver.state.controllers.count, 3)
        XCTAssertEqual(driver.state.assigningPlayer, 3)
        driver.assignPlayer(controllerID: "pad.3", player: 1)
        XCTAssertNil(driver.state.controllers[0].player)
        XCTAssertEqual(driver.state.controllers[2].player, 1)
        XCTAssertNil(driver.state.assigningPlayer)
        driver.requestPlayer(4)
        XCTAssertEqual(driver.state.assigningPlayer, 4)
        driver.assignPlayer(controllerID: "missing", player: 4)
        XCTAssertEqual(driver.state.assigningPlayer, 4)
        driver.assignPlayer(controllerID: "pad.2", player: 5)
        XCTAssertEqual(driver.state.controllers[1].player, 2)
        driver.back()
        XCTAssertNil(driver.state.assigningPlayer)
        driver.assignPlayer(controllerID: "pad.3", player: 2)
        XCTAssertEqual(driver.state.controllers[2].player, 1)
    }

    @MainActor func testMixedControllersActionsMergeAndToasts() {
        let driver = MockConsoleDriver(scenario: .controllersMixed, lang: .en, animated: false)
        XCTAssertFalse(driver.state.padMerge)
        XCTAssertEqual(driver.state.controllers.map(\.kind), [.fullSize, .xbox, .keyboard, .paired])
        XCTAssertEqual(driver.state.controllers[1].batteryPercent, 12)
        XCTAssertNil(driver.state.controllers[2].batteryPercent)
        XCTAssertTrue(driver.state.controllers[3].charging)
        driver.setPadMerge(true)
        XCTAssertTrue(driver.state.padMerge)
        XCTAssertEqual(driver.state.controllers[1].player, 2, "Merging preserves the separate-player mapping for switching back")
        driver.identify(controllerID: "pad.2")
        XCTAssertEqual(driver.state.identifyingControllerID, "pad.2")
        XCTAssertTrue(driver.state.toast?.message.contains("Identifying") == true)
        driver.requestPlayer(3)
        driver.requestAssignment(controllerID: "pad.2")
        driver.assignPlayer(controllerID: "pad.1", player: 3)
        XCTAssertEqual(driver.state.assigningControllerID, "pad.2")
        driver.assignPlayer(controllerID: "pad.2", player: 3)
        XCTAssertEqual(driver.state.controllers[1].player, 3)
        driver.disconnect(controllerID: "pad.2")
        XCTAssertEqual(driver.state.controllers.count, 3)
        XCTAssertTrue(driver.state.toast?.message.contains("disconnected") == true)
        driver.connect(.init(id: "pad.5", name: "Controller 5", player: 4))
        XCTAssertTrue(driver.state.toast?.message.contains("player 1") == true)
        driver.dismissToast()
        XCTAssertNil(driver.state.toast)
        driver.setPadMerge(false)
        XCTAssertFalse(driver.state.padMerge)
        let bridge = AnyConsoleDriver(driver)
        bridge.setPadMerge(true)
        XCTAssertTrue(bridge.state.padMerge)
    }

    func testStartingProgressAndControllerCopy() {
        XCTAssertNil(ConsoleStarting.preparing.progress)
        XCTAssertEqual(ConsoleStarting.compilingShaders(completed: 18, total: 48).progress, 0.375)
        XCTAssertNil(ConsoleStarting.compilingShaders(completed: 0, total: 0).progress)
        XCTAssertEqual(ConsoleStarting.compilingShaders(completed: 60, total: 48).progress, 1)
        for kind in ConsoleController.Kind.allCases { XCTAssertNotNil(L10n.table[kind.labelKey]) }
        for (key, pair) in L10n.table where key.hasPrefix("console.") {
            XCTAssertFalse(pair.en.contains(";"), key)
            XCTAssertFalse(pair.zh.contains(";") || pair.zh.contains("\u{ff1b}"), key)
        }
    }

    func testEveryConsoleStringHasBothLanguages() {
        let keys = L10n.table.keys.filter { $0.hasPrefix("console.") }
        XCTAssertGreaterThan(keys.count, 45)
        for key in keys {
            for lang in [Lang.en, .zh] {
                XCTAssertFalse(L10n.string(key, lang).isEmpty, key)
                XCTAssertNotEqual(L10n.string(key, lang), key)
            }
        }
        for status in [ConsoleGame.Status.ready, .needsBuild, .needsData, .iphoneOnly, .broken("")] {
            XCTAssertNotNil(L10n.table[status.labelKey])
            if let key = status.explanationKey { XCTAssertNotNil(L10n.table[key]) }
        }
        XCTAssertTrue(L10n.selfCheck().isEmpty)
    }

    @MainActor func testRenderDesktopControllerIntegration() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_CONSOLE_CAPTURE_DIR"] else { throw XCTSkip("Set NX_CONSOLE_CAPTURE_DIR for desktop captures") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for lang in [Lang.en, .zh] {
            for width: CGFloat in [900, 1280] {
                let model = BuildModel()
                model.lang = lang
                let library = GameLibrary(file: output.appendingPathComponent("unused-library.json"))
                let driver = MockConsoleDriver(scenario: .controllersMixed, lang: lang, animated: false)
                driver.back()
                let view = ContentView(model: model, library: library, performStartupChecks: false, controllerDriver: AnyConsoleDriver(driver))
                let host = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: width, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.orderBack(nil)
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                host.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("desktop-\(Int(width))-\(lang.rawValue).png"))
                window.orderOut(nil)
                window.contentView = nil
                window.close()
            }
        }
    }

    /// Offscreen, deterministic SwiftUI snapshots; opt-in to avoid opening windows during normal tests.
    @MainActor func testRenderConsoleForVisualQA() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_CONSOLE_CAPTURE_DIR"] else {
            throw XCTSkip("Set NX_CONSOLE_CAPTURE_DIR to capture console screens")
        }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        let sizes: [(String, CGFloat, CGFloat)] = [("tv", 1920, 1080), ("mac", 1280, 800), ("compact", 390, 844)]
        for lang in [Lang.en, .zh] {
            for (name, width, height) in sizes {
                for screen in ["full", "few", "empty", "controllers", "controllersMixed", "mixedHome", "controllerDesktop", "connectedToast", "starting", "options", "needsBuild", "needsData", "broken", "desktop", "prompt"] {
                    let driver = MockConsoleDriver(scenario: MockConsoleDriver.Scenario(rawValue: screen) ?? (screen == "mixedHome" || screen == "controllerDesktop" || screen == "connectedToast" ? .controllersMixed : .full), lang: lang, animated: false)
                    switch screen {
                    case "mixedHome": driver.back()
                    case "connectedToast": driver.back(); driver.disconnect(controllerID: "pad.2"); driver.connect(.init(id: "pad.2", name: L10n.string("console.demoController", lang), player: 2))
                    case "options": driver.openOptions("demo.0")
                    case "needsBuild": driver.focus("demo.3"); driver.play("demo.3")
                    case "needsData": driver.focus("demo.5"); driver.play("demo.5")
                    case "broken": driver.focus("demo.7"); driver.play("demo.7")
                    case "desktop": driver.exitToDesktop()
                    default: break
                    }
                    let view: AnyView
                    if screen == "controllerDesktop" {
                        view = AnyView(ConsoleControllersSheet(driver: driver, lang: lang, close: {}).environmentObject(PadFocus()))
                    } else if screen == "prompt" {
                        view = AnyView(ConsoleConnectionPrompt(lang: lang, enterConsole: {}, dismissPrompt: {}).environmentObject(PadFocus()).preferredColorScheme(.dark))
                    } else { view = AnyView(ConsoleView(driver: driver, lang: lang).transaction { $0.disablesAnimations = true }) }
                    let host = NSHostingView(rootView: view.frame(width: width, height: height))
                    let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = host
                    window.orderBack(nil)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.12))
                    host.layoutSubtreeIfNeeded()
                    let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                        .write(to: output.appendingPathComponent("\(screen)-\(name)-\(lang.rawValue).png"))
                    window.orderOut(nil)
                    window.contentView = nil
                    window.close()
                }
            }
        }
    }

    /// The focus ring of the first tile must survive a scroll to the far end and back. Scrolling to a tile's own edge used to push the
    /// 8 pt of room for the ring out of the row's clip, so the ring was cut at the left. The ring is cream, so the test looks for a
    /// cream column just left of the first tile's image. Set NX_CONSOLE_CAPTURE_DIR to keep the PNGs.
    @MainActor func testFirstTileRingIsNotClippedAfterScrollingBack() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let (width, height): (CGFloat, CGFloat) = (1280, 800)
        let driver = MockConsoleDriver(scenario: .full, lang: .en, animated: false)
        let host = NSHostingView(rootView: ConsoleView(driver: driver, lang: .en).transaction { $0.disablesAnimations = true }.frame(width: width, height: height))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.4)); host.layoutSubtreeIfNeeded() }
        func snapshot(_ name: String) throws -> NSBitmapImageRep {
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            if let directory = ProcessInfo.processInfo.environment["NX_CONSOLE_CAPTURE_DIR"] {
                let output = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
            }
            return rep
        }
        settle()
        let first = try XCTUnwrap(driver.state.games.first).id, last = try XCTUnwrap(driver.state.games.last).id
        let start = try snapshot("clip-1-start")
        driver.focus(last); settle()
        _ = try snapshot("clip-2-last")
        driver.focus(first); settle()
        let rep = try snapshot("clip-3-back")
        // the ring is a vertical cream line along the image's left edge: the leftmost column with a long run of cream pixels
        func ringColumn(_ rep: NSBitmapImageRep) -> Int? {
            func isCream(_ x: Int, _ y: Int) -> Bool {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                return c.redComponent > 0.8 && c.greenComponent > 0.75 && c.blueComponent > 0.6 && c.alphaComponent > 0.9
            }
            let scale = CGFloat(rep.pixelsWide) / width
            for x in 0..<Int(300 * scale) {
                var run = 0
                for y in 0..<rep.pixelsHigh { run = isCream(x, y) ? run + 1 : 0; if run >= Int(150 * scale) { return x } }
            }
            return nil
        }
        let before = try XCTUnwrap(ringColumn(start), "no focus ring found at the start")
        let after = try XCTUnwrap(ringColumn(rep), "no focus ring found on the first tile after scrolling back")
        XCTAssertEqual(after, before, "the first tile's ring is cut off after scrolling back (its left edge moved)")
    }
}
