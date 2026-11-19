import SwiftUI
import XCTest
import Combine
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

@MainActor final class RemainingConsoleNavigationTests: IsolatedDefaultsTestCase {
    private func settle(_ seconds: Double = 0.18) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func host(_ driver: MockConsoleDriver, size: CGSize = .init(width: 1280, height: 800),
        check: (PadFocus, LauncherGamepad, NSHostingView<AnyView>, (Int) -> Void) throws -> Void) rethrows {
        let focus = PadFocus(), source = SteamLinkGamepads(observeSystem: false)
        let pad = LauncherGamepad(steam: source, observeSystem: false, appIsActive: { true })
        let view = NSHostingView(rootView: AnyView(ConsoleView(driver: driver, lang: .en, gamepad: pad, padFocus: focus).frame(width: size.width, height: size.height)))
        let window = OffscreenWindow(size: size, styleMask: [.borderless])
        window.contentView = view; window.orderFront(nil)
        defer { pad.deactivate(); window.contentView = nil; window.orderOut(nil); window.close() }
        settle(0.3)
        func press(_ usage: Int) {
            var packet = SteamVirtualGamepad()
            _ = packet.update(page: 9, usage: usage, value: 1, min: 0, max: 1)
            for state in [packet, SteamVirtualGamepad()] {
                NotificationCenter.default.post(name: .steamLinkPadInput, object: source,
                    userInfo: ["input": SteamLinkGamepads.Input(id: "remaining-navigation", state: state)])
                settle(0.04)
            }
        }
        try check(focus, pad, view, press)
    }

    func testEveryConsolePagePanelAndQuestionHasVisibleActiveFocusAndBack() throws {
        let pages: [ConsoleSheet] = [.menu, .controllers, .options("demo.0"), .explanation("demo.1"), .homeButtonHint,
            .mapping, .gamePad("demo.0"), .library, .settings, .language, .cloudSaves, .confirmExit, .confirmMapping,
            .advanced("demo.0"), .confirmReset("demo.0"), .confirmUpdate, .gamePage("demo.0"), .allGames,
            .search, .builds, .supportedGames, .quickMenu, .manage("demo.0"), .stopped, .confirmStopBuild, .confirmQuitPaused,
            .cloudSave(.init(gameName: "Sample", outcome: .bothChanged, local: .init(hash: "a", saved: nil), cloud: .init(hash: "b", saved: nil), reason: nil, backups: FileManager.default.temporaryDirectory)),
            .cloudSave(.init(gameName: "Sample", outcome: .unreadable, local: .init(hash: "a", saved: nil), cloud: nil, reason: "Offline", backups: FileManager.default.temporaryDirectory))]
        for size in [CGSize(width: 1280, height: 800), CGSize(width: 900, height: 680)] {
            let driver = MockConsoleDriver(scenario: .full, animated: false)
            driver.state.stopped = .init(gameID: "demo.0", lastSave: nil)
            try host(driver, size: size) { focus, pad, view, _ in
                for (index, page) in pages.enumerated() {
                    driver.state.sheets = page == .menu ? [.menu] : [.menu, page]; settle(0.3)
                    XCTAssertEqual(focus.scope, page.scope, "\(page)")
                    let active = try XCTUnwrap(focus.frames[page.scope]?.first { $0.id == focus.focused }, "\(page), \(focus.focused ?? "nil")")
                    XCTAssertGreaterThanOrEqual(active.frame.minY, -1, "\(page)")
                    XCTAssertLessThanOrEqual(active.frame.maxY, size.height + 1, "\(page)")
                    if let path = ProcessInfo.processInfo.environment["NX_REMAINING_CAPTURE_DIR"] {
                        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                        view.cacheDisplay(in: view.bounds, to: rep)
                        let directory = URL(fileURLWithPath: path)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("console-\(Int(size.width))-\(index).png"))
                    }
                    if page.isQuestion {
                        for action in [LauncherGamepad.Action.x, .y, .plus, .select, .l, .r] { pad.perform(action) }
                        XCTAssertEqual(driver.state.presentedSheet, page, "Question must keep background shortcuts isolated")
                    }
                    pad.perform(.b); settle()
                    XCTAssertNotEqual(driver.state.presentedSheet, page, "Back must leave only the current surface: \(page)")
                }
            }
        }
    }

    func testRunningBuildStopStaysVisibleInShortWindow() throws {
        let driver = MockConsoleDriver(scenario: .full, animated: false)
        driver.state.builds.stages = (0..<12).map { .init(id: $0, name: "Stage \($0)", state: $0 == 1 ? .running : .pending) }
        try host(driver, size: .init(width: 900, height: 680)) { focus, pad, _, _ in
            driver.openBuilds(); settle(0.5)
            let stop = try XCTUnwrap(focus.frames[focus.scope]?.first { $0.id == "console.builds.stop" })
            XCTAssertEqual(focus.focused, stop.id)
            let back = try XCTUnwrap(focus.frames[focus.scope]?.first { $0.id == "console.builds.close" })
            XCTAssertEqual(stop.frame.width, back.frame.width, accuracy: 1)
            XCTAssertEqual(stop.frame.minY, back.frame.minY, accuracy: 1)
            XCTAssertGreaterThan(stop.frame.minX, back.frame.maxX)
            XCTAssertGreaterThan(stop.frame.minY, 500)
            XCTAssertLessThanOrEqual(stop.frame.maxY, 680)
            pad.perform(.a); settle()
            XCTAssertEqual(driver.state.presentedSheet, .confirmStopBuild)
            XCTAssertEqual(focus.focused, "console.confirmStop.cancel")
            pad.perform(.b); settle()
            XCTAssertEqual(driver.state.presentedSheet, .builds)
            XCTAssertEqual(focus.focused, stop.id)
        }
    }

    func testLongConsoleGridCanReachTheLastGameWithoutSkippingBehindFooter() throws {
        let driver = MockConsoleDriver(scenario: .full, animated: false)
        let sample = try XCTUnwrap(driver.state.games.first)
        driver.state.games = (0..<62).map { i in var game = sample; game.id = "long.\(i)"; game.title = String(format: "Game %02d", i); return game }
        try host(driver) { focus, pad, _, press in
            driver.openAllGames(); settle(0.3)
            let last = try XCTUnwrap(driver.state.libraryGames.last)
            focus.focused = "console.lib." + driver.state.libraryGames[0].id; settle()
            var previousIndex = 0
            for _ in 0..<(driver.state.libraryGames.count * 2) {
                if focus.focused == "console.lib." + last.id { settle(0.3); break }
                pad.perform(.down); settle(0.08)
                for _ in 0..<50 where focus.focused.flatMap({ focus.frame(of: $0) }) == nil { settle(0.02) }
                if let index = driver.state.libraryGames.firstIndex(where: { "console.lib." + $0.id == focus.focused }) {
                    XCTAssertGreaterThanOrEqual(index, previousIndex, "Scrolling must never reset focus to the top")
                    previousIndex = index
                }
            }
            let focused = try XCTUnwrap(focus.focused)
            let frame = try XCTUnwrap(focus.frames[focus.scope]?.first { $0.id == "console.lib." + last.id }?.frame)
            XCTAssertEqual(focused, "console.lib." + last.id)
            XCTAssertGreaterThanOrEqual(frame.minY, 80)
            XCTAssertLessThanOrEqual(frame.maxY, 632)
            focus.focused = "console.lib." + last.id; settle()
            press(1); settle()
            XCTAssertEqual(driver.state.startingGameID, last.id)
            XCTAssertNil(driver.state.presentedSheet)
        }
    }
    func testConsoleTabsFiltersAndMappingChooserKeepVisibleFocus() throws {
        let driver = MockConsoleDriver(scenario: .full, animated: false)
        try host(driver) { focus, pad, _, _ in
            driver.openGamePage("demo.0"); settle()
            for tab in ConsoleGameTab.allCases {
                while driver.state.gameTab != tab { pad.perform(.r); settle() }
                XCTAssertTrue(focus.frames[focus.scope, default: []].contains { $0.id == focus.focused }, "\(tab)")
            }
            driver.state.sheets = []; driver.openAllGames(); settle()
            for filter in ConsoleLibraryFilter.allCases {
                while driver.state.libraryFilter != filter { pad.perform(.r); settle() }
                XCTAssertTrue(focus.frames[focus.scope, default: []].contains { $0.id == focus.focused }, "\(filter)")
            }
            driver.state.sheets = []; driver.openMapping(); driver.setPadMode(.custom); settle()
            driver.openMappingRow("A"); settle()
            XCTAssertEqual(focus.scope, "console.mapping")
            XCTAssertTrue(focus.frames[focus.scope, default: []].contains { $0.id == focus.focused })
            pad.perform(.b); settle()
            XCTAssertNil(driver.state.mappingRow)
            XCTAssertEqual(focus.focused, "console.map.row.A")
        }
    }

}
