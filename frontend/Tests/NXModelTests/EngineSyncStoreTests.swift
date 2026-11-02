import XCTest
@testable import NXModel
@testable import NXCore

/// `EngineSyncStore` without SwiftUI: a fake `ProcessRunner` stands in for `tools/engine.py sync`, the checkouts and the engine store are
/// folders in a temporary directory and the defaults are a suite of their own. The model's wiring is tested in NX2AppleTests
/// (EngineLayoutTests runs a real script, EngineUpdateModelTests the release app's rules through `LauncherStores`).
@MainActor final class EngineSyncStoreTests: XCTestCase {
    private final class FakeRepo: RepoLocation {
        var path = ""
        var isRepo: Bool { RepoLayout.isRepo(path) }
        var isGit = true
    }

    private final class FakePython: PythonLocation {
        var pythonPath = "/usr/bin/python3"
    }

    private var temporary: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private let runner = FakeProcessRunner()
    private let localizer = Localizer(.en)
    private let repo = FakeRepo()
    private let python = FakePython()
    private var log: [String] = []
    private var building = false
    private var autoUpdate = true
    private var movedTo: [String] = []

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxmodel-engine-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        suite = "nxmodel-engine-tests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporary)
        defaults.removePersistentDomain(forName: suite)
    }

    private func id(_ c: Character) -> String { String(repeating: c, count: 40) + "-0123456789ab" }

    private func touch(_ rel: String, in dir: URL, _ text: String = "x") throws {
        let url = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A checkout that can make engine/ and has none: stale.
    private func staleCheckout() throws -> String {
        let dir = temporary.appendingPathComponent("checkout")
        try touch("tools/engine.py", in: dir)
        try touch(".upstream-ref", in: dir, String(repeating: "a", count: 40) + "\n")
        try touch("patches/series", in: dir, "0001-a.patch\n")
        try touch("patches/0001-a.patch", in: dir)
        return dir.path
    }

    /// A complete engine tree in the store, so the store takes it for usable.
    private func install(_ engineID: String, in store: EngineStore) throws {
        let dir = try XCTUnwrap(store.directory(for: engineID))
        for file in EngineStore.requiredFiles { try touch(file, in: dir) }
        try touch(EngineStore.idFile, in: dir, engineID)
    }

    private func makeStore(bundle: URL? = nil, engines: EngineStore? = nil) -> EngineSyncStore {
        EngineSyncStore(localizer: localizer, runner: runner, repo: repo, python: python,
                        engineStore: engines ?? EngineStore(root: temporary.appendingPathComponent("engines")),
                        bundle: bundle, defaults: defaults, appVersion: "1.2.3",
                        setRepoPath: { [unowned self] in repo.path = $0; movedTo.append($0) },
                        buildRunning: { [unowned self] in building }, autoUpdate: { [unowned self] in autoUpdate },
                        log: { [unowned self] in log.append($0) })
    }

    private func t(_ key: String) -> String { localizer.t(key) }

    // ---- The sync of a checkout's engine ----

    func testAStaleEngineIsSyncedWithTheChosenPythonAndLogged() async throws {
        repo.path = try staleCheckout()
        runner.streamAnswer = { _ in (["engine: ready"], true) }
        let store = makeStore()
        let task = store.syncEngine()
        XCTAssertTrue(store.syncing, "the status line shows from the call on")
        XCTAssertNil(store.failure)
        await task.value
        XCTAssertFalse(store.syncing)
        XCTAssertNil(store.failure)
        XCTAssertEqual(runner.launches.map(\.arguments), [[repo.path + "/tools/engine.py", "sync"]])
        XCTAssertEqual(runner.launches.first?.executable, "/usr/bin/python3")
        XCTAssertEqual(log.first, "$ python3 tools/engine.py sync\n")
        try await Task.sleep(nanoseconds: 50_000_000)   // the lines reach the log through the main queue
        XCTAssertTrue(log.contains("engine: ready\n"))
    }

    func testACurrentEngineRunsNothingAndClearsTheRow() throws {
        repo.path = temporary.path   // no tools/engine.py: nothing to make
        let store = makeStore()
        store.failure = BuildFailure(kind: .engineOffline, gameName: nil)
        var answers: [Bool] = []
        store.syncEngine { answers.append($0) }
        XCTAssertEqual(answers, [true], "then runs at once")
        XCTAssertNil(store.failure)
        XCTAssertFalse(store.syncing)
        XCTAssertTrue(runner.launches.isEmpty)
    }

    func testAFailedFetchIsTheOfflineRowAndAnyOtherStopIsTheGeneralOne() async throws {
        repo.path = try staleCheckout()
        let store = makeStore()
        runner.streamAnswer = { _ in (["engine: cannot fetch aaaaaaaaaaaa from https://github.com/seedds/nxnative.git: Could not resolve host"], false) }
        await store.syncEngine().value
        XCTAssertEqual(store.failure?.kind, .engineOffline)
        runner.streamAnswer = { _ in (["0003-x.patch does not apply to the pin aaaaaaaaaaaa"], false) }
        await store.syncEngine().value
        XCTAssertEqual(store.failure?.kind, .engineSync)
    }

    func testTryAgainClearsTheRowAndRunsTheSyncAgain() async throws {
        repo.path = try staleCheckout()
        runner.streamAnswer = { _ in (["engine: cannot fetch x"], false) }
        let store = makeStore()
        await store.syncEngine().value
        XCTAssertEqual(store.failure?.kind, .engineOffline)
        let retry = store.retrySync()
        XCTAssertNil(store.failure, "Try again clears the row")
        XCTAssertTrue(store.syncing)
        await retry.value
        XCTAssertEqual(store.failure?.kind, .engineOffline)
        XCTAssertEqual(runner.launches.count, 2, "the retry ran the tool again")
    }

    func testASyncThatWorksLeavesNoRow() async throws {
        repo.path = try staleCheckout()
        let store = makeStore()
        store.failure = BuildFailure(kind: .engineOffline, gameName: nil)
        await store.syncEngine().value
        XCTAssertNil(store.failure)
    }

    func testACallDuringASyncWaitsForItAndOneMoreRunFollows() async throws {
        repo.path = try staleCheckout()
        let store = makeStore()
        var answers: [String] = []
        let first = store.syncEngine { answers.append("first \($0)") }
        store.syncEngine { answers.append("second \($0)") }   // the build asks while the launch sync runs
        await first.value
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(runner.launches.count, 2, "what changed during the run is checked once more")
        XCTAssertEqual(answers.sorted(), ["first true", "second true"])
        XCTAssertFalse(store.syncing)
    }

    // ---- The release app's engine ----

    func testAnEngineInstalledDuringABuildWaitsAndTheEndOfTheBuildSwitches() throws {
        let engines = EngineStore(root: temporary.appendingPathComponent("engines"))
        try install(id("a"), in: engines)
        let store = makeStore(bundle: temporary, engines: engines)
        repo.path = "/before"
        building = true
        store.applyOutcome(.installed(.init(id: id("a"), version: "0.7.4"), .download), channel: .stable, quiet: false)
        XCTAssertEqual(repo.path, "/before", "the running build keeps its tools")
        XCTAssertEqual(store.pendingEngine?.engine.id, id("a"))
        XCTAssertEqual(store.status, String(format: t("engine.waitsForBuild"), "0.7.4"))
        store.applyPendingEngine()
        XCTAssertNotNil(store.pendingEngine, "still running")
        building = false
        store.applyPendingEngine()
        XCTAssertNil(store.pendingEngine)
        XCTAssertEqual(repo.path, engines.directory(for: id("a"))?.path)
        XCTAssertEqual(store.selection.engineID, id("a"))
        XCTAssertEqual(store.selection.version, "0.7.4")
        XCTAssertEqual(EngineSelection.load(defaults).engineID, id("a"), "the selection is saved")
        XCTAssertEqual(store.status, String(format: t("engine.installed"), "0.7.4"))
    }

    func testNoCheckRunsWhileABuildRuns() {
        let store = makeStore(bundle: temporary)
        building = true
        store.checkForUpdate()
        XCTAssertFalse(store.busy)
        XCTAssertEqual(store.status, t("engine.waitForBuild"))
        store.checkForUpdate(automatic: true)
        XCTAssertFalse(store.busy)
    }

    func testALauncherBuiltFromTheRepositoryNeverChecksForAnEngine() {
        let store = makeStore(bundle: nil)
        XCTAssertFalse(store.usesEngineStore)
        store.checkForUpdate()
        XCTAssertFalse(store.busy)
        XCTAssertEqual(store.status, "")
    }

    func testTheLaunchCheckIsQuietWhenOffline() {
        let store = makeStore(bundle: temporary)
        store.applyOutcome(.failed(.network), channel: .stable, quiet: true)
        XCTAssertEqual(store.status, "")
        store.applyOutcome(.failed(.digest), channel: .stable, quiet: true)
        XCTAssertEqual(store.status, t("engine.fail.digest"))
        store.applyOutcome(.failed(.noManifest), channel: .experimental, quiet: false)
        XCTAssertEqual(store.status, "The Experimental channel has no engine for this app version yet")
    }

    func testAnAvailableEngineIsOfferedAndTheCurrentOneClearsTheOffer() {
        let store = makeStore(bundle: temporary)
        store.applyOutcome(.available(.init(id: id("b"), version: "0.8.0")), channel: .stable, quiet: true)
        XCTAssertEqual(store.available?.version, "0.8.0")
        XCTAssertEqual(store.status, String(format: t("engine.available"), "0.8.0"))
        store.applyOutcome(.current(.init(id: id("b"), version: "0.8.0")), channel: .experimental, quiet: false)
        XCTAssertNil(store.available)
        XCTAssertEqual(store.selection.channel, .experimental)
        XCTAssertEqual(EngineSelection.load(defaults).channel, .experimental)
        XCTAssertEqual(store.status, String(format: t("engine.upToDate"), "0.8.0"))
    }

    func testChangingTheChannelAsksFirst() {
        let store = makeStore(bundle: temporary)
        store.selection.channel = .stable
        store.requestChannel(.stable)
        XCTAssertNil(store.confirmingChannel, "the same channel asks nothing")
        store.requestChannel(.experimental)
        XCTAssertEqual(store.confirmingChannel, .experimental)
        XCTAssertEqual(store.selection.channel, .stable, "nothing changes before the answer")
        store.cancelChannel()
        XCTAssertNil(store.confirmingChannel)
        XCTAssertEqual(store.selection.channel, .stable)
    }

    func testNoChannelSwitchIsAskedForWhileABuildRuns() {
        let store = makeStore(bundle: temporary)
        building = true
        store.requestChannel(.experimental)
        XCTAssertNil(store.confirmingChannel)
    }

    func testTheLaunchUsesTheSelectedEngineInTheStoreAndPointsTheBuildAtIt() throws {
        let engines = EngineStore(root: temporary.appendingPathComponent("engines"))
        let bundled = temporary.appendingPathComponent("bundled")
        for file in EngineStore.requiredFiles { try touch(file, in: bundled) }
        try touch(EngineStore.idFile, in: bundled, id("a"))
        try install(id("a"), in: engines)
        EngineSelection(channel: .stable, engineID: id("a"), version: "1.2.3", previousID: "").save(defaults)
        autoUpdate = false
        building = true   // the launch check then ends at once, without the network
        let store = makeStore(bundle: bundled, engines: engines)
        store.prepareEngine()
        XCTAssertEqual(repo.path, engines.directory(for: id("a"))?.path)
        XCTAssertFalse(store.busy)
    }

    func testTheDetailNamesTheVersionAndThePin() {
        let store = makeStore(bundle: temporary)
        XCTAssertEqual(store.detail, t("engine.none"))
        store.selection = EngineSelection(channel: .stable, engineID: id("c"), version: "", previousID: "")
        XCTAssertEqual(store.detail, String(format: t("engine.detail"), "?", "cccccccc"))
        store.selection.version = "1.2.3"
        XCTAssertEqual(store.detail, String(format: t("engine.detail"), "1.2.3", "cccccccc"))
    }
}
