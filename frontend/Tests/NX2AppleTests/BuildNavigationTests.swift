import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
@testable import NXLauncher

@MainActor final class BuildNavigationTests: IsolatedDefaultsTestCase {
    private func settle(_ seconds: Double = 0.25) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func withBuilds(count: Int = 3, page: LauncherPage = .builds, ready: Bool = true, height: CGFloat = 1400,
        check: (LauncherStores, GameLibrary, PadFocus, LauncherGamepad, NSWindow, (Int) -> Void) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("build-navigation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let games = (0..<count).map { i in
            LibraryGame(titleID: String(format: "%016llX", UInt64(0x0100000000000000) + UInt64(i) * 0x2000),
                name: String(format: "Game %02d", i), inputs: ["base": [root.appendingPathComponent("Game\(i).nsp").path]])
        }
        for i in 0..<count { try Data().write(to: root.appendingPathComponent("Game\(i).nsp")) }
        let file = root.appendingPathComponent("library.json")
        try JSONEncoder().encode(games).write(to: file)
        let library = GameLibrary(file: file), stores = LauncherStores(defaults: testDefaults)
        let marker = root.appendingPathComponent("dm/tools/nx_extract/Program.cs")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: marker)
        stores.repo.path = root.path
        stores.dependencies.checked = ready
        stores.deviceStore.checked = true
        stores.build.target = BuildTarget.mac
        let focus = PadFocus(), source = SteamLinkGamepads(observeSystem: false)
        let pad = LauncherGamepad(steam: source, observeSystem: false, appIsActive: { true })
        let window = OffscreenWindow(size: .init(width: 1100, height: height))
        window.contentView = NSHostingView(rootView: LauncherView(stores: stores, library: library, initialPage: page,
            performStartupChecks: false, gamepad: pad, padFocus: focus))
        window.orderFront(nil)
        defer { window.contentView = nil; window.orderOut(nil); pad.deactivate(); stores.build.running = false }
        settle(0.5)
        func press(_ usage: Int) {
            var packet = SteamVirtualGamepad()
            _ = packet.update(page: 9, usage: usage, value: 1, min: 0, max: 1)
            for state in [packet, SteamVirtualGamepad()] {
                NotificationCenter.default.post(name: .steamLinkPadInput, object: source,
                    userInfo: ["input": SteamLinkGamepads.Input(id: "build-navigation", state: state)])
                settle(0.04)
            }
        }
        try check(stores, library, focus, pad, window, press)
    }

    private func aim(_ id: String, _ focus: PadFocus) {
        focus.focused = nil
        focus.show(default: id)
    }

    func testHeroArtworkFollowsRunningGameAheadOfEarlierPlatformRetry() throws {
        try withBuilds(count: 6) { stores, library, _, _, _, _ in
            var entries = library.games.map { QueueEntry(game: $0, engineID: "fixture") }
            entries[0].status = .done
            entries.insert(QueueEntry(game: library.games[0], engineID: "fixture", target: BuildTarget.ios), at: 1)
            entries[6].status = .running
            let groups = QueueGame.grouped(entries)
            let hero = BuildMetadataHero(build: stores.build, queueGames: groups)
            XCTAssertEqual(hero.artworkGames.map(\.titleID), [groups[5], groups[0], groups[1], groups[2]].map(\.titleID))
            XCTAssertEqual(BuildMetadataHero(build: stores.build, queueGames: []).artworkGames.count, 0)
            let idle = BuildMetadataHero(build: stores.build, queueGames: Array(groups.prefix(3)))
            XCTAssertEqual(idle.artworkGames.map(\.id), groups.prefix(3).map(\.id))
        }
    }

    func testAdvancingQueueKeepsProgressDuringIdleGapAndUsesExactRowHeight() throws {
        try withBuilds { stores, library, focus, _, window, _ in
            let queue = BuildQueueStore(file: nil, engineID: { "fixture" }, busy: { true }, start: { _ in nil })
            queue.enqueue([QueueEntry(game: library.games[0], engineID: "fixture")])
            queue.start()
            XCTAssertTrue(queue.isAdvancing)
            XCTAssertNil(queue.running)
            stores.build.buildingGame = false
            stores.build.running = false
            stores.build.stages = (0..<3).map { Stage(id: $0, name: "Step \($0)") }
            window.contentView = NSHostingView(rootView: BuildPage(step: .constant(0), build: stores.build, running: false,
                repo: stores.repo, dependencies: stores.dependencies, devices: stores.deviceStore, queue: queue, transfers: stores.transfers,
                extrasOpen: .constant(false), logOpen: .constant(false), confirmingCancel: .constant(false))
                .environmentObject(stores.localizer).environmentObject(focus).padScope("main", focus))
            settle()
            XCTAssertTrue(focus.frames["main", default: []].contains { $0.id == "set.build.action" }, "The progress card must remain mounted between queue jobs")
            XCTAssertFalse(focus.frames["main", default: []].contains { $0.id == "set.build.target.mac" })
            for count in [1, 3, 5] {
                let rows = NSHostingView(rootView: BuildProcessRows(stages: (0..<count).map { Stage(id: $0, name: "Step") }).environmentObject(stores.localizer))
                XCTAssertEqual(rows.fittingSize.height, CGFloat(count * 60 - 16), accuracy: 0.1)
            }
        }
    }

    func testMissingSetupShowsHintAndRoutesToToolsWithoutLosingDraft() throws {
        try withBuilds(ready: false) { stores, library, focus, pad, _, _ in
            let source = library.games[0].inputs["base"]!
            stores.build.take(picked: source, kind: .base); settle()
            XCTAssertTrue(focus.frames["main", default: []].contains { $0.id == "set.build.setup" })
            aim("set.build.setup", focus); pad.perform(.a); settle()
            XCTAssertTrue(focus.frames["main", default: []].contains { $0.id == "set.repoChoose" })
            XCTAssertEqual(stores.build.basePath, source[0])
            stores.dependencies.checked = true
            aim("tab.builds", focus); pad.perform(.a); settle()
            XCTAssertFalse(focus.frames["main", default: []].contains { $0.id == "set.build.setup" })
        }
    }

    func testRunningBuildExposesStepsSheetAndCollapsibleSetupAndLogs() throws {
        try withBuilds { stores, _, focus, pad, window, _ in
            stores.build.buildingGame = true
            stores.build.stages = [Stage(id: 1, name: "Extract", state: .done), Stage(id: 2, name: "Shaders", percent: 42)]
            stores.build.running = true; settle()
            XCTAssertFalse(focus.frames["main", default: []].contains { $0.id == "set.build.file.base" })
            XCTAssertTrue(focus.frames["main", default: []].contains { $0.id == "set.build.action" })
            XCTAssertTrue(focus.frames["main", default: []].contains { $0.id == "set.build.runningSetup" })
            aim("set.build.log", focus); pad.perform(.a); settle()
            XCTAssertTrue(focus.frames["main", default: []].contains { $0.id == "set.build.logContent" })
            window.setContentSize(.init(width: 900, height: 680)); settle()
            XCTAssertTrue(focus.frames["main", default: []].contains { $0.id == "set.build.action" })
            aim("set.build.steps", focus); pad.perform(.a); settle(0.5)
            XCTAssertEqual(focus.scope, "build.steps")
            pad.perform(.b); settle(0.5)
            XCTAssertEqual(focus.scope, "main")
            XCTAssertEqual(focus.focused, "set.build.steps")
            stores.build.running = false; settle()
            XCTAssertTrue(focus.frames["main", default: []].contains { $0.id == "set.build.file.base" })
        }
    }

    func testMinimizedBuildFooterShowsOutsideBuildsAndHidesOnBuilds() throws {
        try withBuilds(page: .settings) { stores, _, focus, pad, _, _ in
            stores.build.running = true
            settle()
            XCTAssertTrue(focus.frames["main", default: []].contains { $0.id == "build.activity" })
            aim("build.activity", focus); pad.perform(.a); settle()
            XCTAssertFalse(focus.frames["main", default: []].contains { $0.id == "build.activity" })
            aim("top.settings", focus); pad.perform(.a); settle()
            XCTAssertTrue(focus.frames["main", default: []].contains { $0.id == "build.activity" })
            stores.build.running = false; settle()
            XCTAssertFalse(focus.frames["main", default: []].contains { $0.id == "build.activity" })
        }
    }

    func testBatchSheetOwnsControllerInputAndStagesOnlyCheckedGames() throws {
        try withBuilds { stores, library, focus, pad, _, _ in
            aim("set.build.queue.select", focus); pad.perform(.a); settle(0.5)
            XCTAssertEqual(focus.scope, "batch")
            guard focus.scope == "batch" else { return }
            for action in [LauncherGamepad.Action.l, .r, .x, .y, .select] { pad.perform(action) }
            XCTAssertEqual(focus.scope, "batch")
            let id = library.games[1].id
            aim("batch.game." + id.uuidString, focus)
            XCTAssertEqual(focus.focused, "batch.game." + id.uuidString)
            pad.perform(.a); settle()
            aim("batch.add", focus); pad.perform(.a); settle(0.5)
            XCTAssertEqual(stores.queue.queued.map(\.gameID), [id])
            XCTAssertFalse(stores.build.running, "staging never starts builds")
            XCTAssertEqual(focus.scope, "main")
        }
    }

    func testBatchPlatformChoiceCommitsOnAddAndCancelLeavesItUnchanged() throws {
        try withBuilds { stores, library, focus, pad, _, _ in
            XCTAssertEqual(stores.build.target, BuildTarget.mac)
            aim("set.build.queue.select", focus); pad.perform(.a); settle(0.5)
            aim("batch.platform", focus); pad.perform(.right); settle()
            XCTAssertEqual(stores.build.target, BuildTarget.mac, "the choice remains a draft until Add")
            aim("batch.game." + library.games[0].id.uuidString, focus); pad.perform(.a); settle()
            aim("batch.add", focus); pad.perform(.a); settle(0.5)
            XCTAssertEqual(stores.build.target, BuildTarget.ios)
            XCTAssertEqual(stores.queue.queued.map(\.target), [BuildTarget.ios])
            XCTAssertFalse(stores.build.running)
            aim("set.build.queue.select", focus); pad.perform(.a); settle(0.5)
            aim("batch.platform", focus); pad.perform(.left); settle()
            pad.perform(.b); settle(0.5)
            XCTAssertEqual(stores.build.target, BuildTarget.ios)
            XCTAssertEqual(stores.queue.queued.map(\.target), [BuildTarget.ios])
        }
    }

    func testAddingIOSMergesWithMacIntoOneVisibleGameAndPreventsDuplicateRequests() throws {
        try withBuilds { stores, library, focus, pad, _, _ in
            let game = library.games[0]
            aim("set.build.queue.select", focus); pad.perform(.a); settle(0.5)
            aim("batch.game." + game.id.uuidString, focus); pad.perform(.a); settle()
            aim("batch.add", focus); pad.perform(.a); settle(0.5)
            let first = stores.queue.games[0].id
            aim("set.build.queue.select", focus); pad.perform(.a); settle(0.5)
            XCTAssertFalse(focus.frames["batch", default: []].contains { $0.id == "batch.game." + game.id.uuidString })
            aim("batch.platform", focus); pad.perform(.right); settle()
            aim("batch.game." + game.id.uuidString, focus); pad.perform(.a); settle()
            aim("batch.add", focus); pad.perform(.a); settle(0.5)
            XCTAssertEqual(stores.queue.entries.count, 2)
            XCTAssertEqual(stores.queue.games.count, 1)
            XCTAssertTrue(stores.queue.games[0].both)
            aim("set.build.queue.select", focus); pad.perform(.a); settle(0.5)
            aim("batch.platform", focus); pad.perform(.right); settle()
            XCTAssertFalse(focus.frames["batch", default: []].contains { $0.id == "batch.game." + game.id.uuidString })
            pad.perform(.b); settle(0.5)
            XCTAssertEqual(stores.queue.games[0].id, first)
            XCTAssertEqual(focus.frames["main", default: []].filter { $0.id.hasPrefix("set.build.queue.remove.") }.count, 1)
            XCTAssertFalse(focus.frames["main", default: []].contains { $0.id.hasPrefix("set.build.target.") })
            XCTAssertTrue(focus.frames["main", default: []].contains { $0.id == "set.build.bc" })
            XCTAssertFalse(stores.build.running)
        }
    }

    func testBothSelectionStagesTwoConsecutiveJobsInOneGameRow() throws {
        try withBuilds { stores, library, focus, pad, _, _ in
            aim("set.build.queue.select", focus); pad.perform(.a); settle(0.5)
            aim("batch.platform", focus); pad.perform(.right); pad.perform(.right); settle()
            aim("batch.game." + library.games[0].id.uuidString, focus); pad.perform(.a); settle()
            aim("batch.add", focus); pad.perform(.a); settle(0.5)
            XCTAssertEqual(stores.queue.games.count, 1)
            XCTAssertEqual(stores.queue.entries.map(\.target), [BuildTarget.mac, BuildTarget.ios])
            XCTAssertEqual(stores.build.queuedCount, 1)
            XCTAssertEqual(focus.frames["main", default: []].filter { $0.id.hasPrefix("set.build.queue.remove.") }.count, 1)
            XCTAssertFalse(stores.build.running)
        }
    }

    func testBatchFilterDropsHiddenSelectionsBeforeAdding() throws {
        try withBuilds { stores, library, focus, pad, _, _ in
            let first = library.games[0], second = library.games[1]
            stores.queue.enqueue([QueueEntry(game: first, engineID: stores.engineSync.selection.engineID, target: BuildTarget.ios)])
            aim("set.build.queue.select", focus); pad.perform(.a); settle(0.5)
            aim("batch.game." + first.id.uuidString, focus); pad.perform(.a); settle()
            aim("batch.platform", focus); pad.perform(.right); settle()
            XCTAssertFalse(focus.frames["batch", default: []].contains { $0.id == "batch.game." + first.id.uuidString || $0.id == "batch.add" })
            aim("batch.game." + second.id.uuidString, focus); pad.perform(.a); settle()
            aim("batch.add", focus); pad.perform(.a); settle(0.5)
            XCTAssertEqual(stores.queue.entries.count, 2)
            XCTAssertTrue(stores.queue.entries.allSatisfy { $0.target == BuildTarget.ios })
        }
    }

    func testBatchKeyboardEnterTogglesTheFocusedRowWithoutSubmitting() throws {
        try withBuilds { stores, library, focus, pad, window, _ in
            aim("set.build.queue.select", focus); pad.perform(.a); settle(0.5)
            let sheet = try XCTUnwrap(window.attachedSheet)
            @MainActor func keyboard(in view: NSView) -> ConsoleKeyboardInput.KeyView? {
                if let key = view as? ConsoleKeyboardInput.KeyView { return key }
                return view.subviews.lazy.compactMap { keyboard(in: $0) }.first
            }
            let adapter = try XCTUnwrap(keyboard(in: try XCTUnwrap(sheet.contentView)))
            @MainActor func key(_ code: UInt16, _ text: String) throws {
                let input = try XCTUnwrap(ConsoleKeyboardInput.KeyView.input(keyCode: code, characters: text, typing: false))
                adapter.perform(input)
                settle()
            }
            try key(36, "\r")
            XCTAssertEqual(focus.scope, "batch")
            XCTAssertTrue(stores.queue.queued.isEmpty)
            XCTAssertTrue(focus.frames["batch", default: []].contains { $0.id == "batch.add" })
            try key(36, "\r")
            XCTAssertFalse(focus.frames["batch", default: []].contains { $0.id == "batch.add" })
            try key(125, "\u{F701}")
            XCTAssertEqual(focus.focused, "batch.game." + library.games[1].id.uuidString)
            try key(36, "\r")
            aim("batch.add", focus); pad.perform(.a); settle()
            XCTAssertEqual(stores.queue.queued.map(\.gameID), [library.games[1].id])
        }
    }

    func testSingleScreenBuilderControlsAreReachableAndDisabledWhileRunning() throws {
        try withBuilds { stores, library, focus, pad, _, _ in
            let ids = Set(focus.frames["main", default: []].map(\.id))
            XCTAssertTrue(ids.isSuperset(of: ["set.build.engine", "set.build.folder", "set.build.file.base", "set.build.file.keys", "set.build.output", "set.build.file.update", "set.build.file.dlc", "set.build.target.ios", "set.build.queue.select", "set.build.log"]))
            stores.build.take(picked: library.games[0].inputs["base"]!, kind: .base); settle()
            aim("set.build.target.ios", focus)
            guard focus.focused == "set.build.target.ios" else { return }
            pad.perform(.a); settle()
            XCTAssertEqual(stores.build.target, BuildTarget.ios)
            XCTAssertTrue(focus.frames["main", default: []].contains { $0.id == "set.build.install.mode" })
            aim("set.build.install.mode", focus); pad.perform(.right); settle()
            XCTAssertTrue(stores.deviceStore.exportIPA)
            stores.build.running = true; settle()
            XCTAssertFalse(focus.frames["main", default: []].contains { $0.id == "set.build.target." + BuildTarget.mac })
            XCTAssertTrue(focus.frames["main", default: []].contains { $0.id == "set.build.action" }, "Stop remains reachable")
        }
    }

    func testFailureLogRequestRevealsLogWithoutLosingSource() throws {
        try withBuilds { stores, library, focus, _, _, _ in
            stores.build.take(picked: library.games[0].inputs["base"]!, kind: .base)
            stores.build.log.append("Fixture build error")
            defer { BuildNotifier.shared.showLog = false }
            BuildNotifier.shared.showLog = true
            settle(0.5)
            XCTAssertTrue(focus.frames["main", default: []].contains { $0.id == "set.build.logContent" })
            XCTAssertEqual(stores.build.basePath, library.games[0].inputs["base"]?.first)
            XCTAssertFalse(stores.build.running)
        }
    }

    func testHeaderTabsStayCenteredAcrossWidthsAndExpandedSearch() throws {
        try withBuilds(height: 720) { stores, _, focus, _, window, _ in
            _ = stores.players.create(name: "A deliberately long player name")
            stores.appUpdates.update = .init(tag: "v9.9.9", url: "", digest: nil)
            func checkCenter() throws {
                let targets = focus.frames["main", default: []]
                let library = try XCTUnwrap(targets.first { $0.id == "tab.library" })
                let builds = try XCTUnwrap(targets.first { $0.id == "tab.builds" })
                let middle = (library.frame.minX + builds.frame.maxX) / 2
                XCTAssertEqual(middle, window.contentView!.bounds.width / 2, accuracy: 1)
                for id in ["top.player", "top.update", "top.settings"] {
                    let target = try XCTUnwrap(targets.first { $0.id == id })
                    XCTAssertGreaterThanOrEqual(target.frame.minX, builds.frame.maxX + 6, id)
                    XCTAssertLessThanOrEqual(target.frame.maxX, window.contentView!.bounds.width, id)
                }
            }
            for width in [900.0, 1100.0, 1600.0] {
                window.setContentSize(.init(width: width, height: 720)); settle()
                try checkCenter()
                XCTAssertFalse(focus.frames["main", default: []].contains { $0.id == "builds.back" || $0.id == "set.build.options" })
            }
            window.setContentSize(.init(width: 900, height: 720)); settle()
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
            XCTAssertTrue(window.performKeyEquivalent(with: event)); settle()
            XCTAssertTrue(window.firstResponder is NSTextView)
            try checkCenter()
        }
    }

    func testOutputHelpOwnsControllerInputAndBackRestoresTheIcon() throws {
        try withBuilds { stores, _, focus, pad, _, _ in
            aim("set.build.output.help", focus); settle()
            XCTAssertEqual(focus.focused, "set.build.output.help")
            pad.perform(.a); settle(0.5)
            XCTAssertEqual(focus.scope, "set.build.output.help.popover")
            for action in [LauncherGamepad.Action.l, .r, .x, .y, .select] { pad.perform(action) }
            XCTAssertEqual(focus.scope, "set.build.output.help.popover")
            XCTAssertTrue(stores.build.basePath.isEmpty)
            pad.perform(.b); settle(0.5)
            XCTAssertEqual(focus.scope, "main")
            XCTAssertEqual(focus.focused, "set.build.output.help")
            XCTAssertTrue(focus.frames["main", default: []].contains { $0.id == "set.build.file.base" })
        }
    }

    func testQueueReorderRemoveAndCancelAreReachableAndDoNotStartWork() throws {
        try withBuilds { stores, library, focus, pad, _, _ in
            stores.queue.enqueue(library.games.map { QueueEntry(game: $0, engineID: stores.engineSync.selection.engineID) })
            focus.show(default: nil)
            settle()
            let entries = stores.queue.queued
            let targets = focus.frames["main", default: []]
            let down = try XCTUnwrap(targets.first { $0.id == "set.build.queue.down." + entries[1].id.uuidString })
            let up = try XCTUnwrap(targets.first { $0.id == "set.build.queue.up." + entries[1].id.uuidString })
            let remove = try XCTUnwrap(targets.first { $0.id == "set.build.queue.remove." + entries[1].id.uuidString })
            for target in [up, down, remove] {
                XCTAssertEqual(target.frame.width, target.frame.height, accuracy: 0.5)
                XCTAssertEqual(target.frame.height, LauncherControl.height, accuracy: 0.5)
            }
            XCTAssertLessThan(up.frame.maxX, down.frame.minX)
            XCTAssertLessThan(down.frame.maxX, remove.frame.minX)
            aim("set.build.queue.up." + entries[1].id.uuidString, focus); pad.perform(.a); settle()
            XCTAssertEqual(stores.queue.queued.first?.id, entries[1].id)
            aim("set.build.queue.remove." + entries[2].id.uuidString, focus); pad.perform(.a); settle()
            XCTAssertEqual(stores.queue.queued.count, 2)
            aim("set.build.queue.cancel", focus); pad.perform(.a); settle(0.5)
            XCTAssertEqual(focus.scope, "queuecancel")
            for action in [LauncherGamepad.Action.l, .r, .x, .y, .select] { pad.perform(action) }
            XCTAssertEqual(focus.scope, "queuecancel")
            pad.perform(.b); settle(0.5)
            XCTAssertEqual(stores.queue.queued.count, 2)
            XCTAssertEqual(focus.scope, "main")
            aim("set.build.queue.cancel", focus); pad.perform(.a); settle(0.5)
            aim("queuecancel.confirm", focus); pad.perform(.a); settle(0.5)
            XCTAssertTrue(stores.queue.queued.isEmpty)
            XCTAssertFalse(stores.build.running)
        }
    }

    func testSupportedGamesLongListRevealsUnmaterializedRows() throws {
        let focus = PadFocus()
        let games = (0..<35).map { SupportedGame(titleID: String(format: "%016llX", UInt64(0x0100000000000000) + UInt64($0) * 0x2000), name: String(format: "Game %02d", $0), edition: .switch1, version: nil, notes: "Notes") }
        let window = OffscreenWindow(size: .init(width: 680, height: 600))
        window.contentView = NSHostingView(rootView: SupportedGamesSheet(games: games, owned: { _ in nil },
            covers: .saved(in: URL(fileURLWithPath: "/fixture/absent"), maxPixel: 224), showInLibrary: { _ in })
            .environmentObject(Localizer(.en)).environmentObject(focus))
        window.orderFront(nil)
        defer { window.contentView = nil; window.orderOut(nil) }
        focus.scope = "supported"
        settle()
        aim("supported.row." + games[0].titleID, focus)
        for _ in 1..<games.count { focus.move(dx: 0, dy: 1); settle(0.06) }
        settle()
        XCTAssertEqual(focus.focused, "supported.row." + games.last!.titleID)
        let frame = try XCTUnwrap(focus.frames["supported"]?.first { $0.id == focus.focused }?.frame)
        XCTAssertGreaterThan(frame.minY, 100)
        XCTAssertLessThan(frame.maxY, 540)
    }

    func testLogControllerScrollReadsTheLogInsteadOfThePageBehindIt() throws {
        let log = BuildLog(), focus = PadFocus()
        log.append((0..<200).map { "Log line \($0)" }.joined(separator: "\n"))
        let host = NSHostingView(rootView: ScrollView {
            VStack { Color.clear.frame(height: 400); BuildLogView(log: log, placeholder: ""); Color.clear.frame(height: 400) }
        }.environmentObject(focus).padScope("main", focus))
        let window = OffscreenWindow(size: .init(width: 800, height: 600))
        window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.orderOut(nil) }
        settle(0.5)
        func scrolls(_ view: NSView) -> [NSScrollView] { ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrolls) }
        let views = scrolls(host).sorted { $0.bounds.height < $1.bounds.height }
        let inner = try XCTUnwrap(views.first), outer = try XCTUnwrap(views.last)
        XCTAssertFalse(inner === outer)
        let before = inner.contentView.bounds.minY, pageBefore = outer.contentView.bounds.minY
        aim("set.build.logContent", focus); focus.move(dx: 0, dy: -1); settle()
        XCTAssertLessThan(inner.contentView.bounds.minY, before)
        XCTAssertEqual(outer.contentView.bounds.minY, pageBefore)
    }

    func testCompletedQueueRowPlayUsesItsGameAndKeepsQueueResults() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let entry = QueueEntry(titleID: "A", name: "Game", target: BuildTarget.mac, inputs: [:], outputDirectory: "/out", engineID: "engine", status: .done)
        BuildQueueFile.save([entry], to: file)
        let queue = BuildQueueStore(file: file, engineID: { "engine" }, busy: { false }, start: { _ in XCTFail("Play must not start a build"); return nil })
        let focus = PadFocus(); var played: [String] = []
        let window = OffscreenWindow(size: .init(width: 900, height: 500))
        window.contentView = NSHostingView(rootView: BuildQueueCard(queue: queue, onSelectGames: {}, canPlay: { _ in true }, onPlay: { played.append($0.titleID) })
            .environmentObject(Localizer(.en)).environmentObject(focus).padScope("main", focus))
        window.orderFront(nil)
        defer { window.contentView = nil; window.orderOut(nil) }
        settle(0.5)
        aim("set.build.queue.play." + entry.id.uuidString, focus); focus.activate(); settle()
        XCTAssertEqual(played, ["A"])
        XCTAssertEqual(queue.entries[0].status, .done)
        XCTAssertFalse(queue.active)
    }

    func testQueueArtworkOutcomeKeepsPartialAndPackagingStatesHonest() {
        var mac = QueueEntry(titleID: "A", name: "Game", target: BuildTarget.mac, inputs: [:], outputDirectory: "/out", engineID: "engine", status: .done)
        var ios = QueueEntry(titleID: "A", name: "Game", target: BuildTarget.ios, inputs: [:], outputDirectory: "/out", engineID: "engine", status: .done)
        func outcome() -> ArtworkOutcomeBadge.Outcome? { BuildQueueCard.outcome(QueueGame(entries: [mac, ios])) }
        XCTAssertEqual(outcome(), .success)
        ios.packagePending = false
        XCTAssertNil(outcome(), "Compiled iOS work is not complete until packaging ends")
        ios.packagePending = nil; ios.status = .failed
        XCTAssertEqual(outcome(), .failure)
        ios.status = .skipped
        XCTAssertEqual(outcome(), .warning)
        ios.status = .queued
        XCTAssertNil(outcome(), "A completed Mac job must not mark the entire game complete")
        mac.status = .failed
        XCTAssertEqual(outcome(), .failure)
    }

    func testBuildRevealClampsJitterAndStartsFreshForANewRun() {
        XCTAssertEqual(BuildProgressRevealMask.target(current: 0.4, reported: 0.39), 0.4)
        XCTAssertEqual(BuildProgressRevealMask.target(current: 0.4, reported: 0.7), 0.7)
        XCTAssertEqual(BuildProgressRevealMask.target(current: 0.7, reported: 1.2), 1)
        XCTAssertEqual(BuildProgressRevealMask.target(current: 0.4, reported: .nan), 0.4)
        XCTAssertEqual(BuildProgressRevealMask.target(current: 0, reported: -0.1), 0)
        XCTAssertEqual(BuildProgressRevealMask.target(current: 0, reported: 0.02), 0.02)
    }

    func testQueueArtworkStackKeepsOneTileFootprintAsQueueShrinks() {
        for size: CGFloat in [64, 96] {
            for count in 1...4 {
                let items = (0..<count).map { QueueArtworkItem(id: "game-\($0)", image: nil) }
                let host = NSHostingView(rootView: QueueArtworkStack(items: items, size: size))
                XCTAssertEqual(host.fittingSize.width, size, accuracy: 0.1, "Queue count must not reserve extra leading space")
                XCTAssertEqual(host.fittingSize.height, size, accuracy: 0.1)
            }
        }
    }

    func testQueueArtworkUpdatesWhenMetadataArrivesWithoutChangingIdentity() throws {
        let window = OffscreenWindow(size: NSSize(width: 120, height: 120))
        let host = NSHostingView(rootView: QueueArtworkStack(items: [.init(id: "current", image: nil)], size: 96))
        window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.orderOut(nil) }
        settle()
        let beforeBitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: beforeBitmap)
        let beforeColor = try XCTUnwrap(beforeBitmap.colorAt(x: beforeBitmap.pixelsWide / 2, y: beforeBitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        XCTAssertLessThan(beforeColor.redComponent - beforeColor.greenComponent, 0.1, "placeholder must not be red before artwork arrives")
        let cs = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: 96, height: 96, bitsPerComponent: 8, bytesPerRow: 96 * 4,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
        let image = NSImage(cgImage: try XCTUnwrap(ctx.makeImage()), size: NSSize(width: 96, height: 96))
        host.rootView = QueueArtworkStack(items: [.init(id: "current", image: image)], size: 96)
        settle()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(color.redComponent, 0.8)
        XCTAssertGreaterThan(color.redComponent - color.greenComponent, 0.5)
    }

    func testDeviceTeamExportAndDriveSelectorsKeepStateAndRunningGuards() throws {
        try withBuilds(height: 1800) { stores, library, focus, pad, _, _ in
            stores.build.target = BuildTarget.ios
            stores.deviceStore.devices = [AppleDevice(id: "fixture-device", name: "Fixture iPad", model: "iPad", os: "27", reachable: true)]
            stores.deviceStore.teams = [SigningTeam(id: "fixture-team", identity: "Fixture Team")]
            settle()
            stores.build.take(picked: library.games[0].inputs["base"]!, kind: .base); settle()
            aim("set.build.install.device.fixture-device", focus); pad.perform(.a); settle()
            XCTAssertEqual(stores.deviceStore.installDevice, "fixture-device")
            aim("set.build.install.team", focus); pad.perform(.a); settle()
            XCTAssertEqual(stores.deviceStore.signingTeam, "fixture-team")
            aim("set.build.install.mode", focus); pad.perform(.a); settle()
            XCTAssertTrue(stores.deviceStore.exportIPA)
            aim("set.build.install.kind.one", focus); pad.perform(.a); settle()
            XCTAssertTrue(stores.deviceStore.exportOneGame)
            stores.build.exportedIPAPath = "/fixture/previous.ipa"
            aim("set.build.install.kind.framework", focus); pad.perform(.a); settle()
            XCTAssertTrue(stores.deviceStore.exportFramework)
            XCTAssertFalse(stores.deviceStore.exportOneGame)
            XCTAssertTrue(stores.build.exportedIPAPath.isEmpty)
            aim("set.build.install.kind.shared", focus); pad.perform(.a); settle()
            XCTAssertFalse(stores.deviceStore.exportOneGame)
            XCTAssertFalse(stores.deviceStore.exportFramework)
            stores.build.exportedIPAPath = "/fixture/export.ipa"
            settle()
            aim("set.build.export.where", focus); pad.perform(.a); settle()
            XCTAssertEqual(stores.deviceStore.sendWhere, SendWhere.drive)
            XCTAssertTrue(focus.frames["main", default: []].contains { $0.id == "set.build.export.folder" })
            XCTAssertFalse(focus.frames["main", default: []].contains { $0.id == "set.build.export.copy" }, "a missing destination cannot start copying")
            stores.build.running = true
            stores.build.send = .copying(done: 10, total: 100)
            settle()
            XCTAssertFalse(focus.frames["main", default: []].contains { $0.id == "set.build.export.where" || $0.id == "set.build.install.mode" })
            XCTAssertTrue(focus.frames["main", default: []].contains { $0.id == "set.build.export.stop" })
        }
    }

    func testBuildOverrideAndStaleFrameworkQuestionsCancelWithoutArmingOrRemoving() throws {
        try withBuilds { stores, _, focus, pad, _, _ in
            stores.build.failure = BuildFailure(kind: .damagedNSP, gameName: "Fixture")
            settle()
            aim("set.build.failure.override", focus); pad.perform(.a); settle(0.5)
            XCTAssertEqual(focus.scope, "buildoverride")
            pad.perform(.r); pad.perform(.x)
            XCTAssertEqual(focus.scope, "buildoverride")
            pad.perform(.b); settle(0.5)
            XCTAssertNil(stores.build.confirmingOverride)
            XCTAssertNil(stores.build.takeOverrideFlag())
            stores.build.failure = nil
            stores.build.staleFrameworks = [.init(titleID: "0100000000000000", name: "Fixture", chain: "old", paths: ["/fixture/must-not-remove.framework"])]
            settle(0.5)
            XCTAssertEqual(focus.scope, "staleframeworks")
            pad.perform(.b); settle(0.5)
            XCTAssertTrue(stores.build.staleFrameworks.isEmpty)
            XCTAssertFalse(stores.build.running)
            XCTAssertEqual(focus.scope, "main")
        }
    }

    func testCompletionShowsOutcomeAndKeepsWorkbenchReachable() throws {
        try withBuilds(height: 1800) { stores, _, focus, _, _, _ in
            let build = stores.build
            build.runningTarget = BuildTarget.mac
            build.macAppPath = "/fixture/Game.app"; build.done = true
            settle()
            func ids() -> Set<String> { Set(focus.frames["main", default: []].map(\.id)) }
            XCTAssertTrue(ids().contains("set.build.done.library"))
            XCTAssertTrue(ids().contains("set.build.done.reveal"))
            XCTAssertTrue(ids().contains("set.build.file.base"))
            build.exportedIPAPath = "/fixture/Game.ipa"; settle()
            XCTAssertTrue(ids().contains("set.build.export.reveal"))
            XCTAssertTrue(ids().contains("set.build.export.where"))
            build.oneGameIPAPath = build.exportedIPAPath; build.done = true; settle()
            XCTAssertFalse(ids().contains("set.build.export.where"))
            build.exportedIPAPath = ""; build.oneGameIPAPath = ""
            build.installedOn = "device"; build.installedAppPath = "/fixture/iOS.app"
            build.archivePath = "/fixture/0100000000000000"; build.installedDataComplete = false
            settle()
            XCTAssertTrue(ids().contains("set.build.done.device"))
            XCTAssertTrue(ids().contains("set.build.export.where"))
            build.installedDataComplete = true; settle()
            XCTAssertTrue(ids().contains("set.build.done.guide"))
            XCTAssertFalse(ids().contains("set.build.export.where"))
        }
    }

    func testCompletedFooterCanBeDismissedOutsideBuildsWithoutClearingTheResult() throws {
        try withBuilds(page: .settings) { stores, _, focus, pad, _, _ in
            stores.build.macAppPath = "/fixture/Game.app"
            stores.build.runningTarget = BuildTarget.mac
            stores.build.done = true; settle()
            XCTAssertTrue(focus.frames["main", default: []].contains { $0.id == "build.activity.dismiss" })
            stores.queue.enqueue([QueueEntry(game: LibraryGame(titleID: "0100000000002000", name: "Next"), engineID: "")]); settle()
            XCTAssertFalse(stores.queue.isAdvancing)
            XCTAssertTrue(focus.frames["main", default: []].contains { $0.id == "build.activity.dismiss" })
            aim("build.activity.dismiss", focus); pad.perform(.a); settle()
            XCTAssertFalse(focus.frames["main", default: []].contains { $0.id == "build.activity" })
            XCTAssertTrue(stores.build.done)
            XCTAssertEqual(stores.build.macAppPath, "/fixture/Game.app")
            stores.build.done = false; stores.build.running = true; settle()
            XCTAssertTrue(focus.frames["main", default: []].contains { $0.id == "build.activity" })
            XCTAssertFalse(focus.frames["main", default: []].contains { $0.id == "build.activity.dismiss" })
        }
    }
}
