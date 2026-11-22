import Foundation
import XCTest
@testable import NXCore
@testable import NXModel

private final class ControlledFetcher: CloudFileFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: @Sendable (URL) -> CloudFetchResult

    init(_ handler: @escaping @Sendable (URL) -> CloudFetchResult) {
        self.handler = handler
    }

    func fetch(_ file: URL, cancelled: @escaping @Sendable () -> Bool) -> CloudFetchResult {
        lock.lock()
        let fn = handler
        lock.unlock()
        return fn(file)
    }
}

@MainActor
final class CloudSaveSyncStoreTests: XCTestCase {
    private var root: URL!
    private let titleID = "0100ABCDEF000000"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-sync-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testInspectSyncConflictAndGenerationStaleness() async throws {
        let localSave = root.appendingPathComponent("local/save")
        try FileManager.default.createDirectory(at: localSave, withIntermediateDirectories: true)
        try Data("local-v1".utf8).write(to: localSave.appendingPathComponent("a.sav"))

        let remoteSource = root.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: remoteSource, withIntermediateDirectories: true)
        try Data("cloud-v1".utf8).write(to: remoteSource.appendingPathComponent("a.sav"))

        let cloudFile = root.appendingPathComponent("cloud/\(titleID)/save.dmsync")
        _ = try XCTUnwrap(CloudSaveArchive.writeCloudAtomically(save: remoteSource, titleID: titleID, device: "iPhone17,1", to: cloudFile))

        let fetcher = ControlledFetcher { FileManager.default.fileExists(atPath: $0.path) ? .ready : .missing }
        let store = CloudSaveSyncStore(fetcher: fetcher, volumeHolds: { _ in true })
        let plan = CloudSaveNow.SyncPlan(titleID: titleID, gameName: "TestGame", save: localSave, cloudFile: cloudFile)

        await store.inspect(plan: plan).value
        guard case .conflict = store.status else {
            return XCTFail("Expected .conflict status, got \(store.status)")
        }

        // syncNow surfaces conflict prompt for UI sheet.
        await store.syncNow(plan: plan, isRunning: { false }).value
        let prompt = try XCTUnwrap(store.conflict)

        // Resolving with .cloud replaces local save and updates status to .inStep.
        await store.resolveConflict(.cloud, prompt: prompt, isRunning: { false }).value
        XCTAssertNil(store.conflict)
        guard case .pulled = store.lastOutcome else {
            return XCTFail("Expected .pulled outcome, got \(String(describing: store.lastOutcome))")
        }
        guard case .inStep = store.status else {
            return XCTFail("Expected .inStep after pull, got \(store.status)")
        }
        XCTAssertEqual(try Data(contentsOf: localSave.appendingPathComponent("a.sav")), Data("cloud-v1".utf8))

        // Calling inspect after external local change must clear stale lastOutcome/lastFailure.
        try Data("imported-switch-save".utf8).write(to: localSave.appendingPathComponent("a.sav"))
        CloudSaveCheck.clearBase(save: localSave)
        await store.inspect(plan: plan).value
        XCTAssertNil(store.lastOutcome, "inspect must clear stale lastOutcome so UI text matches new status")
        XCTAssertNil(store.lastFailure)
        guard case .conflict = store.status else {
            return XCTFail("Expected .conflict after external save change without base, got \(store.status)")
        }

        // Generation staleness check: reset() while slow fetch is running must discard stale result.
        let gate = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let slowFetcher = ControlledFetcher { _ in
            entered.signal()
            _ = gate.wait(timeout: .now() + 5)
            return .ready
        }
        let slowStore = CloudSaveSyncStore(fetcher: slowFetcher, volumeHolds: { _ in true })
        let slowTask = slowStore.inspect(plan: plan)
        _ = entered.wait(timeout: .now() + 2)
        slowStore.reset()
        gate.signal()
        await slowTask.value
        XCTAssertEqual(slowStore.status, .idle, "Stale inspect result must not overwrite post-reset state")
    }

    func testInspectDuringInFlightSyncIsIgnoredAndSwitchingTitleIDDiscardsStaleWrite() async throws {
        let localSave = root.appendingPathComponent("local2/save")
        try FileManager.default.createDirectory(at: localSave, withIntermediateDirectories: true)
        try Data("v1".utf8).write(to: localSave.appendingPathComponent("a.sav"))
        let cloudFile = root.appendingPathComponent("cloud2/\(titleID)/save.dmsync")
        let plan = CloudSaveNow.SyncPlan(titleID: titleID, gameName: "GameA", save: localSave, cloudFile: cloudFile)

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let gatedFetcher = ControlledFetcher { file in
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
            return FileManager.default.fileExists(atPath: file.path) ? .ready : .missing
        }
        let store = CloudSaveSyncStore(fetcher: gatedFetcher, volumeHolds: { _ in true })

        let syncTask = store.syncNow(plan: plan, isRunning: { false })
        _ = entered.wait(timeout: .now() + 2)
        XCTAssertTrue(store.busy)

        // Calling inspect while syncNow is busy must be ignored (must not bump generation or stall busy=true).
        await store.inspect(plan: plan).value
        XCTAssertTrue(store.busy)
        XCTAssertEqual(store.status, .syncing)

        release.signal()
        release.signal()
        await syncTask.value
        XCTAssertFalse(store.busy, "busy must settle cleanly back to false")
        XCTAssertEqual(store.lastOutcome, .pushed(backup: nil))

        // Switching to another titleID while slow inspect runs discards old title's result.
        let otherPlan = CloudSaveNow.SyncPlan(titleID: "0100999988887777", gameName: "GameB", save: root.appendingPathComponent("other/save"), cloudFile: root.appendingPathComponent("other/save.dmsync"))
        let enter2 = DispatchSemaphore(value: 0)
        let release2 = DispatchSemaphore(value: 0)
        let switchStore = CloudSaveSyncStore(fetcher: ControlledFetcher { _ in
            enter2.signal()
            _ = release2.wait(timeout: .now() + 5)
            return .missing
        }, volumeHolds: { _ in true })
        let taskA = switchStore.inspect(plan: plan)
        _ = enter2.wait(timeout: .now() + 2)
        switchStore.reset()
        let taskB = switchStore.inspect(plan: otherPlan)
        release2.signal()
        release2.signal()
        await taskA.value
        await taskB.value
        if case .inStep = switchStore.status {} else {
            XCTFail("Expected empty GameB status (.inStep), got \(switchStore.status)")
        }
    }
}
