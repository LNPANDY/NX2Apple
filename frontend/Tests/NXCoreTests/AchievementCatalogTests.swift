import XCTest
@testable import NXCore

/// Every supported game has a catalog, and marking a goal done is saved.
final class AchievementCatalogTests: XCTestCase {
    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        let fm = FileManager.default
        while url.path != "/" {
            if fm.fileExists(atPath: url.appendingPathComponent("engine/dm/games").path) { return url }
            url.deleteLastPathComponent()
        }
        return url
    }

    func testEverySupportedGameHasGoals() throws {
        let root = repoRoot()
        let games = root.appendingPathComponent("engine/dm/games")
        let catalog = root.appendingPathComponent("frontend/Sources/NXCore/AchievementCatalog")
        let lists = try AchievementCatalog.load(from: catalog)
        let ids = try FileManager.default.contentsOfDirectory(atPath: games.path).filter {
            FileManager.default.fileExists(atPath: games.appendingPathComponent($0).appendingPathComponent("game.tsv").path)
        }
        XCTAssertFalse(ids.isEmpty)
        for id in ids {
            let list = try XCTUnwrap(lists[id.uppercased()], "\(id) has no achievement file")
            XCTAssertEqual(list.titleID.uppercased(), id.uppercased())
            XCTAssertGreaterThanOrEqual(list.achievements.count, 6, id)
            XCTAssertLessThanOrEqual(list.achievements.count, 24, id)
            let names = Set(list.achievements.map(\.id))
            XCTAssertEqual(names.count, list.achievements.count, "\(id) repeats an id")
            for item in list.achievements {
                XCTAssertFalse(item.id.isEmpty)
                XCTAssertFalse(item.name.isEmpty)
                XCTAssertFalse(item.detail.isEmpty)
                XCTAssertEqual(item.id, item.id.lowercased())
            }
        }
    }

    func testMarkingAGoalIsSavedAndCleared() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ach-\(UUID().uuidString).json")
        var book = AchievementProgress()
        book.toggle(titleID: "01007ef00011e000", id: "leave-the-plateau")
        book.toggle(titleID: "01007EF00011E000", id: "the-master-sword")
        try book.write(file: file)
        let loaded = AchievementProgress.load(file: file)
        XCTAssertEqual(loaded.unlocked(titleID: "01007EF00011E000"), ["leave-the-plateau", "the-master-sword"])
        var again = loaded
        again.toggle(titleID: "01007EF00011E000", id: "leave-the-plateau")
        XCTAssertEqual(again.unlocked(titleID: "01007EF00011E000"), ["the-master-sword"])
        XCTAssertEqual(again.marked(titleID: "01007EF00011E000", ids: ["the-master-sword", "leave-the-plateau", "missing"]), 1)
        try? FileManager.default.removeItem(at: file)
    }

    func testABrokenFileIsLeftAlone() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ach-\(UUID().uuidString).json")
        try Data("not json".utf8).write(to: file)
        let loaded = AchievementProgress.load(file: file)
        XCTAssertTrue(loaded.unreadable)
        var book = loaded
        book.toggle(titleID: "01007EF00011E000", id: "leave-the-plateau")
        XCTAssertTrue(book.unreadable)
        XCTAssertTrue(book.unlocked(titleID: "01007EF00011E000").isEmpty)
        XCTAssertThrowsError(try book.write(file: file))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "not json")
        try? FileManager.default.removeItem(at: file)
    }

    func testTheBundledCatalogLoads() {
        XCTAssertFalse(AchievementCatalog.bundled().isEmpty)
    }
}
