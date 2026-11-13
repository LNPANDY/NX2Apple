import XCTest
@testable import NXModel
@testable import NXCore

@MainActor final class FrameworkRefreshStoreTests: XCTestCase {
    private final class FakeRepo: RepoLocation {
        var path: String
        var isRepo = true
        var isGit = true
        init(path: String) { self.path = path }
    }

    private final class FakeDeps: DependencyInstalling {
        var pythonPath = "/usr/bin/python3"
        var dotnetPath = "/usr/bin/true"
        var checked = true
        var allPresent = true
        var deps: [Dep] = []
        func isInstalling(_ id: String) -> Bool { false }
        func install(_ dep: Dep) -> Task<Void, Never> { Task {} }
    }

    private final class FakeEngine: EngineSyncing {
        func syncEngine(then: ((Bool) -> Void)?) -> Task<Void, Never> { then?(true); return Task {} }
    }

    private final class MockRunner: ProcessRunner, @unchecked Sendable {
        var launches: [ProcessLaunch] = []
        var exitStatuses: [Int32] = [0]
        var chunks: [Data] = []
        var onLaunch: ((Int, ProcessLaunch) -> Void)?

        func capture(_ launch: ProcessLaunch) -> ProcessResult { ProcessResult(status: 0) }
        func stream(_ launch: ProcessLaunch, line: @escaping (String) -> Void) -> Bool { true }
        func streamLines(_ launch: ProcessLaunch, started: @escaping (RunningProcess) -> Void, line: @escaping (String) -> Void) -> ProcessResult {
            started(FakeRunningProcess())
            return ProcessResult(status: 0)
        }
        func start(_ launch: ProcessLaunch, onOutput: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> RunningProcess {
            let index = launches.count
            launches.append(launch)
            onLaunch?(index, launch)
            for chunk in chunks { onOutput(chunk) }
            let status = index < exitStatuses.count ? exitStatuses[index] : (exitStatuses.last ?? 0)
            onExit(status)
            return FakeRunningProcess()
        }
    }

    private var defaults: UserDefaults!
    private var temporary: URL!
    private var repo: FakeRepo!
    private let deps = FakeDeps()
    private let engine = FakeEngine()
    private let localizer = Localizer(.en)
    private let titleID = "0100535012974000"

    private func makeDevices(runner: ProcessRunner) -> DeviceStore {
        let store = DeviceStore(runner: runner, xcrun: "/usr/bin/true", defaults: defaults, listDevices: { _ in [] }, readTeams: { [] })
        store.signingTeam = "TEAM1"
        store.exportIPA = true
        store.exportOneGame = false
        return store
    }

    override func setUpWithError() throws {
        defaults = TestDefaults.make("nxmodel-fw-refresh-tests")
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("fwr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defaults.set(temporary.appendingPathComponent("shell").path, forKey: "shellRoot")
        repo = FakeRepo(path: try makeFakeRepo())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    private func makeFakeRepo() throws -> String {
        let root = temporary.appendingPathComponent("repo")
        let fm = FileManager.default
        for rel in [EngineLayout.marker] + RepoLayout.requiredTools {
            let file = root.appendingPathComponent(rel)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("'--work-dir' '--romfs-from'\n".utf8).write(to: file)
        }
        let gameDir = root.appendingPathComponent("dm/games/\(titleID.lowercased())")
        try fm.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try Data("id\t\(titleID)\n".utf8).write(to: gameDir.appendingPathComponent("game.tsv"))
        return root.path
    }

    private func seedCachedBuild(withShaders: Bool = true) throws -> (workDir: URL, archiveDir: URL) {
        let fm = FileManager.default
        let workDir = temporary.appendingPathComponent("\(titleID)_build")
        let exe = workDir.appendingPathComponent("extract/v0/ExeFS")
        try fm.createDirectory(at: exe, withIntermediateDirectories: true)
        try Data("NSO0".utf8).write(to: exe.appendingPathComponent("main"))
        if withShaders {
            let vkLib = workDir.appendingPathComponent("shader/ios/vk/vk_shaders.metallib")
            try fm.createDirectory(at: vkLib.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("lib".utf8).write(to: vkLib)
        }
        let archiveDir = temporary.appendingPathComponent("games/\(titleID)")
        try fm.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        var romfs = Data("DMROMFS1".utf8)
        romfs.append(Data(repeating: 0, count: 64))
        try romfs.write(to: archiveDir.appendingPathComponent("romfs.img"))
        return (workDir, archiveDir)
    }

    private func drainMainQueue(seconds: TimeInterval = 0.08) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testRefreshWithoutOriginalNSPOrKeysRunsDriverUpdatesLauncherJSONAndDefersPackaging() throws {
        let (workDir, archiveDir) = try seedCachedBuild()
        let runner = MockRunner()
        let devices = makeDevices(runner: runner)
        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        store.target = BuildTarget.ios
        store.outDir = temporary.path
        store.deferShellPackaging = true
        store.refreshCandidate = RefreshCandidate(gameID: UUID(), titleID: titleID, name: "Hades", archivePath: archiveDir.path)

        XCTAssertTrue(store.canRefreshCurrentIOSFramework)
        XCTAssertTrue(store.canBuild)
        XCTAssertTrue(store.canStartBuildOrQueue)

        let events = """
        {"ev":"stage","k":1,"n":2,"name":"rewrite","step":"checking"}
        {"ev":"stage_end","k":1,"n":2,"name":"rewrite","ok":true,"summary":"main","elapsed":0.2}
        {"ev":"stage","k":2,"n":2,"name":"game framework","step":"compiling"}
        {"ev":"stage_end","k":2,"n":2,"name":"game framework","ok":true,"summary":"DmGame\(titleID).framework","elapsed":1.0}
        """
        runner.chunks = [Data((events + "\n").utf8)]

        let fwDir = workDir.appendingPathComponent("shell-framework/DmGame\(titleID).framework/dm")
        runner.onLaunch = { _, _ in
            try? FileManager.default.createDirectory(at: fwDir, withIntermediateDirectories: true)
            try? Data("{}".utf8).write(to: fwDir.appendingPathComponent("launcher.json"))
        }

        store.startBuild()
        drainMainQueue(seconds: 0.12)

        XCTAssertEqual(runner.launches.count, 1)
        XCTAssertEqual(runner.launches[0].arguments.first, "-c")
        XCTAssertEqual(store.archivePath, archiveDir.path)
        XCTAssertEqual(store.stages.map(\.name), [localizer.t("stage.rewrite"), localizer.t("stage.game_framework")])
        XCTAssertEqual(store.deferredShell.count, 1)
        XCTAssertEqual(store.deferredShell.first?.titleID, titleID)
        XCTAssertEqual(store.deferredShell.first?.archive, archiveDir.path)
        XCTAssertTrue(store.done)
    }

    func testStaleShadersFailWhenNoOriginalNSPOrFallbackWhenNSPExists() throws {
        let (_, archiveDir) = try seedCachedBuild()
        let runner = MockRunner()
        let devices = makeDevices(runner: runner)
        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        store.target = BuildTarget.ios
        store.outDir = temporary.path
        store.deferShellPackaging = true
        store.refreshCandidate = RefreshCandidate(gameID: UUID(), titleID: titleID, name: "Hades", archivePath: archiveDir.path)

        runner.exitStatuses = [FrameworkRefresh.staleExitCode]
        store.startBuild()
        drainMainQueue()

        XCTAssertFalse(store.done)
        XCTAssertEqual(store.doneNote, localizer.t("msg.refreshShadersStale"))

        let base = temporary.appendingPathComponent("Hades [\(titleID)].nsp")
        let keys = temporary.appendingPathComponent("prod.keys")
        try Data("NSP".utf8).write(to: base)
        try Data("key".utf8).write(to: keys)
        store.updateSlot("base") { $0.paths = [base.path] }
        store.updateSlot("keys") { $0.paths = [keys.path] }
        store.refreshCandidate = RefreshCandidate(
            gameID: UUID(), titleID: titleID, name: "Hades",
            archivePath: archiveDir.path, recordedBase: base.path
        )

        runner.launches = []
        runner.exitStatuses = [FrameworkRefresh.staleExitCode, 1]
        store.startBuild()
        drainMainQueue(seconds: 0.12)

        XCTAssertEqual(runner.launches.count, 2)
        XCTAssertEqual(runner.launches[0].arguments.first, "-c")
        XCTAssertTrue(runner.launches[1].arguments.first?.hasSuffix("build_ipa_from_nsp.py") == true)
    }
}
