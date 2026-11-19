import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

@MainActor final class ConsoleVisualRefreshTests: IsolatedDefaultsTestCase {
    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.4)) }

    func testCircularHeaderAndOverflowArrowsBrowseWithoutOpeningAGame() throws {
        for (size, gutter) in [(CGSize(width: 900, height: 680), CGFloat(70)), (CGSize(width: 1280, height: 800), CGFloat(70)), (CGSize(width: 1920, height: 1080), CGFloat(70))] {
            let driver = MockConsoleDriver(scenario: .full, animated: false)
            let sample = try XCTUnwrap(driver.state.games.first)
            driver.state.games = (0..<12).map { index in
                var game = sample
                game.id = "visual.\(index)"; game.title = "Game \(index)"; game.status = .ready
                return game
            }
            driver.state.focusedGameID = "visual.0"
            let focus = PadFocus()
            let view = NSHostingView(rootView: ConsoleView(driver: driver, lang: .en, padFocus: focus).frame(width: size.width, height: size.height))
            let window = OffscreenWindow(size: size, styleMask: [.borderless])
            window.contentView = view; window.orderBack(nil)
            defer { window.contentView = nil; window.orderOut(nil); window.close() }
            settle()
            for id in ["console.chip.controllers", "console.searchButton", "console.menuButton"] {
                let frame = try XCTUnwrap(focus.frames["console"]?.first { $0.id == id }?.frame)
                XCTAssertEqual(frame.height, 52, accuracy: 0.5)
                if id != "console.chip.controllers" { XCTAssertEqual(frame.width, frame.height, accuracy: 0.5) }
                let search = try XCTUnwrap(focus.frames["console"]?.first { $0.id == "console.searchButton" }?.frame)
                XCTAssertEqual(frame.midY, search.midY, accuracy: 0.5)
                XCTAssertGreaterThanOrEqual(frame.minX, 0)
                XCTAssertLessThanOrEqual(frame.maxX, size.width)
            }
            let initial = try XCTUnwrap(focus.frames["console"]?.first { $0.id == "console.game.visual.0" }?.frame)
            let menu = try XCTUnwrap(focus.frames["console"]?.first { $0.id == "console.menuButton" }?.frame)
            XCTAssertEqual(menu.maxX, size.width - gutter, accuracy: 0.5)
            XCTAssertEqual(menu.minY, 52, accuracy: 0.5, "Header retains its 50pt top padding and centered 52pt controls")
            let open = try XCTUnwrap(focus.frames["console"]?.first { $0.id == "console.open" }?.frame)
            let back = try XCTUnwrap(focus.frames["console"]?.first { $0.id == "console.desktop" }?.frame)
            XCTAssertEqual(open.minX, gutter, accuracy: 0.5)
            XCTAssertEqual(back.maxX, size.width - gutter, accuracy: 0.5)
            for id in ConsoleHomeScreen<MockConsoleDriver>.hintIDs {
                let frame = try XCTUnwrap(focus.frames["console"]?.first { $0.id == id }?.frame)
                XCTAssertGreaterThanOrEqual(frame.minX, gutter - 1, id)
                XCTAssertLessThanOrEqual(frame.maxX, size.width - gutter + 1, id)
                XCTAssertGreaterThanOrEqual(frame.minY, 0, id)
                XCTAssertLessThanOrEqual(frame.maxY, size.height, id)
            }
            if size.width == 1920 {
                let order = ["console.open", "console.options", "console.menu", "console.quickMenuHint", "console.desktop"]
                let controls = try order.map { id in try XCTUnwrap(focus.frames["console"]?.first { $0.id == id }?.frame) }
                let gaps = zip(controls, controls.dropFirst()).map { $1.minX - $0.maxX }
                for gap in gaps { XCTAssertEqual(gap, try XCTUnwrap(gaps.first), accuracy: 0.5, "Footer actions distribute the available width evenly") }
            }
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / size.width
            var borderX: CGFloat?
            for x in 0..<Int((gutter + 12) * scale) {
                var run = 0
                for y in 0..<rep.pixelsHigh {
                    let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                    let cream = c.map { $0.redComponent > 0.8 && $0.greenComponent > 0.75 && $0.blueComponent > 0.6 && $0.alphaComponent > 0.9 } ?? false
                    run = cream ? run + 1 : 0
                    if run > Int(initial.width / 1.8 * 0.5 * scale) { borderX = CGFloat(x) / scale; break }
                }
                if borderX != nil { break }
            }
            XCTAssertEqual(try XCTUnwrap(borderX), gutter, accuracy: 2, "The visible cream border follows the content rail")

            let right = try XCTUnwrap(focus.frames["console"]?.first { $0.id.hasPrefix("console.edge.") && $0.id.hasSuffix(".right") }?.id)
            XCTAssertFalse(focus.frames["console", default: []].contains { $0.id.hasPrefix("console.edge.") && $0.id.hasSuffix(".left") })
            focus.scope = "console"; focus.focused = right; focus.activate(); settle()
            XCTAssertNotEqual(driver.state.focusedGameID, "visual.0")
            XCTAssertEqual(focus.focused, "console.game." + (driver.state.focusedGameID ?? ""))
            XCTAssertNil(driver.state.presentedSheet)
            XCTAssertNil(driver.state.startingGameID)
            let moved = try XCTUnwrap(focus.frames["console"]?.first { $0.id == focus.focused }?.frame)
            XCTAssertEqual(initial.minX, moved.minX, accuracy: 1, "Selection stays in one leading slot")
            driver.focus("visual.11"); settle()
            let last = try XCTUnwrap(focus.frames["console"]?.first { $0.id == "console.game.visual.11" }?.frame)
            XCTAssertEqual(initial.minX, last.minX, accuracy: 1, "The final game retains the same slot")
            let previous = try XCTUnwrap(focus.frames["console"]?.first { $0.id == "console.game.visual.10" }?.frame)
            XCTAssertLessThan(previous.minX, 0)
            XCTAssertGreaterThan(previous.maxX, 0, "The preceding cover remains reachable at the viewport edge")
            XCTAssertFalse(focus.frames["console", default: []].contains { $0.id.hasPrefix("console.edge.") })
        }
    }

    func testNoOverflowArrowsForOneGameAndLongTitlesKeepRowPosition() throws {
        let driver = MockConsoleDriver(scenario: .few, animated: false)
        var game = try XCTUnwrap(driver.state.games.first)
        game.status = .ready
        driver.state.games = [game]; driver.state.focusedGameID = game.id
        let focus = PadFocus(), size = CGSize(width: 900, height: 680)
        let view = NSHostingView(rootView: ConsoleView(driver: driver, lang: .en, padFocus: focus).frame(width: size.width, height: size.height))
        let window = OffscreenWindow(size: size, styleMask: [.borderless])
        window.contentView = view; window.orderBack(nil)
        defer { window.contentView = nil; window.orderOut(nil); window.close() }
        settle()
        XCTAssertFalse(focus.frames["console", default: []].contains { $0.id.hasPrefix("console.edge.") })
        let first = try XCTUnwrap(focus.frames["console"]?.first { $0.id == "console.game." + game.id }?.frame)
        driver.state.games[0].title = "A very long game title that wraps across multiple lines while the artwork and controls stay in their slots"
        settle()
        let second = try XCTUnwrap(focus.frames["console"]?.first { $0.id == "console.game." + game.id }?.frame)
        XCTAssertEqual(first.minY, second.minY, accuracy: 0.5)
        XCTAssertEqual(first.width, second.width, accuracy: 0.5)
    }
}
