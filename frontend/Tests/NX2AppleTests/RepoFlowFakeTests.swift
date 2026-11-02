import XCTest
@testable import NX2Apple
@testable import NXCore

/// The repository flows of BuildModel with a fake `GitCheckout`: the model's states and texts for each answer git can give,
/// with no git and no network. (RepoAutoUpdateTests and RepoToolsTests run the real git against local repositories.)
final class RepoFlowFakeTests: XCTestCase {
    private var temporary: URL!
    private var saved: [(String, Any?)] = []

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-fake-" + UUID().uuidString)
        // what makes it a checkout to the launcher: the extractor's project and a .git
        let marker = temporary.appendingPathComponent("dm/tools/nx_extract/Program.cs")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: marker, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: temporary.appendingPathComponent(".git"), withIntermediateDirectories: true)
        saved = ["repoPath", "autoUpdateRepo"].map { ($0, UserDefaults.standard.object(forKey: $0)) }
    }

    override func tearDownWithError() throws {
        for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) }
        try? FileManager.default.removeItem(at: temporary)
    }

    @MainActor private func model(_ git: GitCheckout) -> BuildModel {
        let m = BuildModel(gitCheckout: git)
        m.repoPath = temporary.path
        m.autoUpdateRepo = false
        return m
    }

    @MainActor private func settle(_ m: BuildModel) {
        let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !m.repoBusy }, object: nil)
        wait(for: [done], timeout: 10)
    }

    @MainActor func testTheCheckShowsHowFarBehindTheCheckoutIs() {
        let git = FakeGitCheckout(); git.behindCount = 3
        let m = model(git)
        m.checkRepoUpdates()
        settle(m)
        XCTAssertEqual(m.repoBehind, 3)
        XCTAssertEqual(m.repoStatus, String(format: m.t("repo.behind"), 3))
        XCTAssertEqual(git.calls, ["behind " + temporary.path])
    }

    @MainActor func testAnOfflineCheckSaysSoAndLeavesTheCountUnknown() {
        let git = FakeGitCheckout(); git.behindCount = nil
        let m = model(git)
        m.checkRepoUpdates()
        settle(m)
        XCTAssertNil(m.repoBehind)
        XCTAssertEqual(m.repoStatus, m.t("repo.netFail"))
    }

    @MainActor func testASilentOfflineCheckSaysNothing() {
        let git = FakeGitCheckout(); git.behindCount = nil
        let m = model(git)
        m.checkRepoUpdates(silent: true)
        settle(m)
        XCTAssertEqual(m.repoStatus, "")
    }

    @MainActor func testADivergedCheckoutGetsTheRepositoryPickerAdvice() {
        let git = FakeGitCheckout()
        git.pullResult = ProcessResult(status: 128, out: "fatal: Not possible to fast-forward, aborting.")
        let m = model(git)
        m.pullRepo()
        settle(m)
        XCTAssertEqual(m.repoStatus, m.t("repo.pullDiverged"))
        XCTAssertEqual(git.calls, ["pull " + temporary.path])
    }

    @MainActor func testAMacWithoutGitIsToldSoAndNothingRuns() {
        let git = FakeGitCheckout(); git.binary = nil
        let m = model(git)
        m.checkRepoUpdates()
        XCTAssertEqual(m.repoStatus, m.t("repo.gitMissing"))
        XCTAssertFalse(m.repoBusy)
        XCTAssertTrue(git.calls.isEmpty)
    }

    @MainActor func testTheAutomaticUpdateOfACheckoutOnABranchIsSkipped() {
        let git = FakeGitCheckout(); git.autoPullResult = nil
        let m = model(git)
        m.autoPull(2)
        settle(m)
        XCTAssertEqual(m.repoStatus, m.t("repo.autoSkipped"))
        XCTAssertNil(m.autoPulled)
    }
}

/// A `GitCheckout` that runs nothing: each call is recorded and answered from the fields.
final class FakeGitCheckout: GitCheckout, @unchecked Sendable {
    var binary: String? = "/fake/git"
    var behindCount: Int? = 0
    var pullResult = ProcessResult()
    var autoPullResult: ProcessResult?
    var adoptResult: (ok: Bool, log: String) = (true, "")
    var cloneOK = true
    var calls: [String] = []

    func run(_ dir: String, _ args: [String]) -> ProcessResult { calls.append("run \(dir) \(args.joined(separator: " "))"); return ProcessResult() }
    func clone(url: String, into dest: String, line: @escaping (String) -> Void) -> Bool { calls.append("clone \(url) \(dest)"); line("Cloning"); return cloneOK }
    func behind(_ dir: String) -> Int? { calls.append("behind \(dir)"); return behindCount }
    func pull(_ dir: String) -> ProcessResult { calls.append("pull \(dir)"); return pullResult }
    func autoPull(_ dir: String) -> ProcessResult? { calls.append("autoPull \(dir)"); return autoPullResult }
    func adopt(_ dir: String, remote: String, branch: String) -> (ok: Bool, log: String) { calls.append("adopt \(dir) \(remote) \(branch)"); return adoptResult }
}
