import XCTest
@testable import NX2Apple
@testable import NXCore
import NXModel
@testable import NXLauncher

/// The automatic update when the app opens (RepoStore.autoPull): a clean checkout on main fast-forwards to origin/main,
/// one with local changes is left as it is. A local bare repository stands in for GitHub.
@MainActor final class RepoAutoUpdateTests: XCTestCase {
    private var temporary: URL!
    private var saved: [(String, Any?)] = []

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { throw XCTSkip("git is required for the fixture") }
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-repo-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        saved = ["repoPath", "autoUpdateRepo"].map { ($0, UserDefaults.standard.object(forKey: $0)) }
    }

    override func tearDownWithError() throws {
        for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) }
        try? FileManager.default.removeItem(at: temporary)
    }

    @discardableResult private func git(_ args: String..., in dir: URL) throws -> String {
        let r = SystemProcessRunner().runQuiet(["/usr/bin/git", "-C", dir.path] + args, env: SystemGitCheckout.environment())
        guard r.ok else { throw NSError(domain: "git", code: 1, userInfo: [NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")): \(r.out)"]) }
        return r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// origin (bare) with two commits on main, and a checkout of the first: one commit behind
    private func fixture() throws -> URL {
        let origin = temporary.appendingPathComponent("origin.git"), work = temporary.appendingPathComponent("work")
        let checkout = temporary.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try git("init", "--bare", "-b", "main", in: origin)
        try git("clone", origin.path, work.path, in: temporary)
        let marker = work.appendingPathComponent("dm/tools/nx_extract/Program.cs")   // what makes it a repository to the launcher
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "one".write(to: marker, atomically: true, encoding: .utf8)
        try git("add", ".", in: work); try git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "one", in: work)
        try git("push", "origin", "HEAD:main", in: work)
        try git("clone", "-b", "main", origin.path, checkout.path, in: temporary)
        try "two".write(to: marker, atomically: true, encoding: .utf8)
        try git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-am", "two", in: work)
        try git("push", "origin", "HEAD:main", in: work)
        return checkout
    }

    @MainActor private func open(_ checkout: URL) -> LauncherStores {
        let mStores = LauncherStores(); let m = mStores.build
        mStores.repo.path = checkout.path
        mStores.repo.autoUpdate = true
        mStores.repo.checkForUpdates(silent: true)   // what the library does when the app opens
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !mStores.repo.busy && mStores.repo.behind != nil && (mStores.repo.autoPulled != nil || !mStores.repo.status.isEmpty) }, object: nil)
        wait(for: [settled], timeout: 20)
        return mStores
    }

    @MainActor func testACleanCheckoutOnMainIsUpdatedWhenTheAppOpens() throws {
        let checkout = try fixture()
        let mStores = open(checkout)
        let m = mStores.build
        XCTAssertEqual(mStores.repo.autoPulled, 1)
        XCTAssertEqual(mStores.repo.behind, 0)
        XCTAssertEqual(try git("log", "-1", "--format=%s", in: checkout), "two")
    }

    @MainActor func testACheckoutWithLocalChangesIsLeftAsItIs() throws {
        let checkout = try fixture()
        try "mine".write(to: checkout.appendingPathComponent("dm/tools/nx_extract/Program.cs"), atomically: true, encoding: .utf8)
        let mStores = open(checkout)
        let m = mStores.build
        XCTAssertNil(mStores.repo.autoPulled)
        XCTAssertEqual(mStores.repo.status, m.t("repo.autoSkipped"))
        XCTAssertEqual(try git("log", "-1", "--format=%s", in: checkout), "one")
    }
}
