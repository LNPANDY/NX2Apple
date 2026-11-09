import XCTest
import NXCore
@testable import NXModel

/// The transfer queue (LNPANDY/NX2Apple#1036): one send per device at a time, waiting for a device, resumption, retry, cancel.
@MainActor final class TransferQueueStoreTests: XCTestCase {
    private var dir: URL!
    private var started: [String] = []
    private var finishers: [String: @MainActor (TransferResult) -> Void] = [:]
    private var progress: [String: @MainActor (Int64, Int64) -> Void] = [:]
    private var cancelled: [UUID] = []

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("transfers-" + UUID().uuidString)
        started = []; finishers = [:]; progress = [:]; cancelled = []
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func store() -> TransferQueueStore {
        TransferQueueStore(file: dir.appendingPathComponent("t.json"), perform: { [unowned self] entry, report, finish in
            started.append(entry.titleID + "@" + entry.deviceID); finishers[entry.titleID] = finish; progress[entry.titleID] = report
        }, cancelRunning: { [unowned self] in cancelled.append($0) })
    }

    private func entry(_ title: String, device: String = "D1") -> TransferEntry {
        TransferEntry(titleID: title, name: "Game " + title, archive: "/out/games/" + title, deviceID: device, deviceName: "iPad " + device)
    }

    func testOneTransferAtATimePerDeviceButDevicesRunSideBySide() {
        let q = store()
        q.enqueue([entry("A"), entry("B"), entry("C", device: "D2")])
        XCTAssertEqual(started, ["A@D1", "C@D2"])
        finishers["A"]?(.done)
        XCTAssertEqual(started, ["A@D1", "C@D2", "B@D1"])
    }

    func testProgressIsKeptOnTheEntry() {
        let q = store()
        q.enqueue([entry("A")])
        progress["A"]?(30, 120)
        XCTAssertEqual(q.entries[0].doneBytes, 30); XCTAssertEqual(q.entries[0].totalBytes, 120)
    }

    func testADeviceThatIsAbsentMakesTheEntryWaitAndItGoesOnWhenTheDeviceIsBack() {
        let q = store()
        q.enqueue([entry("A")])
        finishers["A"]?(.deviceAbsent)
        XCTAssertEqual(q.entries[0].status, .waiting)
        XCTAssertTrue(q.hasWaiting)
        q.deviceConnected(["OTHER"])
        XCTAssertEqual(q.entries[0].status, .waiting)
        q.deviceConnected(["D1"])
        XCTAssertEqual(q.entries[0].status, .sending)
        XCTAssertEqual(started, ["A@D1", "A@D1"])
    }

    func testAFailureKeepsItsReasonAndRetryContinues() {
        let q = store()
        q.enqueue([entry("A")])
        finishers["A"]?(.failed("CoreDeviceError 3"))
        XCTAssertEqual(q.entries[0].status, .failed); XCTAssertEqual(q.entries[0].reason, "CoreDeviceError 3")
        q.retry(q.entries[0].id)
        XCTAssertEqual(q.entries[0].status, .sending)
        XCTAssertNil(q.entries[0].reason)
    }

    func testCancelOfARunningSendSaysCancellingUntilTheToolReturnsThenRemovesTheRow() {
        let q = store()
        q.enqueue([entry("A"), entry("B")])
        let a = q.entries[0].id
        q.cancel(a)
        XCTAssertEqual(cancelled, [a])
        XCTAssertEqual(q.entries[0].status, .cancelling, "not reported stopped before it was")
        XCTAssertEqual(started, ["A@D1"], "the device is not free yet")
        q.cancel(a)
        XCTAssertEqual(cancelled, [a], "asked once")
        finishers["A"]?(.failed("interrupted"))
        XCTAssertEqual(q.entries.map(\.titleID), ["B"])
        XCTAssertEqual(started, ["A@D1", "B@D1"])
    }

    func testCancelOfAWaitingOrFailedEntryRemovesItAtOnce() {
        let q = store()
        q.enqueue([entry("A")])
        finishers["A"]?(.deviceAbsent)
        q.cancel(q.entries[0].id)
        XCTAssertTrue(q.entries.isEmpty)
        XCTAssertEqual(cancelled, [])
    }

    func testTheSameGameForTheSameDeviceIsNotQueuedTwice() {
        let q = store()
        q.enqueue([entry("A")]); q.enqueue([entry("A")])
        XCTAssertEqual(q.entries.count, 1)
        finishers["A"]?(.done)
        q.enqueue([entry("A")])
        XCTAssertEqual(q.entries.count, 1, "the finished one is replaced")
        XCTAssertEqual(q.entries[0].status, .sending)
    }

    func testASendTheAppQuitInWaitsForItsDeviceAfterARestart() {
        let q = store()
        q.enqueue([entry("A")])
        started = []
        let again = store()
        XCTAssertEqual(again.entries[0].status, .waiting)
        again.deviceConnected(["D1"])
        XCTAssertEqual(started, ["A@D1"])
        XCTAssertEqual(q.entries.count, 1)
    }
}
