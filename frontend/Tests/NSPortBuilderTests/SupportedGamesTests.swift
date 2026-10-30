import XCTest
@testable import NSPortBuilder

/// The "All" filter's data (SupportedGames.swift): every profile in the checkout's dm/games becomes a
/// lightweight library entry, owned games matched later by title ID.
final class SupportedGamesTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("supported-" + UUID().uuidString)
        for (id, name) in [("0100535012974000", "Hades"), ("0100152000022000", "Mario Kart 8 Deluxe")] {
            let dir = repo.appendingPathComponent("dm/games/\(id)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "program_id\t\(id)\nname\t\(name)\n".write(to: dir.appendingPathComponent("game.tsv"), atomically: true, encoding: .utf8)
        }
        // Not profiles: a stray folder with a non-ID name, a folder without game.tsv, tests and docs
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("dm/games/notes"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("dm/games/0100F2C0115B6000"), withIntermediateDirectories: true)
        try "prose".write(to: repo.appendingPathComponent("dm/games/notes/README.md"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: repo) }

    func testEveryProfileFolderBecomesAnEntryNamedFromItsTable() {
        let games = SupportedGames.load(repo: repo.path)
        XCTAssertEqual(games.map(\.titleID), ["0100152000022000", "0100535012974000"])
        XCTAssertEqual(games.map(\.name), ["Mario Kart 8 Deluxe", "Hades"])
    }

    func testAnEntryHasNoPathsAndIsNotReady() {
        for game in SupportedGames.load(repo: repo.path) {
            XCTAssertEqual(game.appPath, "")
            XCTAssertFalse(game.isReady)
            XCTAssertEqual(game.inputs, [:])
        }
    }

    func testAnEmptyOrMissingRepoGivesNothing() {
        XCTAssertTrue(SupportedGames.load(repo: "").isEmpty)
        XCTAssertTrue(SupportedGames.load(repo: repo.appendingPathComponent("missing").path).isEmpty)
    }
}
