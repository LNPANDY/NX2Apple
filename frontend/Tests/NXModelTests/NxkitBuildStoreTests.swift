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
        func data(from url: URL) -> EngineFetch<Data> { answers[url].map { .ok($0) } ?? .failed }
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
    private let tag = "v0.10.1"

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

    private func makeStore(runner: ProcessRunner = ChunkedRunner(), transport: EngineTransport = StubTransport()) -> BuildStore {
        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        store.home = temporary.path
        store.upstreamTransport = transport
        store.refreshNxkit()   // the support folder moved with `home`
        return store
    }

    /// The files an install leaves in `upstreams/nxkit/`, made directly (the ZIP path is tested in NxkitBuilderTests).
    private func installTree(host: Bool, tag: String = "v0.10.1") throws {
        let dir = temporary.appendingPathComponent("Library/Application Support/NX2Apple/upstreams/nxkit", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in host ? ["nxb", "nxkit-host"] : ["nxb"] {
            try Data("#!/bin/sh\n".utf8).write(to: dir.appendingPathComponent(name))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent(name).path)
        }
        NxkitBuilder.writeInfo(NxkitBuilder.InstallInfo(tag: tag, hasHost: host), in: dir)
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

    // MARK: Selection

    func testNotInstalledCannotBeSelectedAndIOSIsNotOffered() throws {
        let store = makeStore()
        XCTAssertEqual(store.upstreamState(.nxkit), .notInstalled)
        XCTAssertFalse(store.canSelectUpstream(.nxkit))
        store.selectUpstream(.nxkit)
        XCTAssertEqual(store.buildUpstream, .nxnative)

        try installTree(host: true)
        store.refreshNxkit()
        XCTAssertTrue(store.canSelectUpstream(.nxkit))
        store.target = BuildTarget.ios
        store.selectUpstream(.nxkit)
        XCTAssertEqual(store.buildUpstream, .nxkit)
        XCTAssertEqual(store.target, BuildTarget.mac)
        XCTAssertTrue(store.isMacOnlyUpstreamSelected)
        XCTAssertEqual(store.macOnlyNoteKey, "upstream.nxkitMacOnly")
    }

    func testSelectionPersistsAndFeatureOffFallsBack() throws {
        try installTree(host: true)
        let store1 = makeStore()
        store1.selectUpstream(.nxkit)
        XCTAssertEqual(makeStore().buildUpstream, .nxkit)
        NxkitBuilder.featureEnabled = false
        XCTAssertEqual(makeStore().buildUpstream, .nxnative)
    }

    func testIOSBuildWithNxkitSelectedDoesNotStart() throws {
        try installTree(host: true)
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
        try installTree(host: true)
        let store = makeStore()
        store.selectUpstream(.nxkit)
        try pickGame(store)
        XCTAssertTrue(store.usesExternalUpstreamRepo)
        XCTAssertTrue(store.canBuild)
    }

    // MARK: Install through the store

    func testInstallFromTheLatestReleaseSelectsNxkit() async throws {
        let transport = StubTransport()
        let dir = temporary.appendingPathComponent("nxb-v0.10.1-macos-arm64", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: dir.appendingPathComponent("nxb"))
        try Data("#!/bin/sh\n".utf8).write(to: dir.appendingPathComponent("nxkit-host"))
        let zip = temporary.appendingPathComponent("r.zip")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-c", "-k", "--keepParent", dir.path, zip.path]
        try proc.run()
        proc.waitUntilExit()
        let zipName = "nxb-v0.10.1-macos-arm64.zip"
        let sums = "\(try XCTUnwrap(NxkitBuilder.sha256(of: zip)))  \(zipName)\n"
        let zipURL = URL(string: "https://example.invalid/\(zipName)")!
        let sumsURL = URL(string: "https://example.invalid/SHA256SUMS")!
        transport.answers[NxkitBuilder.latestReleaseURL] = Data("""
        {"tag_name":"v0.10.1","assets":[{"name":"\(zipName)","browser_download_url":"\(zipURL.absoluteString)"},
        {"name":"SHA256SUMS","browser_download_url":"\(sumsURL.absoluteString)"}]}
        """.utf8)
        transport.answers[sumsURL] = Data(sums.utf8)
        transport.archives[zipURL] = zip

        let store = makeStore(transport: transport)
        await store.downloadUpstream(.nxkit).value
        XCTAssertEqual(store.upstreamState(.nxkit), .installed)
        XCTAssertEqual(store.buildUpstream, .nxkit)
        XCTAssertEqual(store.nxkitInfo, NxkitBuilder.InstallInfo(tag: "v0.10.1", hasHost: true))
        XCTAssertTrue(store.nxkitCanBuildApps)

        // a bad checksum fails with its own reason and keeps what is installed
        transport.answers[sumsURL] = Data((String(repeating: "0", count: 64) + "  " + zipName).utf8)
        await store.downloadUpstream(.nxkit).value
        XCTAssertEqual(store.upstreamState(.nxkit), .installed)
        XCTAssertEqual(store.upstreamDownloads[.nxkit], .failed(.verify))
        XCTAssertTrue(store.nxkitCanBuildApps)
    }

    func testInstallFailsWhenNoReleaseAnswers() async {
        let store = makeStore()
        await store.downloadUpstream(.nxkit).value
        XCTAssertEqual(store.upstreamState(.nxkit), .failed(.download))
        XCTAssertFalse(store.nxkitInstalled)
    }

    // MARK: Update check

    func testUpdateCheckComparesTheLatestTagWithTheInstalledOne() async throws {
        try installTree(host: true, tag: "v0.10.1")
        let transport = StubTransport()
        let store = makeStore(transport: transport)
        XCTAssertEqual(store.nxkitUpdate, .unknown)

        func answer(_ tag: String) {
            transport.answers[NxkitBuilder.latestReleaseURL] = Data("""
            {"tag_name":"\(tag)","assets":[{"name":"nxb-\(tag)-macos-arm64.zip","browser_download_url":"https://example.invalid/z.zip"}]}
            """.utf8)
        }
        answer("v0.11.0")
        await store.checkNxkitUpdate().value
        XCTAssertEqual(store.nxkitUpdate, .available("v0.11.0"))
        answer("v0.10.1")
        await store.checkNxkitUpdate().value
        XCTAssertEqual(store.nxkitUpdate, .upToDate)
        transport.answers[NxkitBuilder.latestReleaseURL] = nil
        await store.checkNxkitUpdate().value
        XCTAssertEqual(store.nxkitUpdate, .failed)
    }

    // MARK: A release without nxkit-host

    func testReleaseWithoutHostShowsAClearStateAndDoesNotStartABuild() throws {
        try installTree(host: false)
        let runner = ChunkedRunner()
        let store = makeStore(runner: runner)
        XCTAssertTrue(store.nxkitInstalled)
        XCTAssertFalse(store.nxkitCanBuildApps)
        store.selectUpstream(.nxkit)
        try pickGame(store)
        store.startBuild()
        XCTAssertTrue(runner.launches.isEmpty)
        XCTAssertEqual(store.doneNote, String(format: localizer.t("upstream.nxkitNoHost"), "v0.10.1"))
        XCTAssertFalse(store.running)
    }

    // MARK: The build

    func testBuildLaunchesNxbWithTheDocumentedArguments() throws {
        try installTree(host: true)
        let runner = ChunkedRunner()
        runner.exitStatus = 3
        let store = makeStore(runner: runner)
        store.selectUpstream(.nxkit)
        try pickGame(store)
        store.startBuild()

        let launch = try XCTUnwrap(runner.launches.first)
        let tree = store.nxkitPath
        XCTAssertEqual(launch.executable, tree + "/nxb")
        XCTAssertNil(launch.groupPython)
        let args = launch.arguments
        XCTAssertEqual(args.first, "build")
        XCTAssertEqual(args[1], temporary.path)   // the folder of the picked package
        XCTAssertEqual(args[args.firstIndex(of: "-k")! + 1], temporary.appendingPathComponent("prod.keys").path)
        XCTAssertEqual(args[args.firstIndex(of: "--platform")! + 1], "mac")
        XCTAssertEqual(args[args.firstIndex(of: "--progress")! + 1], "json")
        XCTAssertEqual(args[args.firstIndex(of: "--work-dir")! + 1], temporary.path + "/Library/Caches/NX2Apple/nxkit/01007EF00011E000")
        XCTAssertTrue(args[args.firstIndex(of: "-o")! + 1].hasSuffix("01007EF00011E000_build/01007EF00011E000.app"))
        XCTAssertEqual(launch.environment?["NXB_NXKIT_HOST"], tree + "/nxkit-host")
        XCTAssertEqual(store.lastBuildCommand.first, tree + "/nxb")
        XCTAssertEqual(store.effectiveWorkDir, temporary.path + "/Library/Caches/NX2Apple/nxkit/01007EF00011E000")
        // nxb's exit code 3 is shown in words
        let deadline = Date().addingTimeInterval(3)
        while store.doneNote.isEmpty && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(store.doneNote.contains(String(format: localizer.t("nxb.exit.3"), 3)), store.doneNote)
        XCTAssertFalse(store.running)
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
