import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

/// #214: which engine the launcher builds from. A checkout of this repository builds from its engine/ (synced first when it is stale or
/// missing, there is no committed tree), a folder that is an engine tree itself (an installed release's engine) from that folder.
/// The stamp key matches tools/engine.py's.
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

    func testAnEngineTreeIsItsOwnRoot() throws {
        try touch(EngineLayout.marker)
        XCTAssertTrue(BuildModel.isRepo(repo))
        XCTAssertEqual(EngineLayout.root(repo), repo)
        XCTAssertFalse(EngineLayout.isStale(repo))
        XCTAssertFalse(EngineLayout.needsSyncBeforeBuild(repo))
    }

    func testTheBuildScriptComesFromTheCheckoutsEngine() throws {
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

    func testAStaleEngineIsStillTheCheckoutsEngineAndTheBuildSyncsItFirst() throws {
        try newLayout()
        try syncedEngine()
        try touch("patches/0002-b.patch", "changed\n")
        XCTAssertTrue(EngineLayout.isStale(repo))
        XCTAssertEqual(EngineLayout.root(repo), repo + "/engine")   // there is no committed tree to fall back to
        XCTAssertTrue(EngineLayout.needsSyncBeforeBuild(repo))
    }

    func testACommitInEngineMakesItStale() throws {
        try newLayout()
        try syncedEngine()
        try touch("engine/.git/refs/heads/nx2apple", String(repeating: "c", count: 40) + "\n")
        XCTAssertTrue(EngineLayout.isStale(repo))
    }

    func testACheckoutWithoutAnEngineIsSyncedBeforeABuild() throws {
        try newLayout()
        XCTAssertTrue(BuildModel.isRepo(repo))
        XCTAssertTrue(EngineLayout.needsSyncBeforeBuild(repo))
        XCTAssertTrue(BuildModel.repoSupportsWorkDir(repo))   // the fork's engine always has --work-dir
        XCTAssertEqual(EngineLayout.root(repo), repo + "/engine")
        try syncedEngine()
        XCTAssertFalse(EngineLayout.needsSyncBeforeBuild(repo))
    }

    func testTheSyncCommandHasNoSeed() {
        XCTAssertEqual(EngineLayout.syncArguments(repo: "/c", python: "py"), ["py", "/c/tools/engine.py", "sync"])
    }

    // ---- the online sync of a release app (no engine in the bundle)

    private var toolSource: String {
        let tools = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("tools/engine.py")
        return (try? String(contentsOf: tools, encoding: .utf8)) ?? ""
    }

    func testAFailedFetchIsTheOfflineRowAndAnyOtherStopIsTheGeneralOne() {
        XCTAssertTrue(toolSource.contains("cannot fetch "), "tools/engine.py no longer says \"cannot fetch\": update EngineLayout.failureKind")
        let offline = "engine: cannot fetch aaaaaaaaaaaa from https://github.com/seedds/nxnative.git: fatal: unable to access: Could not resolve host\n"
        XCTAssertEqual(EngineLayout.failureKind(offline), .engineOffline)
        XCTAssertEqual(EngineLayout.failureKind("0003-x.patch does not apply to the pin aaaaaaaaaaaa\n"), .engineSync)
        XCTAssertEqual(EngineLayout.failureKind(""), .engineSync)
    }

    /// A checkout whose tools/engine.py is `script` (a stand-in for the real one) and a model on it.
    private func model(engineScript script: String) throws -> BuildModel {
        try newLayout()
        try touch("tools/engine.py", script)
        let m = BuildModel()
        m.repoPath = repo
        m.pythonPath = "/usr/bin/python3"
        return m
    }

    private func waitForSync(_ m: BuildModel, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(20)
        while m.engineSyncing && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertFalse(m.engineSyncing, "the sync did not end", file: file, line: line)
    }

    func testNoNetworkShowsTheStatusThenTheOfflineRowAndRetryRunsTheSyncAgain() throws {
        let counter = root.appendingPathComponent("runs.txt").path
        let m = try model(engineScript: """
            import sys
            open(\(String(reflecting: counter)), 'a').write('x')
            print('engine: cannot fetch aaaaaaaaaaaa from https://github.com/seedds/nxnative.git: Could not resolve host: github.com')
            sys.exit(2)
            """)
        XCTAssertNil(m.engineFailure)
        m.syncEngine()
        XCTAssertTrue(m.engineSyncing, "the status line shows while the engine is fetched")
        waitForSync(m)
        XCTAssertEqual(m.engineFailure?.kind, .engineOffline)
        XCTAssertTrue(m.logTail.contains("cannot fetch"), "the log has the tool's line")
        m.retryEngineSync()
        XCTAssertNil(m.engineFailure, "Try again clears the row")
        XCTAssertTrue(m.engineSyncing)
        waitForSync(m)
        XCTAssertEqual(m.engineFailure?.kind, .engineOffline)
        XCTAssertEqual(try String(contentsOfFile: counter, encoding: .utf8), "xx", "the retry ran the tool again")
    }

    func testASyncThatWorksLeavesNoRow() throws {
        let m = try model(engineScript: "print('engine: ready')\n")
        m.engineFailure = BuildFailure(kind: .engineOffline, gameName: nil)
        m.syncEngine()
        waitForSync(m)
        XCTAssertNil(m.engineFailure)
    }

    func testOfflineRowsHaveARetryButtonAndTheStatusLineHasText() {
        for k in [BuildFailureKind.engineOffline, .engineSync] {
            XCTAssertNotNil(L10n.table[k.whatKey]); XCTAssertNotNil(L10n.table[k.nextKey])
        }
        let en = L10n.table["fail.engineOffline.next"]?.en ?? ""
        for w in ["internet connection", "github.com", "Try again"] { XCTAssertTrue(en.contains(w), w) }
        XCTAssertNotNil(L10n.table["engine.syncing"]); XCTAssertNotNil(L10n.sv["engine.syncing"])
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
