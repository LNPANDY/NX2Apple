import Combine
import XCTest
@testable import NXModel
@testable import NXCore

@MainActor final class S2ArmBuildStoreTests: XCTestCase {
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
        func syncEngine(then: ((Bool) -> Void)?) -> Task<Void, Never> {
            then?(true)
            return Task {}
        }
    }

    private final class FakeDevices: InstallTarget {
        var installDevice = "device-ios-1"
        var signingTeam = "TEAM1"
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

    private final class ChunkedRunner: ProcessRunner, @unchecked Sendable {
        var chunks: [Data] = []
        var exitStatus: Int32 = 0
        var shouldThrowOnStart = false
        var onStartInspect: ((ProcessLaunch) -> Void)?
        var captureAnswer: (ProcessLaunch) -> ProcessResult = { _ in ProcessResult() }
        var streamLinesHandler: ((ProcessLaunch, (RunningProcess) -> Void, (String) -> Void) -> ProcessResult)?

        var streamHandler: ((ProcessLaunch, (String) -> Void) -> Bool)?

        func capture(_ launch: ProcessLaunch) -> ProcessResult { captureAnswer(launch) }
        func stream(_ launch: ProcessLaunch, line: @escaping (String) -> Void) -> Bool {
            if let streamHandler { return streamHandler(launch, line) }
            return true
        }
        func streamLines(_ launch: ProcessLaunch, started: @escaping (RunningProcess) -> Void, line: @escaping (String) -> Void) -> ProcessResult {
            if let handler = streamLinesHandler { return handler(launch, started, line) }
            started(FakeRunningProcess())
            return ProcessResult(status: 0)
        }
        func start(_ launch: ProcessLaunch, onOutput: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> RunningProcess {
            onStartInspect?(launch)
            if shouldThrowOnStart { throw CocoaError(.fileNoSuchFile) }
            for chunk in chunks { onOutput(chunk) }
            onExit(exitStatus)
            return FakeRunningProcess()
        }
    }

    private var defaults: UserDefaults!
    private var temporary: URL!
    private var repo: FakeRepo!
    private let deps = FakeDeps()
    private let engine = FakeEngine()
    private let devices = FakeDevices()
    private let localizer = Localizer(.en)
    private var originalFeatureEnabled = false
    private var originalMNGFeatureEnabled = false

    private var originalVenvDir = ""

    override func setUpWithError() throws {
        originalFeatureEnabled = S2ArmBuilder.featureEnabled
        originalMNGFeatureEnabled = MacNativeGamesBuilder.featureEnabled
        originalVenvDir = Toolchain.venvDir
        S2ArmBuilder.featureEnabled = true
        defaults = TestDefaults.make("nxmodel-s2arm-build-tests")
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        Toolchain.venvDir = temporary.appendingPathComponent("venv").path
        repo = FakeRepo(path: temporary.appendingPathComponent("repo").path)
    }

    override func tearDownWithError() throws {
        S2ArmBuilder.featureEnabled = originalFeatureEnabled
        MacNativeGamesBuilder.featureEnabled = originalMNGFeatureEnabled
        Toolchain.venvDir = originalVenvDir
        try? FileManager.default.removeItem(at: temporary)
    }

    private func makeFakeS2ArmTree() throws -> String {
        let root = temporary.appendingPathComponent("fake-s2arm")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("pack/jobs"), withIntermediateDirectories: true)
        try Data("#!/usr/bin/env python3\n".utf8).write(to: root.appendingPathComponent("pack/jobs/main.py"))
        try fm.createDirectory(at: root.appendingPathComponent("runtime/rewriter"), withIntermediateDirectories: true)
        try Data("/* rewriter */\n".utf8).write(to: root.appendingPathComponent("runtime/rewriter/rewriter.c"))
        try fm.createDirectory(at: root.appendingPathComponent("pack/oneclick"), withIntermediateDirectories: true)
        try Data("#!/bin/bash\n".utf8).write(to: root.appendingPathComponent("pack/oneclick/oneclick.sh"))
        return root.path
    }

    func testPersistenceAndFeatureDisabledFallback() throws {
        let runner = ChunkedRunner()
        let tree = try makeFakeS2ArmTree()
        let store1 = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        store1.buildUpstream = .s2arm
        store1.s2armPath = tree

        let store2 = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        XCTAssertEqual(store2.buildUpstream, .s2arm)
        XCTAssertEqual(store2.s2armPath, tree)

        S2ArmBuilder.featureEnabled = false
        MacNativeGamesBuilder.featureEnabled = false
        let store3 = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        XCTAssertEqual(store3.buildUpstream, .nxnative)
        XCTAssertEqual(store3.availableUpstreams, [.nxnative])
        XCTAssertFalse(store3.canSelectUpstream(.s2arm))
        store3.selectUpstream(.s2arm)
        XCTAssertEqual(store3.buildUpstream, .nxnative)

        // When MacNativeGames is enabled and S2Arm stays off, UserDefaults="s2arm" falls back cleanly and availableUpstreams excludes S2Arm.
        MacNativeGamesBuilder.featureEnabled = true
        defaults.set(EngineUpstreamKind.s2arm.rawValue, forKey: BuildStore.buildUpstreamKey)
        let store4 = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        XCTAssertEqual(store4.buildUpstream, .nxnative)
        XCTAssertEqual(store4.availableUpstreams, [.nxnative, .macNativeGames])
        XCTAssertFalse(store4.canSelectUpstream(.s2arm))
        _ = store4.downloadUpstream(.s2arm)
        XCTAssertNil(store4.upstreamDownloads[.s2arm])
    }

    func testTreeValidation() throws {
        let runner = ChunkedRunner()
        var runnerStarted = false
        runner.onStartInspect = { _ in runnerStarted = true }
        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        store.buildUpstream = .s2arm
        store.target = BuildTarget.ios

        let base = temporary.appendingPathComponent("Game [0100F2C0115B6000].nsp")
        let keys = temporary.appendingPathComponent("prod.keys")
        try Data([0]).write(to: base)
        try Data([0]).write(to: keys)
        store.updateSlot("base") { $0.paths = [base.path] }
        store.updateSlot("keys") { $0.paths = [keys.path] }

        store.s2armPath = ""
        store.startBuild()
        XCTAssertFalse(runnerStarted)
        XCTAssertEqual(store.doneNote, localizer.t("upstream.s2armMissing"))

        store.s2armPath = temporary.appendingPathComponent("invalid").path
        store.startBuild()
        XCTAssertFalse(runnerStarted)
        XCTAssertTrue(store.doneNote.contains("not an S2Arm folder"))
    }

    private func makeFakeVenvWithTools(in tree: String) throws -> String {
        let fm = FileManager.default
        let venvBin = URL(fileURLWithPath: S2ArmBootstrap.venvDirectory(in: tree), isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: venvBin, withIntermediateDirectories: true)
        for name in ["python3", "cmake", "meson", "ninja"] {
            let file = venvBin.appendingPathComponent(name)
            try Data("#!/bin/sh\n".utf8).write(to: file)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return venvBin.appendingPathComponent("python3").path
    }

    private func makeFakeManagedBash(home: String) throws -> String {
        let fm = FileManager.default
        let bashPath = S2ArmBootstrap.managedBashPath(home: home)
        let url = URL(fileURLWithPath: bashPath)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho 5\n".utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bashPath)
        return bashPath
    }

    private func makeReadyS2ArmRunner(tree: String) throws -> ChunkedRunner {
        let dotnetDir = temporary.appendingPathComponent(".dotnet", isDirectory: true)
        try FileManager.default.createDirectory(at: dotnetDir, withIntermediateDirectories: true)
        let fakeDotnet = dotnetDir.appendingPathComponent("dotnet")
        try Data("#!/bin/sh\n".utf8).write(to: fakeDotnet)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeDotnet.path)
        _ = try makeFakeVenvWithTools(in: tree)
        let fakeBash = try makeFakeManagedBash(home: temporary.path)

        let runner = ChunkedRunner()
        runner.captureAnswer = { launch in
            if launch.executable == fakeBash {
                return ProcessResult(status: 0, out: "5\n")
            }
            if launch.arguments.contains("--list-sdks") {
                return ProcessResult(status: 0, out: "10.0.403 [\(dotnetDir.path)/sdk]\n")
            }
            if launch.arguments.contains("--list-runtimes") {
                return ProcessResult(status: 0, out: "Microsoft.NETCore.App 10.0.0 [\(dotnetDir.path)/shared/Microsoft.NETCore.App]\n")
            }
            return ProcessResult(status: 0, out: "")
        }
        return runner
    }

    func testBuildIOSWithoutNxnativeRepoAndSkipsDeviceCheck() throws {
        repo.isRepo = false
        let validTree = try makeFakeS2ArmTree()
        let runner = try makeReadyS2ArmRunner(tree: validTree)
        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        store.home = temporary.path
        store.buildUpstream = .s2arm
        store.s2armPath = validTree
        store.target = BuildTarget.ios

        let tid = "0100F2C0115B6000"
        let base = temporary.appendingPathComponent("Zelda [\(tid)].nsp")
        let keys = temporary.appendingPathComponent("prod.keys")
        try Data([0]).write(to: base)
        try Data([0]).write(to: keys)
        store.updateSlot("base") { $0.paths = [base.path] }
        store.updateSlot("keys") { $0.paths = [keys.path] }
        store.outDir = temporary.appendingPathComponent("out").path
        try FileManager.default.createDirectory(atPath: store.outDir, withIntermediateDirectories: true)

        XCTAssertTrue(store.canBuild)

        var launchedCommand: [String] = []
        runner.onStartInspect = { launch in
            launchedCommand = [launch.executable] + launch.arguments
            let eventsURL = URL(fileURLWithPath: store.s2armEventsPath)
            let outIPA = URL(fileURLWithPath: store.outDir).appendingPathComponent("Zelda.ipa")
            try? Data("ipa-content".utf8).write(to: outIPA)
            let events = """
            {"ev": "stage", "name": "extract"}
            {"ev": "result", "ok": true, "ipa": "\(outIPA.path)"}
            """
            try? Data(events.utf8).write(to: eventsURL)
        }

        store.startBuild()

        let deadline = Date().addingTimeInterval(3)
        while (!store.done || launchedCommand.isEmpty) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertFalse(launchedCommand.isEmpty)
        XCTAssertEqual(launchedCommand[0], S2ArmBootstrap.managedBashPath(home: temporary.path))
        XCTAssertEqual(launchedCommand[1], "\(validTree)/pack/oneclick/oneclick.sh")
        XCTAssertTrue(launchedCommand.contains("--target"))
        XCTAssertTrue(launchedCommand.contains("ios"))
        XCTAssertTrue(launchedCommand.contains("--device"))
        XCTAssertTrue(launchedCommand.contains("device-ios-1"))

        XCTAssertTrue(store.done)
        XCTAssertFalse(store.exportedIPAPath.isEmpty)
        XCTAssertTrue(store.exportedIPAPath.hasSuffix("Zelda.ipa"))
        XCTAssertTrue(store.doneNote.contains("Zelda.ipa"))
    }

    func testBuildMacTargetWithoutNxnativeRepo() throws {
        repo.isRepo = false
        let validTree = try makeFakeS2ArmTree()
        let runner = try makeReadyS2ArmRunner(tree: validTree)
        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        store.home = temporary.path
        store.buildUpstream = .s2arm
        store.s2armPath = validTree
        store.target = BuildTarget.mac

        let tid = "0100F2C0115B6000"
        let base = temporary.appendingPathComponent("Game [\(tid)].nsp")
        let keys = temporary.appendingPathComponent("prod.keys")
        try Data([0]).write(to: base)
        try Data([0]).write(to: keys)
        store.updateSlot("base") { $0.paths = [base.path] }
        store.updateSlot("keys") { $0.paths = [keys.path] }
        store.outDir = temporary.appendingPathComponent("out").path

        var launchedCommand: [String] = []
        runner.onStartInspect = { launch in
            launchedCommand = [launch.executable] + launch.arguments
            let eventsURL = URL(fileURLWithPath: store.s2armEventsPath)
            let outMac = URL(fileURLWithPath: store.outDir).appendingPathComponent("MacRoot")
            let events = """
            {"ev": "result", "ok": true, "root": "\(outMac.path)"}
            """
            try? Data(events.utf8).write(to: eventsURL)
        }

        store.startBuild()

        let deadline = Date().addingTimeInterval(3)
        while (!store.done || launchedCommand.isEmpty) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertFalse(launchedCommand.isEmpty)
        XCTAssertTrue(launchedCommand.contains("--target"))
        XCTAssertTrue(launchedCommand.contains("mac"))
        XCTAssertFalse(launchedCommand.contains("--device"))

        XCTAssertTrue(store.done)
        XCTAssertTrue(store.doneNote.contains("MacRoot"))
    }

    func testBuildFailureWithEventsAndSymbols() throws {
        let validTree = try makeFakeS2ArmTree()
        let runner = try makeReadyS2ArmRunner(tree: validTree)
        runner.exitStatus = 1
        runner.chunks = [Data("stage 1\n🔴 shader compilation failed\n".utf8)]
        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        store.home = temporary.path
        store.buildUpstream = .s2arm
        store.s2armPath = validTree
        store.target = BuildTarget.mac

        let base = temporary.appendingPathComponent("Game.nsp")
        let keys = temporary.appendingPathComponent("prod.keys")
        try Data([0]).write(to: base)
        try Data([0]).write(to: keys)
        store.updateSlot("base") { $0.paths = [base.path] }
        store.updateSlot("keys") { $0.paths = [keys.path] }

        runner.onStartInspect = { _ in
            let eventsURL = URL(fileURLWithPath: store.s2armEventsPath)
            let events = """
            {"ev": "result", "ok": false, "msg": "S2Arm failed with fatal error"}
            """
            try? Data(events.utf8).write(to: eventsURL)
        }

        store.startBuild()

        let deadline = Date().addingTimeInterval(3)
        while store.running && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertFalse(store.running)
        XCTAssertFalse(store.done)
        XCTAssertTrue(store.doneNote.contains("S2Arm failed with fatal error"))
    }

    func testSingleNupInputAlwaysPassesDirectoryAndNoKeysToS2Arm() throws {
        repo.isRepo = false
        let validTree = try makeFakeS2ArmTree()
        let runner = try makeReadyS2ArmRunner(tree: validTree)
        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        store.home = temporary.path
        store.buildUpstream = .s2arm
        store.s2armPath = validTree
        store.target = BuildTarget.mac
        store.outDir = temporary.appendingPathComponent("out").path
        try FileManager.default.createDirectory(atPath: store.outDir, withIntermediateDirectories: true)

        // Case 1: Solo .nup in its own folder -> passes parent folder directly.
        let soloDir = temporary.appendingPathComponent("solo-nup", isDirectory: true)
        try FileManager.default.createDirectory(at: soloDir, withIntermediateDirectories: true)
        let soloNup = soloDir.appendingPathComponent("SoloGame.nup")
        try Data("nup".utf8).write(to: soloNup)

        store.gameFolder = GameFolder.Contents(
            folder: soloDir.path,
            titleID: 0x0400_A3A0_1EE4_C000,
            updates: [],
            dlc: [],
            nup: soloNup.path
        )
        store.updateSlot("base") { $0.paths = [soloNup.path] }

        var launched: [String] = []
        runner.onStartInspect = { launch in
            launched = [launch.executable] + launch.arguments
        }
        store.startBuild()
        let deadline1 = Date().addingTimeInterval(3)
        while (store.running || launched.isEmpty) && Date() < deadline1 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertGreaterThan(launched.count, 2)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: launched[2], isDirectory: &isDir) && isDir.boolValue)
        XCTAssertEqual(launched[2], soloDir.path)
        XCTAssertFalse(launched.contains("--keys"))

        // Case 2: Shared folder with another package beside .nup -> stages into workDir/staging directory.
        let sharedDir = temporary.appendingPathComponent("shared-nup", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
        let targetNup = sharedDir.appendingPathComponent("Target.nup")
        let siblingPkg = sharedDir.appendingPathComponent("Other.nsp")
        try Data("nup".utf8).write(to: targetNup)
        try Data("nsp".utf8).write(to: siblingPkg)

        store.gameFolder = GameFolder.Contents(
            folder: sharedDir.path,
            titleID: 0x0400_A3A0_1EE4_C000,
            updates: [],
            dlc: [],
            nup: targetNup.path
        )
        store.updateSlot("base") { $0.paths = [targetNup.path] }

        launched = []
        store.startBuild()
        let deadline2 = Date().addingTimeInterval(3)
        while (store.running || launched.isEmpty) && Date() < deadline2 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertGreaterThan(launched.count, 2)
        var isStagedDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: launched[2], isDirectory: &isStagedDir) && isStagedDir.boolValue)
        XCTAssertTrue(launched[2].hasSuffix("/staging"))
        XCTAssertFalse(launched.contains("--keys"))
    }

    func testAutoInstallsDotnet10WhenMissingBeforeRunningS2Arm() throws {
        repo.isRepo = false
        let validTree = try makeFakeS2ArmTree()
        let dotnetDir = temporary.appendingPathComponent(".dotnet", isDirectory: true)
        let fakeDotnet = dotnetDir.appendingPathComponent("dotnet")
        _ = try makeFakeVenvWithTools(in: validTree)
        let fakeBash = try makeFakeManagedBash(home: temporary.path)

        let lock = NSLock()
        var dotnetInstalled = false
        var sawDotnetInstallCmd = false

        let runner = ChunkedRunner()
        var dotnetInstallLaunch: ProcessLaunch?
        runner.streamHandler = { launch, line in
            if launch.arguments.joined(separator: " ").contains("dotnet-install.sh") {
                lock.lock()
                sawDotnetInstallCmd = true
                dotnetInstallLaunch = launch
                dotnetInstalled = true
                lock.unlock()
                try? FileManager.default.createDirectory(at: dotnetDir, withIntermediateDirectories: true)
                try? Data("#!/bin/sh\n".utf8).write(to: fakeDotnet)
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeDotnet.path)
                line("Installed .NET 10.0.403")
                return true
            }
            return true
        }
        runner.captureAnswer = { launch in
            if launch.executable == fakeBash {
                return ProcessResult(status: 0, out: "5\n")
            }
            lock.lock()
            let ready = dotnetInstalled
            lock.unlock()
            if launch.arguments.contains("--list-sdks") {
                return ready && launch.executable == fakeDotnet.path
                    ? ProcessResult(status: 0, out: "10.0.403 [\(dotnetDir.path)/sdk]\n")
                    : ProcessResult(status: 0, out: "9.0.100 [/old/sdk]\n")
            }
            if launch.arguments.contains("--list-runtimes") {
                return ProcessResult(status: 0, out: "Microsoft.NETCore.App 10.0.0 [\(dotnetDir.path)/shared/Microsoft.NETCore.App]\n")
            }
            return ProcessResult(status: 0, out: "")
        }

        var launchedEnv: [String: String] = [:]
        runner.onStartInspect = { launch in
            launchedEnv = launch.environment ?? [:]
        }

        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        store.home = temporary.path
        store.buildUpstream = .s2arm
        store.s2armPath = validTree
        store.target = BuildTarget.mac
        let base = temporary.appendingPathComponent("Game [0100F2C0115B6000].nsp")
        let keys = temporary.appendingPathComponent("prod.keys")
        try Data([0]).write(to: base)
        try Data([0]).write(to: keys)
        store.updateSlot("base") { $0.paths = [base.path] }
        store.updateSlot("keys") { $0.paths = [keys.path] }

        store.startBuild()
        let dl = Date().addingTimeInterval(3)
        while launchedEnv.isEmpty && Date() < dl {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertTrue(sawDotnetInstallCmd, "Missing .NET 10.0.403 must trigger rootless dotnet-install.sh")
        XCTAssertEqual(dotnetInstallLaunch?.executable, "/bin/bash")
        XCTAssertEqual(dotnetInstallLaunch?.arguments.first, "-c")
        XCTAssertFalse(
            (dotnetInstallLaunch?.arguments.last ?? "").hasPrefix("/bin/bash"),
            "dotnetInstallCmd must not be double-wrapped with shellCommand"
        )
        XCTAssertEqual(launchedEnv["DOTNET_ROOT"], dotnetDir.path)
        XCTAssertTrue((launchedEnv["PATH"] ?? "").contains(dotnetDir.path))
        let expectedTmp = store.effectiveWorkDir + "/.tmp"
        XCTAssertEqual(launchedEnv["TMPDIR"], expectedTmp)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedTmp))
    }

    func testExternalLogLinesDriveBuildStagesForS2ArmAndMNG() throws {
        let runner = ChunkedRunner()
        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)

        store.s2armRun = true
        store.ingest("▶ 解包游戏开始\n")
        XCTAssertEqual(store.stages.last?.name, "解包游戏")
        XCTAssertEqual(store.stages.last?.state, .running)
        store.ingest("解包游戏完成，用时 3.5s\n")
        XCTAssertEqual(store.stages.last?.state, .done)
        XCTAssertEqual(store.stages.last?.detail, "3.5s")

        store.s2armRun = false
        store.mngRun = true
        store.stages = []
        store.ingest("1/4 code\n2/4 data\n")
        XCTAssertEqual(store.stages.count, 2)
        XCTAssertEqual(store.stages[0].state, .done)
        XCTAssertEqual(store.stages[1].name, "2/4 data")
        XCTAssertEqual(store.stages[1].state, .running)
    }

    func testBootstrapsGitBash5AndRewriterDepsBeforeRunningOneclick() throws {
        repo.isRepo = false
        let validTree = try makeFakeS2ArmTree()
        let fm = FileManager.default
        let prepScript = URL(fileURLWithPath: validTree).appendingPathComponent("runtime/rewriter/prepare_deps.py")
        try Data("#!/usr/bin/env python3\n".utf8).write(to: prepScript)
        let staleDep = URL(fileURLWithPath: validTree).appendingPathComponent("build/rewriter-deps/stale.txt")
        try fm.createDirectory(at: staleDep.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("broken\n".utf8).write(to: staleDep)
        let fontsReq = URL(fileURLWithPath: validTree).appendingPathComponent("pack/fonts/requirements.txt")
        try fm.createDirectory(at: fontsReq.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fonttools==4.67.0\nskia-pathops==0.9.2\n".utf8).write(to: fontsReq)
        let rtScript = URL(fileURLWithPath: validTree).appendingPathComponent("launchers/macos/runtime_sources.py")
        try fm.createDirectory(at: rtScript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# runtime_sources\n".utf8).write(to: rtScript)

        let dotnetDir = temporary.appendingPathComponent(".dotnet", isDirectory: true)
        try fm.createDirectory(at: dotnetDir, withIntermediateDirectories: true)
        let fakeDotnet = dotnetDir.appendingPathComponent("dotnet")
        try Data("#!/bin/sh\n".utf8).write(to: fakeDotnet)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeDotnet.path)

        let managedBash = S2ArmBootstrap.managedBashPath(home: temporary.path)
        let rtPrefix = URL(fileURLWithPath: S2ArmBootstrap.runtimeToolsPrefix(in: validTree), isDirectory: true)
        let lock = NSLock()
        var sawGitInit = false
        var sawGitCommit = false
        var sawVenvCreate = false
        var sawPinnedPip = false
        var sawBashBuild = false
        var sawPrepareDeps = false
        var sawRuntimeTools = false
        var staleClearedBeforePrep = false

        let runner = ChunkedRunner()
        runner.streamHandler = { launch, line in
            let joined = launch.arguments.joined(separator: " ")
            if launch.arguments.count >= 3 && launch.arguments[0] == "-m" && launch.arguments[1] == "venv" {
                lock.lock()
                sawVenvCreate = true
                lock.unlock()
                let vBin = URL(fileURLWithPath: launch.arguments[2], isDirectory: true).appendingPathComponent("bin", isDirectory: true)
                try? fm.createDirectory(at: vBin, withIntermediateDirectories: true)
                let pyFile = vBin.appendingPathComponent("python3")
                try? Data("#!/bin/sh\n".utf8).write(to: pyFile)
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pyFile.path)
                line("Created dedicated s2arm .venv")
                return true
            }
            if launch.arguments.contains("pip") && launch.arguments.contains("install") {
                lock.lock()
                sawPinnedPip = launch.arguments.contains("fonttools==4.67.0") && launch.arguments.contains("cmake")
                lock.unlock()
                let vBin = URL(fileURLWithPath: S2ArmBootstrap.venvDirectory(in: validTree), isDirectory: true).appendingPathComponent("bin", isDirectory: true)
                for tool in ["cmake", "meson", "ninja"] {
                    let p = vBin.appendingPathComponent(tool)
                    try? Data("#!/bin/sh\n".utf8).write(to: p)
                    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p.path)
                }
                line("Installed pinned S2Arm requirements")
                return true
            }
            if joined.contains("bash-5.2.37.tar.gz") {
                lock.lock()
                sawBashBuild = true
                lock.unlock()
                let url = URL(fileURLWithPath: managedBash)
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data("#!/bin/sh\necho 5\n".utf8).write(to: url)
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: managedBash)
                line("Built Bash 5.2.37")
                return true
            }
            if launch.arguments.first == prepScript.path, launch.arguments.count >= 2 {
                lock.lock()
                sawPrepareDeps = true
                staleClearedBeforePrep = !fm.fileExists(atPath: staleDep.path)
                lock.unlock()
                let depsDir = URL(fileURLWithPath: launch.arguments[1], isDirectory: true)
                try? fm.createDirectory(at: depsDir.appendingPathComponent("capstone-5.0.7/src"), withIntermediateDirectories: true)
                try? fm.createDirectory(at: depsDir.appendingPathComponent("lz4-4.4.5/lz4libs"), withIntermediateDirectories: true)
                try? Data("# cmake\n".utf8).write(to: depsDir.appendingPathComponent("capstone-5.0.7/src/CMakeLists.txt"))
                try? Data("/* lz4 */\n".utf8).write(to: depsDir.appendingPathComponent("lz4-4.4.5/lz4libs/lz4.c"))
                line("Prepared rewriter deps")
                return true
            }
            if joined.contains("runtime_sources.tools()") {
                lock.lock()
                sawRuntimeTools = true
                lock.unlock()
                try? fm.createDirectory(at: rtPrefix.appendingPathComponent("bin"), withIntermediateDirectories: true)
                try? fm.createDirectory(at: rtPrefix.appendingPathComponent("lib"), withIntermediateDirectories: true)
                for tool in S2ArmBootstrap.requiredRuntimeToolBinaries {
                    let p = rtPrefix.appendingPathComponent("bin/\(tool)")
                    try? Data("#!/bin/sh\n".utf8).write(to: p)
                    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p.path)
                }
                try? Data("dylib".utf8).write(to: rtPrefix.appendingPathComponent("lib/libzstd.1.dylib"))
                line("\(S2ArmBootstrap.runtimeToolsMarker)\(rtPrefix.path)")
                return true
            }
            return true
        }
        runner.captureAnswer = { launch in
            if launch.executable.hasSuffix("/git") || launch.executable == "git" {
                lock.lock()
                if launch.arguments.contains("init") { sawGitInit = true }
                if launch.arguments.contains("commit") { sawGitCommit = true }
                lock.unlock()
                return ProcessResult(status: 0, out: "")
            }
            if launch.executable == managedBash {
                return ProcessResult(status: 0, out: "5\n")
            }
            if launch.executable == "/opt/homebrew/bin/bash" || launch.executable == "/usr/local/bin/bash" {
                return ProcessResult(status: 0, out: "3\n")
            }
            if launch.arguments.contains("--list-sdks") {
                return ProcessResult(status: 0, out: "10.0.403 [\(dotnetDir.path)/sdk]\n")
            }
            if launch.arguments.contains("--list-runtimes") {
                return ProcessResult(status: 0, out: "Microsoft.NETCore.App 10.0.0 [\(dotnetDir.path)/shared/Microsoft.NETCore.App]\n")
            }
            return ProcessResult(status: 0, out: "")
        }

        var launched: ProcessLaunch?
        runner.onStartInspect = { launch in
            launched = launch
        }

        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        store.home = temporary.path
        store.buildUpstream = .s2arm
        store.s2armPath = validTree
        store.target = BuildTarget.mac
        let base = temporary.appendingPathComponent("Game [0100F2C0115B6000].nsp")
        let keys = temporary.appendingPathComponent("prod.keys")
        try Data([0]).write(to: base)
        try Data([0]).write(to: keys)
        store.updateSlot("base") { $0.paths = [base.path] }
        store.updateSlot("keys") { $0.paths = [keys.path] }

        store.startBuild()
        let dl = Date().addingTimeInterval(3)
        while launched == nil && Date() < dl {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        let finalLaunch = try XCTUnwrap(launched)
        XCTAssertTrue(sawGitInit)
        XCTAssertTrue(sawGitCommit)
        XCTAssertTrue(sawVenvCreate)
        XCTAssertTrue(sawPinnedPip)
        XCTAssertTrue(sawBashBuild)
        XCTAssertTrue(sawPrepareDeps)
        XCTAssertTrue(sawRuntimeTools)
        XCTAssertTrue(staleClearedBeforePrep)
        XCTAssertEqual(finalLaunch.executable, managedBash)
        XCTAssertEqual(finalLaunch.environment?["SHELL"], managedBash)
        XCTAssertEqual(finalLaunch.environment?["S2A_PYTHON"], S2ArmBootstrap.venvPython(in: validTree))
        XCTAssertEqual(finalLaunch.environment?["S2A_REWRITER_DEPS"], S2ArmBootstrap.rewriterDepsDirectory(in: validTree))
        XCTAssertEqual(finalLaunch.environment?["S2A_ZSTD_LIB"], rtPrefix.appendingPathComponent("lib/libzstd.1.dylib").path)
        let shimDir = S2ArmBootstrap.shimDirectory(in: validTree)
        let pathParts = (finalLaunch.environment?["PATH"] ?? "").split(separator: ":").map(String.init)
        XCTAssertEqual(pathParts.first, shimDir)
        XCTAssertEqual(pathParts.dropFirst().first, rtPrefix.appendingPathComponent("bin").path)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: shimDir + "/bash"), managedBash)
    }

    func testStopDuringS2ArmPrepAndMacAppPackerResetsState() throws {
        repo.isRepo = false
        let validTree = try makeFakeS2ArmTree()
        let fm = FileManager.default
        let base = temporary.appendingPathComponent("Game [0100F2C0115B6000].nsp")
        let keys = temporary.appendingPathComponent("prod.keys")
        try Data([0]).write(to: base)
        try Data([0]).write(to: keys)

        // Part A: stop during S2Arm venv preparation skips remaining steps and resets state cleanly.
        let prepRunner = ChunkedRunner()
        var startedOneclick = false
        prepRunner.onStartInspect = { _ in startedOneclick = true }
        let prepStore = BuildStore(localizer: localizer, runner: prepRunner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        prepStore.home = temporary.path
        prepStore.buildUpstream = .s2arm
        prepStore.s2armPath = validTree
        prepStore.target = BuildTarget.mac
        prepStore.updateSlot("base") { $0.paths = [base.path] }
        prepStore.updateSlot("keys") { $0.paths = [keys.path] }

        prepRunner.streamHandler = { [weak prepStore] launch, _ in
            if launch.arguments.contains("venv") {
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        prepStore?.stop()
                        sem.signal()
                    }
                }
                _ = sem.wait(timeout: .now() + 2)
                return false
            }
            return true
        }

        prepStore.startBuild()
        let dl1 = Date().addingTimeInterval(3)
        while prepStore.running && Date() < dl1 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertFalse(startedOneclick)
        XCTAssertFalse(prepStore.running)
        XCTAssertFalse(prepStore.stopping)
        XCTAssertFalse(prepStore.installPhaseActive)
        XCTAssertTrue(prepStore.stages.isEmpty)
        XCTAssertEqual(prepStore.doneNote, localizer.t("msg.stopped"))

        // Part B: stop during finishS2ArmBuild S2ArmMacAppPacker.packApp resets state cleanly.
        try Data("all:\n".utf8).write(to: URL(fileURLWithPath: validTree).appendingPathComponent("Makefile"))
        try fm.createDirectory(at: URL(fileURLWithPath: validTree).appendingPathComponent("launchers/macos"), withIntermediateDirectories: true)
        try Data("# build.mk\n".utf8).write(to: URL(fileURLWithPath: validTree).appendingPathComponent("launchers/macos/build.mk"))
        let packRunner = try makeReadyS2ArmRunner(tree: validTree)
        let packStore = BuildStore(localizer: localizer, runner: packRunner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        packStore.home = temporary.path
        packStore.buildUpstream = .s2arm
        packStore.s2armPath = validTree
        packStore.target = BuildTarget.mac
        packStore.outDir = temporary.appendingPathComponent("out-pack").path
        packStore.updateSlot("base") { $0.paths = [base.path] }
        packStore.updateSlot("keys") { $0.paths = [keys.path] }

        let macRoot = temporary.appendingPathComponent("MacRoot")
        try fm.createDirectory(at: macRoot, withIntermediateDirectories: true)
        packRunner.onStartInspect = { _ in
            let eventsURL = URL(fileURLWithPath: packStore.s2armEventsPath)
            let events = "{\"ev\": \"result\", \"ok\": true, \"root\": \"\(macRoot.path)\"}\n"
            try? Data(events.utf8).write(to: eventsURL)
        }
        var sawPackMake = false
        packRunner.streamHandler = { [weak packStore] launch, _ in
            if launch.arguments.contains("host") {
                sawPackMake = true
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        packStore?.stop()
                        sem.signal()
                    }
                }
                _ = sem.wait(timeout: .now() + 2)
                return false
            }
            return true
        }

        packStore.startBuild()
        let dl2 = Date().addingTimeInterval(3)
        while (!sawPackMake || packStore.running) && Date() < dl2 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(sawPackMake)
        XCTAssertFalse(packStore.running)
        XCTAssertFalse(packStore.stopping)
        XCTAssertFalse(packStore.installPhaseActive)
        XCTAssertTrue(packStore.stages.isEmpty)
        XCTAssertTrue(packStore.macAppPath.isEmpty)
        XCTAssertEqual(packStore.doneNote, localizer.t("msg.stopped"))
    }
}
