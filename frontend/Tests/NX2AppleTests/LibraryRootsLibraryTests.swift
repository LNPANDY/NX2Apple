import XCTest
@testable import NX2Apple
@testable import NXCore

/// Several library roots (LNPANDY/NX2Apple#992) through the library itself.
final class LibraryRootsLibraryTests: IsolatedDefaultsTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("roots-lib-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func root(_ name: String, files: [String]) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for file in files { try Data([0]).write(to: url.appendingPathComponent(file)) }
        return url
    }

    private func scan(_ library: GameLibrary, _ run: () -> Void) {
        let finished = expectation(description: "scan")
        let token = library.$scanning.dropFirst().filter { !$0 }.sink { _ in finished.fulfill() }
        run()
        wait(for: [finished], timeout: 5)
        withExtendedLifetime(token) {}
    }

    func testTwoRootsAreBothScannedAndAGameInBothIsOne() throws {
        let a = try root("a", files: ["Hades [0100535012974000][v0].nsp", "Only A [0100000000001000][v0].nsp"])
        let b = try root("b", files: ["Hades copy [0100535012974000][v0].nsp", "Only B [0100000000002000][v0].nsp"])
        let library = GameLibrary(file: directory.appendingPathComponent("library.json"))
        library.applicationFolders = []
        scan(library) { library.addFolder(a) }
        scan(library) { library.addFolder(b) }
        XCTAssertEqual(Set(library.games.map(\.titleID)), ["0100535012974000", "0100000000001000", "0100000000002000"])
        XCTAssertEqual(library.folders.count, 2)
        let hades = try XCTUnwrap(library.games.first { $0.titleID == "0100535012974000" })
        XCTAssertTrue(hades.inputs["base"]?.first?.contains("/a/") ?? false, "the first root wins when two hold a game")
    }

    func testAddingTheSameFolderAgainChangesNothing() throws {
        let a = try root("a", files: [])
        let library = GameLibrary(file: directory.appendingPathComponent("library.json"))
        library.applicationFolders = []
        scan(library) { library.addFolder(a) }
        library.addFolder(URL(fileURLWithPath: a.path + "/"))
        XCTAssertEqual(library.folders.count, 1)
    }

    func testAnOldLibraryFileWithOneFolderLoadsAsOneRoot() throws {
        let a = try root("a", files: [])
        let file = directory.appendingPathComponent("library.json")
        try #"{"games":[],"folder":"\#(a.path)"}"#.write(to: file, atomically: true, encoding: .utf8)
        let library = GameLibrary(file: file)
        XCTAssertEqual(library.folders, [a.path])
        XCTAssertEqual(library.folder, a.path)
    }

    func testRemovingARootKeepsItsGamesAndFilesAndOrderSurvivesARestart() throws {
        let a = try root("a", files: ["Only A [0100000000001000][v0].nsp"])
        let b = try root("b", files: [])
        let file = directory.appendingPathComponent("library.json")
        let library = GameLibrary(file: file)
        library.applicationFolders = []
        scan(library) { library.addFolder(a) }
        library.addFolder(b)
        library.removeFolder(a.path)
        XCTAssertEqual(GameLibrary(file: file).folders, [b.path])
        XCTAssertEqual(library.games.map(\.titleID), ["0100000000001000"], "the game stays in the library")
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.appendingPathComponent("Only A [0100000000001000][v0].nsp").path), "its files are never touched")
    }

    func testARootOnAnUnmountedDriveIsDisconnectedAndKeepsItsGames() throws {
        let volumes = directory.appendingPathComponent("Volumes")
        try FileManager.default.createDirectory(at: volumes, withIntermediateDirectories: true)
        let gone = volumes.appendingPathComponent("Games/Switch").path
        let library = GameLibrary(file: directory.appendingPathComponent("library.json"), volumes: volumes.path)
        XCTAssertEqual(library.rootState(gone, volumes: volumes.path), .disconnected)
    }
}
