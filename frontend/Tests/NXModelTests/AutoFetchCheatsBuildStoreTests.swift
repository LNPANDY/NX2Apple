import Foundation
import XCTest
@testable import NXCore
@testable import NXModel

@MainActor final class AutoFetchCheatsBuildStoreTests: XCTestCase {
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

    private final class StartRecordingRunner: ProcessRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [ProcessLaunch] = []
        var launches: [ProcessLaunch] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        func capture(_ launch: ProcessLaunch) -> ProcessResult {
            lock.lock(); recorded.append(launch); lock.unlock()
            return ProcessResult()
        }

        func stream(_ launch: ProcessLaunch, line: @escaping (String) -> Void) -> Bool {
            lock.lock(); recorded.append(launch); lock.unlock()
            return true
        }

        func streamLines(_ launch: ProcessLaunch, started: @escaping (RunningProcess) -> Void, line: @escaping (String) -> Void) -> ProcessResult {
            lock.lock(); recorded.append(launch); lock.unlock()
            started(FakeRunningProcess())
            return ProcessResult(status: 0)
        }

        func start(_ launch: ProcessLaunch, onOutput: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> RunningProcess {
            lock.lock(); recorded.append(launch); lock.unlock()
            return FakeRunningProcess()
        }
    }

    private var temporary: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        temporary = fm.temporaryDirectory.appendingPathComponent("nx-autofetch-store-\(UUID().uuidString)")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        let suite = TestDefaults.suite("autofetch-cheats")
        suiteName = suite.name
        defaults = suite.defaults
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? fm.removeItem(at: temporary)
    }

    private func makeMockRepo(supportsFetch: Bool) throws -> URL {
        let repo = temporary.appendingPathComponent("repo-\(UUID().uuidString)")
        try fm.createDirectory(at: repo.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try fm.createDirectory(at: repo.appendingPathComponent("dm/tools/nx_extract"), withIntermediateDirectories: true)
        try Data().write(to: repo.appendingPathComponent("dm/tools/nx_extract/Program.cs"))
        try Data().write(to: repo.appendingPathComponent("dm/tools/romfs_image.py"))
        var script = """
        # stub
        ap.add_argument('--work-dir')
        ap.add_argument('--from-seed')
        ap.add_argument('--cheat-dir')
        """
        if supportsFetch {
            script += "\nap.add_argument('--fetch-cheats')\n"
        }
        try Data(script.utf8).write(to: repo.appendingPathComponent("scripts/build_ipa_from_nsp.py"))
        try Data("print('synced')\n".utf8).write(to: repo.appendingPathComponent("engine.marker"))
        return repo
    }

    private func makeStore(repo: URL, runner: StartRecordingRunner, fakeHome: URL) -> BuildStore {
        let shellDir = temporary.appendingPathComponent("shell-\(UUID().uuidString)")
        try? fm.createDirectory(at: fakeHome, withIntermediateDirectories: true)
        try? fm.createDirectory(at: shellDir, withIntermediateDirectories: true)
        defaults.set(shellDir.path, forKey: "shellRoot")
        let localizer = Localizer(.en)
        let repoLoc = FakeRepo()
        repoLoc.path = repo.path
        let deps = FakeDeps()
        let devices = FakeDevices()
        devices.exportIPA = true
        let store = BuildStore(
            localizer: localizer,
            runner: runner,
            repo: repoLoc,
            deps: deps,
            engine: FakeEngine(),
            devices: devices,
            defaults: defaults
        )
        store.home = fakeHome.path
        store.outDir = temporary.appendingPathComponent("out-\(UUID().uuidString)").path
        store.spaceAvailable = { _ in 100_000_000_000 }
        store.cloudFolderCheck = { _ in false }
        store.preflightKeyProblem = { _, _ in nil }
        return store
    }

    func testAutoFetchCheatsDefaultsTrueAndPersistsAcrossStoreInstances() throws {
        let repo = try makeMockRepo(supportsFetch: true)
        let store1 = makeStore(repo: repo, runner: StartRecordingRunner(), fakeHome: temporary)
        XCTAssertTrue(store1.autoFetchCheats, "autoFetchCheats must default to true")

        store1.autoFetchCheats = false
        let store2 = makeStore(repo: repo, runner: StartRecordingRunner(), fakeHome: temporary)
        XCTAssertFalse(store2.autoFetchCheats, "autoFetchCheats false preference must persist in UserDefaults")
    }

    func testMacAndIOSFullBuildsPassFetchCheatsAndStandardCheatsDirEvenWhenFolderDoesNotExist() throws {
        let repo = try makeMockRepo(supportsFetch: true)
        let tid = "010015100B514000"
        let fakeHome = temporary.appendingPathComponent("home")
        let nsp = temporary.appendingPathComponent("Game [\(tid)].nsp")
        let keys = temporary.appendingPathComponent("prod.keys")
        try Data("nsp".utf8).write(to: nsp)
        try Data("keys".utf8).write(to: keys)

        let expectedCheatsDir = fakeHome.appendingPathComponent("Library/Application Support/nxnative/\(tid)/cheats").path
        XCTAssertFalse(fm.fileExists(atPath: expectedCheatsDir))

        for target in [BuildTarget.mac, BuildTarget.ios] {
            let runner = StartRecordingRunner()
            let store = makeStore(repo: repo, runner: runner, fakeHome: fakeHome)
            store.target = target
            store.slots[0].paths = [nsp.path]
            store.slots[3].paths = [keys.path]
            store.startBuild()

            let launch = try XCTUnwrap(runner.launches.last, "expected build launch for target \(target): \(store.doneNote)")
            XCTAssertTrue(launch.arguments.contains("--fetch-cheats"), "expected --fetch-cheats for target \(target)")
            let idx = try XCTUnwrap(launch.arguments.firstIndex(of: "--cheat-dir"), "expected --cheat-dir for target \(target)")
            XCTAssertEqual(launch.arguments[idx + 1], expectedCheatsDir)
            XCTAssertTrue(store.logTail.contains(store.t("msg.fetchCheatsOn")))
        }

        // When toggled off, --fetch-cheats is omitted and missing cheats dir is not passed.
        let offRunner = StartRecordingRunner()
        let offStore = makeStore(repo: repo, runner: offRunner, fakeHome: fakeHome)
        offStore.autoFetchCheats = false
        offStore.target = BuildTarget.ios
        offStore.slots[0].paths = [nsp.path]
        offStore.slots[3].paths = [keys.path]
        offStore.startBuild()

        let offLaunch = try XCTUnwrap(offRunner.launches.last)
        XCTAssertFalse(offLaunch.arguments.contains("--fetch-cheats"))
        XCTAssertFalse(offLaunch.arguments.contains("--cheat-dir"))
    }

    func testFastRefreshAndQueueEntrySnapshotAndLegacyEngineGate() throws {
        let modernRepo = try makeMockRepo(supportsFetch: true)
        let tid = "010015100B514000"
        let fakeHome = temporary.appendingPathComponent("home-fast")
        let expectedCheatsDir = fakeHome.appendingPathComponent("Library/Application Support/nxnative/\(tid)/cheats").path

        // Queue entry snapshot overrides store default (true -> false, and false -> true).
        let queueRunner = StartRecordingRunner()
        let store = makeStore(repo: modernRepo, runner: queueRunner, fakeHome: fakeHome)
        store.autoFetchCheats = false
        let queuedMac = QueueEntry(
            titleID: tid,
            name: "Game",
            target: BuildTarget.mac,
            inputs: [:],
            outputDirectory: temporary.appendingPathComponent("out-q").path,
            engineID: "main",
            fastRefresh: true,
            autoFetchCheats: true
        )
        XCTAssertNil(store.startQueued(queuedMac))
        let qLaunch = try XCTUnwrap(queueRunner.launches.last)
        XCTAssertTrue(qLaunch.arguments.contains("--fetch-cheats"))
        let qIdx = try XCTUnwrap(qLaunch.arguments.firstIndex(of: "--cheat-dir"))
        XCTAssertEqual(qLaunch.arguments[qIdx + 1], expectedCheatsDir)
        XCTAssertEqual(store.installRecovery.lastFastRefresh?.autoFetchCheats, true)

        // Codable backward compatibility: legacy QueueEntry JSON without autoFetchCheats decodes cleanly with nil.
        let legacyJSON = """
        {"id":"00000000-0000-0000-0000-000000000001","titleID":"\(tid)","name":"G","target":"mac-app","engineID":"main","batch":"00000000-0000-0000-0000-000000000002","status":"queued"}
        """
        let decoded = try JSONDecoder().decode(QueueEntry.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(decoded.autoFetchCheats)

        // Legacy engine lacking --fetch-cheats never receives it even when autoFetchCheats == true.
        let legacyRepo = try makeMockRepo(supportsFetch: false)
        let legacyRunner = StartRecordingRunner()
        let legacyStore = makeStore(repo: legacyRepo, runner: legacyRunner, fakeHome: fakeHome)
        legacyStore.autoFetchCheats = true
        legacyStore.startFastRefresh(titleID: tid, targetName: BuildTarget.mac)
        let legacyLaunch = try XCTUnwrap(legacyRunner.launches.last)
        XCTAssertFalse(legacyLaunch.arguments.contains("--fetch-cheats"))
        XCTAssertFalse(legacyLaunch.arguments.contains("--cheat-dir"))
    }
}
