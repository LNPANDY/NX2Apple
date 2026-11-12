import XCTest
import NXCore
@testable import NXModel

/// The one persistent build queue (LNPANDY/NX2Apple#943, #997).
@MainActor final class BuildQueueStoreTests: XCTestCase {
    private var dir: URL!
    private var file: URL { dir.appendingPathComponent("queue.json") }
    private var started: [String] = []
    private var busy = false
    private var engine = "release-1"
    private var refuse: Set<String> = []
    private var packaged: [[String]] = []

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("queue-" + UUID().uuidString)
        started = []; busy = false; engine = "release-1"; refuse = []; packaged = []
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func store(file: URL? = nil) -> BuildQueueStore {
        BuildQueueStore(file: file ?? self.file, engineID: { [unowned self] in engine }, busy: { [unowned self] in busy },
                        start: { [unowned self] in
                            if refuse.contains($0.titleID) { return "refused" }
                            started.append($0.titleID); busy = true; return nil
                        },
                        packageBatch: { [unowned self] in packaged.append($0.map(\.titleID)) },
                        engineChangedReason: { "engine changed" })
    }

    private func entry(_ id: String, batch: UUID = UUID(), package: Bool = false, engine: String? = nil) -> QueueEntry {
        QueueEntry(titleID: id, name: "Game " + id, target: BuildTarget.mac, inputs: ["base": ["/g/\(id).nsp"]],
                   outputDirectory: "/out", engineID: engine ?? "release-1", batch: batch, packageAfter: package)
    }

    func testEnqueueWaitsForStartAndSurvivesARestartUnstarted() {
        let q = store()
        q.enqueue([entry("A"), entry("B")])
        XCTAssertEqual(started, [], "adding games waits for Start build")
        XCTAssertEqual(q.entries.map(\.status), [.queued, .queued])

        let again = store()
        XCTAssertFalse(again.awaitingResume, "an unstarted queue was not interrupted mid-build")
        XCTAssertFalse(again.paused)
        again.processNext()
        XCTAssertEqual(started, [], "background ticks do not start a waiting queue on their own")

        again.start(target: BuildTarget.ios, packageAfter: true)
        XCTAssertEqual(started, ["A"])
        XCTAssertEqual(again.entries.map(\.target), [BuildTarget.ios, BuildTarget.ios])
        XCTAssertEqual(again.entries.map(\.packageAfter), [true, true])
        XCTAssertEqual(Set(again.entries.map(\.batch)).count, 1)
    }

    func testAppendingWhileRunningInheritsActiveBatchTargetAndPackaging() {
        let q = store()
        q.enqueue([entry("A")])
        q.start(target: BuildTarget.ios, packageAfter: true)
        XCTAssertEqual(started, ["A"])
        q.enqueue([entry("B")])   // added with default Mac/false while the iOS batch runs
        XCTAssertEqual(q.entries[1].target, BuildTarget.ios)
        XCTAssertTrue(q.entries[1].packageAfter)
        XCTAssertEqual(q.entries[1].batch, q.entries[0].batch)
        busy = false; q.buildEnded(succeeded: true)
        busy = false; q.buildEnded(succeeded: true)
        XCTAssertEqual(packaged, [["A", "B"]])
    }

    func testEntriesBuildOneAfterTheOtherInOrder() {
        let q = store()
        q.enqueue([entry("A"), entry("B"), entry("C")])
        q.start()
        XCTAssertEqual(started, ["A"])
        busy = false; q.buildEnded(succeeded: true)
        XCTAssertEqual(started, ["A", "B"])
        busy = false; q.buildEnded(succeeded: false, reason: "no keys")
        XCTAssertEqual(started, ["A", "B", "C"])
        busy = false; q.buildEnded(succeeded: true)
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
        busy = false; q.buildEnded(succeeded: false, reason: "Stopped", stopped: true)
        XCTAssertTrue(q.paused)
        XCTAssertEqual(started, ["A"], "the next game does not start")
        q.enqueue([entry("C")])
        XCTAssertEqual(started, ["A"], "nor does a game added meanwhile")
        q.resume()
        XCTAssertFalse(q.paused)
        XCTAssertEqual(started, ["A", "B"])
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
        started = []; busy = false
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
        q.enqueue([entry("A", batch: batch, package: true), entry("B", batch: batch, package: true), entry("C", batch: batch, package: true)])
        q.start()
        busy = false; q.buildEnded(succeeded: true)
        busy = false; q.buildEnded(succeeded: false, reason: "failed")
        XCTAssertEqual(packaged, [])
        busy = false; q.buildEnded(succeeded: true)
        XCTAssertEqual(packaged, [["A", "C"]])
    }

    func testAGameAlreadyWaitingIsNotQueuedTwiceAndANewBatchReplacesTheResults() {
        let q = store()
        q.enqueue([entry("A"), entry("B")])
        q.enqueue([entry("B")])
        XCTAssertEqual(q.entries.count, 2)
        q.start()
        busy = false; q.buildEnded(succeeded: true)
        busy = false; q.buildEnded(succeeded: true)
        q.enqueue([entry("C")])
        XCTAssertEqual(q.entries.map(\.titleID), ["C"])
        XCTAssertEqual(q.entries.map(\.status), [.queued])
    }

    func testInputSummaryNamesTheRowsThatHaveFiles() {
        var e = entry("A")
        e.inputs = ["base": ["/a"], "update": ["/u"], "dlc": ["/d1", "/d2"], "keys": ["/k"]]
        XCTAssertEqual(e.inputSummary { $0 }, "data.base, data.update, 2 × data.dlc")
        e.gameFolder = "/folder"
        XCTAssertEqual(e.inputSummary { $0 }, "queue.inputFolder")
    }
}
