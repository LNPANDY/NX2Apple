import XCTest
@testable import NXCore

/// LNPANDY/NX2Apple#427: the shared app's folder moves out of the output folder, once, and only when that is safe. Every test
/// runs in a temporary folder with its own `home`, so the real Application Support folder is never touched.
final class ShellRootMigrationTests: XCTestCase {
    private let fm = FileManager.default
    private var base: String!
    private var home: String { base + "/home" }
    private var out: String { base + "/Games" }
    private var oldRoot: String { out + "/NX2Apple-shell" }
    private var newRoot: String { home + "/Library/Application Support/NX2Apple/shell" }

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.path + "/nspb-migrate-" + UUID().uuidString
        try fm.createDirectory(atPath: out, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(atPath: base) }

    private func defaults() -> UserDefaults { TestDefaults.make("nspb-migrate") }

    /// An old shell folder: a mirrored framework (listed in shell.json), a framework in a build folder, and the other folders.
    @discardableResult
    private func makeOldShell(extra: [String: Any] = [:]) throws -> (mirror: String, build: String) {
        let mirror = oldRoot + "/frameworks/DmGame0100AAAA.framework"
        let build = out + "/build/DmGame0100BBBB.framework"
        for dir in [mirror, build, oldRoot + "/derived-data", oldRoot + "/project"] {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        try Data("shader".utf8).write(to: URL(fileURLWithPath: mirror + "/game.manifest.json"))
        var json: [String: Any] = ["bundleID": "org.nxnative.shell.TEAM", "team": "TEAM",
                                   "games": [["titleID": "0100AAAA", "name": "A", "framework": mirror],
                                             ["titleID": "0100BBBB", "name": "B", "framework": build]]]
        for (k, v) in extra { json[k] = v }
        try JSONSerialization.data(withJSONObject: json).write(to: URL(fileURLWithPath: oldRoot + "/shell.json"))
        return (mirror, build)
    }

    func testAnOldFolderMovesAndShellJsonFollows() throws {
        let (_, build) = try makeOldShell(extra: ["futureKey": 7])
        let d = defaults()
        d.set(oldRoot, forKey: "shellRoot")
        XCTAssertEqual(ShellLibrary.resolveRoot(defaults: d, parent: out, home: home), newRoot)
        XCTAssertEqual(d.string(forKey: "shellRoot"), newRoot)
        XCTAssertFalse(fm.fileExists(atPath: oldRoot), "moved, not copied")
        XCTAssertTrue(fm.fileExists(atPath: newRoot + "/frameworks/DmGame0100AAAA.framework/game.manifest.json"))
        XCTAssertTrue(fm.fileExists(atPath: newRoot + "/derived-data"))
        let library = ShellLibrary.load(root: newRoot)
        XCTAssertEqual(library.games.map(\.framework), [newRoot + "/frameworks/DmGame0100AAAA.framework", build],
                       "the mirror follows, a framework in a build folder stays")
        XCTAssertEqual(library.team, "TEAM")
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: newRoot + "/shell.json"))) as? [String: Any]
        XCTAssertEqual(raw?["futureKey"] as? Int, 7, "a key this version does not know is kept")
    }

    func testTheSecondCallLeavesTheNewFolderAlone() throws {
        try makeOldShell()
        let d = defaults()
        d.set(oldRoot, forKey: "shellRoot")
        _ = ShellLibrary.resolveRoot(defaults: d, parent: out, home: home)
        try Data("later".utf8).write(to: URL(fileURLWithPath: newRoot + "/frameworks/marker"))
        XCTAssertEqual(ShellLibrary.resolveRoot(defaults: d, parent: out, home: home), newRoot)
        XCTAssertTrue(fm.fileExists(atPath: newRoot + "/frameworks/marker"))
    }

    /// Defaults that were reset leave the old folder without a saved root: older versions derived it from the output folder.
    func testAnOldFolderWithNoSavedRootIsFoundNextToTheOutputFolder() throws {
        try makeOldShell()
        XCTAssertEqual(ShellLibrary.resolveRoot(defaults: defaults(), parent: out, home: home), newRoot)
        XCTAssertTrue(fm.fileExists(atPath: newRoot + "/shell.json"))
        XCTAssertFalse(fm.fileExists(atPath: oldRoot))
    }

    func testARootThePlayerChoseIsNotMoved() throws {
        let chosen = out + "/MyCache"
        try fm.createDirectory(atPath: chosen, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: chosen + "/shell.json"))
        let d = defaults()
        d.set(chosen, forKey: "shellRoot")
        XCTAssertEqual(ShellLibrary.resolveRoot(defaults: d, parent: out, home: home), chosen)
        XCTAssertTrue(fm.fileExists(atPath: chosen + "/shell.json"))
        XCTAssertFalse(fm.fileExists(atPath: newRoot))
    }

    func testAFolderThatIsAlreadyThereIsNeverOverwritten() throws {
        try makeOldShell()
        try fm.createDirectory(atPath: newRoot, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: URL(fileURLWithPath: newRoot + "/keep"))
        let d = defaults()
        d.set(oldRoot, forKey: "shellRoot")
        XCTAssertEqual(ShellLibrary.resolveRoot(defaults: d, parent: out, home: home), oldRoot, "the old folder keeps being used")
        XCTAssertTrue(fm.fileExists(atPath: newRoot + "/keep"))
        XCTAssertTrue(fm.fileExists(atPath: oldRoot + "/shell.json"))
        XCTAssertEqual(d.string(forKey: "shellRoot"), oldRoot)
    }

    func testAShellJsonThatCannotBeReadLeavesTheFolder() throws {
        try makeOldShell()
        try Data("{ not json".utf8).write(to: URL(fileURLWithPath: oldRoot + "/shell.json"))
        let d = defaults()
        d.set(oldRoot, forKey: "shellRoot")
        XCTAssertEqual(ShellLibrary.resolveRoot(defaults: d, parent: out, home: home), oldRoot)
        XCTAssertTrue(fm.fileExists(atPath: oldRoot + "/frameworks/DmGame0100AAAA.framework"))
        XCTAssertFalse(fm.fileExists(atPath: newRoot))
    }

    func testAFolderWithFilesButNoShellJsonIsNotOurs() throws {
        try fm.createDirectory(atPath: oldRoot, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: oldRoot + "/holiday.mov"))
        let d = defaults()
        d.set(oldRoot, forKey: "shellRoot")
        XCTAssertEqual(ShellLibrary.resolveRoot(defaults: d, parent: out, home: home), oldRoot)
        XCTAssertTrue(fm.fileExists(atPath: oldRoot + "/holiday.mov"))
    }

    func testASymbolicLinkIsNotFollowed() throws {
        let target = base + "/Elsewhere"
        try fm.createDirectory(atPath: target, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: target + "/shell.json"))
        try fm.createSymbolicLink(atPath: oldRoot, withDestinationPath: target)
        let d = defaults()
        d.set(oldRoot, forKey: "shellRoot")
        XCTAssertEqual(ShellLibrary.resolveRoot(defaults: d, parent: out, home: home), oldRoot)
        XCTAssertTrue(fm.fileExists(atPath: target + "/shell.json"))
    }

    /// A player who deleted the folder has nothing to move. A folder whose own parent is gone (an unplugged drive) may come back.
    func testAMissingFolderMovesOnOnlyWhenItsParentIsThere() throws {
        let d = defaults()
        d.set(oldRoot, forKey: "shellRoot")
        XCTAssertEqual(ShellLibrary.resolveRoot(defaults: d, parent: out, home: home), newRoot)

        let unplugged = base + "/Volumes/Games/NX2Apple-shell"
        d.set(unplugged, forKey: "shellRoot")
        XCTAssertEqual(ShellLibrary.resolveRoot(defaults: d, parent: out, home: home), unplugged)
        XCTAssertEqual(d.string(forKey: "shellRoot"), unplugged)
    }

    func testAnEmptyOldFolderMoves() throws {
        try fm.createDirectory(atPath: oldRoot, withIntermediateDirectories: true)
        let d = defaults()
        d.set(oldRoot, forKey: "shellRoot")
        XCTAssertEqual(ShellLibrary.resolveRoot(defaults: d, parent: out, home: home), newRoot)
        XCTAssertTrue(fm.fileExists(atPath: newRoot))
        XCTAssertFalse(fm.fileExists(atPath: oldRoot))
    }
}
