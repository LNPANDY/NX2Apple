import XCTest
import NXCore
@testable import NXModel

/// The one persistent build queue (LNPANDY/NX2Apple#943, #997).
@MainActor final class BuildQueueStoreTests: XCTestCase {
    private var dir: URL!
    private var file: URL { dir.appendingPathComponent("queue.json") }
    private var started: [String] = []
    private var startedTargets: [String] = []
    private var busy = false
    private var engine = "release-1"
    private var refuse: Set<String> = []
    private var packaged: [[String]] = []

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("queue-" + UUID().uuidString)
        started = []; startedTargets = []; busy = false; engine = "release-1"; refuse = []; packaged = []
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func store(file: URL? = nil) -> BuildQueueStore {
        BuildQueueStore(file: file ?? self.file, engineID: { [unowned self] in engine }, busy: { [unowned self] in busy },
                        start: { [unowned self] in
                            if refuse.contains($0.titleID) { return "refused" }
                            started.append($0.titleID); startedTargets.append($0.target); busy = true; return nil
                        },
                        packageBatch: { [unowned self] in packaged.append($0.map(\.titleID)); busy = true; return true },
                        engineChangedReason: { "engine changed" })
    }

    private func entry(_ id: String, target: String = BuildTarget.mac, batch: UUID = UUID(), package: Bool = false, engine: String? = nil) -> QueueEntry {
        QueueEntry(titleID: id, name: "Game " + id, target: target, inputs: ["base": ["/g/\(id).nsp"]],
                   outputDirectory: "/out", engineID: engine ?? "release-1", batch: batch, packageAfter: package)
    }

    func testEnqueueWaitsForStartAndSurvivesARestartUnstarted() {
        let q = store()
        q.enqueue([entry("A", target: BuildTarget.ios), entry("B", target: BuildTarget.ios)])
        XCTAssertEqual(started, [], "adding games waits for Start build")
        XCTAssertEqual(q.entries.map(\.status), [.queued, .queued])

        let again = store()
        XCTAssertFalse(again.awaitingResume, "an unstarted queue was not interrupted mid-build")
        XCTAssertFalse(again.paused)
        again.processNext()
        XCTAssertEqual(started, [], "background ticks do not start a waiting queue on their own")

        again.start(packageAfter: true)
        XCTAssertEqual(started, ["A"])
        XCTAssertEqual(again.entries.map(\.target), [BuildTarget.ios, BuildTarget.ios])
        XCTAssertEqual(again.entries.map(\.packageAfter), [true, true])
        XCTAssertEqual(Set(again.entries.map(\.batch)).count, 1)
    }

    func testAppendingWhileRunningKeepsItsChosenTargetAndPackaging() {
        let q = store()
        q.enqueue([entry("A", target: BuildTarget.ios)])
        q.start(packageAfter: true)
        XCTAssertEqual(started, ["A"])
        q.enqueue([entry("B")])   // added with default Mac/false while the iOS batch runs
        XCTAssertEqual(q.entries[1].target, BuildTarget.mac)
        XCTAssertFalse(q.entries[1].packageAfter)
        XCTAssertNotEqual(q.entries[1].batch, q.entries[0].batch)
        busy = false; q.buildEnded(succeeded: true)
        busy = false; q.packageEnded(succeeded: true)
        busy = false; q.buildEnded(succeeded: true)
        XCTAssertEqual(packaged, [["A"]])
    }

    func testEntriesBuildOneAfterTheOtherInOrder() {
        let q = store()
        q.enqueue([entry("A"), entry("B"), entry("C")])
        XCTAssertFalse(q.active)
        q.start()
        XCTAssertTrue(q.active)
        XCTAssertEqual(started, ["A"])
        busy = false; q.buildEnded(succeeded: true)
        XCTAssertEqual(started, ["A", "B"])
        XCTAssertTrue(q.active, "presentation must stay mounted between games")
        busy = false; q.buildEnded(succeeded: false, reason: "no keys")
        XCTAssertEqual(started, ["A", "B", "C"])
        busy = false; q.buildEnded(succeeded: true)
        XCTAssertFalse(q.active)
        XCTAssertEqual(q.entries.map(\.status), [.done, .failed, .done])
        XCTAssertEqual(q.entries[1].reason, "no keys")
    }

    func testNothingStartsWhileAnotherOperationRuns() {
        busy = true
        let q = store()
        q.enqueue([entry("A")])
        q.start()
        XCTAssertEqual(started, [])
        busy = false; q.processNext()
        XCTAssertEqual(started, ["A"])
    }

    func testMoveControlsStopAtTheBoundariesAndLeaveTheRunningEntryAlone() {
        let q = store()
        q.enqueue([entry("A"), entry("B"), entry("C")])
        q.start()   // A runs
        let b = q.entries[1].id, c = q.entries[2].id, a = q.entries[0].id
        XCTAssertFalse(q.canMoveUp(b)); XCTAssertTrue(q.canMoveDown(b))
        XCTAssertFalse(q.canMoveDown(c)); XCTAssertTrue(q.canMoveUp(c))
        XCTAssertFalse(q.canMoveUp(a)); XCTAssertFalse(q.canMoveDown(a))
        q.moveUp(c)
        XCTAssertEqual(q.entries.map(\.titleID), ["A", "C", "B"])
        q.moveUp(c)   // already first of the waiting ones
        XCTAssertEqual(q.entries.map(\.titleID), ["A", "C", "B"])
        q.remove(a)   // the running one cannot be removed
        XCTAssertEqual(q.entries.count, 3)
        q.remove(b)
        XCTAssertEqual(q.entries.map(\.titleID), ["A", "C"])
    }

    func testDragInsertionPreservesPairsAndRunningSlotsAndPersists() {
        let q = store()
        q.enqueue([entry("A"), entry("B"), entry("B", target: BuildTarget.ios), entry("C"), entry("D")])
        let ids = Dictionary(uniqueKeysWithValues: q.games.map { ($0.titleID, $0.id) })
        q.move(ids["A"]!, relativeTo: ids["C"]!, after: true)
        XCTAssertEqual(q.entries.map(\.titleID), ["B", "B", "C", "A", "D"])
        XCTAssertEqual(q.entries.prefix(2).map(\.target), [BuildTarget.mac, BuildTarget.ios])
        XCTAssertEqual(store().entries.map(\.titleID), q.entries.map(\.titleID))
        q.start()
        q.move(ids["D"]!, relativeTo: ids["C"]!, after: false)
        XCTAssertEqual(q.entries.map(\.titleID), ["B", "B", "D", "C", "A"])
        q.move(ids["B"]!, relativeTo: ids["A"]!, after: true)
        q.move(ids["A"]!, relativeTo: ids["B"]!, after: false)
        q.move(UUID(), relativeTo: ids["A"]!, after: false)
        q.move(ids["A"]!, relativeTo: ids["A"]!, after: true)
        XCTAssertEqual(q.entries.map(\.titleID), ["B", "B", "D", "C", "A"])
        XCTAssertEqual(q.running?.titleID, "B")
        busy = false; q.buildEnded(succeeded: true)
        busy = false; q.buildEnded(succeeded: true)
        q.move(ids["A"]!, relativeTo: ids["C"]!, after: false)
        XCTAssertEqual(q.entries.map(\.titleID), ["B", "B", "D", "A", "C"])
        XCTAssertEqual(q.running?.titleID, "D", "completed and running rows keep their slots")
    }

    func testDragRejectsSourceThatStartedOrWasRemovedDuringTheDrag() {
        let q = store()
        q.enqueue([entry("A"), entry("B"), entry("C")])
        let a = q.games[0].id, b = q.games[1].id, c = q.games[2].id
        q.start()
        q.move(a, relativeTo: c, after: true)
        q.remove(b)
        q.move(b, relativeTo: c, after: true)
        XCTAssertEqual(q.entries.map(\.titleID), ["A", "C"])
        XCTAssertEqual(q.running?.id, a)
    }

    func testCancelQueuedKeepsTheRunningEntryAndTheResults() {
        let q = store()
        q.enqueue([entry("A"), entry("B"), entry("C")])
        q.start()
        q.cancelQueued()
        XCTAssertEqual(q.entries.map(\.titleID), ["A"])
        busy = false; q.buildEnded(succeeded: true)
        XCTAssertEqual(started, ["A"])
        XCTAssertEqual(q.entries.map(\.status), [.done])
    }

    func testStopEndsTheRunningBuildAndPausesTheQueueUntilResume() {
        let q = store()
        q.enqueue([entry("A"), entry("B")])
        q.start()
        busy = false; q.buildEnded(succeeded: false, stopped: true)
        XCTAssertTrue(q.paused)
        XCTAssertEqual(q.entries[0].status, .stopped)
        XCTAssertNil(q.entries[0].reason)
        XCTAssertEqual(started, ["A"], "the next game does not start")
        q.enqueue([entry("C")])
        XCTAssertEqual(started, ["A"], "nor does a game added meanwhile")
        q.resume()
        XCTAssertFalse(q.paused)
        XCTAssertEqual(started, ["A", "B"])
    }

    func testStoppedAndFailedEntriesCanRetryRemoveOrClearFinished() {
        let q = store()
        q.enqueue([entry("A"), entry("B"), entry("C")])
        q.start()
        busy = false; q.buildEnded(succeeded: true)                          // A -> .done
        busy = false; q.buildEnded(succeeded: false, reason: "missing key")  // B -> .failed
        busy = false; q.buildEnded(succeeded: false, stopped: true)          // C -> .stopped
        XCTAssertEqual(q.entries.map(\.status), [.done, .failed, .stopped])
        XCTAssertTrue(q.hasFinished)

        // Stopped status persists across reload without masquerading as failed.
        let reloaded = store()
        XCTAssertEqual(reloaded.entries.map(\.status), [.done, .failed, .stopped])
        XCTAssertNil(reloaded.entries[2].reason)

        // Retry failed B under a new engine refreshes engineID and queues at the end.
        engine = "release-2"
        let bID = reloaded.entries[1].id
        let cID = reloaded.entries[2].id
        let originalIDs = reloaded.entries.map(\.id)
        reloaded.retry(bID)
        XCTAssertEqual(reloaded.entries.map(\.id), originalIDs, "group retry preserves queue order")
        let retried = reloaded.entries.first { $0.id == bID }
        XCTAssertEqual(retried?.status, .queued)
        XCTAssertEqual(retried?.engineID, "release-2")
        XCTAssertNil(retried?.reason)

        // Remove individual stopped entry C while keeping done A and queued B.
        reloaded.remove(cID)
        XCTAssertEqual(reloaded.entries.map(\.titleID), ["A", "B"])

        // clearFinished drops finished entries only and keeps queued/running items.
        reloaded.clearFinished()
        XCTAssertEqual(reloaded.entries.map(\.titleID), ["B"])
        XCTAssertEqual(reloaded.entries.map(\.status), [.queued])
        XCTAssertFalse(reloaded.hasFinished)
    }

    func testRetryingStoppedIOSKeepsMacSuccessAndRefreshesTheEngine() {
        let q = store()
        q.enqueue([entry("A"), entry("A", target: BuildTarget.ios)])
        q.start()
        busy = false; q.buildEnded(succeeded: true)
        busy = false; q.buildEnded(succeeded: false, stopped: true)
        XCTAssertEqual(q.entries.map(\.status), [.done, .stopped])
        XCTAssertTrue(q.games[0].retryable)

        engine = "release-2"
        q.retry(q.games[0].id)
        XCTAssertEqual(q.entries.map(\.status), [.done, .queued])
        XCTAssertEqual(q.entries[1].engineID, "release-2")
        XCTAssertEqual(q.entries[1].target, BuildTarget.ios)
        q.start()
        XCTAssertEqual(startedTargets, [BuildTarget.mac, BuildTarget.ios, BuildTarget.ios])
        XCTAssertEqual(q.entries.map(\.status), [.done, .running])
    }

    func testClearFinishedKeepsAPlatformPairUntilEveryJobSettles() {
        let q = store()
        q.enqueue([entry("A"), entry("A", target: BuildTarget.ios), entry("B")])
        q.start()
        busy = false; q.buildEnded(succeeded: true) // A Mac done, A iOS starts

        XCTAssertFalse(q.hasFinished)
        q.clearFinished()
        XCTAssertEqual(q.entries.map(\.status), [.done, .running, .queued])

        busy = false; q.buildEnded(succeeded: false, reason: "iOS failed")
        XCTAssertTrue(q.hasFinished)
        q.clearFinished()
        XCTAssertEqual(q.entries.map(\.titleID), ["B"])
        XCTAssertEqual(q.entries.first?.status, .running)
    }

    func testFastRefreshQueueSnapshotSurvivesRestart() {
        var fast = entry("REFRESH", target: BuildTarget.ios)
        fast.fastRefresh = true
        fast.locksTarget = true
        fast.existingAppPath = "/Applications/Game.app"
        fast.externalImgPath = "/Volumes/USB/Game.img"
        let q = store()
        q.enqueue([fast])

        let restored = store()
        XCTAssertEqual(restored.entries.first?.target, BuildTarget.ios)
        XCTAssertTrue(restored.entries.first?.fastRefresh == true)
        XCTAssertTrue(restored.entries.first?.locksTarget == true)
        XCTAssertEqual(restored.entries.first?.existingAppPath, "/Applications/Game.app")
        XCTAssertEqual(restored.entries.first?.externalImgPath, "/Volumes/USB/Game.img")
    }

    func testAPausedQueueIsStillPausedAfterARestartAndStartsNothing() {
        let q = store()
        q.enqueue([entry("A"), entry("B")])
        q.start()
        busy = false; q.buildEnded(succeeded: false, reason: "Stopped", stopped: true)
        started = []
        let again = store()
        XCTAssertTrue(again.paused)
        XCTAssertFalse(again.awaitingResume)
        again.processNext()
        XCTAssertEqual(started, [])
        again.cancelQueued()
        XCTAssertFalse(again.paused)
    }

    func testAFailureThatIsNotAStopKeepsTheQueueGoing() {
        let q = store()
        q.enqueue([entry("A"), entry("B")])
        q.start()
        busy = false; q.buildEnded(succeeded: false, reason: "no keys")
        XCTAssertFalse(q.paused)
        XCTAssertEqual(started, ["A", "B"])
    }

    func testQueueSurvivesARestartAndAsksBeforeStartingAgain() {
        let q = store()
        q.enqueue([entry("A"), entry("B")])
        q.start()   // A running, B waiting, then the app quits
        started = []; startedTargets = []; busy = false
        let again = store()
        XCTAssertTrue(again.awaitingResume)
        XCTAssertEqual(again.entries.map(\.status), [.queued, .queued], "the build that was interrupted goes first again")
        again.processNext()
        XCTAssertEqual(started, [], "nothing starts before the player confirms")
        again.resume()
        XCTAssertEqual(started, ["A"])
    }

    func testEntryBuiltUnderAnotherEngineIsSkippedWithItsReasonNotRebuiltWithTheNewOne() {
        let q = store()
        q.enqueue([entry("A", engine: "release-1")])
        q.start()
        busy = false; q.buildEnded(succeeded: true)
        q.enqueue([entry("B", engine: "release-1"), entry("C", engine: "release-2")])
        q.start()
        engine = "release-2"; busy = false
        q.buildEnded(succeeded: true)   // B was running under release-1 when the engine changed
        XCTAssertEqual(q.entries.first { $0.titleID == "C" }?.status, .running)
        XCTAssertEqual(started, ["A", "B", "C"].filter { started.contains($0) })
        q.cancelQueued()
        engine = "release-3"
        busy = false; q.buildEnded(succeeded: true)
        q.enqueue([entry("D", engine: "release-2")])
        q.start()
        XCTAssertEqual(q.entries.first { $0.titleID == "D" }?.status, .skipped)
        XCTAssertEqual(q.entries.first { $0.titleID == "D" }?.reason, "engine changed")
    }

    func testAnEntryThatCannotStartIsSkippedAndTheNextOneTries() {
        refuse = ["A"]
        let q = store()
        q.enqueue([entry("A"), entry("B")])
        q.start()
        XCTAssertEqual(q.entries.map(\.status), [.skipped, .running])
        XCTAssertEqual(q.entries[0].reason, "refused")
    }

    func testASharedAppBatchIsPackagedOnceWithTheSuccessfulGamesOnly() {
        let batch = UUID()
        let q = store()
        q.enqueue([entry("A", target: BuildTarget.ios, batch: batch, package: true), entry("B", target: BuildTarget.ios, batch: batch, package: true), entry("C", target: BuildTarget.ios, batch: batch, package: true)])
        q.start()
        busy = false; q.buildEnded(succeeded: true)
        busy = false; q.buildEnded(succeeded: false, reason: "failed")
        XCTAssertEqual(packaged, [])
        busy = false; q.buildEnded(succeeded: true)
        XCTAssertEqual(packaged, [["A", "C"]])
    }

    func testDuplicateWaitingJobsMergeAndNewGamesPreserveTheResults() {
        let q = store()
        q.enqueue([entry("A"), entry("B")])
        q.enqueue([entry("B")])
        XCTAssertEqual(q.entries.count, 2)
        q.start()
        busy = false; q.buildEnded(succeeded: true)
        busy = false; q.buildEnded(succeeded: true)
        q.enqueue([entry("C")])
        XCTAssertEqual(q.entries.map(\.titleID), ["A", "B", "C"])
        XCTAssertEqual(q.entries.map(\.status), [.done, .done, .queued])
    }

    func testBothMergesDuplicatesMovesAsOneGameAndRunsMacThenIOS() {
        let q = store()
        q.enqueue([entry("A", target: BuildTarget.ios), entry("B")])
        q.enqueue([entry("A"), entry("a")])
        XCTAssertEqual(q.entries.count, 3)
        XCTAssertEqual(q.games.count, 2)
        XCTAssertTrue(q.games[0].both)
        XCTAssertEqual(q.games[0].entries.map(\.target), [BuildTarget.mac, BuildTarget.ios])
        q.moveDown(q.games[0].id)
        XCTAssertEqual(q.entries.map(\.titleID), ["B", "A", "A"])
        q.moveUp(q.games[1].id)
        q.start()
        busy = false; q.buildEnded(succeeded: true)
        busy = false; q.buildEnded(succeeded: true)
        busy = false; q.buildEnded(succeeded: true)
        XCTAssertEqual(started, ["A", "A", "B"])
        XCTAssertEqual(startedTargets, [BuildTarget.mac, BuildTarget.ios, BuildTarget.mac])
    }

    func testPartialFailureSurvivesRestartAndRetryDoesNotRepeatMac() {
        let q = store()
        q.enqueue([entry("A"), entry("A", target: BuildTarget.ios)])
        q.start()
        busy = false; q.buildEnded(succeeded: true)
        busy = false; q.buildEnded(succeeded: false, reason: "ios failed")
        let again = store()
        XCTAssertEqual(again.games.count, 1)
        XCTAssertEqual(again.entries.map(\.status), [.done, .failed])
        again.retry(again.games[0].id)
        again.start()
        XCTAssertEqual(again.entries.map(\.status), [.done, .running])
        busy = false; again.buildEnded(succeeded: true)
        XCTAssertEqual(startedTargets, [BuildTarget.mac, BuildTarget.ios, BuildTarget.ios])
        XCTAssertEqual(again.entries.map(\.status), [.done, .done])
    }

    func testSharedPackagingFailurePreservesMacAndRetriesIOSOnly() {
        let q = store()
        q.enqueue([entry("A"), entry("A", target: BuildTarget.ios)])
        q.start(packageAfter: true, exportIPA: true)
        busy = false; q.buildEnded(succeeded: true)
        busy = false; q.buildEnded(succeeded: true)
        XCTAssertEqual(q.packaging.map(\.target), [BuildTarget.ios])
        XCTAssertTrue(q.games[0].running)
        busy = false; q.packageEnded(succeeded: false, reason: "signing failed")
        XCTAssertEqual(q.entries.map(\.status), [.done, .failed])
        q.retry(q.games[0].id)
        q.start(packageAfter: true, exportIPA: true)
        busy = false; q.buildEnded(succeeded: true)
        busy = false; q.packageEnded(succeeded: true)
        XCTAssertEqual(q.entries.map(\.status), [.done, .done])
        XCTAssertEqual(startedTargets.filter { $0 == BuildTarget.mac }.count, 1)
    }

    func testInterruptedPackagingIsRetryableWithoutLosingMacResult() {
        let q = store()
        q.enqueue([entry("A"), entry("A", target: BuildTarget.ios)])
        q.start(packageAfter: true, exportIPA: true)
        busy = false; q.buildEnded(succeeded: true)
        busy = false; q.buildEnded(succeeded: true)
        let restored = store()
        XCTAssertEqual(restored.entries.map(\.status), [.done, .queued])
        XCTAssertTrue(restored.awaitingResume)
        XCTAssertTrue(restored.packaging.isEmpty)
    }

    func testAddingMissingPlatformDuringMacBuildRunsItNext() {
        let q = store()
        q.enqueue([entry("A"), entry("B")]); q.start()
        q.enqueue([entry("A", target: BuildTarget.ios), entry("A", target: BuildTarget.ios)])
        XCTAssertEqual(q.entries.count, 3)
        XCTAssertFalse(q.canMoveDown(q.games[0].id))
        busy = false; q.buildEnded(succeeded: true)
        XCTAssertEqual(started, ["A", "A"])
        XCTAssertEqual(startedTargets, [BuildTarget.mac, BuildTarget.ios])
    }

    func testRetryingEarlierGameDoesNotInterruptTheCurrentBothPair() {
        let q = store()
        q.enqueue([entry("A"), entry("A", target: BuildTarget.ios), entry("B"), entry("B", target: BuildTarget.ios)])
        let a = q.games[0].id
        q.start()
        busy = false; q.buildEnded(succeeded: true)
        busy = false; q.buildEnded(succeeded: false, reason: "failure")
        XCTAssertEqual(q.running?.titleID, "B")
        q.retry(a)
        busy = false; q.buildEnded(succeeded: true)
        XCTAssertEqual(q.running?.titleID, "B")
        XCTAssertEqual(q.running?.target, BuildTarget.ios)
        busy = false; q.buildEnded(succeeded: true)
        XCTAssertEqual(q.running?.titleID, "A")
        XCTAssertEqual(q.running?.target, BuildTarget.ios)
    }

    func testStoppingTheFinalJobPackagesSuccessfulGamesAndKeepsTheirResults() {
        let batch = UUID(), q = store()
        q.enqueue([entry("A", target: BuildTarget.ios, batch: batch), entry("B", batch: batch)])
        q.start(packageAfter: true, exportIPA: true)
        busy = false; q.buildEnded(succeeded: true)
        busy = false; q.buildEnded(succeeded: false, reason: "Stopped", stopped: true)
        XCTAssertEqual(packaged, [["A"]])
        XCTAssertEqual(q.entries.map(\.status), [.done, .stopped])
        XCTAssertEqual(q.packaging.map(\.titleID), ["A"])
        busy = false; q.packageEnded(succeeded: true)
        XCTAssertEqual(q.entries.map(\.status), [.done, .stopped])
        XCTAssertTrue(q.entries.allSatisfy { $0.packagePending == nil })
    }

    func testStoppingMidBatchPackagesOnlySuccessfulGamesAndResumeDoesNotReuseThem() {
        let batch = UUID(), q = store()
        q.enqueue(["A", "B", "C", "D"].map { entry($0, target: BuildTarget.ios, batch: batch) })
        q.start(packageAfter: true, exportIPA: true)
        busy = false; q.buildEnded(succeeded: true)
        busy = false; q.buildEnded(succeeded: true)
        busy = false; q.buildEnded(succeeded: false, stopped: true)
        XCTAssertEqual(packaged, [["A", "B"]])
        XCTAssertTrue(q.paused)
        busy = false; q.packageEnded(succeeded: true)
        XCTAssertEqual(q.entries.map(\.status), [.done, .done, .stopped, .queued])
        q.resume()
        busy = false; q.buildEnded(succeeded: true)
        XCTAssertEqual(packaged, [["A", "B"], ["D"]])
    }

    func testCancellingAnIdleBatchPackagesItsBuiltGamesInsteadOfFailingThem() {
        let batch = UUID(), q = store()
        q.enqueue(["A", "B", "C"].map { entry($0, target: BuildTarget.ios, batch: batch) })
        q.start(packageAfter: true, exportIPA: true)
        busy = true; q.buildEnded(succeeded: true)   // another operation runs, so B does not start
        XCTAssertNil(q.running)
        XCTAssertEqual(q.entries.map(\.packagePending), [false, nil, nil])
        busy = false; q.cancelQueued()
        XCTAssertEqual(packaged, [["A"]], "the built game is packaged now, as the build store's deferred list would package it")
        XCTAssertEqual(q.entries.map(\.titleID), ["A"])
        XCTAssertEqual(q.entries[0].status, .done)
        XCTAssertNil(q.entries[0].reason)
        XCTAssertEqual(q.packaging.map(\.titleID), ["A"])
        XCTAssertFalse(q.active)
        busy = false; q.packageEnded(succeeded: true)
        XCTAssertEqual(q.entries.map(\.status), [.done])
        XCTAssertTrue(q.entries.allSatisfy { $0.packagePending == nil })
    }

    func testBuiltButUnpackagedGamesRecoverAsWaitingAfterRestart() {
        let batch = UUID(), q = store()
        q.enqueue(["A", "B"].map { entry($0, target: BuildTarget.ios, batch: batch) })
        q.start(packageAfter: true, exportIPA: true)
        busy = false; q.buildEnded(succeeded: true)
        XCTAssertEqual(q.entries[0].packagePending, false)
        busy = false
        let restored = store()
        XCTAssertEqual(restored.entries.map(\.status), [.queued, .queued])
        XCTAssertTrue(restored.awaitingResume)
    }

    func testMissingDeferredPayloadKeepsAnExplicitPackagingFailureReason() {
        let q = BuildQueueStore(file: nil, engineID: { "release-1" }, busy: { false }, start: { _ in nil },
            packageBatch: { _ in false }, packageFailureReason: { "No deferred game payload" })
        q.enqueue([entry("A", target: BuildTarget.ios, package: true)])
        q.start(); q.buildEnded(succeeded: true)
        XCTAssertEqual(q.entries[0].status, .failed)
        XCTAssertEqual(q.entries[0].reason, "No deferred game payload")
        XCTAssertTrue(q.games[0].retryable)
    }

    func testInputSummaryNamesTheRowsThatHaveFiles() {
        var e = entry("A")
        e.inputs = ["base": ["/a"], "update": ["/u"], "dlc": ["/d1", "/d2"], "keys": ["/k"]]
        XCTAssertEqual(e.inputSummary { $0 }, "data.base, data.update, 2 × data.dlc")
        e.gameFolder = "/folder"
        XCTAssertEqual(e.inputSummary { $0 }, "queue.inputFolder")

        var fastEntry = entry("F")
        fastEntry.fastRefresh = true
        XCTAssertEqual(fastEntry.inputSummary { $0 }, "queue.fastRefreshSummary")
    }

    func testDeduplicationByTitleAndTargetAllowsMacAndIOSCoexistence() {
        let q = store()
        let batch = UUID()
        let macA = QueueEntry(
            titleID: "0100152000022000",
            name: "Game A",
            target: BuildTarget.mac,
            inputs: [:],
            outputDirectory: "/out",
            engineID: "release-1",
            batch: batch,
            packageAfter: false,
            fastRefresh: true,
            locksTarget: true
        )
        let iosA = QueueEntry(
            titleID: "0100152000022000",
            name: "Game A",
            target: BuildTarget.ios,
            inputs: [:],
            outputDirectory: "/out",
            engineID: "release-1",
            batch: batch,
            packageAfter: true,
            fastRefresh: true,
            locksTarget: true
        )
        let duplicateMacA = QueueEntry(
            titleID: "0100152000022000",
            name: "Game A",
            target: BuildTarget.mac,
            inputs: [:],
            outputDirectory: "/out",
            engineID: "release-1",
            batch: batch,
            packageAfter: false,
            fastRefresh: false,
            locksTarget: true
        )

        q.enqueue([macA, iosA, duplicateMacA])
        XCTAssertEqual(q.entries.count, 2)
        XCTAssertEqual(q.entries.map(\.target), [BuildTarget.mac, BuildTarget.ios])
    }

    func testLockedTargetMixedBatchPreservesTargetsAndPackagesOnlyIOSOnce() {
        var startedTargets: [(String, String, Bool)] = []
        var packagedEntries: [[QueueEntry]] = []
        let q = BuildQueueStore(
            file: file,
            engineID: { [unowned self] in engine },
            busy: { [unowned self] in busy },
            start: { [unowned self] item in
                startedTargets.append((item.titleID, item.target, item.fastRefresh))
                busy = true
                return nil
            },
            packageBatch: { entries in
                packagedEntries.append(entries)
                return true
            },
            engineChangedReason: { "engine changed" }
        )

        let batch = UUID()
        let macFast = QueueEntry(
            titleID: "A",
            name: "Game A",
            target: BuildTarget.mac,
            inputs: [:],
            outputDirectory: "/out",
            engineID: "release-1",
            batch: batch,
            packageAfter: false,
            fastRefresh: true,
            locksTarget: true
        )
        let iosFast = QueueEntry(
            titleID: "A",
            name: "Game A",
            target: BuildTarget.ios,
            inputs: [:],
            outputDirectory: "/out",
            engineID: "release-1",
            batch: batch,
            packageAfter: true,
            fastRefresh: true,
            locksTarget: true,
            externalImgPath: "/Volumes/USB/A.img"
        )
        let iosFull = QueueEntry(
            titleID: "B",
            name: "Game B",
            target: BuildTarget.ios,
            inputs: ["base": ["/g/b.nsp"]],
            outputDirectory: "/out",
            engineID: "release-1",
            batch: batch,
            packageAfter: true,
            fastRefresh: false,
            locksTarget: true
        )

        q.enqueue([macFast, iosFast, iosFull])
        q.start(target: BuildTarget.mac, packageAfter: false)

        XCTAssertEqual(startedTargets.count, 1)
        XCTAssertEqual(startedTargets[0].0, "A")
        XCTAssertEqual(startedTargets[0].1, BuildTarget.mac)
        XCTAssertTrue(startedTargets[0].2)

        busy = false
        q.buildEnded(succeeded: true)
        XCTAssertEqual(startedTargets.count, 2)
        XCTAssertEqual(startedTargets[1].0, "A")
        XCTAssertEqual(startedTargets[1].1, BuildTarget.ios)
        XCTAssertTrue(startedTargets[1].2)
        XCTAssertTrue(packagedEntries.isEmpty)

        busy = false
        q.buildEnded(succeeded: true)
        XCTAssertEqual(startedTargets.count, 3)
        XCTAssertEqual(startedTargets[2].0, "B")
        XCTAssertEqual(startedTargets[2].1, BuildTarget.ios)
        XCTAssertFalse(startedTargets[2].2)
        XCTAssertTrue(packagedEntries.isEmpty)

        busy = false
        q.buildEnded(succeeded: true)
        XCTAssertEqual(packagedEntries.count, 1)
        XCTAssertEqual(packagedEntries[0].map(\.titleID), ["A", "B"])
        XCTAssertTrue(packagedEntries[0].allSatisfy { $0.target == BuildTarget.ios })
    }

    func testStartAppliesAndClearsExportFrameworkAcrossQueuedEntries() {
        var started: [QueueEntry] = []
        let q = BuildQueueStore(
            file: nil,
            engineID: { "release-1" },
            busy: { false },
            start: { entry in
                started.append(entry)
                return nil
            }
        )
        let batch = UUID()
        let plainEntry = QueueEntry(
            titleID: "0100000000010000",
            name: "Game A",
            target: BuildTarget.ios,
            inputs: [:],
            outputDirectory: "/out",
            engineID: "release-1",
            batch: batch,
            packageAfter: true
        )
        q.enqueue([plainEntry])
        q.start(target: BuildTarget.ios, packageAfter: false, exportIPA: true, exportFramework: true)
        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(started[0].exportFramework, true)
        XCTAssertEqual(started[0].exportIPA, true)
        XCTAssertFalse(started[0].packageAfter)

        q.buildEnded(succeeded: true)
        let fwEntry = QueueEntry(
            titleID: "0100000000020000",
            name: "Game B",
            target: BuildTarget.ios,
            inputs: [:],
            outputDirectory: "/out",
            engineID: "release-1",
            batch: UUID(),
            packageAfter: false,
            exportIPA: true,
            exportFramework: true
        )
        q.enqueue([fwEntry])
        q.start(target: BuildTarget.ios, packageAfter: true, exportIPA: true, exportFramework: false)
        XCTAssertEqual(started.count, 2)
        XCTAssertEqual(started[1].exportFramework, false)
        XCTAssertTrue(started[1].packageAfter)
    }
    func testFrameworkModePreservesMixedTargetsAndRetriesOnlyFailedIOS() throws {
        var started: [QueueEntry] = []
        let q = BuildQueueStore(file: nil, engineID: { "fixture" }, busy: { false }, start: { started.append($0); return nil })
        let mac = QueueEntry(titleID: "A", name: "Game", target: BuildTarget.mac, inputs: [:], outputDirectory: "/out", engineID: "fixture")
        var ios = mac; ios.id = UUID(); ios.target = BuildTarget.ios
        q.enqueue([mac, ios])
        q.start(packageAfter: false, exportIPA: true, exportFramework: true)
        XCTAssertEqual(started.first?.target, BuildTarget.mac)
        XCTAssertNil(started.first?.exportFramework)
        q.buildEnded(succeeded: true)
        XCTAssertEqual(started.last?.target, BuildTarget.ios)
        XCTAssertEqual(started.last?.exportFramework, true)
        XCTAssertFalse(try XCTUnwrap(started.last).packageAfter)
        let decoded = try JSONDecoder().decode(QueueEntry.self, from: JSONEncoder().encode(try XCTUnwrap(started.last)))
        XCTAssertEqual(decoded.exportFramework, true)
        q.buildEnded(succeeded: false, reason: "fixture failure")
        q.retry(mac.id); q.start()
        XCTAssertEqual(started.map(\.target), [BuildTarget.mac, BuildTarget.ios, BuildTarget.ios])
        XCTAssertEqual(started.last?.exportFramework, true)
        XCTAssertEqual(q.entries.first?.status, .done)
    }

}
