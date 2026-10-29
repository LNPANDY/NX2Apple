import XCTest
@testable import NSPortBuilder

/// #214: which engine the launcher builds from. engine/ when synced and current, the committed tree of a checkout from before the
/// switch, and engine/ as the only choice (with a sync first) once the committed tree is gone. The stamp key matches tools/engine.py's.
final class EngineLayoutTests: XCTestCase {
    private var root: URL!
    private var repo: String { root.path }
    private let pin = String(repeating: "a", count: 40)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nx2apple-engine214-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func touch(_ rel: String, _ text: String = "x") throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func newLayout() throws {
        try touch("tools/engine.py")
        try touch(".upstream-ref", pin + "\n")
        try touch("patches/series", "# order\n0001-a.patch\n\n0002-b.patch  # trailing note\n")
        try touch("patches/0001-a.patch", "patch a\n")
        try touch("patches/0002-b.patch", "patch b\n")
    }

    private func syncedEngine() throws {
        let head = String(repeating: "b", count: 40)
        try touch("engine/" + EngineLayout.marker)
        try touch("engine/.git/HEAD", "ref: refs/heads/nx2apple\n")
        try touch("engine/.git/refs/heads/nx2apple", head + "\n")
        try touch("engine/.git/nx2apple-stamp", "nx2apple-engine 1\npin \(pin)\nkey \(EngineLayout.stampKey(repo)!)\nhead \(head)\n")
    }

    func testACheckoutFromBeforeTheSwitchUsesItsCommittedTree() throws {
        try touch(EngineLayout.marker)
        XCTAssertTrue(BuildModel.isRepo(repo))
        XCTAssertEqual(EngineLayout.root(repo), repo)
        XCTAssertFalse(EngineLayout.isStale(repo))
        XCTAssertFalse(EngineLayout.needsSyncBeforeBuild(repo))
    }

    func testACurrentEngineWinsAndTheBuildScriptComesFromIt() throws {
        try touch(EngineLayout.marker)
        try newLayout()
        try syncedEngine()
        XCTAssertFalse(EngineLayout.isStale(repo))
        XCTAssertEqual(EngineLayout.root(repo), repo + "/engine")
        XCTAssertEqual(BuildModel.missingTools(in: repo), BuildModel.requiredTools)   // looked for under engine/, which lacks them here
        try touch("engine/scripts/build_ipa_from_nsp.py", "p.add_argument('--work-dir')\n")
        try touch("engine/dm/tools/romfs_image.py")
        XCTAssertEqual(BuildModel.missingTools(in: repo), [])
        XCTAssertTrue(BuildModel.repoSupportsWorkDir(repo))
    }

    func testAStaleEngineFallsBackToTheCommittedTree() throws {
        try touch(EngineLayout.marker)
        try newLayout()
        try syncedEngine()
        try touch("patches/0002-b.patch", "changed\n")
        XCTAssertTrue(EngineLayout.isStale(repo))
        XCTAssertEqual(EngineLayout.root(repo), repo)
        XCTAssertFalse(EngineLayout.needsSyncBeforeBuild(repo))
    }

    func testACommitInEngineMakesItStale() throws {
        try newLayout()
        try syncedEngine()
        try touch("engine/.git/refs/heads/nx2apple", String(repeating: "c", count: 40) + "\n")
        XCTAssertTrue(EngineLayout.isStale(repo))
    }

    func testWithoutACommittedTreeTheEngineIsSyncedBeforeABuild() throws {
        try newLayout()
        XCTAssertTrue(BuildModel.isRepo(repo))
        XCTAssertTrue(EngineLayout.needsSyncBeforeBuild(repo))
        XCTAssertTrue(BuildModel.repoSupportsWorkDir(repo))   // the fork's engine always has --work-dir
        XCTAssertEqual(EngineLayout.root(repo), repo + "/engine")
        try syncedEngine()
        XCTAssertFalse(EngineLayout.needsSyncBeforeBuild(repo))
    }

    func testTheSyncCommandPassesTheAppsSeed() {
        XCTAssertEqual(EngineLayout.syncArguments(repo: "/c", python: "py", seed: nil), ["py", "/c/tools/engine.py", "sync"])
        XCTAssertEqual(EngineLayout.syncArguments(repo: "/c", python: "py", seed: "/A.app/Contents/Resources/engine.git"),
                       ["py", "/c/tools/engine.py", "--seed", "/A.app/Contents/Resources/engine.git", "sync"])
    }

    /// The launcher's key and tools/engine.py's agree, so a sync's stamp reads as current here.
    func testTheStampKeyMatchesTheTool() throws {
        try newLayout()
        let tools = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("tools").path
        let code = "import sys; sys.path.insert(0, sys.argv[1]); import engine, pathlib; print(engine.stamp_key(pathlib.Path(sys.argv[2])))"
        let r = BuildModel.runQuiet(["/usr/bin/env", "python3", "-c", code, tools, repo], env: ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"])
        try XCTSkipUnless(r.ok, "python3 did not run: \(r.out)")
        XCTAssertEqual(r.out.trimmingCharacters(in: .whitespacesAndNewlines), EngineLayout.stampKey(repo))
    }
}
