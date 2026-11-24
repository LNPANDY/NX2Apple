import XCTest
@testable import NXModel
@testable import NXCore

@MainActor final class BuildStoreProcessAndStopTests: XCTestCase {
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
    private let localizer = Localizer(.en)

    override func setUpWithError() throws {
        defaults = TestDefaults.make("nxmodel-process-stop-tests")
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("bs-\(UUID().uuidString)")
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
            try Data("'--work-dir' '--romfs-from' '--from-seed'\n".utf8).write(to: file)
        }
        return root.path
    }

    private func drainMainQueue(seconds: TimeInterval = 0.08) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testBuildRunAndRunToolDecodeMultiByteUTF8SplitAcrossPipeChunks() throws {
        let runner = ChunkedRunner()
        let deviceStore = DeviceStore(runner: runner, xcrun: "/usr/bin/true", defaults: defaults, listDevices: { _ in [] }, readTeams: { [] })
        deviceStore.exportIPA = true
        deviceStore.exportOneGame = true

        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: deviceStore, defaults: defaults)
        store.target = BuildTarget.ios
        let base = temporary.appendingPathComponent("Game [0100000000001000].nsp")
        let keys = temporary.appendingPathComponent("prod.keys")
        try Data([0]).write(to: base)
        try Data([0]).write(to: keys)
        store.updateSlot("base") { $0.paths = [base.path] }
        store.updateSlot("keys") { $0.paths = [keys.path] }
        store.outDir = temporary.path

        // Split right inside 3-byte "✓" (E2 9C 93) and 3-byte "存" (E5 AD 98) across chunks.
        let jsonLine = "{\"ev\":\"stage_end\",\"k\":1,\"name\":\"Extract\",\"ok\":true,\"elapsed\":1.0,\"summary\":\"✓ 存档就绪\"}\n"
        let jsonBytes = Data(jsonLine.utf8)
        let checkMarkIndex = try XCTUnwrap(jsonBytes.firstIndex(of: 0xE2))
        XCTAssertNil(String(data: jsonBytes[..<(checkMarkIndex + 1)], encoding: .utf8))
        runner.chunks = [
            jsonBytes[..<(checkMarkIndex + 1)],
            jsonBytes[(checkMarkIndex + 1)...],
        ]
        runner.exitStatus = 1

        store.startBuild()
        drainMainQueue()

        let extractStage = store.stages.first { $0.id == 1 }
        XCTAssertEqual(extractStage?.state, .done, "JSON stage_end split mid-UTF-8 scalar must still be parsed")
        XCTAssertEqual(extractStage?.detail, "✓ 存档就绪")

        // Verify BuildStore+Install.runTool also decodes split multi-byte UTF-8 and flushes a trailing error line without newline.
        let toolLine = "xcodebuild: error: 签名失败 ✓ 路径"
        let toolBytes = Data(toolLine.utf8)
        let splitIdx = try XCTUnwrap(toolBytes.firstIndex(of: 0xE7)) // inside "签" (E7 AD BE)
        XCTAssertNil(String(data: toolBytes[..<(splitIdx + 2)], encoding: .utf8))
        runner.chunks = [toolBytes[..<(splitIdx + 2)], toolBytes[(splitIdx + 2)...]]
        runner.exitStatus = 65

        var reportedError: String?
        store.runTool(id: 1006, name: "Sign", ["/usr/bin/false"], step: { _ in nil }) { err in
            reportedError = err
        }
        drainMainQueue()
        XCTAssertEqual(reportedError, toolLine)
    }

    func testTemporaryEnvFileIsRemovedAfterBuildExitAndLaunchFailure() throws {
        let runner = ChunkedRunner()
        let deviceStore = DeviceStore(runner: runner, xcrun: "/usr/bin/true", defaults: defaults, listDevices: { _ in [] }, readTeams: { [] })
        deviceStore.exportIPA = true
        deviceStore.exportOneGame = true

        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: deviceStore, defaults: defaults)
        store.target = BuildTarget.ios
        let base = temporary.appendingPathComponent("Game [0100000000001000].nsp")
        let keys = temporary.appendingPathComponent("prod.keys")
        try Data([0]).write(to: base)
        try Data([0]).write(to: keys)
        store.updateSlot("base") { $0.paths = [base.path] }
        store.updateSlot("keys") { $0.paths = [keys.path] }
        store.outDir = temporary.path

        var capturedEnvPath: String?
        var existedAtStart = false
        runner.onStartInspect = { launch in
            if let idx = launch.arguments.firstIndex(of: "--env-file"), idx + 1 < launch.arguments.count {
                let path = launch.arguments[idx + 1]
                capturedEnvPath = path
                existedAtStart = FileManager.default.fileExists(atPath: path)
            }
        }
        runner.exitStatus = 1
        store.startBuild()
        drainMainQueue()

        let firstEnv = try XCTUnwrap(capturedEnvPath)
        XCTAssertTrue(existedAtStart, "the script needs the env file while it runs")
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstEnv), "temp nspb-env file must be removed when the process exits")

        // Also verify cleanup when runner.start throws before any onExit callback can fire.
        capturedEnvPath = nil
        existedAtStart = false
        runner.shouldThrowOnStart = true
        store.startBuild()
        drainMainQueue()

        let failedEnv = try XCTUnwrap(capturedEnvPath)
        XCTAssertTrue(existedAtStart)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedEnv), "temp nspb-env file must be removed on launch failure too")
    }

    func testInstallRetryNeverRestartsTheGameBuilder() throws {
        let fm = FileManager.default
        for mode in 0..<3 {
            let runner = ChunkedRunner()
            runner.onStartInspect = { _ in XCTFail("Retry must not start a game build") }
            let devices = DeviceStore(runner: runner, xcrun: "/usr/bin/true", defaults: defaults,
                                      listDevices: { _ in [] }, readTeams: { [] })
            let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps,
                                   engine: engine, devices: devices, defaults: defaults)
            store.home = temporary.path
            let framework = temporary.appendingPathComponent("fw-\(mode)/DmGame0100000000001000.framework").path
            try fm.createDirectory(atPath: framework, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: URL(fileURLWithPath: framework + "/game.manifest.json"))
            let archive = temporary.appendingPathComponent("archive-\(mode)").path
            try fm.createDirectory(atPath: archive, withIntermediateDirectories: true)
            try Data("romfs".utf8).write(to: URL(fileURLWithPath: archive + "/romfs.img"))
            func waitForFailure() {
                let end = Date().addingTimeInterval(3)
                while store.running && Date() < end { drainMainQueue(seconds: 0.01) }
                XCTAssertFalse(store.running)
            }
            switch mode {
            case 0: store.installShell(framework: framework, titleID: "0100000000001000", name: "Game", archive: archive)
            case 1: store.installBuiltShell(framework: framework, titleID: "0100000000001000", name: "Game")
            default: store.installShellBatch([.init(framework: framework, titleID: "0100000000001000", name: "Game", archive: archive)])
            }
            waitForFailure()
            let originalFailure = store.doneNote
            // Recovery uses the completed install's inputs even if unrelated form state has changed.
            store.shellRetry = ("/unrelated.framework", "OTHER", "Other", "/other-archive")
            for kind in [BuildFailureKind.deviceTransfer, .devicePairing, .developerMode] {
                store.failure = .init(kind: kind, gameName: nil)
                store.fixBuildFailure(kind)
                XCTAssertTrue(store.running, "Retry must resume the cached install in mode \(mode)")
                XCTAssertNil(store.failure, "The previous failure must not remain after retry starts")
                waitForFailure()
                XCTAssertEqual(store.doneNote, originalFailure)
            }
            store.beginOperation(.building, game: "Other", titleID: "OTHER", destination: .none)
            store.fixBuildFailure(.deviceTransfer)
            XCTAssertFalse(store.running, "A new operation must discard the old installation retry")
        }
    }

    func testInstallRetryFallsBackToRebuildWhenBuiltProductsDisappear() throws {
        let fm = FileManager.default
        let baseNSP = temporary.appendingPathComponent("Game [0100000000001000].nsp").path
        let keysFile = temporary.appendingPathComponent("prod.keys").path
        try Data("nsp".utf8).write(to: URL(fileURLWithPath: baseNSP))
        try Data("keys".utf8).write(to: URL(fileURLWithPath: keysFile))

        let framework = temporary.appendingPathComponent("fw-missing-fallback/DmGame0100000000001000.framework").path
        let archive = temporary.appendingPathComponent("archive-missing-fallback").path
        try fm.createDirectory(atPath: framework, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: framework + "/game.manifest.json"))
        try fm.createDirectory(atPath: archive, withIntermediateDirectories: true)
        try Data("romfs".utf8).write(to: URL(fileURLWithPath: archive + "/romfs.img"))

        var launchedScripts: [[String]] = []
        let runner = ChunkedRunner()
        runner.exitStatus = 1
        runner.onStartInspect = { launch in launchedScripts.append(launch.arguments) }
        let devices = DeviceStore(runner: runner, xcrun: "/usr/bin/true", defaults: defaults,
                                  listDevices: { _ in [] }, readTeams: { [] })
        devices.installDevice = "UDID-1"
        devices.signingTeam = "TEAM1"
        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps,
                               engine: engine, devices: devices, defaults: defaults)
        store.home = temporary.path
        try fm.createDirectory(atPath: store.home + "/Library/Application Support/NX2Apple/shell", withIntermediateDirectories: true)
        store.target = BuildTarget.ios
        store.shellDeviceChecked = true
        store.updateSlot("base") { $0.paths = [baseNSP] }
        store.updateSlot("keys") { $0.paths = [keysFile] }

        store.installShell(framework: framework, titleID: "0100000000001000", name: "Game", archive: archive)
        let end1 = Date().addingTimeInterval(3)
        while store.running && Date() < end1 { drainMainQueue(seconds: 0.01) }
        XCTAssertTrue(launchedScripts.isEmpty)

        // Removing the built framework triggers a full rebuild fallback instead of failing with missing framework.
        try fm.removeItem(atPath: framework)
        store.shellDeviceChecked = true
        store.failure = .init(kind: .developerMode, gameName: nil)
        store.fixBuildFailure(.developerMode)
        let end2 = Date().addingTimeInterval(3)
        while store.running && Date() < end2 { drainMainQueue(seconds: 0.01) }
        let fullArgs = try XCTUnwrap(launchedScripts.first, "Missing framework must fall back to full rebuild")
        XCTAssertEqual(launchedScripts.count, 1)
        XCTAssertFalse(fullArgs.contains("--from-seed"))

        // Fast-refresh context: missing archive falls back to --from-seed rebuild rather than normal NSP build.
        try fm.createDirectory(atPath: framework, withIntermediateDirectories: true)
        try fm.removeItem(atPath: archive)
        launchedScripts.removeAll()
        store.lastRunWasFastRefresh = true
        store.installRecovery.lastFastRefresh = FastRefreshRequest(
            titleID: "0100000000001000", targetName: BuildTarget.ios, outDir: temporary.path,
            gameName: "Game", existingMacAppPath: nil, externalImgPath: nil, cheatsDir: nil,
            knownArchivePath: nil, forceShaderRebuildTrailer: false
        )
        store.installShell(framework: framework, titleID: "0100000000001000", name: "Game", archive: archive)
        let end3 = Date().addingTimeInterval(3)
        while store.running && Date() < end3 { drainMainQueue(seconds: 0.01) }
        XCTAssertTrue(launchedScripts.isEmpty)

        store.shellDeviceChecked = true
        store.failure = .init(kind: .deviceTransfer, gameName: nil)
        store.fixBuildFailure(.deviceTransfer)
        let end4 = Date().addingTimeInterval(3)
        while store.running && Date() < end4 { drainMainQueue(seconds: 0.01) }
        let refreshArgs = try XCTUnwrap(launchedScripts.first, "Missing fast-refresh archive must fall back to fast refresh")
        XCTAssertEqual(launchedScripts.count, 1)
        XCTAssertTrue(refreshArgs.contains("--from-seed"), "Fast refresh fallback must preserve --from-seed flow")
    }

    func testSendGameDataRetryDoesNotRebuildAndDropFailureClearsRecovery() throws {
        let fm = FileManager.default
        let runner = ChunkedRunner()
        runner.onStartInspect = { _ in XCTFail("sendGameData retry must not start a game build") }
        let devices = DeviceStore(runner: runner, xcrun: "/usr/bin/true", defaults: defaults,
                                  listDevices: { _ in [] }, readTeams: { [] })
        devices.installDevice = "UDID-1"
        devices.signingTeam = "TEAM1"
        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps,
                               engine: engine, devices: devices, defaults: defaults)
        store.home = temporary.path
        let archive = temporary.appendingPathComponent("send-archive").path
        try fm.createDirectory(atPath: archive, withIntermediateDirectories: true)
        try Data("romfs".utf8).write(to: URL(fileURLWithPath: archive + "/romfs.img"))
        store.archivePath = archive
        store.installedOn = "UDID-1"
        store.installedAppPath = "/tmp/DmShell.app"

        store.sendGameData()
        let end1 = Date().addingTimeInterval(3)
        while store.running && Date() < end1 { drainMainQueue(seconds: 0.01) }
        XCTAssertEqual(store.failure?.kind, .devicePairing)

        store.fixBuildFailure(.devicePairing)
        XCTAssertTrue(store.running, "sendGameData retry must re-run sendGameData")
        XCTAssertNil(store.failure)
        let end2 = Date().addingTimeInterval(3)
        while store.running && Date() < end2 { drainMainQueue(seconds: 0.01) }
        XCTAssertEqual(store.failure?.kind, .devicePairing)

        // Switching to another game clears failure and discards pending install recovery.
        let nspA = temporary.appendingPathComponent("A [0100000000001000].nsp").path
        let nspB = temporary.appendingPathComponent("B [0100000000002000].nsp").path
        try Data("a".utf8).write(to: URL(fileURLWithPath: nspA))
        try Data("b".utf8).write(to: URL(fileURLWithPath: nspB))
        store.updateSlot("base") { $0.paths = [nspA] }
        store.sendGameData()
        let end3 = Date().addingTimeInterval(3)
        while store.running && Date() < end3 { drainMainQueue(seconds: 0.01) }
        XCTAssertEqual(store.failure?.kind, .devicePairing)
        XCTAssertNotNil(store.installRecovery.pending)
        store.updateSlot("base") { $0.paths = [nspB] }
        XCTAssertNil(store.failure)
        XCTAssertNil(store.installRecovery.pending)
    }

    func testStopCancelsPostInstallAskCopyAndCableWaitWhenNoSubprocessIsRunning() throws {
        let phone = AppleDevice(id: "UDID-1", name: "Jo's iPhone", model: "iPhone 17", os: "27.0", reachable: true, transport: "network")
        let team = SigningTeam(id: "TEAM123456", identity: "Apple Development")
        let runner = ChunkedRunner()
        // devicectl list devices reports the phone over Wi-Fi so copyGameData enters askCopy(plan).
        runner.captureAnswer = { launch in
            if let idx = launch.arguments.firstIndex(of: "--json-output"), idx + 1 < launch.arguments.count {
                let path = launch.arguments[idx + 1]
                // Matches DeviceTools.parseDevices (Devices.swift:66-95) based on `xcrun devicectl list devices --json-output`.
                let json = """
                {"result":{"devices":[{"connectionProperties":{"pairingState":"paired","transportType":"localNetwork"},"deviceProperties":{"name":"Jo's iPhone","osVersionNumber":"27.0"},"hardwareProperties":{"marketingName":"iPhone 17","platform":"iOS","udid":"UDID-1"}}]}}
                """
                try? Data(json.utf8).write(to: URL(fileURLWithPath: path))
            }
            return ProcessResult(status: 0)
        }

        let deviceStore = DeviceStore(runner: runner, xcrun: "/usr/bin/true", defaults: defaults, listDevices: { _ in [phone] }, readTeams: { [team] })
        deviceStore.installDevice = phone.id
        deviceStore.signingTeam = team.id

        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: deviceStore, defaults: defaults)
        store.home = temporary.path

        let archiveDir = temporary.appendingPathComponent("games/0100000000001000")
        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        try Data(repeating: 0xAA, count: 1024).write(to: archiveDir.appendingPathComponent("romfs.img"))

        // 1. Stop while blocked on the askCopy semaphore with proc == nil / not running.
        store.installShell(framework: temporary.appendingPathComponent("Dummy.framework").path,
                           titleID: "0100000000001000", name: "Game", archive: archiveDir.path, dataOnly: true)
        let askDeadline = Date().addingTimeInterval(3)
        while deviceStore.shellCopy == nil && Date() < askDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNotNil(deviceStore.shellCopy, "install is now blocked in askCopy")
        XCTAssertFalse(store.proc?.isRunning == true, "no subprocess is running during askCopy")

        store.stop()
        let finishDeadline = Date().addingTimeInterval(3)
        while store.running && Date() < finishDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertFalse(store.running, "Stop must unblock askCopy and finish the install run")
        XCTAssertTrue(store.stoppedByPlayer)
        XCTAssertNil(deviceStore.shellCopy)
        XCTAssertEqual(store.doneNote, store.t("msg.stopped"))

        // 2. Stop while waiting for a cable (shellWaiting == true) with no running subprocess.
        store.installShell(framework: temporary.appendingPathComponent("Dummy.framework").path,
                           titleID: "0100000000001000", name: "Game", archive: archiveDir.path, dataOnly: true)
        let ask2Deadline = Date().addingTimeInterval(3)
        while deviceStore.shellCopy == nil && Date() < ask2Deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        deviceStore.answerCopy(.waitForCable)
        let waitDeadline = Date().addingTimeInterval(3)
        while !deviceStore.shellWaiting && Date() < waitDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(deviceStore.shellWaiting, "install is now polling for a cable")
        XCTAssertFalse(store.proc?.isRunning == true)

        store.stop()
        let stopWaitDeadline = Date().addingTimeInterval(5)
        while store.running && Date() < stopWaitDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertFalse(store.running, "Stop must cancel the cable wait and end the install")
        XCTAssertTrue(store.stoppedByPlayer)
        XCTAssertTrue(deviceStore.waitCancelled)
        XCTAssertFalse(deviceStore.shellWaiting)
        XCTAssertEqual(store.doneNote, store.t("msg.stopped"))
        XCTAssertNil(store.failure)
        XCTAssertNil(store.installRecovery.pending)
    }
}
