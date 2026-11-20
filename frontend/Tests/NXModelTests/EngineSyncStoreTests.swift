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

    private final class FakeTransport: EngineTransport {
        var files: [String: Data] = [:]
        var failing = false
        var downloads: [String] = []
        func data(from url: URL) -> EngineFetch<Data> {
            if failing { return .failed }
            return files[url.absoluteString].map { .ok($0) } ?? .missing
        }
        func download(from url: URL, to destination: URL) -> Bool {
            downloads.append(url.absoluteString)
            guard !failing, let data = files[url.absoluteString] else { return false }
            return (try? data.write(to: destination)) != nil
        }
    }

    private let stableBase = "https://github.com/LNPANDY/NX2Apple/releases/download/v"
    private let experimentalBase = "https://github.com/LNPANDY/NX2Apple/releases/download/engine-experimental/"

    private var temporary: URL!
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
        defaults = TestDefaults.make("nxmodel-engine-tests")
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporary)
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
    private func install(_ engineID: String, in store: EngineStore, upstreamDate: String? = nil) throws {
        let dir = try XCTUnwrap(store.directory(for: engineID))
        for file in EngineStore.requiredFiles { try touch(file, in: dir) }
        try touch(EngineStore.idFile, in: dir, engineID)
        if let upstreamDate { try touch(EngineStore.upstreamDateFile, in: dir, upstreamDate + "\n") }
    }

    private func makeBundled(_ engineID: String, upstreamDate: String? = nil) throws -> URL {
        let dir = temporary.appendingPathComponent("bundled-" + UUID().uuidString)
        for file in EngineStore.requiredFiles { try touch(file, in: dir) }
        try touch(EngineStore.idFile, in: dir, engineID)
        if let upstreamDate { try touch(EngineStore.upstreamDateFile, in: dir, upstreamDate + "\n") }
        return dir
    }

    private func makeStore(bundle: URL? = nil, engines: EngineStore? = nil,
                           transport: EngineTransport = URLSessionEngineTransport(),
                           appVersion: String = "1.2.3",
                           publicKey: String = EngineManifest.publicKey) -> EngineSyncStore {
        EngineSyncStore(localizer: localizer, runner: runner, repo: repo, python: python,
                        engineStore: engines ?? EngineStore(root: temporary.appendingPathComponent("engines")),
                        transport: transport,
                        bundle: bundle, defaults: defaults, appVersion: appVersion, publicKey: publicKey,
                        setRepoPath: { [unowned self] in repo.path = $0; movedTo.append($0) },
                        buildRunning: { [unowned self] in building }, autoUpdate: { [unowned self] in autoUpdate },
                        log: { [unowned self] in log.append($0) })
    }

    private func publish(_ t: FakeTransport, id: String, channel: EngineChannel, version: String,
                         base: String, upstreamDate: String? = nil) throws {
        let tree = try makeBundled(id, upstreamDate: upstreamDate)
        let zipURL = temporary.appendingPathComponent(UUID().uuidString + ".zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", tree.path, zipURL.path]
        try ditto.run(); ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)
        let archive = try Data(contentsOf: zipURL)
        let digest = try XCTUnwrap(AppUpdate.sha256(of: zipURL))
        let pin = String(id.prefix(40))
        let dateField = upstreamDate.map { ",\"upstream_date\":\"\($0)\"" } ?? ""
        t.files[base + "latest.json"] = Data("""
        {"version":"\(version)","pin":"\(pin)","engine_id":"\(id)","channel":"\(channel.rawValue)"\(dateField),
         "engine":{"asset":"NX2Apple-engine.zip","sha256":"\(digest)","size":\(archive.count)}}
        """.utf8)
        t.files[base + "NX2Apple-engine.zip"] = archive
    }

    private func publishExperimental(_ t: FakeTransport, id: String, version: String = "1.4.0-experimental",
                                     upstreamDate: String? = nil) throws {
        try publish(t, id: id, channel: .experimental, version: version, base: experimentalBase, upstreamDate: upstreamDate)
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

    func testNoSwitchToExperimentalIsAskedForWhileItIsNotAheadOfStable() {
        let store = makeStore(bundle: temporary)
        store.selection.channel = .stable
        store.setStanding(.notAhead)
        store.requestChannel(.experimental)
        XCTAssertNil(store.confirmingChannel)
        XCTAssertEqual(store.channelChoice.options, [.stable])
        store.setStanding(.unknown)
        store.requestChannel(.experimental)
        XCTAssertEqual(store.confirmingChannel, .experimental, "an unknown standing offers it as before")
    }

    func testALauncherOnAnOlderExperimentalCanGoBackToStable() {
        let store = makeStore(bundle: temporary)
        store.selection.channel = .experimental
        store.setStanding(.notAhead)
        XCTAssertTrue(store.channelChoice.offersBackToStable)
        store.requestChannel(.stable)
        XCTAssertEqual(store.confirmingChannel, .stable)
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

    /// The state in words, no pin or "upstream" (#1458): not set up, set up, up to date, or a newer engine to install.
    func testTheDetailSaysTheEngineStateInWords() {
        let store = makeStore(bundle: temporary)
        XCTAssertEqual(store.detail, t("engine.none"))
        store.selection = EngineSelection(channel: .stable, engineID: id("c"), version: "", previousID: "")
        XCTAssertEqual(store.detail, t("engine.state.set"))
        store.selection.version = "1.2.3"
        XCTAssertEqual(store.detail, String(format: t("engine.state.current"), "1.2.3"))
        XCTAssertFalse(store.detail.contains("cccccccc"))
        store.applyOutcome(.available(EngineUpdate.Engine(id: id("d"), version: "1.2.4")), channel: .stable, quiet: true)
        XCTAssertEqual(store.detail, String(format: t("engine.state.update"), "1.2.3", "1.2.4"))
    }

    func testPrepareEngineOnExperimentalDoesNotDowngradeNewerBundledEngine() async throws {
        let engines = EngineStore(root: temporary.appendingPathComponent("engines"))
        let oldID = id("a"), newID = id("b")
        let bundled = try makeBundled(newID, upstreamDate: "2026-11-18T18:35:43Z")
        let t = FakeTransport()
        try publishExperimental(t, id: oldID, version: "1.4.0-experimental", upstreamDate: "2026-11-16T00:00:00Z")

        // Case 1: old experimental tree was not cached locally (seed bundled -> checkForUpdate must not revert to oldID).
        EngineSelection(channel: .experimental, engineID: oldID, version: "1.4.0-experimental", previousID: "").save(defaults)
        autoUpdate = true
        let store1 = makeStore(bundle: bundled, engines: engines, transport: t, appVersion: "1.5.0", publicKey: "")
        await store1.prepareEngine().value
        XCTAssertEqual(store1.selection.engineID, newID)
        XCTAssertEqual(repo.path, engines.directory(for: newID)?.path)
        XCTAssertTrue(t.downloads.isEmpty, "older experimental engine must not be downloaded")
        XCTAssertEqual(store1.experimentalStanding, .notAhead)

        // Case 2: old experimental tree without .upstream-date is still usable in the store (upgrade in place).
        try install(oldID, in: engines)
        EngineSelection(channel: .experimental, engineID: oldID, version: "1.4.0-experimental", previousID: "").save(defaults)
        let store2 = makeStore(bundle: bundled, engines: engines, transport: t, appVersion: "1.5.0", publicKey: "")
        await store2.prepareEngine().value
        XCTAssertEqual(store2.selection.engineID, newID)
        XCTAssertEqual(repo.path, engines.directory(for: newID)?.path)
        XCTAssertTrue(t.downloads.isEmpty)
        XCTAssertEqual(store2.experimentalStanding, .notAhead)
    }

    func testPrepareEngineUnderSameAppVersionMovesOntoNewerBundledEngine() async throws {
        let engines = EngineStore(root: temporary.appendingPathComponent("engines"))
        let oldRC = id("a"), newRC = id("b")
        try install(oldRC, in: engines)
        let bundled = try makeBundled(newRC, upstreamDate: "2026-11-18T18:35:43Z")
        EngineSelection(channel: .stable, engineID: oldRC, version: "1.5.0", previousID: "").save(defaults)
        autoUpdate = false
        building = false
        let t = FakeTransport()
        let storeWithTransport = makeStore(bundle: bundled, engines: engines, transport: t, appVersion: "1.5.0", publicKey: "")
        await storeWithTransport.prepareEngine().value
        XCTAssertEqual(storeWithTransport.selection.engineID, newRC)
        XCTAssertEqual(repo.path, engines.directory(for: newRC)?.path)

        // Conversely, if the store tree under the same appVersion carries a strictly newer upstream date, keep it.
        let newerInStore = id("c")
        try install(newerInStore, in: engines, upstreamDate: "2026-11-20T00:00:00Z")
        EngineSelection(channel: .stable, engineID: newerInStore, version: "1.5.0", previousID: "").save(defaults)
        let storeKeepNewer = makeStore(bundle: bundled, engines: engines, transport: t, appVersion: "1.5.0", publicKey: "")
        await storeKeepNewer.prepareEngine().value
        XCTAssertEqual(storeKeepNewer.selection.engineID, newerInStore)
        XCTAssertEqual(repo.path, engines.directory(for: newerInStore)?.path)
    }

    func testConfirmExperimentalDoesNotSwitchWhenExperimentalIsBehindBundled() async throws {
        let engines = EngineStore(root: temporary.appendingPathComponent("engines"))
        let oldID = id("a"), newID = id("b")
        try install(newID, in: engines, upstreamDate: "2026-11-18T18:35:43Z")
        let bundled = try makeBundled(newID, upstreamDate: "2026-11-18T18:35:43Z")
        let t = FakeTransport()
        try publishExperimental(t, id: oldID, version: "1.4.0-experimental", upstreamDate: "2026-11-16T00:00:00Z")
        EngineSelection(channel: .stable, engineID: newID, version: "1.5.0", previousID: "").save(defaults)
        let store = makeStore(bundle: bundled, engines: engines, transport: t, appVersion: "1.5.0", publicKey: "")
        await store.confirmChannel(.experimental).value
        XCTAssertEqual(store.selection.channel, .stable)
        XCTAssertEqual(store.selection.engineID, newID)
        XCTAssertTrue(t.downloads.isEmpty)
        XCTAssertEqual(store.experimentalStanding, .notAhead)
    }

    func testConfirmExperimentalIsBlockedWithoutDownloadWhenExperimentalLagsRemoteStable() async throws {
        let engines = EngineStore(root: temporary.appendingPathComponent("engines"))
        let bundledID = id("a"), experimentalID = id("b"), stableID = id("c")
        try install(bundledID, in: engines, upstreamDate: "2026-11-10T00:00:00Z")
        let bundled = try makeBundled(bundledID, upstreamDate: "2026-11-10T00:00:00Z")
        let t = FakeTransport()
        try publish(t, id: experimentalID, channel: .experimental, version: "1.5.0-experimental",
                    base: experimentalBase, upstreamDate: "2026-11-15T00:00:00Z")
        try publish(t, id: stableID, channel: .stable, version: "1.5.0",
                    base: stableBase + "1.5.0/", upstreamDate: "2026-11-20T00:00:00Z")
        EngineSelection(channel: .stable, engineID: bundledID, version: "1.5.0", previousID: "").save(defaults)
        let store = makeStore(bundle: bundled, engines: engines, transport: t, appVersion: "1.5.0", publicKey: "")
        await store.confirmChannel(.experimental).value
        XCTAssertEqual(store.selection.channel, .stable)
        XCTAssertEqual(store.selection.engineID, bundledID)
        XCTAssertTrue(t.downloads.isEmpty, "older-than-stable experimental archive must not be downloaded")
        XCTAssertEqual(store.experimentalStanding, .notAhead)
        XCTAssertEqual(store.status, self.t("engine.experimentalBehind"))
    }
}
