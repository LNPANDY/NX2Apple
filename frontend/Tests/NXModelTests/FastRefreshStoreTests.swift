import Foundation
import XCTest
@testable import NXModel
@testable import NXCore

@MainActor final class FastRefreshStoreTests: XCTestCase {
    private final class FakeRepo: RepoLocation {
        var path = "/repo"
        var isRepo = true
        var isGit = true
    }

    private final class FakeDeps: DependencyInstalling {
        var pythonPath = "/usr/bin/python3"
        var dotnetPath = "/usr/bin/true"
        var checked = true
        var allPresent = true
        var deps: [Dep] = []
        var installed: [String] = []
        var busy: Set<String> = []
        func isInstalling(_ id: String) -> Bool { busy.contains(id) }
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

    private final class StartRecordingRunner: ProcessRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [ProcessLaunch] = []
        var launches: [ProcessLaunch] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }
        var onStart: (@Sendable (ProcessLaunch, @escaping (Int32) -> Void) -> Void)?

        func capture(_ launch: ProcessLaunch) -> ProcessResult {
            lock.lock()
            recorded.append(launch)
            lock.unlock()
            return ProcessResult()
        }

        func stream(_ launch: ProcessLaunch, line: @escaping (String) -> Void) -> Bool {
            lock.lock()
            recorded.append(launch)
            lock.unlock()
            return true
        }

        func streamLines(_ launch: ProcessLaunch, started: @escaping (RunningProcess) -> Void, line: @escaping (String) -> Void) -> ProcessResult {
            lock.lock()
            recorded.append(launch)
            lock.unlock()
            started(FakeRunningProcess())
            return ProcessResult(status: 0)
        }

        func start(_ launch: ProcessLaunch, onOutput: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> RunningProcess {
            lock.lock()
            recorded.append(launch)
            let handler = onStart
            lock.unlock()
            if let handler {
                handler(launch, onExit)
            }
            return FakeRunningProcess()
        }
    }

    private var defaults: UserDefaults!
    private var temporary: URL!
    private let repo = FakeRepo()
    private let deps = FakeDeps()
    private let engine = FakeEngine()
    private let devices = FakeDevices()
    private let localizer = Localizer(.en)
    private let fm = FileManager.default

    override func setUpWithError() throws {
        defaults = TestDefaults.make("nxmodel-fastrefresh-tests")
        temporary = fm.temporaryDirectory.appendingPathComponent("nxmodel-fastrefresh-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: temporary)
    }

    private func makeStore(runner: ProcessRunner = FakeProcessRunner()) -> BuildStore {
        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices,
                               defaults: defaults, targetChanged: {})
        store.home = temporary.appendingPathComponent("test-home").path
        try? fm.createDirectory(atPath: store.home + "/Library/Application Support/NX2Apple/shell", withIntermediateDirectories: true)
        return store
    }

    private func setupMockRepo(in dir: String) throws {
        let scriptsDir = dir + "/scripts"
        let dmToolsDir = dir + "/dm/tools"
        try fm.createDirectory(atPath: scriptsDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: dmToolsDir, withIntermediateDirectories: true)
        try "ap.add_argument('--from-seed')".write(toFile: scriptsDir + "/build_ipa_from_nsp.py", atomically: true, encoding: .utf8)
        try "ap.add_argument('--extract-msl')".write(toFile: dmToolsDir + "/romfs_image.py", atomically: true, encoding: .utf8)
        try "#!/bin/sh\n".write(toFile: dmToolsDir + "/build_seed.py", atomically: true, encoding: .utf8)
    }

    func testKeyPreflightProblemBypassedDuringFastRefresh() {
        let store = makeStore()
        store.updateSlot("keys") { $0.paths = ["/path/to/nonexistent/prod.keys"] }
        store.updateSlot("base") { $0.paths = ["/path/to/game.nsp"] }
        store.preflightKeyProblem = { _, _ in "Missing keys!" }

        // Normal build: problem reported
        store.fastRefreshActive = false
        XCTAssertEqual(store.keyPreflightProblem(), "Missing keys!")

        // Fast refresh: problem bypassed (nil)
        store.fastRefreshActive = true
        XCTAssertNil(store.keyPreflightProblem())
    }

    func testPreflightSpaceProblemUsesCompactBudgetDuringFastRefresh() {
        let store = makeStore()
        let out = temporary.appendingPathComponent("out").path
        try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)
        store.outDir = out
        let hugeNSP = temporary.appendingPathComponent("huge.nsp").path
        try? "x".write(toFile: hugeNSP, atomically: true, encoding: .utf8)
        store.updateSlot("base") { $0.paths = [hugeNSP] }

        // Set available space to 1 GB
        store.spaceAvailable = { _ in 1_000_000_000 }

        store.fastRefreshActive = true
        // 1 GB is well above 500 MB compact budget -> no space problem
        XCTAssertNil(store.preflightSpaceProblem())

        // If available space is less than 500 MB (e.g. 200 MB), it should report short
        store.spaceAvailable = { _ in 200_000_000 }
        XCTAssertNotNil(store.preflightSpaceProblem())
    }

    func testPackArchivePreservesExistingImageWhenVersionMissing() {
        let runner = FakeProcessRunner()
        runner.answer = { _ in ProcessResult(status: 0, out: "{\"has_trailer\": false}") }
        let store = makeStore(runner: runner)

        let out = temporary.appendingPathComponent("out").path
        let work = temporary.appendingPathComponent("work").path
        let tid = "0100111100001111"
        let folderName = tid
        let dest = out + "/games/" + folderName
        let targetImg = dest + "/" + folderName + ".img"

        try? fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
        try? "existing-romfs-data".write(toFile: targetImg, atomically: true, encoding: .utf8)
        try? fm.createDirectory(atPath: work + "/extract", withIntermediateDirectories: true)
        // Note: No work/extract/v* exists!

        store.outDir = out
        store.selectedTitleID = tid
        self.repo.path = temporary.path

        let exp = expectation(description: "packArchive callback")
        var returnedDest = ""

        store.packArchive(workDir: work, titleID: tid) { destPath in
            returnedDest = destPath
            exp.fulfill()
        }

        waitForExpectations(timeout: 5)
        XCTAssertEqual(returnedDest, dest)
        XCTAssertTrue(fm.fileExists(atPath: targetImg))
        let contents = try? String(contentsOfFile: targetImg, encoding: .utf8)
        XCTAssertEqual(contents, "existing-romfs-data")
    }

    func testPackArchiveGracefullyHandlesMissingLocalImageWhenVersionMissing() {
        let store = makeStore()
        let out = temporary.appendingPathComponent("out").path
        let work = temporary.appendingPathComponent("work").path
        let tid = "0100222200002222"

        try? fm.createDirectory(atPath: work + "/extract", withIntermediateDirectories: true)
        // No targetImg on disk and no work/extract/v*

        store.outDir = out
        store.selectedTitleID = tid
        self.repo.path = temporary.path

        let exp = expectation(description: "packArchive callback without local img")
        var returnedDest = "initial"

        store.packArchive(workDir: work, titleID: tid) { destPath in
            returnedDest = destPath
            exp.fulfill()
        }

        waitForExpectations(timeout: 5)
        XCTAssertEqual(returnedDest, "")
        XCTAssertFalse(store.stages.contains(where: { $0.state == .failed }))
        XCTAssertTrue(store.stages.contains(where: { $0.id == 1000 && $0.state == .done }))
    }

    func testResolvedOutDirIsolationWhenEmptyOutDir() throws {
        let runner = StartRecordingRunner()
        let store = makeStore(runner: runner)
        let repoDir = temporary.appendingPathComponent("repo").path
        try setupMockRepo(in: repoDir)
        self.repo.path = repoDir

        // Case 1: outDir is empty, basePath is empty -> fallback to refresh-builds under store.home
        store.outDir = ""
        store.leaveGameFolder()
        store.updateSlot("base") { $0.paths = [] }
        let tid = "0100333300003333"

        store.startFastRefresh(titleID: tid, target: 0)

        // Verify effectiveOutputFolder did not resolve to "/"
        XCTAssertNotEqual(store.effectiveOutputFolder, "")
        XCTAssertNotEqual(store.effectiveOutputFolder, "/")
        let expectedFallback = (BuildSeedCache.defaultRoot(home: store.home) as NSString).deletingLastPathComponent + "/refresh-builds"
        XCTAssertEqual(store.effectiveOutputFolder, expectedFallback)
        XCTAssertTrue(runner.launches.contains { launch in
            launch.arguments.contains(expectedFallback + "/" + tid + "_build")
        })
    }

    func testResolvedOutDirDoesNotPolluteOtherGameBasePath() throws {
        let runner = StartRecordingRunner()
        let store = makeStore(runner: runner)
        let repoDir = temporary.appendingPathComponent("repo").path
        try setupMockRepo(in: repoDir)
        self.repo.path = repoDir

        // Store has residual basePath from game 0100999900009999
        let otherDir = temporary.appendingPathComponent("other-game-folder").path
        try fm.createDirectory(atPath: otherDir, withIntermediateDirectories: true)
        let otherNSP = otherDir + "/0100999900009999.nsp"
        try "x".write(toFile: otherNSP, atomically: true, encoding: .utf8)
        store.updateSlot("base") { $0.paths = [otherNSP] }
        store.outDir = ""

        let currentTID = "0100111100001111"
        store.startFastRefresh(titleID: currentTID, target: 0)

        // It must NOT borrow otherDir!
        XCTAssertNotEqual(store.effectiveOutputFolder, otherDir)
        let expectedFallback = (BuildSeedCache.defaultRoot(home: store.home) as NSString).deletingLastPathComponent + "/refresh-builds"
        XCTAssertEqual(store.effectiveOutputFolder, expectedFallback)
    }

    func testHomeDirectoryIsolation() throws {
        let runner = StartRecordingRunner()
        let store = makeStore(runner: runner)
        let customHome = temporary.appendingPathComponent("isolated-home").path
        try fm.createDirectory(atPath: customHome, withIntermediateDirectories: true)
        store.home = customHome

        let repoDir = temporary.appendingPathComponent("repo").path
        try setupMockRepo(in: repoDir)
        self.repo.path = repoDir

        let tid = "0100444400004444"
        store.startFastRefresh(titleID: tid, target: 0)

        let expectedSeedRoot = BuildSeedCache.defaultRoot(home: customHome)
        XCTAssertTrue(runner.launches.contains { launch in
            launch.arguments.contains("--seed-cache-dir") && launch.arguments.contains(expectedSeedRoot)
        })
    }

    func testExportsOneGameArgumentsAndCompletion() throws {
        let runner = StartRecordingRunner()
        let store = makeStore(runner: runner)
        let repoDir = temporary.appendingPathComponent("repo").path
        try setupMockRepo(in: repoDir)
        self.repo.path = repoDir

        self.devices.exportIPA = true
        self.devices.exportOneGame = true
        let tid = "0100555500005555"

        store.startFastRefresh(titleID: tid, target: 1) // iOS target

        XCTAssertTrue(runner.launches.contains { launch in
            launch.arguments.contains("-o") && launch.arguments.contains(store.oneGameIPAPath) && launch.environment?["DM_FULL_ROMFS"] == "1"
        })
        XCTAssertFalse(store.oneGameIPAPath.isEmpty)
    }

    func testVerifyShellDeviceCalledWhenNeeded() throws {
        let store = makeStore()
        let repoDir = temporary.appendingPathComponent("repo").path
        try setupMockRepo(in: repoDir)
        self.repo.path = repoDir

        self.devices.installDevice = "device-123"
        self.devices.exportIPA = false
        store.shellDeviceChecked = false

        var resumeCalled = false
        store.verifyShellDevice(then: {
            resumeCalled = true
        })

        // verifyShellDevice sets running = true and launches async check
        XCTAssertTrue(store.running)
        store.stopping = true
        _ = resumeCalled
    }

    func testIOSFastRefreshExitZeroPackArchiveUsesIsolatedGamesRootAndClearsState() throws {
        let runner = StartRecordingRunner()
        let store = makeStore(runner: runner)
        let repoDir = temporary.appendingPathComponent("repo").path
        try setupMockRepo(in: repoDir)
        self.repo.path = repoDir

        // Residual form state from another game
        let otherDir = temporary.appendingPathComponent("other-game-folder").path
        try fm.createDirectory(atPath: otherDir, withIntermediateDirectories: true)
        store.updateSlot("base") { $0.paths = [otherDir + "/other.nsp"] }
        store.outDir = ""

        let tid = "0100777700007777"
        let gameName = "TestGame"
        store.shellDeviceChecked = true
        self.devices.exportIPA = true
        self.devices.exportOneGame = false

        let expectedFallback = (BuildSeedCache.defaultRoot(home: store.home) as NSString).deletingLastPathComponent + "/refresh-builds"
        let expectedGamesRoot = expectedFallback + "/games"
        let expectedDest = expectedGamesRoot + "/" + gameName
        try fm.createDirectory(atPath: expectedDest, withIntermediateDirectories: true)
        try "fake img".write(toFile: expectedDest + "/" + gameName + ".img", atomically: true, encoding: .utf8)

        let workDir = expectedFallback + "/" + tid + "_build"
        let fwDir = workDir + "/nxnative.framework"
        try fm.createDirectory(atPath: fwDir, withIntermediateDirectories: true)

        runner.onStart = { launch, onExit in
            DispatchQueue.global().async {
                onExit(0)
            }
        }

        store.startFastRefresh(titleID: tid, target: 1, gameName: gameName)

        let waitGate = expectation(description: "wait packArchive")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            waitGate.fulfill()
        }
        wait(for: [waitGate], timeout: 2.0)

        // Verify gamesRoot did NOT fall back to otherDir or "/games"
        XCTAssertFalse(store.archivePath.hasPrefix(otherDir))
        XCTAssertFalse(store.archivePath.hasPrefix("/games"))
        XCTAssertEqual(store.archivePath, expectedDest)

        // Verify fast refresh state is cleanly reset
        XCTAssertFalse(store.fastRefreshActive)
        XCTAssertNil(store.fastRefreshBaseDir)
        XCTAssertNil(store.fastRefreshGameName)
    }

    func testVerifyShellDeviceStoppingClearsFastRefreshState() throws {
        let store = makeStore()
        let repoDir = temporary.appendingPathComponent("repo").path
        try setupMockRepo(in: repoDir)
        self.repo.path = repoDir

        self.devices.installDevice = "device-123"
        self.devices.exportIPA = false
        store.shellDeviceChecked = false

        store.fastRefreshActive = true
        store.fastRefreshBaseDir = "/tmp/test"
        store.fastRefreshGameName = "TestGame"
        store.stopping = true

        let exp = expectation(description: "verify completed stopping")
        store.verifyShellDevice {
            XCTFail("resume should not be called when stopping")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        XCTAssertFalse(store.fastRefreshActive)
        XCTAssertNil(store.fastRefreshBaseDir)
        XCTAssertNil(store.fastRefreshGameName)
    }

    func testVerifyShellDeviceUnpairedClearsFastRefreshState() throws {
        let store = makeStore()
        let repoDir = temporary.appendingPathComponent("repo").path
        try setupMockRepo(in: repoDir)
        self.repo.path = repoDir

        self.devices.installDevice = "unpaired-device"
        self.devices.exportIPA = false
        store.shellDeviceChecked = false

        store.fastRefreshActive = true
        store.fastRefreshBaseDir = "/tmp/test"
        store.fastRefreshGameName = "TestGame"
        store.stopping = false

        let exp = expectation(description: "verify completed unpaired")
        store.verifyShellDevice {
            XCTFail("resume should not be called when unpaired")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        XCTAssertFalse(store.fastRefreshActive)
        XCTAssertNil(store.fastRefreshBaseDir)
        XCTAssertNil(store.fastRefreshGameName)
    }
}
