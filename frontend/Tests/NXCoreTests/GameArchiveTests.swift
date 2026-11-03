import XCTest
@testable import NXCore

/// Game engine files (`.nxgame`, tools/game_archive.py): reading and checking one, keeping it per game, the checks before a build, and
/// the engine copy a build runs from. Real ditto and git on files in a temporary folder.
final class GameArchiveTests: XCTestCase {
    static let tid = "0100ABCD12340000"
    static let other = "0100000000010000"
    static let patch = """
        diff --git a/dm/tools/sdk_patches.py b/dm/tools/sdk_patches.py
        --- a/dm/tools/sdk_patches.py
        +++ b/dm/tools/sdk_patches.py
        @@ -1 +1 @@
        -RULES = [1]
        +RULES = [1, 2]

        """

    private var tmp: String!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("game-archive-tests-" + UUID().uuidString)
        try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(atPath: tmp) }

    private func write(_ path: String, _ text: String) throws {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// A `.nxgame` made the way tools/game_archive.py makes it: the files, a manifest with their SHA-256, zipped by ditto.
    private func makeArchive(_ name: String = "a", titleID: String = GameArchiveTests.tid, patch: String? = GameArchiveTests.patch,
                             base: String = #"{"commit": "c", "remote": "github.com/seedds/nxnative", "pin": "p1", "engine_id": "p1-aaaaaaaaaaaa"}"#,
                             updates: [Int] = [65536], format: Int = 1, edit: ((String) throws -> Void)? = nil) throws -> String {
        let content = tmp + "/content-" + name
        var files: [String: String] = ["game/dm/games/\(titleID)/game.tsv": "title_id\t\(titleID)\nbuild\tv65536\n"]
        if let patch { files["engine.patch"] = patch }
        var sums: [String] = []
        for (rel, text) in files.sorted(by: { $0.key < $1.key }) {
            try write(content + "/" + rel, text)
            sums.append("\"\(rel)\": \"\(GameArchive.hex(Data(text.utf8)))\"")
        }
        let manifest = """
            {"format": \(format), "title_id": "\(titleID)", "name": "A Test Game", "updates": \(updates), "base": \(base),
             "commits": [{"hash": "h", "subject": "s"}], "patched": \(patch == nil ? "[]" : "[\"dm/tools/sdk_patches.py\"]"),
             "author": "someone", "notes": "", "created": "", "files": {\(sums.joined(separator: ", "))}}
            """
        try write(content + "/manifest.json", manifest)
        try edit?(content)
        let zip = tmp + "/\(name).nxgame"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", content, zip]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        return zip
    }

    /// An installed engine: .engine-id, .upstream-ref, dm/ with two games and shared files, scripts/, a build product.
    private func makeEngine() throws -> String {
        let e = tmp + "/engine"
        try write(e + "/.engine-id", "p1-aaaaaaaaaaaa\n")
        try write(e + "/.upstream-ref", "p1\n")
        try write(e + "/.iosdd/junk", "x")
        try write(e + "/scripts/build_ipa_from_nsp.py", "print(1)\n")
        try write(e + "/dm/tools/sdk_patches.py", "RULES = [1]\n")
        try write(e + "/dm/games/game.py", "GAMES = 1\n")
        try write(e + "/dm/games/\(Self.other)/game.tsv", "other\n")
        try write(e + "/dm/fork_patches.txt", "0001-a.patch\n")
        return e
    }

    // MARK: Reading

    func testAddKeepsTheArchiveAndLoadFindsIt() throws {
        let root = tmp + "/kept"
        let s = try GameArchiveLibrary.add(try makeArchive(), root: root)
        XCTAssertEqual(s.titleID, Self.tid)
        XCTAssertEqual(s.manifest.name, "A Test Game")
        XCTAssertEqual(s.manifest.updates, [65536])
        XCTAssertEqual(s.manifest.base.engineID, "p1-aaaaaaaaaaaa")
        XCTAssertTrue(s.manifest.hasPatch)
        XCTAssertEqual(GameArchiveLibrary.load(root: root)[Self.tid], s)
        // another archive for the game replaces it
        let s2 = try GameArchiveLibrary.add(try makeArchive("b", patch: nil), root: root)
        XCTAssertNotEqual(s.sha256, s2.sha256)
        XCTAssertEqual(GameArchiveLibrary.load(root: root)[Self.tid], s2)
        XCTAssertFalse(fm.fileExists(atPath: s.folder))
        GameArchiveLibrary.remove(titleID: Self.tid, root: root)
        XCTAssertTrue(GameArchiveLibrary.load(root: root).isEmpty)
    }

    func testProblems() throws {
        let root = tmp + "/kept"
        XCTAssertThrowsError(try GameArchiveLibrary.add(try makeArchive("f", format: 2), root: root)) { XCTAssertEqual($0 as? GameArchive.Problem, .format(2)) }
        XCTAssertThrowsError(try GameArchiveLibrary.add(try makeArchive("t", titleID: "0100abcd12340000"), root: root)) {
            XCTAssertEqual($0 as? GameArchive.Problem, .badTitleID("0100abcd12340000"))
        }
        let changed = try makeArchive("d") { try "changed".write(toFile: $0 + "/engine.patch", atomically: true, encoding: .utf8) }
        XCTAssertThrowsError(try GameArchiveLibrary.add(changed, root: root)) { XCTAssertEqual($0 as? GameArchive.Problem, .digest("engine.patch")) }
        let extra = try makeArchive("u") { try "x".write(toFile: $0 + "/extra.txt", atomically: true, encoding: .utf8) }
        XCTAssertThrowsError(try GameArchiveLibrary.add(extra, root: root)) { XCTAssertEqual($0 as? GameArchive.Problem, .unlisted("extra.txt")) }
        try write(tmp + "/not.nxgame", "not a zip")
        XCTAssertThrowsError(try GameArchiveLibrary.add(tmp + "/not.nxgame", root: root)) { XCTAssertEqual($0 as? GameArchive.Problem, .unpack) }
        XCTAssertTrue(GameArchiveLibrary.load(root: root).isEmpty)
    }

    // MARK: Checks

    func testCheck() throws {
        let m = GameArchive.Manifest(titleID: Self.tid, name: "A", updates: [65536], base: .init(pin: "p1", engineID: "p1-aaaaaaaaaaaa"))
        let same = GameArchive.EngineIdentity(engineID: "p1-aaaaaaaaaaaa", pin: "p1")
        let tid = UInt64(Self.tid, radix: 16)!
        XCTAssertEqual(GameArchive.check(m, baseTitleID: tid, updateVersion: 65536, engine: same), .warnings([]))
        XCTAssertEqual(GameArchive.check(m, baseTitleID: UInt64(Self.other, radix: 16)!, updateVersion: 65536, engine: same),
                       .otherGame(Self.tid, Self.other))
        XCTAssertEqual(GameArchive.check(m, baseTitleID: nil, updateVersion: 65536, engine: same), .warnings([.unknownTitle]))
        XCTAssertEqual(GameArchive.check(m, baseTitleID: tid, updateVersion: 0, engine: same), .warnings([.otherUpdate(0, [65536])]))
        XCTAssertEqual(GameArchive.check(m, baseTitleID: tid, updateVersion: nil, engine: same), .warnings([]))   // a name without a version
        let other = GameArchive.EngineIdentity(engineID: "p1-bbbbbbbbbbbb", pin: "p1")
        XCTAssertEqual(GameArchive.check(m, baseTitleID: tid, updateVersion: 65536, engine: other),
                       .warnings([.otherEngine("p1-aaaaaaaaaaaa", "p1-bbbbbbbbbbbb")]))
        // without an engine ID in the archive, the upstream commit is compared
        var pinOnly = m; pinOnly.base = .init(pin: "p1")
        XCTAssertEqual(GameArchive.check(pinOnly, baseTitleID: tid, updateVersion: 65536, engine: other), .warnings([]))
        XCTAssertEqual(GameArchive.check(pinOnly, baseTitleID: tid, updateVersion: 65536, engine: .init(engineID: "", pin: "p2")),
                       .warnings([.otherEngine("p1", "p2")]))
    }

    func testEngineIdentityOfAnInstalledEngine() throws {
        let e = try makeEngine()
        XCTAssertEqual(GameArchive.EngineIdentity.of(repo: e), .init(engineID: "p1-aaaaaaaaaaaa", pin: "p1"))
    }

    // MARK: The build's engine

    func testTreeHasTheGameAndThePatchAndLeavesTheEngineAlone() throws {
        let e = try makeEngine()
        let s = try GameArchiveLibrary.add(try makeArchive(), root: tmp + "/kept")
        let tree = try GameArchiveTree.make(engineRoot: e, archive: s, into: tmp + "/trees/\(Self.tid)/engine")
        XCTAssertEqual(try String(contentsOfFile: tree + "/dm/tools/sdk_patches.py", encoding: .utf8), "RULES = [1, 2]\n")
        XCTAssertEqual(try String(contentsOfFile: e + "/dm/tools/sdk_patches.py", encoding: .utf8), "RULES = [1]\n")
        XCTAssertTrue(fm.fileExists(atPath: tree + "/dm/games/\(Self.tid)/game.tsv"))
        XCTAssertTrue(fm.fileExists(atPath: tree + "/dm/games/game.py"))
        XCTAssertTrue(fm.fileExists(atPath: tree + "/scripts/build_ipa_from_nsp.py"))
        XCTAssertTrue(fm.fileExists(atPath: tree + "/.engine-id"))
        XCTAssertFalse(fm.fileExists(atPath: tree + "/dm/games/\(Self.other)"))
        XCTAssertFalse(fm.fileExists(atPath: tree + "/.iosdd"))
        XCTAssertEqual(try String(contentsOfFile: tree + "/dm/fork_patches.txt", encoding: .utf8),
                       "0001-a.patch\n" + GameArchive.forkPatchLine(titleID: Self.tid, sha256: s.sha256) + "\n")
        XCTAssertFalse(fm.fileExists(atPath: e + "/dm/games/\(Self.tid)"))
        XCTAssertEqual(try String(contentsOfFile: e + "/dm/fork_patches.txt", encoding: .utf8), "0001-a.patch\n")
        // made again: replaced, not patched twice
        try GameArchiveTree.make(engineRoot: e, archive: s, into: tree)
        XCTAssertEqual(try String(contentsOfFile: tree + "/dm/tools/sdk_patches.py", encoding: .utf8), "RULES = [1, 2]\n")
    }

    func testTreeStopsWhenThePatchDoesNotApply() throws {
        let e = try makeEngine()
        try write(e + "/dm/tools/sdk_patches.py", "RULES = [7]\n")
        let s = try GameArchiveLibrary.add(try makeArchive(), root: tmp + "/kept")
        XCTAssertThrowsError(try GameArchiveTree.make(engineRoot: e, archive: s, into: tmp + "/tree")) { error in
            guard case GameArchiveTree.Problem.patch(let output)? = error as? GameArchiveTree.Problem else { return XCTFail("\(error)") }
            XCTAssertTrue(output.contains("sdk_patches.py"), output)
        }
    }
}
