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

    func testAMissingCatalogFolderThrows() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-ach-\(UUID().uuidString)")
        XCTAssertThrowsError(try AchievementCatalog.load(from: missing))
    }

    func testOneBrokenFileDoesNotHideTheRest() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ach-cat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let good = """
        {"titleID":"01007EF00011E000","name":"One","achievements":[{"id":"plateau","name":"Plateau","detail":"Leave.","hidden":false}]}
        """
        try good.write(to: dir.appendingPathComponent("good.json"), atomically: true, encoding: .utf8)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("bad.json"))
        XCTAssertThrowsError(try AchievementCatalog.load(from: dir))
        let kept = try AchievementCatalog.load(from: dir, skipBroken: true)
        XCTAssertEqual(kept["01007EF00011E000"]?.achievements.map(\.id), ["plateau"])
        try? FileManager.default.removeItem(at: dir)
    }

    func testTwoFilesForOneTitleAreJoined() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ach-cat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func write(_ name: String, _ title: String, _ id: String) throws {
            let text = """
            {"titleID":"\(title)","name":"One","achievements":[{"id":"\(id)","name":"Goal","detail":"Do it.","hidden":false}]}
            """
            try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try write("a.json", "01007ef00011e000", "plateau")
        try write("b.json", "01007EF00011E000", "sword")
        let lists = try AchievementCatalog.load(from: dir)
        XCTAssertEqual(lists.count, 1)
        XCTAssertEqual(Set(lists["01007EF00011E000"]?.achievements.map(\.id) ?? []), ["plateau", "sword"])
        try? FileManager.default.removeItem(at: dir)
    }

    func testMixedCaseMarksAreKeptTogether() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ach-\(UUID().uuidString).json")
        let raw = ["01007ef00011e000": ["leave-the-plateau"], "01007EF00011E000": ["the-master-sword"]]
        try JSONEncoder().encode(raw).write(to: file)
        let loaded = AchievementProgress.load(file: file)
        XCTAssertEqual(loaded.unlocked(titleID: "01007EF00011E000"), ["leave-the-plateau", "the-master-sword"])
        try? FileManager.default.removeItem(at: file)
    }
}
