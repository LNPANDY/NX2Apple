import XCTest
@testable import NXCore
import GameTime

final class GameTimeMetricsTests: XCTestCase {
    func testFormatsMinutesAndHoursForTheSelectedLocale() {
        let en = Locale(identifier: "en_US")
        let de = Locale(identifier: "de_DE")
        let english = GameTimeMetrics.duration(7_500_000, locale: en)
        XCTAssertTrue(english.contains("2") && english.contains("5"))
        XCTAssertNotEqual(english, GameTimeMetrics.duration(7_500_000, locale: de))
    }
    func testCachedHistoryDoesNotWaitForOrOverwriteBadCloudData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let save = root.appendingPathComponent("save"), folder = root.appendingPathComponent("cloud")
        let title = "0100000000000000"
        let cloud = try XCTUnwrap(DMGameTimeCloudURL(folder.path, title))
        let local = try XCTUnwrap(DMGameTimeLocalURL(save, cloud, title))
        var error: NSError?
        XCTAssertTrue(DMGameTimeUpdateRun(local, UUID().uuidString, 90_000, &error))
        try FileManager.default.createDirectory(at: cloud.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bad = Data("not a play time document".utf8)
        try bad.write(to: cloud)
        XCTAssertEqual(GameTimeMetrics.cached(save: save, cloudFolder: folder.path, titleID: title), 90_000)
        XCTAssertEqual(try Data(contentsOf: cloud), bad)
    }
    func testMissingLocalHistoryDoesNotCreateACloudDocument() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(GameTimeMetrics.refresh(save: root.appendingPathComponent("save"), cloudFolder: nil, titleID: "0100000000000000"), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
