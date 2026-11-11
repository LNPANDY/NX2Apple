import XCTest
@testable import NX2Apple
@testable import NXCore

/// The live driver's side of #816 (the play history, the screen after a crash) and #952 (a paused game, Resume, the question before
/// another game starts and before the launcher quits), over a real GameLibrary in a temporary folder with a fake launch call. The
/// distributed notifications are replaced: the test calls what they would call and records what the driver posts.
@MainActor final class ConsoleSessionLiveTests: IsolatedDefaultsTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ConsoleSessionLiveTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: temporary) }

    private func makeApp(_ name: String, titleID: String, in folder: URL) throws -> URL {
        let app = folder.appendingPathComponent(name + ".app")
        let macos = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        for exe in ["nxnative", "dmhost"] { try FileManager.default.createSymbolicLink(at: macos.appendingPathComponent(exe), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true")) }
        let info: [String: Any] = ["DMTitleID": titleID, "CFBundleDisplayName": name, "CFBundleExecutable": "nxnative",
                                   "CFBundleIdentifier": TestPreferences.domain(in: folder, name.lowercased())]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    private struct Harness {
        let driver: LiveConsoleDriver
        let ids: [String]
        var launches: () -> [String]
        var posts: () -> [String]
        var yields: () -> [String?]
        let folder: URL
    }

    private func makeHarness() throws -> Harness {
        let folder = temporary.appendingPathComponent(UUID().uuidString)   // a test may make two
        let library = GameLibrary(file: folder.appendingPathComponent("library.json"))
        _ = try library.addApp(try makeApp("Hades", titleID: "0100000000000001", in: folder))
        _ = try library.addApp(try makeApp("Celeste", titleID: "0100000000000002", in: folder))
        final class Log { var launches: [String] = []; var posts: [String] = []; var yields: [String?] = []; var pid: Int32 = 4000 }
        let log = Log()
        let driver = LiveConsoleDriver(library: library, controls: ControlLayout(defaults: testDefaults), repo: { "" }, lang: { .en },
                                       labels: { L10n.string($0, .en) }, pads: { [] },
                                       launch: { game, _, done in log.pid += 1; log.launches.append(game.name); done(log.pid, nil) },
                                       artwork: { _, _ in nil }, startingTimeout: 0.2, observeSystem: false)
        driver.tracking.post = { log.posts.append($0) }
        driver.tracking.yieldFront = { log.yields.append($0) }
        driver.tracking.exit = { _ in .quit }
        driver.tracking.terminateApp = { log.posts.append("terminate") }
        driver.tracking.sortDefaults = testDefaults
        driver.homeHintDefaults = testDefaults
        driver.isMacOS27 = false
        let ids = ["Hades", "Celeste"].compactMap { name in driver.state.games.first { $0.title == name }?.id }
        XCTAssertEqual(ids.count, 2)
        return Harness(driver: driver, ids: ids, launches: { log.launches }, posts: { log.posts }, yields: { log.yields }, folder: folder)
    }

    /// The launch callback hops to the main queue: wait for it.
    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    func testASessionIsRecordedAndFeedsContinuePlaying() throws {
        let h = try makeHarness()
        let hades = h.ids[0]
        XCTAssertFalse(h.driver.state.homeSections.contains { $0.row == .continuePlaying }, "nothing played yet")
        h.driver.play(hades); settle()
        XCTAssertEqual(h.launches(), ["Hades"])
        XCTAssertEqual(h.driver.sessions["0100000000000001"]?.isOpen, true, "the session starts with the game")
        h.driver.gameDidTerminate(pid: 4001)
        let record = try XCTUnwrap(h.driver.sessions["0100000000000001"])
        XCTAssertFalse(record.isOpen)
        XCTAssertEqual(record.sessions, 1)
        XCTAssertFalse(record.endedUnexpectedly)
        XCTAssertEqual(h.driver.state.homeSections.first?.row, .continuePlaying)
        XCTAssertEqual(h.driver.state.homeSections.first?.gameIDs, [hades])
        XCTAssertNotNil(h.driver.state.games.first { $0.id == hades }?.lastPlayed)
        XCTAssertNil(h.driver.state.presentedSheet, "a normal quit shows nothing")
    }

    func testACrashShowsStoppedUnexpectedlyAndPlayAgain() throws {
        let h = try makeHarness()
        let hades = h.ids[0]
        h.driver.tracking.exit = { _ in .stoppedUnexpectedly }
        let saved = Date(timeIntervalSince1970: 1_800_000_000)
        h.driver.tracking.newestSave = { _ in saved }
        h.driver.play(hades); settle()
        h.driver.gameDidTerminate(pid: 4001)
        XCTAssertEqual(h.driver.state.presentedSheet, .stopped)
        XCTAssertEqual(h.driver.state.stopped, ConsoleStopped(gameID: hades, lastSave: saved))
        XCTAssertEqual(h.driver.sessions["0100000000000001"]?.endedUnexpectedly, true)
        h.driver.play(hades); settle()
        XCTAssertEqual(h.launches(), ["Hades", "Hades"], "Play again starts it again")
        XCTAssertNil(h.driver.state.stopped)
    }

    func testPauseResumeAndTheQuestionBeforeAnotherGame() throws {
        let h = try makeHarness()
        let (hades, celeste) = (h.ids[0], h.ids[1])
        h.driver.play(hades); settle()
        h.driver.gameWindowAppeared()
        h.driver.gamePaused(hostPID: 5001)   // org.nxnative.paused.5001, from the game's host
        XCTAssertEqual(h.driver.state.pausedGameID, hades)
        XCTAssertEqual(h.driver.state.homeSections.first?.gameIDs.first, hades, "its tile leads Continue playing")

        h.driver.play(hades)
        XCTAssertEqual(h.posts(), ["org.nxnative.resume.5001"], "A on the paused game resumes it, to the host's process")
        XCTAssertEqual(h.yields(), [TestPreferences.domain(in: h.folder, "hades")], "and the front is handed to it")
        XCTAssertEqual(h.launches(), ["Hades"], "nothing starts again")
        h.driver.gameResumed(hostPID: 5001)
        XCTAssertNil(h.driver.state.pausedGameID)

        h.driver.gamePaused(hostPID: 5001)
        h.driver.play(celeste)
        XCTAssertEqual(h.driver.state.presentedSheet, .confirmQuitPaused, "another game asks first")
        h.driver.back()
        XCTAssertEqual(h.driver.state.pausedGameID, hades, "Cancel keeps it paused")
        XCTAssertEqual(h.launches(), ["Hades"])

        h.driver.play(celeste)
        h.driver.quitPausedGame()
        XCTAssertEqual(h.posts().last, "org.nxnative.quit.5001", "Quit asks the game to quit as ⌘Q does")
        XCTAssertEqual(h.launches(), ["Hades"], "the other game waits for the exit")
        h.driver.gameDidTerminate(pid: 4001)
        settle()
        XCTAssertEqual(h.launches(), ["Hades", "Celeste"], "then it starts")
        XCTAssertNil(h.driver.state.pausedGameID)
    }

    func testAGameThatDoesNotQuitStaysPaused() throws {
        let h = try makeHarness()
        h.driver.tracking.quitTimeoutSeconds = 0.05
        h.driver.play(h.ids[0]); settle()
        h.driver.gamePaused(hostPID: 5001)
        h.driver.play(h.ids[1])
        h.driver.quitPausedGame()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(h.driver.state.pausedGameID, h.ids[0])
        XCTAssertFalse(h.driver.state.quittingPaused)
        XCTAssertNil(h.driver.state.presentedSheet)
        XCTAssertEqual(h.driver.state.toast?.message, "Hades did not quit. It stays paused.")
        XCTAssertEqual(h.launches(), ["Hades"])
    }

    func testLeavingConsoleModeAndQuittingTheLauncherAskFirst() throws {
        let h = try makeHarness()
        h.driver.play(h.ids[0]); settle()
        h.driver.gamePaused(hostPID: 5001)
        h.driver.openOnDesktop(h.ids[1])
        XCTAssertEqual(h.driver.state.presentedSheet, .confirmQuitPaused)
        XCTAssertFalse(h.driver.state.exited, "not before the answer")
        h.driver.back()
        XCTAssertTrue(h.driver.shouldDeferTermination(consoleShown: true), "the launcher's quit waits for the answer")
        XCTAssertEqual(h.driver.state.afterQuit, .terminate)
        h.driver.quitPausedGame()
        h.driver.gameDidTerminate(pid: 4001)
        XCTAssertEqual(h.posts(), ["org.nxnative.quit.5001", "terminate"], "the launcher quits once the game has")

        let other = try makeHarness()
        XCTAssertFalse(other.driver.shouldDeferTermination(consoleShown: true), "no paused game: the launcher quits at once")
        other.driver.play(other.ids[0]); settle()
        other.driver.gamePaused(hostPID: 6001)
        XCTAssertFalse(other.driver.shouldDeferTermination(consoleShown: false), "out of console mode nothing can ask")
        XCTAssertEqual(other.posts(), ["org.nxnative.quit.6001"], "the game is asked to quit with the launcher")
    }

    func testAllGamesOrderFollowsTheDesktopsSortAndTheSearch() throws {
        let h = try makeHarness()
        h.driver.openMenu(); h.driver.openAllGames()
        XCTAssertEqual(h.driver.state.librarySort, .recent)
        h.driver.toggleLibrarySort()
        XCTAssertEqual(LibrarySort.load(testDefaults), .name, "the desktop's own setting")
        XCTAssertEqual(h.driver.state.libraryGames.map(\.title), ["Celeste", "Hades"])
        h.driver.back(); h.driver.back()
        h.driver.openSearch()
        for key in ["h", "a"] { h.driver.typeSearch(key) }
        XCTAssertEqual(h.driver.state.searchGames.map(\.title), ["Hades"])
        h.driver.deleteSearch(); h.driver.deleteSearch()
        XCTAssertEqual(h.driver.state.searchResults, [])
        h.driver.typeSearch("0100000000000002")
        XCTAssertEqual(h.driver.state.searchGames.map(\.title), ["Celeste"], "the title ID")
    }

    func testBuildsPageRowsFromTheStoreAndQueue() {
        let stages = [Stage(id: 1, name: "Read", state: .done), Stage(id: 2, name: "Translate", state: .running, percent: 40)]
        let queue = [QueueEntry(titleID: "A", name: "Hades", target: "mac", inputs: [:], outputDirectory: "/o", engineID: "e"),
                     QueueEntry(titleID: "B", name: "Celeste", target: "mac", inputs: [:], outputDirectory: "/o", engineID: "e", status: .done)]
        let builds = LiveConsoleDriver.builds(running: true, stopping: false, title: "Building", stages: stages, queue: queue)
        XCTAssertEqual(builds.stages.map(\.progress), [nil, 0.4], "the stage's own share")
        XCTAssertEqual(builds.queue.map(\.name), ["Hades"], "the queue's waiting games, not the earlier results")
        XCTAssertEqual(builds.queue.first?.statusKey, "queue.status.queued")
        XCTAssertEqual(LiveConsoleDriver.builds(running: false, stopping: false, title: "", stages: stages, queue: []).stages, [], "no build, no stages")
        var state = ConsoleState()
        state.askStopBuild()
        XCTAssertNil(state.presentedSheet, "nothing runs: nothing to stop")
        state.builds = builds
        state.openBuilds(); state.askStopBuild()
        XCTAssertEqual(state.presentedSheet, .confirmStopBuild)
        XCTAssertTrue(ConsoleSheet.confirmStopBuild.isQuestion)
    }

    func testDelayedDmhostSpawnBeyondInitialPollsIsCapturedAndResumed() throws {
        let defaultIntervals = ConsoleGameTracking().lookupIntervals
        XCTAssertGreaterThan(defaultIntervals.count, 5)
        XCTAssertGreaterThanOrEqual(defaultIntervals.reduce(0, +), 300)

        let h = try makeHarness()
        let hades = h.ids[0]
        var polls = 0
        h.driver.tracking.runsChildLookup = true
        h.driver.tracking.lookupIntervals = Array(repeating: 0.01, count: 12)
        h.driver.tracking.isProcessAlive = { _ in true }
        h.driver.tracking.children = { _ in
            polls += 1
            return polls >= 8 ? [5099] : []
        }

        h.driver.play(hades)
        let deadline = Date().addingTimeInterval(3.0)
        while h.driver.tracking.hostPID == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(polls, 8)
        XCTAssertTrue(h.driver.tracking.observedPIDs.contains(5099))
        XCTAssertEqual(h.driver.tracking.hostPID, 5099)
        XCTAssertNil(h.driver.tracking.lookup)
    }

    func testChildLookupStopsImmediatelyWhenOuterGameProcessExitsOrSessionEnds() throws {
        let h = try makeHarness()
        let hades = h.ids[0]
        var polls = 0
        h.driver.tracking.runsChildLookup = true
        h.driver.tracking.lookupIntervals = Array(repeating: 0.01, count: 100)
        h.driver.tracking.children = { _ in
            polls += 1
            return []
        }
        h.driver.tracking.isProcessAlive = { _ in
            polls < 2
        }

        h.driver.play(hades)
        let deadline = Date().addingTimeInterval(2.0)
        while (polls == 0 || h.driver.tracking.lookup != nil) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertEqual(polls, 2)
        XCTAssertNil(h.driver.tracking.lookup)

        let second = try makeHarness()
        second.driver.tracking.runsChildLookup = true
        second.driver.tracking.lookupIntervals = [5.0, 5.0]
        second.driver.tracking.isProcessAlive = { _ in true }
        second.driver.tracking.children = { _ in [] }
        second.driver.play(second.ids[0])
        settle()
        XCTAssertNotNil(second.driver.tracking.lookup)
        second.driver.gameDidTerminate(pid: 4001)
        XCTAssertNil(second.driver.tracking.lookup)
    }
}
