import XCTest
@testable import NXCore

final class LibraryRootsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("roots-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func folder(_ name: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    func testTwoSpellingsOfOneFolderAreOneRoot() throws {
        let games = try folder("games")
        let link = directory.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: games)
        var roots = LibraryRoots.adding(games, to: [])
        roots = LibraryRoots.adding(link, to: roots)
        roots = LibraryRoots.adding(games + "/", to: roots)
        roots = LibraryRoots.adding(games + "/../games", to: roots)
        XCTAssertEqual(roots.count, 1)
    }

    func testRootsKeepTheirOrderAndRemovalIsBySpelling() throws {
        let a = try folder("a"), b = try folder("b"), c = try folder("c")
        var roots: [String] = []
        for path in [b, a, c, a] { roots = LibraryRoots.adding(path, to: roots) }
        XCTAssertEqual(roots.map { ($0 as NSString).lastPathComponent }, ["b", "a", "c"])
        XCTAssertEqual(LibraryRoots.removing(a + "/", from: roots).map { ($0 as NSString).lastPathComponent }, ["b", "c"])
    }

    func testStates() throws {
        let parent = try folder("games"), child = try folder("games/inner"), other = try folder("other")
        let roots = [parent, child, other, directory.appendingPathComponent("gone").path]
        XCTAssertEqual(LibraryRoots.state(of: parent, in: roots), .connected)
        XCTAssertEqual(LibraryRoots.state(of: child, in: roots), .covered(by: parent))
        XCTAssertEqual(LibraryRoots.state(of: other, in: roots), .connected)
        XCTAssertEqual(LibraryRoots.state(of: roots[3], in: roots), .missing)
        XCTAssertEqual(LibraryRoots.scannable(roots), [parent, other])
    }

    func testADriveThatIsNotConnectedIsNotMissing() throws {
        let volumes = try folder("Volumes")
        let path = volumes + "/Games/Switch"
        XCTAssertEqual(LibraryRoots.state(of: path, in: [path], volumes: volumes), .disconnected)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        XCTAssertEqual(LibraryRoots.state(of: path, in: [path], volumes: volumes), .connected)
        try FileManager.default.removeItem(atPath: path)
        XCTAssertEqual(LibraryRoots.state(of: path, in: [path], volumes: volumes), .missing)
    }
}
