import Foundation
import XCTest
import GameTime
@testable import NXCore

final class GameTimeIndexTests: XCTestCase {
    private let title = "0100000000000000"
    private func write(_ save: URL, cloud: URL? = nil, ms: UInt64) throws {
        let local = try XCTUnwrap(DMGameTimeLocalURL(save, DMGameTimeCloudURL(cloud?.path, title), title))
        var error: NSError?
        XCTAssertTrue(DMGameTimeUpdateSegments(local, [["id": UUID().uuidString, "day": "2026-11-12", "milliseconds": NSNumber(value: ms)]], 1_794_480_000_000, &error))
        XCTAssertNil(error)
    }
    func testSummarySurvivesReloadInvalidatesOneChangeAndRetainsMissingHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let save = root.appendingPathComponent("save"), file = root.appendingPathComponent("index.json"), index = PlayTimeIndex(indexURL: root.appendingPathComponent("index.json"))
        try write(save, ms: 3_600_000)
        let first = await index.refresh(save: save, cloudFolder: nil, titleID: title)
        XCTAssertEqual(first?.totalMilliseconds, 3_600_000)
        XCTAssertEqual(first?.lastActivityAt, Date(timeIntervalSince1970: 1_794_480_000))
        await index.flush()
        let before = try Data(contentsOf: file), stamp = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        let unchanged = await index.refresh(save: save, cloudFolder: nil, titleID: title)
        await index.flush()
        XCTAssertEqual(unchanged, first); XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, stamp)
        try write(save, ms: 60_000)
        let changed = await index.refresh(save: save, cloudFolder: nil, titleID: title)
        XCTAssertEqual(changed?.totalMilliseconds, 3_660_000)
        await index.flush()
        let restored = PlayTimeIndex(indexURL: file)
        let cached = await restored.cached(save: save, cloudFolder: nil, titleID: title)
        XCTAssertEqual(cached, changed)
        try FileManager.default.removeItem(at: XCTUnwrap(DMGameTimeLocalURL(save, nil, title)))
        let retained = await restored.refresh(save: save, cloudFolder: nil, titleID: title)
        XCTAssertEqual(retained, changed, "cached totals are displayed, never imported as new runtime records")
    }
    func testLocalWarmupDoesNotSuppressConcurrentCloudMerge() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let save = root.appendingPathComponent("save"), cloud = root.appendingPathComponent("cloud")
        try write(save, cloud: cloud, ms: 1000)
        let remote = try XCTUnwrap(DMGameTimeCloudURL(cloud.path, title))
        try FileManager.default.createDirectory(at: remote.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["version": 1, "runs": [UUID().uuidString: 2000]]).write(to: remote)
        let index = PlayTimeIndex(indexURL: root.appendingPathComponent("index.json"))
        async let warm = index.refresh(save: save, cloudFolder: cloud.path, titleID: title, synchronize: false)
        async let full = index.refresh(save: save, cloudFolder: cloud.path, titleID: title)
        _ = await warm; let result = await full
        XCTAssertEqual(result?.totalMilliseconds, 3000)
        let repeated = await index.refresh(save: save, cloudFolder: cloud.path, titleID: title)
        XCTAssertEqual(repeated?.totalMilliseconds, 3000)
        await index.flush()
    }
    func testDownloadCompletingDuringRetryRefreshesWithoutAnotherSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = root.appendingPathComponent("cloud"), save = root.appendingPathComponent("save")
        let remote = try XCTUnwrap(DMGameTimeCloudURL(cloud.path, title))
        try FileManager.default.createDirectory(at: remote.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: remote.deletingLastPathComponent().appendingPathComponent(".playtime.json.icloud"))
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "runs": [UUID().uuidString: 90_000]])
        let materialize = Task.detached { try await Task.sleep(nanoseconds: 300_000_000); try data.write(to: remote, options: .atomic) }
        let index = PlayTimeIndex(indexURL: root.appendingPathComponent("index.json"))
        let result = await index.refresh(save: save, cloudFolder: cloud.path, titleID: title)
        try await materialize.value
        XCTAssertEqual(result?.totalMilliseconds, 90_000)
        await index.flush()
    }
    func testUnknownCloudDocumentIsPreservedWhileLocalTimeRemainsAvailable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = root.appendingPathComponent("cloud"), save = root.appendingPathComponent("save")
        try write(save, cloud: cloud, ms: 90_000)
        let remote = try XCTUnwrap(DMGameTimeCloudURL(cloud.path, title))
        try FileManager.default.createDirectory(at: remote.deletingLastPathComponent(), withIntermediateDirectories: true)
        let unknown = Data("{\"version\":999,\"future\":true}".utf8); try unknown.write(to: remote)
        let index = PlayTimeIndex(indexURL: root.appendingPathComponent("index.json"))
        let result = await index.refresh(save: save, cloudFolder: cloud.path, titleID: title)
        XCTAssertEqual(result?.totalMilliseconds, 90_000); XCTAssertEqual(try Data(contentsOf: remote), unknown)
        await index.flush()
    }
}
