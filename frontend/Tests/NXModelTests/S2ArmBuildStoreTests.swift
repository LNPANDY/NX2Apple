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

        func capture(_ launch: ProcessLaunch) -> ProcessResult { captureAnswer(launch) }
        func stream(_ launch: ProcessLaunch, line: @escaping (String) -> Void) -> Bool { true }
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

    override func setUpWithError() throws {
        originalFeatureEnabled = S2ArmBuilder.featureEnabled
        originalMNGFeatureEnabled = MacNativeGamesBuilder.featureEnabled
        S2ArmBuilder.featureEnabled = true
        defaults = TestDefaults.make("nxmodel-s2arm-build-tests")
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        repo = FakeRepo(path: temporary.appendingPathComponent("repo").path)
    }

    override func tearDownWithError() throws {
        S2ArmBuilder.featureEnabled = originalFeatureEnabled
        MacNativeGamesBuilder.featureEnabled = originalMNGFeatureEnabled
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

    func testBuildIOSWithoutNxnativeRepoAndSkipsDeviceCheck() throws {
        repo.isRepo = false
        let validTree = try makeFakeS2ArmTree()
        let runner = ChunkedRunner()
        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
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

        XCTAssertFalse(launchedCommand.isEmpty)
        XCTAssertEqual(launchedCommand[0], "/bin/bash")
        XCTAssertEqual(launchedCommand[1], "\(validTree)/pack/oneclick/oneclick.sh")
        XCTAssertTrue(launchedCommand.contains("--target"))
        XCTAssertTrue(launchedCommand.contains("ios"))
        XCTAssertTrue(launchedCommand.contains("--device"))
        XCTAssertTrue(launchedCommand.contains("device-ios-1"))

        let deadline = Date().addingTimeInterval(3)
        while !store.done && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertTrue(store.done)
        XCTAssertFalse(store.exportedIPAPath.isEmpty)
        XCTAssertTrue(store.exportedIPAPath.hasSuffix("Zelda.ipa"))
        XCTAssertTrue(store.doneNote.contains("Zelda.ipa"))
    }

    func testBuildMacTargetWithoutNxnativeRepo() throws {
        repo.isRepo = false
        let validTree = try makeFakeS2ArmTree()
        let runner = ChunkedRunner()
        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
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

        XCTAssertFalse(launchedCommand.isEmpty)
        XCTAssertTrue(launchedCommand.contains("--target"))
        XCTAssertTrue(launchedCommand.contains("mac"))
        XCTAssertFalse(launchedCommand.contains("--device"))

        let deadline = Date().addingTimeInterval(3)
        while !store.done && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertTrue(store.done)
        XCTAssertTrue(store.doneNote.contains("MacRoot"))
    }

    func testBuildFailureWithEventsAndSymbols() throws {
        let validTree = try makeFakeS2ArmTree()
        let runner = ChunkedRunner()
        runner.exitStatus = 1
        runner.chunks = [Data("stage 1\n🔴 shader compilation failed\n".utf8)]
        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
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
}
