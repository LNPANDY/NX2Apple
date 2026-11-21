import XCTest
@testable import NXModel
@testable import NXCore

/// The build store's moves of the nxkit work folder and the build seeds (BuildStore+CacheFolders.swift): the saved roots, the way
/// back, the build guard, `DM_SEED_CACHE_DIR` for the engine and a drive that is not connected. Every test has its own home and
/// defaults, so the real Library is never touched.
@MainActor final class CacheFolderStoreTests: XCTestCase {
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
        func syncEngine(then: ((Bool) -> Void)?) -> Task<Void, Never> { then?(true); return Task {} }
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

    private var defaults: UserDefaults!
    private var temporary: String!
    private let fm = FileManager.default
    private var volumes: String { temporary + "/Volumes" }

    override func setUpWithError() throws {
        defaults = TestDefaults.make("nxmodel-cache-folders")
        temporary = fm.temporaryDirectory.path + "/nxmodel-cache-folders-" + UUID().uuidString
        try fm.createDirectory(atPath: temporary + "/home", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: volumes, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(atPath: temporary) }

    private func makeStore() -> BuildStore {
        let store = BuildStore(localizer: Localizer(.en), runner: FakeProcessRunner(), repo: FakeRepo(), deps: FakeDeps(), engine: FakeEngine(),
                               devices: FakeDevices(), defaults: defaults, volumesRoot: volumes, targetChanged: {})
        store.home = temporary + "/home"
        store.launcherEnvironment = [:]
        return store
    }

    private func write(_ path: String) throws {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: URL(fileURLWithPath: path))
    }

    func testTheRowsShowTodaysPlacesUntilTheyMove() {
        let store = makeStore()
        XCTAssertEqual(store.cachePath(.nxkit), store.home + "/Library/Caches/NX2Apple/nxkit")
        XCTAssertEqual(store.cachePath(.seeds), store.home + "/Library/Application Support/nxnative/build-seeds")
        XCTAssertEqual(store.refreshBuildsRoot, store.home + "/Library/Application Support/nxnative/refresh-builds")
        XCTAssertTrue(store.cacheIsDefault(.nxkit))
        XCTAssertTrue(store.cacheIsDefault(.seeds))
        XCTAssertFalse(store.cacheUnreachable(.nxkit))
        XCTAssertNil(store.seedRootProblem())
        XCTAssertNil(store.nxkitWorkRootProblem())
        XCTAssertNil(store.toolEnvironment(python: "/usr/bin/python3")["DM_SEED_CACHE_DIR"], "the engine keeps its own default")
    }

    func testTheNxkitWorkFolderMovesSavesItsPlaceAndComesBack() async throws {
        let store = makeStore()
        let old = store.nxkitWorkRoot
        try write(old + "/01007EF00011E000/romfs/data.bin")
        let picked = temporary + "/Drive"
        try fm.createDirectory(atPath: picked, withIntermediateDirectories: true)

        store.prepareCacheMove(.nxkit, into: picked)
        guard case .confirm(let plan) = store.nxkitMove else { return XCTFail("the confirmation shows") }
        XCTAssertEqual(plan.destination, picked + "/NX2Apple-nxkit")
        XCTAssertEqual(store.shellMove, .idle, "only this row's panel opens")
        store.running = true
        XCTAssertNil(store.confirmCacheMove(.nxkit), "refused while a build runs")
        store.running = false

        let task = try XCTUnwrap(store.confirmCacheMove(.nxkit))
        XCTAssertTrue(store.running, "no build starts while the folder moves")
        XCTAssertTrue(store.cacheMoveRuns)
        await task.value
        XCTAssertEqual(store.nxkitMove, .moved(picked + "/NX2Apple-nxkit"))
        XCTAssertFalse(store.running)
        XCTAssertEqual(defaults.string(forKey: BuildCacheRoots.nxkitKey), picked + "/NX2Apple-nxkit")
        XCTAssertEqual(store.nxkitWorkRoot, picked + "/NX2Apple-nxkit")
        XCTAssertEqual(NxkitBuilder.workDirectory(root: store.nxkitWorkRoot, key: "01007EF00011E000"), picked + "/NX2Apple-nxkit/01007EF00011E000")
        XCTAssertTrue(fm.fileExists(atPath: picked + "/NX2Apple-nxkit/01007EF00011E000/romfs/data.bin"))
        XCTAssertFalse(store.cacheIsDefault(.nxkit))

        store.dismissCacheMove(.nxkit)
        store.prepareCacheMoveToDefault(.nxkit)
        await store.confirmCacheMove(.nxkit)?.value
        XCTAssertEqual(store.nxkitMove, .moved(old))
        XCTAssertNil(defaults.string(forKey: BuildCacheRoots.nxkitKey), "the default place is no saved value")
        XCTAssertTrue(fm.fileExists(atPath: old + "/01007EF00011E000/romfs/data.bin"))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: picked), [], "the picked folder stays, empty as it was")
    }

    func testTheSeedsMoveWithRefreshBuildsAndTheEngineIsToldWhere() async throws {
        let store = makeStore()
        try write(store.seedCacheRoot + "/0100AAAA00000000/seed.json")
        try write(store.refreshBuildsRoot + "/0100AAAA00000000_build/work.bin")
        let picked = temporary + "/Drive"
        try fm.createDirectory(atPath: picked, withIntermediateDirectories: true)

        store.prepareCacheMove(.seeds, into: picked)
        await store.confirmCacheMove(.seeds)?.value
        let seeds = picked + "/NX2Apple-build-seeds/build-seeds"
        XCTAssertEqual(store.seedMove, .moved(seeds))
        XCTAssertEqual(store.seedCacheRoot, seeds)
        XCTAssertEqual(store.refreshBuildsRoot, picked + "/NX2Apple-build-seeds/refresh-builds")
        XCTAssertTrue(fm.fileExists(atPath: seeds + "/0100AAAA00000000/seed.json"))
        XCTAssertTrue(fm.fileExists(atPath: store.refreshBuildsRoot + "/0100AAAA00000000_build/work.bin"))
        XCTAssertEqual(store.toolEnvironment(python: "/usr/bin/python3")["DM_SEED_CACHE_DIR"], seeds, "every engine build gets the moved root")
        XCTAssertEqual(store.seedEnvironment, ["DM_SEED_CACHE_DIR": seeds])
    }

    func testDMSeedCacheDirOfTheLauncherKeepsWinningAndTheSeedsDoNotMove() {
        let store = makeStore()
        store.launcherEnvironment = ["DM_SEED_CACHE_DIR": temporary + "/custom-seeds"]
        XCTAssertEqual(store.seedCacheRoot, temporary + "/custom-seeds")
        XCTAssertEqual(store.toolEnvironment(python: "/usr/bin/python3")["DM_SEED_CACHE_DIR"], temporary + "/custom-seeds")
        XCTAssertTrue(store.cacheFixedByEnvironment(.seeds))
        store.prepareCacheMove(.seeds, into: temporary)
        XCTAssertEqual(store.seedMove, .idle, "a move would not change the folder that is used")
    }

    /// The drive with a moved root is not connected: builds that write there stop early, nothing is made under /Volumes, and the
    /// way back to the default place still works (only the saved place changes, the files stay on that drive).
    func testADriveThatIsNotConnectedStopsTheBuildAndTheWayBackStillWorks() async throws {
        let store = makeStore()
        let drive = volumes + "/T7"
        defaults.set(drive + "/Games/NX2Apple-nxkit", forKey: BuildCacheRoots.nxkitKey)
        defaults.set(drive + "/Games/NX2Apple-build-seeds/build-seeds", forKey: BuildCacheRoots.seedKey)
        XCTAssertTrue(store.cacheUnreachable(.nxkit))
        XCTAssertTrue(store.cacheUnreachable(.seeds))
        XCTAssertEqual(store.nxkitWorkRootProblem(), String(format: Localizer(.en).t("nxkitCache.driveMissing"), store.shortPath(drive + "/Games/NX2Apple-nxkit")))
        XCTAssertNotNil(store.seedRootProblem())

        store.prepareCacheMoveToDefault(.seeds)
        guard case .confirm(let plan) = store.seedMove else { return XCTFail("the way back is offered") }
        XCTAssertNil(plan.problem)
        XCTAssertFalse(plan.sourceExists)
        await store.confirmCacheMove(.seeds)?.value
        XCTAssertEqual(store.seedMove, .moved(BuildCacheRoots.defaultSeedRoot(home: store.home)))
        XCTAssertNil(defaults.string(forKey: BuildCacheRoots.seedKey))
        XCTAssertNil(store.seedRootProblem())
        XCTAssertFalse(fm.fileExists(atPath: drive), "the launcher never makes the drive's folder")
    }
}
