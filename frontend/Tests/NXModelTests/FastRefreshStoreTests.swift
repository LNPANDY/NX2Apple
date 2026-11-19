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

    func testPackArchiveWithoutExtractMigratesLegacyTitleIDFolderToNamedGameFolderAndAvoidsEmptyDirWhenNoLegacyExists() throws {
        let store = makeStore()
        let out = temporary.appendingPathComponent("out-migrate").path
        let gamesRoot = out + "/games"
        self.repo.path = temporary.path
        store.outDir = out

        // Scenario A: legacy <TID>/romfs.img exists while named dest folder does not exist yet and workDir has no extract/v*.
        let tidA = "0100888800008888"
        let gameNameA = "Legacy Named Game"
        let legacyDirA = gamesRoot + "/" + tidA
        let legacyAOC = legacyDirA + "/aoc/0100888800008889"
        try fm.createDirectory(atPath: legacyAOC, withIntermediateDirectories: true)
        try "romfs-legacy".write(toFile: legacyDirA + "/romfs.img", atomically: true, encoding: .utf8)
        try "DMROMFSID1 size=12 index=cafe1234\n".write(toFile: legacyDirA + "/romfs.img.id", atomically: true, encoding: .utf8)
        try "stamp-v0".write(toFile: legacyDirA + "/.packstamp", atomically: true, encoding: .utf8)
        try "dlc-data".write(toFile: legacyAOC + "/addon.txt", atomically: true, encoding: .utf8)

        let workA = temporary.appendingPathComponent("workA").path
        try fm.createDirectory(atPath: workA + "/extract", withIntermediateDirectories: true)
        store.fastRefreshGameName = gameNameA
        store.selectedTitleID = tidA

        let destA = gamesRoot + "/" + gameNameA
        XCTAssertFalse(fm.fileExists(atPath: destA))

        let expA = expectation(description: "packArchive migrates legacy archive without extract")
        var returnedDestA = ""
        store.packArchive(workDir: workA, titleID: tidA) { path in
            returnedDestA = path
            expA.fulfill()
        }
        wait(for: [expA], timeout: 5.0)

        XCTAssertEqual(returnedDestA, destA)
        XCTAssertEqual(store.archivePath, destA)
        XCTAssertTrue(fm.fileExists(atPath: destA + "/" + gameNameA + ".img"))
        XCTAssertTrue(fm.fileExists(atPath: destA + "/" + gameNameA + ".img.id"))
        XCTAssertTrue(fm.fileExists(atPath: destA + "/.packstamp"))
        XCTAssertTrue(fm.fileExists(atPath: destA + "/aoc/0100888800008889/addon.txt"))
        XCTAssertTrue(fm.fileExists(atPath: destA + "/.titleid"))
        XCTAssertFalse(fm.fileExists(atPath: legacyDirA))

        // Scenario B: neither extract/v* nor legacy/local archive exists -> must not leave an empty dest folder behind.
        let tidB = "0100999900009999"
        let gameNameB = "External Only Game"
        let workB = temporary.appendingPathComponent("workB").path
        try fm.createDirectory(atPath: workB + "/extract", withIntermediateDirectories: true)
        store.fastRefreshGameName = gameNameB
        store.selectedTitleID = tidB

        let destB = gamesRoot + "/" + gameNameB
        let expB = expectation(description: "packArchive leaves no empty folder when no legacy exists")
        var returnedDestB = "initial"
        store.packArchive(workDir: workB, titleID: tidB) { path in
            returnedDestB = path
            expB.fulfill()
        }
        wait(for: [expB], timeout: 5.0)

        XCTAssertEqual(returnedDestB, "")
        XCTAssertEqual(store.archivePath, "")
        XCTAssertFalse(fm.fileExists(atPath: destB))
    }

    func testExternalImgFastRefreshUpdatesStageDetailAndAppendsReplaceReminder() throws {
        let runner = FakeProcessRunner()
        runner.answer = { launch in
            if launch.arguments.contains("--inspect-msl") {
                return ProcessResult(status: 0, out: "{\"has_trailer\": false}")
            }
            return ProcessResult(status: 0, out: "appended DMMSLTR1")
        }
        let store = makeStore(runner: runner)
        let repoDir = temporary.appendingPathComponent("repo-ext").path
        try setupMockRepo(in: repoDir)
        self.repo.path = repoDir

        let out = temporary.appendingPathComponent("out-ext").path
        let work = temporary.appendingPathComponent("work-ext").path
        let tid = "0100555500005555"
        try fm.createDirectory(atPath: out, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: work + "/extract", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: work + "/shader/ios/b-a5e7fb6e4fa4", withIntermediateDirectories: true)
        try Data("msl-payload".utf8).write(to: URL(fileURLWithPath: work + "/shader/ios/b-a5e7fb6e4fa4/shaders.metallib"))

        let extImg = temporary.appendingPathComponent("PulledMario.img").path
        try Data("existing-romfs".utf8).write(to: URL(fileURLWithPath: extImg))

        store.outDir = out
        store.selectedTitleID = tid
        store.fastRefreshExternalImgPath = extImg

        let exp = expectation(description: "packArchive external img in-place update")
        var returnedDest = "unset"
        store.packArchive(workDir: work, titleID: tid, isFastRefresh: true) { path in
            returnedDest = path
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)

        XCTAssertEqual(returnedDest, "")
        let stage = try XCTUnwrap(store.stages.first(where: { $0.id == 1000 }))
        XCTAssertEqual(stage.state, .done)
        XCTAssertNotEqual(stage.detail, store.t("prog.noRomfs"))
        XCTAssertEqual(stage.detail, String(format: store.t("prog.externalImgUpdated"), "PulledMario.img"))
        XCTAssertTrue(store.needsReplaceOldImgReminder)
        XCTAssertEqual(store.updatedImgPath, extImg)

        store.finishInstall(nil, note: "Installed on iPhone")
        XCTAssertTrue(store.done)
        let expectedReminder = String(format: store.t("imgGuide.replaceOldImgBody"), "PulledMario.img")
        XCTAssertTrue(store.doneNote.contains(expectedReminder), store.doneNote)
    }

    func testLocalTargetImgFastRefreshSetsReplaceReminderAndFrameworkExportShowsRealSize() throws {
        let runner = FakeProcessRunner()
        runner.answer = { launch in
            if launch.arguments.contains("--inspect-msl") {
                return ProcessResult(status: 0, out: "{\"has_trailer\": false}")
            }
            return ProcessResult(status: 0, out: "appended DMMSLTR1")
        }
        let store = makeStore(runner: runner)
        let repoDir = temporary.appendingPathComponent("repo-local").path
        try setupMockRepo(in: repoDir)
        self.repo.path = repoDir

        let out = temporary.appendingPathComponent("out-local").path
        let work = temporary.appendingPathComponent("work-local").path
        let tid = "0100666600006666"
        let dest = out + "/games/Mario"
        let targetImg = dest + "/Mario.img"
        try fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
        try Data("local-romfs".utf8).write(to: URL(fileURLWithPath: targetImg))
        try fm.createDirectory(atPath: work + "/extract", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: work + "/shader/ios/b-a5e7fb6e4fa4", withIntermediateDirectories: true)
        try Data("msl-payload".utf8).write(to: URL(fileURLWithPath: work + "/shader/ios/b-a5e7fb6e4fa4/shaders.metallib"))

        store.outDir = out
        store.selectedTitleID = tid
        store.fastRefreshGameName = "Mario"

        let exp = expectation(description: "packArchive local targetImg fast refresh")
        store.packArchive(workDir: work, titleID: tid, isFastRefresh: true) { _ in
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)

        XCTAssertTrue(store.needsReplaceOldImgReminder)
        XCTAssertEqual(store.updatedImgPath, targetImg)

        let fwDir = out + "/DmGame\(tid).framework"
        try fm.createDirectory(atPath: fwDir, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 3_145_728).write(to: URL(fileURLWithPath: fwDir + "/DmGame\(tid)"))
        store.exportedIPAPath = fwDir

        XCTAssertTrue(store.exportedIPAText.contains("3 MB"), store.exportedIPAText)
        XCTAssertFalse(store.exportedIPAText.contains("1 KB"), store.exportedIPAText)
    }

    func testArchiveReusableAndRomfsImageSetReplaceReminderWhenIOSAndShaderSource() throws {
        let runner = FakeProcessRunner()
        runner.answer = { launch in
            if launch.arguments.contains("--inspect-msl") {
                return ProcessResult(status: 0, out: "{\"has_trailer\": false}")
            }
            return ProcessResult(status: 0, out: "appended DMMSLTR1")
        }
        let repoDir = temporary.appendingPathComponent("repo-archive-paths").path
        try setupMockRepo(in: repoDir)
        self.repo.path = repoDir

        let tid = "0100777700007777"
        let version = "v0"

        // 1. archiveReusable path (extract/<v>/RomFS + matching .packstamp + existing targetImg)
        let outReuse = temporary.appendingPathComponent("out-reuse").path
        let workReuse = temporary.appendingPathComponent("work-reuse").path
        let romfsReuse = workReuse + "/extract/" + version + "/RomFS"
        let destReuse = outReuse + "/games/Mario"
        let targetImgReuse = destReuse + "/Mario.img"
        try fm.createDirectory(atPath: romfsReuse, withIntermediateDirectories: true)
        try Data("asset".utf8).write(to: URL(fileURLWithPath: romfsReuse + "/data.bin"))
        try fm.createDirectory(atPath: destReuse, withIntermediateDirectories: true)
        try Data("existing-img".utf8).write(to: URL(fileURLWithPath: targetImgReuse))
        try fm.createDirectory(atPath: workReuse + "/shader/ios/b-a5e7fb6e4fa4", withIntermediateDirectories: true)
        try Data("msl-payload".utf8).write(to: URL(fileURLWithPath: workReuse + "/shader/ios/b-a5e7fb6e4fa4/shaders.metallib"))
        RomFSArchive.writeStamp(source: romfsReuse, version: version, to: destReuse + "/.packstamp")

        let storeReuse = makeStore(runner: runner)
        storeReuse.outDir = outReuse
        storeReuse.selectedTitleID = tid
        storeReuse.runningTarget = BuildTarget.ios
        storeReuse.fastRefreshGameName = "Mario"

        let expReuse = expectation(description: "packArchive archiveReusable sets replace reminder")
        storeReuse.packArchive(workDir: workReuse, titleID: tid, isFastRefresh: false) { _ in
            expReuse.fulfill()
        }
        wait(for: [expReuse], timeout: 5.0)
        XCTAssertTrue(storeReuse.needsReplaceOldImgReminder)
        XCTAssertEqual(storeReuse.updatedImgPath, targetImgReuse)

        // 2. romfsImage path (extract/<v>/RomFS.img without .packstamp)
        let outImg = temporary.appendingPathComponent("out-romfsimg").path
        let workImg = temporary.appendingPathComponent("work-romfsimg").path
        let extractVImg = workImg + "/extract/" + version
        let destImg = outImg + "/games/Mario"
        let targetImg = destImg + "/Mario.img"
        try fm.createDirectory(atPath: extractVImg, withIntermediateDirectories: true)
        try Data("romfs-image-bytes".utf8).write(to: URL(fileURLWithPath: extractVImg + "/RomFS.img"))
        try fm.createDirectory(atPath: workImg + "/shader/ios/b-a5e7fb6e4fa4", withIntermediateDirectories: true)
        try Data("msl-payload".utf8).write(to: URL(fileURLWithPath: workImg + "/shader/ios/b-a5e7fb6e4fa4/shaders.metallib"))

        let storeImg = makeStore(runner: runner)
        storeImg.outDir = outImg
        storeImg.selectedTitleID = tid
        storeImg.runningTarget = BuildTarget.ios
        storeImg.fastRefreshGameName = "Mario"

        let expImg = expectation(description: "packArchive romfsImage sets replace reminder")
        storeImg.packArchive(workDir: workImg, titleID: tid, isFastRefresh: false) { _ in
            expImg.fulfill()
        }
        wait(for: [expImg], timeout: 5.0)
        XCTAssertTrue(storeImg.needsReplaceOldImgReminder)
        XCTAssertEqual(storeImg.updatedImgPath, targetImg)
    }
}
