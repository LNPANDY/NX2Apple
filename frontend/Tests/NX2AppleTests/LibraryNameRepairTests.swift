import XCTest
@testable import NX2Apple
@testable import NXCore

/// A library card shows the game's name: never a raw title ID while the package names it, never a size or a dump tool's tags.
final class LibraryNameRepairTests: IsolatedDefaultsTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("names-lib-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func scan(_ library: GameLibrary, _ run: () -> Void) {
        let finished = expectation(description: "scan")
        let token = library.$scanning.dropFirst().filter { !$0 }.sink { _ in finished.fulfill() }
        run()
        wait(for: [finished], timeout: 5)
        withExtendedLifetime(token) {}
    }

    func testASizeInTheFileNameIsNotPartOfTheName() {
        XCTAssertEqual(LibraryGame.cleanedName("Batman Arkham Knight [0100ACD0163D0000][v0] (0.01 GB)"), "Batman Arkham Knight")
        XCTAssertEqual(LibraryGame.cleanedName("Super Smash Bros Ultimate [01006A800016E000][v0] (13.63 GB)"), "Super Smash Bros Ultimate")
        XCTAssertEqual(LibraryGame.cleanedName("Hades (512 MB)"), "Hades")
        XCTAssertEqual(LibraryGame.cleanedName("Mario Kart 8 (Deluxe)"), "Mario Kart 8 (Deluxe)", "only a size goes")
        XCTAssertEqual(GameLibrary.title(for: "/g/Batman Arkham Knight [0100ACD0163D0000][v0] (0.01 GB).nsz", repo: "", titleID: "0100ACD0163D0000"),
                       "Batman Arkham Knight")
    }

    func testAStoredNameWithASizeShowsWithoutIt() {
        let game = LibraryGame(titleID: "0100ACD0163D0000", name: "Batman Arkham Knight  (0.01 GB)")
        XCTAssertEqual(game.displayName(.en), "Batman Arkham Knight")
    }

    func testARawTitleIDIsNeverShownWhileThePackageNamesTheGame() {
        var game = LibraryGame(titleID: "0400486024DEC000", name: "0400486024DEC000")
        game.inputs["base"] = ["/g/The Legend of Zelda Ocarina of Time [NUP]/The Legend of Zelda Ocarina of Time [0400486024DEC000][v131072].nup"]
        XCTAssertEqual(game.displayName(.en), "The Legend of Zelda Ocarina of Time")
        XCTAssertEqual(game.displayName(Lang("de")), "The Legend of Zelda Ocarina of Time")
        game.titleNames = ["en-US": "The Legend of Zelda: Ocarina of Time"]
        XCTAssertEqual(game.displayName(.en), "The Legend of Zelda: Ocarina of Time", "the control data's name comes first")
    }

    func testTheScanRepairsANameAnOlderScanKept() throws {
        let root = directory.appendingPathComponent("games")
        let folder = root.appendingPathComponent("Some Game [0100000000003000]")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([0]).write(to: folder.appendingPathComponent("Some Game [0100000000003000][v0] (0.01 GB).nsz"))
        try Data([0]).write(to: root.appendingPathComponent("Other Game [0100000000004000][v0].nsp"))
        let library = GameLibrary(file: directory.appendingPathComponent("library.json"))
        library.applicationFolders = []
        library.upsert(LibraryGame(titleID: "0100000000003000", name: "Some Game  (0.01 GB)"))
        library.upsert(LibraryGame(titleID: "0100000000004000", name: "0100000000004000"))
        scan(library) { library.setFolder(root) }
        XCTAssertEqual(library.games.first { $0.titleID == "0100000000003000" }?.name, "Some Game")
        XCTAssertEqual(library.games.first { $0.titleID == "0100000000004000" }?.name, "Other Game")
    }
}
