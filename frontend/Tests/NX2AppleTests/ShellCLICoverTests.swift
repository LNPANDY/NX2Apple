import XCTest
@testable import NX2Apple

/// `--artwork <titleID>=<path>` on a terminal shell install names each game's own cover.
final class ShellCLICoverTests: XCTestCase {
    /// Both flags survive, the title ids are lowercased, and the paths stay intact.
    func testRepeatedArtworkFlagsKeepLowercasedIdsAndFullPaths() {
        let args = [
            "--install-shell",
            "--artwork", "0100ABCDEF000000=/Users/me/cover.gif",
            "--framework", "/fw",
            "--artwork", "0100BBBBBB000000=/Users/me/clip.mp4",
        ]
        XCTAssertEqual(ShellCLI.covers(args), [
            "0100abcdef000000": "/Users/me/cover.gif",
            "0100bbbbbb000000": "/Users/me/clip.mp4",
        ])
    }

    /// The path is everything after the first equals, including a later equals.
    func testArtworkPathKeepsEqualsAfterTheTitleId() {
        XCTAssertEqual(ShellCLI.covers(["--artwork", "0100=/tmp/a=b.gif"]), ["0100": "/tmp/a=b.gif"])
        XCTAssertEqual(
            ShellCLI.covers(["--artwork", "0100ABCDEF000000=/tmp/a=b.gif"]),
            ["0100abcdef000000": "/tmp/a=b.gif"])
    }

    /// A flag with no equals or an empty path is left out.
    func testArtworkMissingEqualsOrPathIsIgnored() {
        let args = [
            "--artwork", "0100ABCDEF000000",
            "--artwork", "0100BBBBBB000000=",
            "--artwork", "=",
            "--artwork", "0100CCCCCCCC000000=/tmp/kept.png",
            "--artwork",
        ]
        XCTAssertEqual(ShellCLI.covers(args), ["0100cccccccc000000": "/tmp/kept.png"])
    }

    /// parse returns the install keys when the command also carries artwork flags.
    func testParseKeepsRequiredInstallKeysBesideArtwork() throws {
        let parsed = ShellCLI.parse([
            "--install-shell",
            "--framework", "/Frameworks/DmGame.framework",
            "--artwork", "0100ABCDEF000000=/Users/me/cover.gif",
            "--archive", "/games/0100ABCDEF000000",
            "--title-id", "0100ABCDEF000000",
            "--name", "Test Game",
            "--device", "00008150-AAAA",
            "--team", "TEAM123456",
            "--repo", "/repo",
            "--artwork", "0100BBBBBB000000=/Users/me/clip.mp4",
        ])
        let options = try XCTUnwrap(parsed)
        XCTAssertEqual(options["framework"], "/Frameworks/DmGame.framework")
        XCTAssertEqual(options["archive"], "/games/0100ABCDEF000000")
        XCTAssertEqual(options["title-id"], "0100ABCDEF000000")
        XCTAssertEqual(options["name"], "Test Game")
        XCTAssertEqual(options["device"], "00008150-AAAA")
        XCTAssertEqual(options["team"], "TEAM123456")
        XCTAssertEqual(options["repo"], "/repo")
    }

    /// Saved paths fill the games a flag does not name. A flag replaces the saved path. An empty or missing path is left out.
    func testSavedCoversFillGapsAndAFlagReplacesOne() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("covers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let gif = dir.appendingPathComponent("cover.gif")
        let movie = dir.appendingPathComponent("clip.mp4")
        try Data("gif".utf8).write(to: gif)
        try Data("mp4".utf8).write(to: movie)
        let library = dir.appendingPathComponent("library.json")
        let body = """
        {"folder":"","games":[
          {"titleID":"0100ABCDEF000000","artworkPath":"\(gif.path)"},
          {"titleID":"0100BBBBBB000000","artworkPath":"\(movie.path)"},
          {"titleID":"0100CCCCCCCC000000","artworkPath":""},
          {"titleID":"0100DDDDDD000000","artworkPath":"/no/such.png"}
        ]}
        """
        try Data(body.utf8).write(to: library)
        XCTAssertEqual(ShellCLI.mergedCovers(["--artwork", "0100ABCDEF000000=/override.gif"], library: library), [
            "0100abcdef000000": "/override.gif",
            "0100bbbbbb000000": movie.path,
        ])
        let bare = dir.appendingPathComponent("bare.json")
        try Data("""
        [{"titleID":"0100BBBBBB000000","artworkPath":"\(movie.path)"}]
        """.utf8).write(to: bare)
        XCTAssertEqual(ShellCLI.savedCovers(bare), ["0100bbbbbb000000": movie.path])
        XCTAssertEqual(ShellCLI.savedCovers(dir.appendingPathComponent("missing.json")), [:])
    }
}
