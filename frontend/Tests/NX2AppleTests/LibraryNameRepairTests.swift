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

    func testBareSwitch2AndSwitch1DumpFilenamesUseTheParentFolderName() throws {
        XCTAssertEqual(LibraryGame.cleanedName("0400000000005000_v0_420d1c5034ab"), "0400000000005000")
        XCTAssertEqual(LibraryGame.cleanedName("0100000000006000_v0_420d1c5034ab"), "0100000000006000")
        XCTAssertEqual(LibraryGame.cleanedName("Mario Kart World 0400000000005000_v0_420d1c5034ab"), "Mario Kart World")

        let root = directory.appendingPathComponent("switch2-games")
        let sw2Folder = root.appendingPathComponent("Mario Kart World")
        let sw1Folder = root.appendingPathComponent("Astral Chain")
        try FileManager.default.createDirectory(at: sw2Folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sw1Folder, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: sw2Folder.appendingPathComponent("0400000000005000_v0_420d1c5034ab.nsp"))
        try Data([1, 2, 3]).write(to: sw1Folder.appendingPathComponent("0100000000006000_v0_420d1c5034ab.nsp"))

        let library = GameLibrary(file: directory.appendingPathComponent("library-sw2.json"))
        library.applicationFolders = []
        scan(library) { library.setFolder(root) }

        let sw2 = try XCTUnwrap(library.games.first { $0.titleID == "0400000000005000" })
        XCTAssertEqual(sw2.name, "Mario Kart World")
        XCTAssertEqual(sw2.displayName(.en), "Mario Kart World")
        let sw1 = try XCTUnwrap(library.games.first { $0.titleID == "0100000000006000" })
        XCTAssertEqual(sw1.name, "Astral Chain")
        XCTAssertEqual(sw1.displayName(.en), "Astral Chain")
    }
}
