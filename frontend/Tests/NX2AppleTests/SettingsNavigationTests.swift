import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
@testable import NXLauncher

@MainActor final class SettingsNavigationTests: IsolatedDefaultsTestCase {
    private func settle(_ seconds: Double = 0.2) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func withSettings(_ category: SettingsCategory,
        check: (LauncherStores, PadFocus, LauncherGamepad, NSWindow) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let stores = LauncherStores(defaults: testDefaults)
        let marker = folder.appendingPathComponent(EngineLayout.marker)
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: marker)
        stores.repo.path = folder.path
        stores.deviceStore.checked = true
        stores.dependencies.checked = true
        stores.dependencies.deps = [Dep(id: "xcode", name: "Xcode", hint: "", present: true, installCmd: [])]
        stores.players.create(name: "Second player")
        let library = GameLibrary(file: folder.appendingPathComponent("library.json"))
        let focus = PadFocus(), pad = LauncherGamepad(observeSystem: false, appIsActive: { true })
        let window = OffscreenWindow(size: .init(width: 1000, height: 700))
        window.contentView = NSHostingView(rootView: LauncherView(stores: stores, library: library, initialPage: .settings,
            settingsCategory: category, performStartupChecks: false, onRunSetup: {},
            controllerDriver: AnyConsoleDriver(MockConsoleDriver(scenario: .full, animated: false)), controls: ControlLayout(defaults: testDefaults), gamepad: pad, padFocus: focus))
        window.orderFront(nil)
        defer { window.contentView = nil; window.orderOut(nil); window.close(); pad.deactivate() }
        settle(0.5)
        try check(stores, focus, pad, window)
    }

    private func aim(_ id: String, _ focus: PadFocus) {
        focus.focused = nil; focus.show(default: id)
        XCTAssertEqual(focus.focused, id)
    }

    func testConnectionPromptWaitsForAnAvailableSurface() {
        XCTAssertFalse(ConsolePrompt.shouldShow(enabled: true, shown: false, surfaceAvailable: false))
        XCTAssertTrue(ConsolePrompt.shouldShow(enabled: true, shown: false, surfaceAvailable: true))
        XCTAssertFalse(ConsolePrompt.shouldShow(enabled: true, shown: true, surfaceAvailable: true))
    }

    func testEverySettingsCategoryExposesItsControls() throws {
        let expected: [(SettingsCategory, Set<String>)] = [
            (.general, ["set.category", "set.language", "set.appearance", "set.defaultDisplay", "set.returnAfterPlay"]),
            (.library, ["set.folder", "saves.global.cloud", "players.add"]),
            (.controls, ["set.controls", "set.controllers", "sticks.custom", "set.padMerge"]),
            (.tools, ["set.xcodeChoose", "set.deps.expand", "set.repoAuto", "set.setup"])]
        for (category, expected) in expected {
            try withSettings(category) { _, focus, _, _ in
                let ids = Set(focus.frames["main", default: []].map(\.id))
                XCTAssertTrue(ids.isSuperset(of: expected), "Missing \(expected.subtracting(ids)) in \(category)")
            }
        }
    }

    func testPlayerNamingAndRemovalOwnInputAndCancelSafely() throws {
        try withSettings(.library) { stores, focus, pad, _ in
            let before = stores.players.profiles
            aim("players.add", focus); pad.perform(.a); settle(0.4)
            XCTAssertEqual(focus.scope, "playername")
            guard focus.scope == "playername" else { return }
            for action in [LauncherGamepad.Action.l, .r, .x, .y, .select] { pad.perform(action) }
            XCTAssertEqual(focus.scope, "playername")
            pad.perform(.b); settle(0.4)
            XCTAssertEqual(focus.scope, "main")
            XCTAssertEqual(stores.players.profiles, before)
            let second = try XCTUnwrap(before.first { !$0.isDefault })
            aim("players.remove." + second.id, focus); pad.perform(.a); settle(0.4)
            XCTAssertEqual(focus.scope, "playerremove")
            pad.perform(.b); settle(0.4)
            XCTAssertEqual(stores.players.profiles, before)
            XCTAssertEqual(focus.scope, "main")
        }
    }

    func testDeadzoneControlsAdjustOnlyWhileEnabledAndRemainVisible() throws {
        try withSettings(.controls) { stores, focus, pad, window in
            XCTAssertFalse(focus.frames["main", default: []].contains { $0.id == "sticks.left" })
            aim("sticks.custom", focus); pad.perform(.a); settle()
            XCTAssertTrue(stores.sticks.settings.custom)
            aim("sticks.left", focus); pad.perform(.right); settle()
            XCTAssertEqual(stores.sticks.settings.left, StickDeadzoneSettings().left + 1)
            let frame = try XCTUnwrap(focus.frames["main"]?.first { $0.id == "sticks.left" }?.frame)
            XCTAssertGreaterThanOrEqual(frame.minY, 64)
            XCTAssertLessThanOrEqual(frame.maxY, window.contentView!.bounds.height)
            aim("sticks.custom", focus); pad.perform(.a); settle()
            XCTAssertFalse(focus.frames["main", default: []].contains { $0.id == "sticks.left" })
        }
    }

    func testUpdateSheetBlocksBackgroundNavigationAndBackDismissesIt() throws {
        try withSettings(.general) { stores, focus, pad, _ in
            stores.appUpdates.showUpdateSheet = true; settle(0.4)
            XCTAssertEqual(focus.scope, "update")
            guard focus.scope == "update" else { return }
            for action in [LauncherGamepad.Action.l, .r, .x, .y, .select] { pad.perform(action) }
            XCTAssertTrue(stores.appUpdates.showUpdateSheet)
            XCTAssertEqual(focus.scope, "update")
            pad.perform(.b); settle(0.4)
            XCTAssertFalse(stores.appUpdates.showUpdateSheet)
            XCTAssertEqual(focus.scope, "main")
        }
    }
    func testControlsDirtyCancelQuestionClosesOnlyTheQuestion() throws {
        try withSettings(.controls) { _, focus, pad, _ in
            aim("set.controls", focus); pad.perform(.a); settle(0.4)
            XCTAssertEqual(focus.scope, "controls")
            aim("pad.mode", focus); pad.perform(.right); settle()
            pad.perform(.b); settle(0.4)
            XCTAssertEqual(focus.scope, "controldiscard")
            XCTAssertEqual(focus.focused, "controldiscard.cancel")
            pad.perform(.b); settle(0.4)
            XCTAssertEqual(focus.scope, "controls")
            aim("controls.done", focus); pad.perform(.a); settle(0.4)
            XCTAssertEqual(focus.scope, "main")
        }
    }

    func testUninstallQuestionCancelNeverDeletesFiles() throws {
        try withSettings(.tools) { stores, focus, pad, _ in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let sentinel = folder.appendingPathComponent("keep")
            try Data("keep".utf8).write(to: sentinel)
            stores.appUpdates.uninstallPlan = Uninstall.plan(home: folder.path, gamesFolder: "", outputFolder: "", checkouts: [], defaultsDomain: nil)
            settle(0.4)
            XCTAssertEqual(focus.scope, "uninstall")
            pad.perform(.b); settle(0.4)
            XCTAssertNil(stores.appUpdates.uninstallPlan)
            XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
            XCTAssertEqual(focus.scope, "main")
        }
    }

    func testPersonalLanguageSelectorActivatesAndWrapsWithController() {
        let focus = PadFocus()
        let host = NSHostingView(rootView: PersonalDefaultsCard(defaults: testDefaults)
            .environmentObject(Localizer(.en)).environmentObject(focus).padScope("main", focus))
        let window = OffscreenWindow(size: .init(width: 900, height: 400))
        window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.orderOut(nil); window.close() }
        settle()
        aim("set.defaultLanguage", focus); focus.horizontal(-1); settle()
        XCTAssertEqual(PersonalDefaults.load(testDefaults).value(for: "DM_LANG"), RomFSLanguages.table.last?.code)
        focus.horizontal(1); settle()
        XCTAssertNil(PersonalDefaults.load(testDefaults).value(for: "DM_LANG"))
        focus.activate(); settle()
        XCTAssertEqual(PersonalDefaults.load(testDefaults).value(for: "DM_LANG"), RomFSLanguages.table.first?.code)
    }

    func testCacheMoveQuestionCanCancelAndRunningMoveKeepsStopReachable() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let stores = LauncherStores(defaults: testDefaults), focus = PadFocus()
        stores.build.shellMove = .confirm(ShellRootMove.plan(from: folder.appendingPathComponent("old").path, to: folder.appendingPathComponent("new").path))
        let host = NSHostingView(rootView: ShellCacheRow(build: stores.build).environmentObject(stores.localizer)
            .environmentObject(focus).padScope("main", focus))
        let window = OffscreenWindow(size: .init(width: 900, height: 500))
        window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.orderOut(nil); window.close() }
        settle()
        aim("set.cache.cancel", focus); focus.activate(); settle()
        XCTAssertEqual(stores.build.shellMove, .idle)
        stores.build.shellMove = .moving(phase: .copying, done: 0, total: 100); stores.build.running = true; settle()
        aim("set.cache.stop", focus)
        XCTAssertFalse(focus.frames["main", default: []].contains { $0.id == "set.cacheMove" })
        stores.build.running = false
    }

    func testReturnAfterPlayHelpOwnsInputAndRestoresFocus() throws {
        try withSettings(.general) { _, focus, pad, _ in
            aim("set.returnAfterPlay.help", focus)
            pad.perform(.a); settle(0.5)
            XCTAssertEqual(focus.scope, "set.returnAfterPlay.help.popover")
            for action in [LauncherGamepad.Action.l, .r, .x, .y, .select] { pad.perform(action) }
            XCTAssertEqual(focus.scope, "set.returnAfterPlay.help.popover")
            pad.perform(.b); settle(0.5)
            XCTAssertEqual(focus.scope, "main")
            XCTAssertEqual(focus.focused, "set.returnAfterPlay.help")
            XCTAssertTrue(focus.frames["main", default: []].contains { $0.id == "set.returnAfterPlay" })
        }
    }

}
