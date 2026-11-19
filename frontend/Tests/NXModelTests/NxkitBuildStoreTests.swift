import Combine
import XCTest
@testable import NXModel
@testable import NXCore

@MainActor final class NxkitBuildStoreTests: XCTestCase {
    private final class FakeRepo: RepoLocation {
        var path: String
        var isRepo = false
        var isGit = false
        init(path: String) { self.path = path }
    }

    private final class FakeDeps: DependencyInstalling {
        var pythonPath = ""
        var dotnetPath = ""
        var checked = true
        var allPresent = true
        var deps: [Dep] = []
        func isInstalling(_ id: String) -> Bool { false }
        func install(_ dep: Dep) -> Task<Void, Never> { Task {} }
    }

    private final class FakeEngine: EngineSyncing {
        func syncEngine(then: ((Bool) -> Void)?) -> Task<Void, Never> {
            then?(true)
            return Task {}
        }
    }

    private final class FakeDevices: InstallTarget {
        var installDevice = ""
        var signingTeam = ""
        var exportIPA = false
        var exportOneGame = false
        var driveFolder = ""
        var devices: [AppleDevice] = []
        var xcrun = "/usr/bin/true"
        var readTeams: @Sendable () -> [SigningTeam] = { [] }
        func deviceName(_ udid: String) -> String { "iPhone" }
        nonisolated func askCopy(_ plan: ShellCopyPlan) -> ShellCopyDecision { .skip }
        nonisolated func setWaiting(_ on: Bool) {}
        nonisolated var waitCancelled: Bool { false }
        func copyEnded() {}
    }

    private final class StubTransport: EngineTransport, @unchecked Sendable {
        var answers: [URL: Data] = [:]
        var archives: [URL: URL] = [:]
        var offline = false
        func data(from url: URL) -> EngineFetch<Data> { offline ? .failed : (answers[url].map { .ok($0) } ?? .missing) }
        func download(from url: URL, to destination: URL) -> Bool {
            guard let src = archives[url], let payload = try? Data(contentsOf: src) else { return false }
            return (try? payload.write(to: destination)) != nil
        }
    }

    private final class ChunkedRunner: ProcessRunner, @unchecked Sendable {
        var chunks: [Data] = []
        var exitStatus: Int32 = 0
        var launches: [ProcessLaunch] = []
        func capture(_ launch: ProcessLaunch) -> ProcessResult { ProcessResult() }
        func stream(_ launch: ProcessLaunch, line: @escaping (String) -> Void) -> Bool { true }
        func streamLines(_ launch: ProcessLaunch, started: @escaping (RunningProcess) -> Void, line: @escaping (String) -> Void) -> ProcessResult {
            started(FakeRunningProcess())
            return ProcessResult(status: 0)
        }
        func start(_ launch: ProcessLaunch, onOutput: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> RunningProcess {
            launches.append(launch)
            for chunk in chunks { onOutput(chunk) }
            onExit(exitStatus)
            return FakeRunningProcess()
        }
    }

    private var defaults: UserDefaults!
    private var temporary: URL!
    private let repo = FakeRepo(path: "/nonexistent")
    private let deps = FakeDeps()
    private let engine = FakeEngine()
    private let devices = FakeDevices()
    private let localizer = Localizer(.en)
    private var savedFlag = true

    override func setUpWithError() throws {
        savedFlag = NxkitBuilder.featureEnabled
        NxkitBuilder.featureEnabled = true
        defaults = TestDefaults.make("nxmodel-nxkit-tests")
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxkit-store-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        NxkitBuilder.featureEnabled = savedFlag
        try? FileManager.default.removeItem(at: temporary)
    }

    private var bundledFolder: String { temporary.appendingPathComponent("NX2Apple.app/Contents/Resources/nxbuild").path }
    private var supportRoot: URL { temporary.appendingPathComponent("Application Support/NX2Apple/nxkit", isDirectory: true) }

    /// The pair the app bundles, as nxbuild.py fetch lays it out: nxb, nxkit-host and MANIFEST.json.
    private func bundlePair(version: String = "0.10.2") throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: bundledFolder, withIntermediateDirectories: true)
        for name in ["nxb", "nxkit-host"] {
            fm.createFile(atPath: bundledFolder + "/" + name, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        }
        let manifest = #"{"format":1,"version":"VERSION","platform":"macos","arch":"arm64","macos_min":"26.0","files":{"nxb":"aa","nxkit-host":"e01c6312144767845a60021bc69fb597"}}"#
        try Data(manifest.replacingOccurrences(of: "VERSION", with: version).utf8).write(to: URL(fileURLWithPath: bundledFolder + "/MANIFEST.json"))
    }

    /// A version the update installed and verified, made directly (the ZIP path is NxkitUpdateTests').
    private func installedVersion(_ version: String) throws {
        let dir = supportRoot.appendingPathComponent(version, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["nxb", "nxkit-host"] {
            fm.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        }
        let manifest = #"{"format":1,"version":"VERSION","arch":"arm64","macos_min":"26.0","files":{"nxb":"bb","nxkit-host":"cc"}}"#
        try Data(manifest.replacingOccurrences(of: "VERSION", with: version).utf8).write(to: dir.appendingPathComponent("MANIFEST.json"))
        fm.createFile(atPath: dir.appendingPathComponent(".verified").path, contents: Data(version.utf8))
    }

    private func makeStore(runner: ProcessRunner = ChunkedRunner(), transport: EngineTransport = StubTransport(),
                           availability: NxkitBuilder.Availability = .available) -> BuildStore {
        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        store.home = temporary.path
        store.upstreamTransport = transport
        store.nxkitBundledFolder = bundledFolder
        store.nxkitVersions = NxkitVersionStore(root: supportRoot)
        store.nxkitAvailability = availability
        store.nxkitPrepare = { _ in true }
        store.refreshNxkit()
        return store
    }

    private func pickGame(_ store: BuildStore) throws {
        let base = temporary.appendingPathComponent("Zelda [01007EF00011E000].nsp")
        let keys = temporary.appendingPathComponent("prod.keys")
        try Data([0]).write(to: base)
        try Data([0]).write(to: keys)
        store.updateSlot("base") { $0.paths = [base.path] }
        store.updateSlot("keys") { $0.paths = [keys.path] }
        store.outDir = temporary.appendingPathComponent("out").path
        try FileManager.default.createDirectory(atPath: store.outDir, withIntermediateDirectories: true)
    }

    private func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    // MARK: The engine pop-up

    func testWithoutAPairNxkitCannotBeChosenWithTheBundledPairItCanAndIOSIsNotOffered() throws {
        let store = makeStore()
        XCTAssertFalse(store.nxkitSelectable)
        XCTAssertEqual(store.upstreamState(.nxkit), .notInstalled)
        store.selectUpstream(.nxkit)
        XCTAssertEqual(store.buildUpstream, .nxnative)

        try bundlePair()
        store.refreshNxkit()
        XCTAssertTrue(store.nxkitSelectable)
        XCTAssertTrue(store.availableUpstreams.contains(.nxkit))
        XCTAssertEqual(store.nxkitInUse?.source, .bundled)
        XCTAssertEqual(store.nxkitInUse?.version, "0.10.2")
        store.target = BuildTarget.ios
        store.selectUpstream(.nxkit)
        XCTAssertEqual(store.buildUpstream, .nxkit)
        XCTAssertEqual(store.target, BuildTarget.mac)
        XCTAssertTrue(store.isMacOnlyUpstreamSelected)
        XCTAssertEqual(store.macOnlyNoteKey, "upstream.nxkitMacOnly")
        XCTAssertEqual(store.nxkitStatusLine, "nxkit 0.10.2")
        XCTAssertEqual(store.nxkitStatusMessage.text, localizer.t("nxkit.betaNote"))
    }

    func testOlderMacOSOrIntelHidesNxkit() throws {
        try bundlePair()
        for availability in [NxkitBuilder.Availability.needsNewerMacOS, .needsAppleSilicon] {
            let store = makeStore(availability: availability)
            XCTAssertFalse(store.nxkitSelectable)
            XCTAssertFalse(store.availableUpstreams.contains(.nxkit))
            store.selectUpstream(.nxkit)
            XCTAssertEqual(store.buildUpstream, .nxnative)
        }
    }

    func testSelectionPersistsAndFeatureOffFallsBack() throws {
        try bundlePair()
        makeStore().selectUpstream(.nxkit)
        XCTAssertEqual(makeStore().buildUpstream, NxkitBuilder.currentAvailability == .available ? .nxkit : .nxnative)
        NxkitBuilder.featureEnabled = false
        XCTAssertEqual(makeStore().buildUpstream, .nxnative)
    }

    func testIOSBuildWithNxkitSelectedDoesNotStart() throws {
        try bundlePair()
        let runner = ChunkedRunner()
        let store = makeStore(runner: runner)
        store.selectUpstream(.nxkit)
        try pickGame(store)
        store.target = BuildTarget.ios
        store.startBuild()
        XCTAssertTrue(runner.launches.isEmpty)
        XCTAssertEqual(store.doneNote, localizer.t("upstream.nxkitMacOnly"))
    }

    func testNxkitNeedsNoNxnativeCheckout() throws {
        try bundlePair()
        let store = makeStore()
        store.selectUpstream(.nxkit)
        try pickGame(store)
        XCTAssertTrue(store.usesExternalUpstreamRepo)
        XCTAssertTrue(store.canBuild)
    }

    // MARK: The build

    func testBuildRunsTheBundledNxbWithTheDocumentedArgumentsAndNamesTheVersion() throws {
        try bundlePair()
        let runner = ChunkedRunner()
        runner.chunks = [Data((#"{"ev":"say","msg":"[RED] RomFS hash mismatch in /Users/someone/Games/x.nsp"}"# + "\nnxb: exiting\n").utf8)]
        runner.exitStatus = 3
        let store = makeStore(runner: runner)
        store.selectUpstream(.nxkit)
        try pickGame(store)
        store.startBuild()

        let launch = try XCTUnwrap(runner.launches.first)
        XCTAssertEqual(launch.executable, bundledFolder + "/nxb")
        XCTAssertNil(launch.groupPython, "no Python, no NSP script")
        let args = launch.arguments
        XCTAssertEqual(args.first, "build")
        XCTAssertEqual(args[1], temporary.path)   // the folder of the picked package
        XCTAssertEqual(args[args.firstIndex(of: "-k")! + 1], temporary.appendingPathComponent("prod.keys").path)
        XCTAssertEqual(args[args.firstIndex(of: "--platform")! + 1], "mac")
        XCTAssertEqual(args[args.firstIndex(of: "--progress")! + 1], "json")
        XCTAssertEqual(args[args.firstIndex(of: "--work-dir")! + 1], temporary.path + "/Library/Caches/NX2Apple/nxkit/01007EF00011E000")
        XCTAssertTrue(args[args.firstIndex(of: "-o")! + 1].hasSuffix("01007EF00011E000_build/01007EF00011E000.app"))
        XCTAssertEqual(launch.environment?["NXB_NXKIT_HOST"], bundledFolder + "/nxkit-host", "the host beside the nxb that runs")
        XCTAssertEqual(store.lastBuildCommand.first, bundledFolder + "/nxb")
        XCTAssertTrue(store.log.text.contains(String(format: localizer.t("nxkit.logHeaderBundled"), "0.10.2", "e01c63121447")), "the log names the engine and version")

        // nxb's exit code 3: the failure card of its own, with the code and the last lines, and no script ran
        waitUntil { !store.doneNote.isEmpty }
        XCTAssertTrue(store.doneNote.contains(String(format: localizer.t("nxb.exit.3"), 3)), store.doneNote)
        let failure = try XCTUnwrap(store.failure)
        XCTAssertEqual(failure.kind, .nxkit)
        XCTAssertEqual(failure.detail, "3")
        XCTAssertEqual(Array(failure.lines.suffix(2)), ["[RED] RomFS hash mismatch in /Users/someone/Games/x.nsp", "nxb: exiting"])
        XCTAssertEqual(store.failureWhat(failure), String(format: localizer.t("fail.nxkit.whatCode"), "3"))
        XCTAssertEqual(runner.launches.count, 1, "no fallback to the NSP script")
        XCTAssertFalse(store.running)

        // "Did it work?" once for this build: the failed build reports "Does not start" with the exit code
        let prompt = try XCTUnwrap(store.nxkitFeedback)
        XCTAssertEqual(prompt.moment, .failed)
        XCTAssertEqual(prompt.exitCode, 3)
        XCTAssertEqual(prompt.nxkitVersion, "0.10.2")
        XCTAssertEqual(prompt.titleID, "01007EF00011E000")
        XCTAssertEqual(prompt.report(.works).result, .doesNotStart)
        store.markNxkitFeedbackAsked(prompt.id)
        XCTAssertNil(store.nxkitFeedback)
        XCTAssertTrue(store.nxkitFeedbackAsked(prompt.id))
        store.askNxkitFeedback(.failed, gameVersion: "", exitCode: 3)
        XCTAssertNil(store.nxkitFeedback, "asked once per build")
    }

    func testAnInstalledNewerVersionRunsInsteadOfTheBundledOne() throws {
        try bundlePair()
        try installedVersion("0.11.0")
        try NxkitVersionStore(root: supportRoot).switchTo("0.11.0")
        let runner = ChunkedRunner()
        let store = makeStore(runner: runner)
        XCTAssertEqual(store.nxkitInUse?.source, .installed)
        store.selectUpstream(.nxkit)
        try pickGame(store)
        store.startBuild()
        let launch = try XCTUnwrap(runner.launches.first)
        XCTAssertEqual(launch.executable, supportRoot.path + "/0.11.0/nxb")
        XCTAssertEqual(launch.environment?["NXB_NXKIT_HOST"], supportRoot.path + "/0.11.0/nxkit-host")
        XCTAssertTrue(store.log.text.contains(String(format: localizer.t("nxkit.logHeaderInstalled"), "0.11.0", "cc")))
    }

    // MARK: The update

    func testCheckOfflineIsQuietAtLaunchAndSaidAfterCheckForUpdates() async throws {
        try bundlePair()
        let transport = StubTransport()
        let store = makeStore(transport: transport)   // the stub answers nothing
        transport.offline = true
        await store.checkNxkitUpdate(manual: false).value
        XCTAssertEqual(store.nxkitUpdate, .idle)
        await store.checkNxkitUpdate(manual: true).value
        XCTAssertEqual(store.nxkitUpdate, .unreachable)
        XCTAssertEqual(store.nxkitStatusMessage.tone, .warning)
    }

    func testTheLaunchCheckFollowsUpdateAutomatically() async throws {
        try bundlePair()
        let transport = StubTransport()
        transport.answers[NxkitUpdate.latestReleaseURL] = Data(#"{"tag_name":"v0.10.2","assets":[{"name":"nxb-v0.10.2-macos-arm64.zip","browser_download_url":"https://example.invalid/z.zip"}]}"#.utf8)
        let store = makeStore(transport: transport)
        store.nxkitAutoUpdate = { false }
        await store.checkNxkitUpdate(manual: false).value
        XCTAssertEqual(store.nxkitUpdate, .idle, "off: no check when the app opens")
        await store.checkNxkitUpdate(manual: true).value
        XCTAssertEqual(store.nxkitUpdate, .upToDate)
        XCTAssertEqual(store.nxkitStatusLine, "nxkit 0.10.2 · " + localizer.t("nxkit.upToDate"))
    }

    func testAnUnsignedNewerReleaseIsNamedAndNotInstalled() async throws {
        try bundlePair()
        let transport = StubTransport()
        let sums = URL(string: "https://example.invalid/SHA256SUMS")!
        transport.answers[NxkitUpdate.latestReleaseURL] = Data(#"""
        {"tag_name":"v0.11.0","assets":[{"name":"nxb-v0.11.0-macos-arm64.zip","browser_download_url":"https://example.invalid/z.zip"},
        {"name":"SHA256SUMS","browser_download_url":"https://example.invalid/SHA256SUMS"}]}
        """#.utf8)
        transport.answers[sums] = Data((String(repeating: "a", count: 64) + "  nxb-v0.11.0-macos-arm64.zip\n").utf8)
        let store = makeStore(transport: transport)
        await store.checkNxkitUpdate(manual: false).value
        XCTAssertEqual(store.nxkitUpdate, .rejected("0.11.0", .unsigned))
        XCTAssertEqual(store.nxkitStatusMessage.text, String(format: localizer.t("nxkit.unsigned"), "0.11.0"))
        XCTAssertEqual(store.nxkitInUse?.source, .bundled, "never runs unverified binaries")
    }

    func testNoSwitchWhileAnNxkitBuildRunsThenAfterIt() throws {
        try bundlePair()
        try installedVersion("0.11.0")
        let store = makeStore()
        store.running = true
        store.nxkitRun = true
        store.switchNxkit(to: "0.11.0")
        XCTAssertEqual(store.nxkitUpdate, .waitingForBuild("0.11.0"))
        XCTAssertEqual(store.nxkitInUse?.source, .bundled, "the running build keeps its pair")
        XCTAssertNil(NxkitVersionStore(root: supportRoot).readState().current)
        store.running = false
        XCTAssertEqual(store.nxkitInUse?.version, "0.11.0")
        XCTAssertEqual(store.nxkitUpdate, .upToDate)
    }

    func testUsePreviousVersion() throws {
        try bundlePair()
        let versions = NxkitVersionStore(root: supportRoot)
        try installedVersion("0.11.0")
        try versions.switchTo("0.11.0")
        try installedVersion("0.12.0")
        try versions.switchTo("0.12.0")
        let store = makeStore()
        XCTAssertEqual(store.nxkitInUse?.version, "0.12.0")
        XCTAssertEqual(store.nxkitPreviousVersion, "0.11.0")
        store.useNxkitPreviousVersion()
        XCTAssertEqual(store.nxkitInUse?.version, "0.11.0")
        XCTAssertEqual(store.nxkitPreviousVersion, "0.12.0")
    }

    // MARK: What the launcher keeps

    func testRecordsAndQuestionsArePerBuild() {
        let store = makeStore()
        XCTAssertNil(store.nxkitRecord("01007ef00011e000"))
        var records = store.nxkitRecords
        records["01007EF00011E000"] = NxkitBuildRecord(version: "0.10.2", hostBuild: "e01c", buildID: "b1", date: Date(timeIntervalSince1970: 1))
        store.nxkitRecords = records
        XCTAssertEqual(makeStore().nxkitRecord("01007ef00011e000")?.version, "0.10.2")
        XCTAssertFalse(store.nxkitFeedbackAsked("b1.firstLaunch"))
        store.markNxkitFeedbackAsked("b1.firstLaunch")
        XCTAssertTrue(makeStore().nxkitFeedbackAsked("b1.firstLaunch"))
        XCTAssertFalse(store.nxkitFeedbackAsked("b1.built"))
    }

    func testProgressEventsFillTheStageList() throws {
        let store = makeStore()
        let lines = [
            #"{"ev":"stage","k":1,"n":3,"name":"extract","step":"","code":"NXB1001","severity":"info","t":1767000000.0}"#,
            #"{"ev":"progress","k":1,"name":"extract","step":"files","done":30,"total":120,"unit":"files","est":false,"note":"","frac":0.25,"eta":42.0,"elapsed":8.0,"code":"NXB1004","severity":"debug","t":1767000008.0}"#,
            #"{"ev":"say","msg":"[1/3] 30 of 120 files","code":"NXB1005","severity":"info","t":1767000008.5}"#,
            #"{"ev":"stage_end","k":1,"name":"extract","ok":true,"summary":"120 files","elapsed":31.5,"code":"NXB1002","severity":"info","t":1767000031.0}"#,
            #"{"ev":"stage","k":2,"n":3,"name":"shaders","step":"Mac shaders","code":"NXB1001","severity":"info","t":1767000032.0}"#,
            #"{"ev":"progress","k":2,"name":"shaders","step":"Mac shaders","done":500,"total":1000,"unit":"shaders","est":false,"note":"","frac":0.5,"eta":null,"elapsed":10.0,"code":"NXB1004","severity":"debug","t":1767000042.0}"#,
        ]
        for line in lines.prefix(2) { store.handle(line) }
        XCTAssertEqual(store.stages.map(\.name), ["extract"])
        XCTAssertEqual(store.stages[0].state, .running)
        XCTAssertEqual(try XCTUnwrap(store.stages[0].percent), 25, accuracy: 0.001)
        for line in lines.dropFirst(2) { store.handle(line) }
        XCTAssertEqual(store.stages.map(\.name), ["extract", "shaders"])
        XCTAssertEqual(store.stages[0].state, .done)
        XCTAssertEqual(store.stages[1].state, .running)
        XCTAssertEqual(try XCTUnwrap(store.stages[1].percent), 50, accuracy: 0.001)
        XCTAssertEqual(store.currentStagePosition?.total, 3)
        XCTAssertTrue(store.log.text.contains("[1/3] 30 of 120 files"))
    }

    func testStopEndsTheProcessWithSIGINT() {
        // pid 0 and 1 are never signalled
        makeStore().endNxkitProcess(0)
        makeStore().endNxkitProcess(1)
    }
}
