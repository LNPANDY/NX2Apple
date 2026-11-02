import XCTest
@testable import NXModel
@testable import NXCore

/// `RepoStore` without SwiftUI: a fake `GitCheckout` answers for git, the checkouts are folders in a temporary directory and the
/// defaults are a suite of their own. The model's wiring is tested in NX2AppleTests (RepoAutoUpdateTests, RepoToolsTests run the
/// real git against local repositories).
@MainActor final class RepoStoreTests: XCTestCase {
    private var temporary: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private let git = FakeGitCheckout()
    private let localizer = Localizer(.en)
    private var log: [String] = []
    private var moved = 0
    private var building = false
    private var releaseApp = false

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxmodel-repo-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        suite = "nxmodel-repo-tests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporary)
        defaults.removePersistentDomain(forName: suite)
    }

    /// A folder the launcher takes for a checkout: the extractor's project, and a .git when `isGit`.
    @discardableResult
    private func makeCheckout(_ name: String = "clone", isGit: Bool = true) throws -> String {
        let dir = temporary.appendingPathComponent(name)
        let marker = dir.appendingPathComponent(EngineLayout.marker)
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: marker, atomically: true, encoding: .utf8)
        if isGit { try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true) }
        return dir.path
    }

    private func makeStore(path: String? = nil, autoUpdate: Bool? = nil) -> RepoStore {
        if let autoUpdate { defaults.set(autoUpdate, forKey: RepoStore.autoUpdateKey) }
        return RepoStore(localizer: localizer, git: git, defaults: defaults, path: path ?? "", home: temporary.path,
                         buildRunning: { [unowned self] in building }, isReleaseApp: { [unowned self] in releaseApp },
                         log: { [unowned self] in log.append($0) }, didMove: { [unowned self] in moved += 1 })
    }

    private func t(_ key: String) -> String { localizer.t(key) }

    // ---- State ----

    func testThePathIsSavedAndTheSwitchIsOnByDefault() throws {
        let dir = try makeCheckout()
        let store = makeStore(path: dir)
        XCTAssertTrue(store.autoUpdate)
        XCTAssertTrue(store.isRepo)
        XCTAssertTrue(store.isGit)
        store.path = temporary.path
        XCTAssertEqual(defaults.string(forKey: RepoStore.pathKey), temporary.path)
        XCTAssertFalse(store.isRepo)
        store.autoUpdate = false
        XCTAssertEqual(defaults.object(forKey: RepoStore.autoUpdateKey) as? Bool, false)
        XCTAssertFalse(makeStore().autoUpdate, "the next start reads the switch back")
    }

    func testAZipCopyIsARepositoryWithoutGit() throws {
        let store = makeStore(path: try makeCheckout("zip", isGit: false))
        XCTAssertTrue(store.isRepo)
        XCTAssertFalse(store.isGit)
    }

    func testTheStoreIsTheRepoLocationOthersAskFor() throws {
        let store = makeStore(path: try makeCheckout())
        let location: RepoLocation = store
        XCTAssertEqual(location.path, store.path)
        XCTAssertTrue(location.isRepo)
    }

    func testTheHomeIsShownAsATilde() {
        XCTAssertEqual(makeStore().shortPath(temporary.path + "/NX2Apple"), "~/NX2Apple")
        XCTAssertEqual(makeStore().shortPath("/elsewhere/NX2Apple"), "/elsewhere/NX2Apple")
    }

    // ---- Check ----

    func testTheCheckShowsHowFarBehindTheCheckoutIs() async throws {
        git.behindCount = 3
        let dir = try makeCheckout()
        let store = makeStore(path: dir, autoUpdate: false)
        let task = store.checkForUpdates()
        XCTAssertTrue(store.busy, "set before the task runs")
        XCTAssertEqual(store.status, t("repo.checking"))
        await task.value
        XCTAssertFalse(store.busy)
        XCTAssertEqual(store.behind, 3)
        XCTAssertEqual(store.status, String(format: t("repo.behind"), 3))
        XCTAssertEqual(git.calls, ["behind " + dir])
    }

    func testACheckoutThatIsUpToDateSaysSo() async throws {
        git.behindCount = 0
        let store = makeStore(path: try makeCheckout())
        await store.checkForUpdates().value
        XCTAssertEqual(store.behind, 0)
        XCTAssertEqual(store.status, t("repo.upToDate"))
    }

    func testAnOfflineCheckSaysSoAndLeavesTheCountUnknown() async throws {
        git.behindCount = nil
        let store = makeStore(path: try makeCheckout())
        await store.checkForUpdates().value
        XCTAssertNil(store.behind)
        XCTAssertEqual(store.status, t("repo.netFail"))
    }

    func testASilentOfflineCheckSaysNothing() async throws {
        git.behindCount = nil
        let store = makeStore(path: try makeCheckout())
        await store.checkForUpdates(silent: true).value
        XCTAssertEqual(store.status, "")
    }

    func testASilentCheckPullsWhenTheSwitchIsOn() async throws {
        git.behindCount = 2
        git.autoPullResult = ProcessResult()
        let store = makeStore(path: try makeCheckout(), autoUpdate: true)
        await store.checkForUpdates(silent: true).value
        XCTAssertEqual(store.autoPulled, 2)
        XCTAssertEqual(store.behind, 0)
        XCTAssertEqual(store.status, String(format: t("repo.autoPulled"), 2))
        XCTAssertEqual(moved, 1, "the engine may be stale after a pull")
        XCTAssertFalse(store.busy)
    }

    func testASilentCheckOnlyCountsWhenTheSwitchIsOff() async throws {
        git.behindCount = 2
        let store = makeStore(path: try makeCheckout(), autoUpdate: false)
        await store.checkForUpdates(silent: true).value
        XCTAssertEqual(store.behind, 2)
        XCTAssertEqual(store.status, "")
        XCTAssertNil(store.autoPulled)
        XCTAssertEqual(moved, 0)
    }

    func testAMacWithoutGitIsToldSoAndNothingRuns() throws {
        git.binary = nil
        let store = makeStore(path: try makeCheckout())
        store.checkForUpdates()
        XCTAssertEqual(store.status, t("repo.gitMissing"))
        XCTAssertFalse(store.busy)
        XCTAssertTrue(git.calls.isEmpty)
    }

    func testNoCheckForAZipCopy() async throws {
        let store = makeStore(path: try makeCheckout("zip", isGit: false))
        await store.checkForUpdates().value
        XCTAssertTrue(git.calls.isEmpty)
        XCTAssertNil(store.behind)
    }

    // ---- Pull ----

    func testAPullBringsTheCheckoutUpToDate() async throws {
        git.pullResult = ProcessResult(status: 0, out: "Updating 1..2")
        let dir = try makeCheckout()
        let store = makeStore(path: dir)
        store.behind = 4
        let task = store.pull()
        XCTAssertEqual(store.status, t("repo.pulling"))
        await task.value
        XCTAssertEqual(store.behind, 0)
        XCTAssertEqual(store.status, t("repo.pulled"))
        XCTAssertEqual(log, ["Updating 1..2\n"])
        XCTAssertEqual(moved, 1)
        XCTAssertEqual(git.calls, ["pull " + dir])
    }

    func testADivergedCheckoutGetsTheRepositoryPickerAdvice() async throws {
        git.pullResult = ProcessResult(status: 128, out: "fatal: Not possible to fast-forward, aborting.")
        let store = makeStore(path: try makeCheckout())
        await store.pull().value
        XCTAssertEqual(store.status, t("repo.pullDiverged"))
        XCTAssertEqual(moved, 0)
        XCTAssertEqual(log.count, 1, "git's words go to the log")
    }

    func testAnotherFailedPullSaysSo() async throws {
        git.pullResult = ProcessResult(status: 1, out: "fatal: unable to access")
        let store = makeStore(path: try makeCheckout())
        await store.pull().value
        XCTAssertEqual(store.status, t("repo.pullFail"))
    }

    // ---- The automatic update ----

    func testTheAutomaticUpdateOfACheckoutOnABranchIsSkipped() async throws {
        git.autoPullResult = nil
        let store = makeStore(path: try makeCheckout())
        await store.autoPull(2).value
        XCTAssertEqual(store.status, t("repo.autoSkipped"))
        XCTAssertNil(store.autoPulled)
        XCTAssertFalse(store.busy)
    }

    func testAFailedAutomaticUpdateSaysWhy() async throws {
        git.autoPullResult = ProcessResult(status: 128, out: "fatal: Not possible to fast-forward")
        let store = makeStore(path: try makeCheckout())
        await store.autoPull(2).value
        XCTAssertEqual(store.status, t("repo.pullDiverged"))
        XCTAssertNil(store.autoPulled)
    }

    // ---- A ZIP copy ----

    func testAZipCopyIsAdoptedAtLaunch() async throws {
        let dir = try makeCheckout("zip", isGit: false)
        let store = makeStore(path: dir, autoUpdate: true)
        await store.adoptAtLaunch(remote: "file:///origin").value
        let branch = GitRules.zipCopyBranch()
        XCTAssertEqual(git.calls, ["adopt \(dir) file:///origin \(branch)"])
        XCTAssertTrue(store.isGit)
        XCTAssertTrue(store.autoAdopted)
        XCTAssertEqual(store.behind, 0)
        XCTAssertEqual(store.status, String(format: t("repo.adoptedAuto"), branch))
        XCTAssertEqual(moved, 1)
    }

    func testWithTheSwitchOffTheZipCopyIsLeftAlone() async throws {
        let store = makeStore(path: try makeCheckout("zip", isGit: false), autoUpdate: false)
        await store.adoptAtLaunch().value
        XCTAssertTrue(git.calls.isEmpty)
        XCTAssertEqual(store.status, "")
        XCTAssertFalse(store.autoAdopted)
    }

    func testAZipCopyWaitsForTheBuild() async throws {
        building = true
        let store = makeStore(path: try makeCheckout("zip", isGit: false), autoUpdate: true)
        await store.adoptAtLaunch().value
        XCTAssertTrue(git.calls.isEmpty)
        XCTAssertEqual(store.status, t("repo.zipWaits"))
    }

    func testAFailedAdoptionSaysSoAndKeepsTheCopy() async throws {
        git.adoptResult = (false, "fatal: no network")
        let dir = try makeCheckout("zip", isGit: false)
        let store = makeStore(path: dir, autoUpdate: true)
        await store.adoptAtLaunch().value
        XCTAssertEqual(store.status, t("repo.adoptFailAuto"))
        XCTAssertFalse(store.autoAdopted)
        XCTAssertFalse(store.isGit)
        XCTAssertTrue(store.isRepo)
        XCTAssertEqual(log, ["fatal: no network\n"])
    }

    func testTheAdoptionByHandSaysSoInItsOwnWords() async throws {
        let store = makeStore(path: try makeCheckout("zip", isGit: false), autoUpdate: false)
        await store.adoptAsGit().value
        XCTAssertEqual(store.status, String(format: t("repo.adopted"), GitRules.zipCopyBranch()))
        XCTAssertFalse(store.autoAdopted, "only the launch-time adoption sets it")
    }

    // ---- Clone ----

    func testACloneIsSelectedAndTheEngineIsToldItMoved() async throws {
        git.cloneMakes = { dest in
            let marker = URL(fileURLWithPath: dest).appendingPathComponent(EngineLayout.marker)
            try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "x".write(to: marker, atomically: true, encoding: .utf8)
        }
        let store = makeStore()
        let dest = temporary.path + "/NX2Apple"
        let task = store.clone()
        XCTAssertEqual(store.status, t("repo.downloading"))
        XCTAssertEqual(log.first, "git clone --depth 1 \(RepoStore.url) \(dest)\n")
        await task.value
        XCTAssertEqual(store.path, dest)
        XCTAssertEqual(store.status, String(format: t("repo.downloadDone"), "~/NX2Apple"))
        XCTAssertEqual(moved, 1)
        XCTAssertFalse(store.busy)
    }

    func testAFailedCloneLeavesNothingBehind() async throws {
        git.cloneOK = false
        git.cloneMakes = { try? FileManager.default.createDirectory(atPath: $0, withIntermediateDirectories: true) }
        let store = makeStore()
        await store.clone().value
        XCTAssertEqual(store.status, t("repo.downloadFail"))
        XCTAssertEqual(store.path, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path + "/NX2Apple"))
        XCTAssertEqual(moved, 0)
    }

    func testAFolderThatIsNotARepositoryIsNotCloned() async throws {
        try FileManager.default.createDirectory(atPath: temporary.path + "/NX2Apple", withIntermediateDirectories: true)
        let store = makeStore()
        await store.clone().value
        XCTAssertEqual(store.status, String(format: t("repo.destBusy"), "~/NX2Apple"))
        XCTAssertTrue(git.calls.isEmpty)
    }

    func testAnExistingCheckoutIsSelectedAndChecked() async throws {
        try makeCheckout("NX2Apple")
        git.behindCount = 1
        let store = makeStore(autoUpdate: false)
        await store.clone().value
        XCTAssertEqual(store.path, temporary.path + "/NX2Apple")
        XCTAssertEqual(store.behind, 1)
        XCTAssertEqual(git.calls, ["behind " + temporary.path + "/NX2Apple"])
    }

    // ---- Conditions ----

    func testNothingRunsWhileABuildRuns() async throws {
        building = true
        let store = makeStore(path: try makeCheckout())
        await store.checkForUpdates().value
        await store.pull().value
        await store.autoPull(1).value
        await store.clone().value
        XCTAssertTrue(git.calls.isEmpty)
        XCTAssertFalse(store.busy)
    }

    func testAReleaseAppNeverRunsGit() async throws {
        releaseApp = true
        let store = makeStore(path: try makeCheckout("zip", isGit: false))
        await store.clone().value
        await store.pull().value
        await store.autoPull(3).value
        await store.adoptAsGit().value
        await store.checkForUpdates().value
        await store.adoptAtLaunch().value
        XCTAssertTrue(git.calls.isEmpty)
        XCTAssertFalse(store.busy)
        XCTAssertEqual(store.status, "")
    }

    func testOneTaskAtATime() async throws {
        let store = makeStore(path: try makeCheckout())
        let first = store.checkForUpdates()
        await store.pull().value   // refused: the check is still in flight
        await first.value
        XCTAssertEqual(git.calls.count, 1)
        XCTAssertFalse(git.calls.contains { $0.hasPrefix("pull") })
    }
}
