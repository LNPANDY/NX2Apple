import XCTest
@testable import NXCore

/// `SystemGitCheckout` over a fake runner: which git commands each flow runs, and what it makes of the answers.
final class GitCheckoutTests: XCTestCase {
    private func checkout(_ fake: FakeProcessRunner, binary: String = "/usr/bin/git") -> SystemGitCheckout {
        SystemGitCheckout(runner: fake, candidates: [binary])
    }

    private func git(_ fake: FakeProcessRunner) -> SystemGitCheckout { checkout(fake, binary: "/usr/bin/true") }   // a file that exists

    func testNoGitMeansNoBinaryAndEveryRunFails() {
        let fake = FakeProcessRunner()
        let none = checkout(fake, binary: "/nonexistent/git")
        XCTAssertNil(none.binary)
        XCTAssertFalse(none.run("/repo", ["status"]).ok)
        XCTAssertNil(none.behind("/repo"))
        XCTAssertFalse(none.clone(url: "u", into: "/d") { _ in })
        XCTAssertTrue(fake.launches.isEmpty, "nothing is started without git")
    }

    func testRunPutsTheDirectoryFirstAndGivesGitTheGuiEnvironment() {
        let fake = FakeProcessRunner()
        _ = git(fake).run("/repo", ["log", "-1"])
        XCTAssertEqual(fake.commands, ["true -C /repo log -1"])
        XCTAssertEqual(fake.launches[0].environment, SystemGitCheckout.environment())
        XCTAssertEqual(SystemGitCheckout.environment()["PATH"], "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin")
    }

    func testBehindFetchesThenCountsTheCommitsOriginMainHas() {
        let fake = FakeProcessRunner()
        fake.answer = { $0.arguments.contains("rev-list") ? ProcessResult(out: "7\n") : ProcessResult() }
        XCTAssertEqual(git(fake).behind("/repo"), 7)
        XCTAssertEqual(fake.commands, ["true -C /repo fetch origin main", "true -C /repo rev-list --count HEAD..origin/main"])
    }

    func testBehindIsNilWhenTheFetchFailsAndItCountsNothingThen() {
        let fake = FakeProcessRunner()
        fake.answer = { _ in ProcessResult(status: 128, out: "could not resolve host") }
        XCTAssertNil(git(fake).behind("/repo"))
        XCTAssertEqual(fake.commands.count, 1)
    }

    func testBehindIsNilWhenTheCountIsNotANumber() {
        let fake = FakeProcessRunner()
        fake.answer = { $0.arguments.contains("rev-list") ? ProcessResult(out: "fatal") : ProcessResult() }
        XCTAssertNil(git(fake).behind("/repo"))
    }

    func testPullIsAFastForwardOnlyOfOriginMain() {
        let fake = FakeProcessRunner()
        fake.answer = { _ in ProcessResult(status: 1, out: "Not possible to fast-forward") }
        let r = git(fake).pull("/repo")
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.out, "Not possible to fast-forward")
        XCTAssertEqual(fake.commands, ["true -C /repo pull --ff-only origin main"])
    }

    func testAutoPullPullsOnlyAMainWithNoChangesToTrackedFiles() {
        func run(branch: String, status: String) -> (pulled: ProcessResult?, commands: [String]) {
            let fake = FakeProcessRunner()
            fake.answer = { l in
                if l.arguments.contains("rev-parse") { return ProcessResult(out: branch) }
                if l.arguments.contains("status") { return ProcessResult(out: status) }
                return ProcessResult(out: "Fast-forward")
            }
            return (git(fake).autoPull("/repo"), fake.commands)
        }
        let clean = run(branch: "main\n", status: "")
        XCTAssertEqual(clean.pulled?.out, "Fast-forward")
        XCTAssertEqual(clean.commands.last, "true -C /repo pull --ff-only origin main")
        XCTAssertNil(run(branch: "device-install\n", status: "").pulled)
        XCTAssertNil(run(branch: "main\n", status: " M scripts/build.py\n").pulled)
        XCTAssertEqual(run(branch: "device-install\n", status: "").commands.count, 2, "a refused checkout is not pulled")
    }

    func testAutoPullDoesNotPullWhenGitCannotTellTheBranch() {
        let fake = FakeProcessRunner()
        fake.answer = { _ in ProcessResult(status: 128) }
        XCTAssertNil(git(fake).autoPull("/repo"))
        XCTAssertFalse(fake.commands.contains { $0.contains("pull") })
    }

    func testCloneIsShallowSingleBranchAndStreamsItsProgress() {
        let fake = FakeProcessRunner()
        fake.lines = ["Receiving objects: 50%"]
        let lines = NSMutableArray()
        let ok = git(fake).clone(url: "https://example.test/repo.git", into: "/dest") { lines.add($0) }
        XCTAssertTrue(ok)
        XCTAssertEqual(lines as? [String], ["Receiving objects: 50%"])
        XCTAssertEqual(fake.commands, ["true clone --depth 1 --single-branch --progress https://example.test/repo.git /dest"])
        fake.streamOK = false
        XCTAssertFalse(git(fake).clone(url: "u", into: "/d") { _ in })
    }

    func testAdoptionRunsInitRemoteFetchThenRecordsTheCopyAndChecksOutMain() throws {
        let dir = try temporaryFolder()
        try "kept".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        let fake = FakeProcessRunner()
        fake.answer = { $0.arguments.contains("ls-tree") ? ProcessResult(out: "a.txt\0b.txt\0") : ProcessResult() }
        let r = git(fake).adopt(dir, remote: "https://example.test/repo.git", branch: "zip-copy-2026-11-01")
        XCTAssertTrue(r.ok)
        XCTAssertTrue(r.log.contains("$ git init"))
        let subcommands = fake.launches.map { l -> String in
            // after `-C dir`, skipping the identity options of the commit
            let rest = Array(l.arguments.dropFirst(2))
            return rest.first == "-c" ? "commit" : rest[0]
        }
        XCTAssertEqual(subcommands, ["init", "remote", "fetch", "ls-tree", "symbolic-ref", "add", "commit", "checkout", "branch"])
        XCTAssertTrue(fake.commands.contains("true -C \(dir) symbolic-ref HEAD refs/heads/zip-copy-2026-11-01"))
        XCTAssertTrue(fake.commands.contains("true -C \(dir) checkout -f -B main origin/main"))
    }

    func testAFailedFetchStopsTheAdoptionAndRemovesTheGitFolderItMade() throws {
        let dir = try temporaryFolder()
        let fake = FakeProcessRunner()
        fake.answer = { l in
            if l.arguments.contains("init") { try? FileManager.default.createDirectory(atPath: dir + "/.git", withIntermediateDirectories: true) }
            return l.arguments.contains("fetch") ? ProcessResult(status: 128, out: "could not resolve host") : ProcessResult()
        }
        let r = git(fake).adopt(dir, remote: "https://example.test/repo.git", branch: "zip-copy-2026-11-01")
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.log.contains("could not resolve host"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/.git"), "the copy must not count as a checkout after a failed adoption")
        XCTAssertFalse(fake.commands.contains { $0.contains(" checkout ") }, "nothing in the folder changes before the fetch has worked")
    }

    // MARK: Pure decisions

    func testAutoPullIsAllowedOnlyOnMainWithoutChanges() {
        XCTAssertTrue(GitRules.autoPullAllowed(branch: "main\n", status: ""))
        XCTAssertFalse(GitRules.autoPullAllowed(branch: "device-install", status: ""))
        XCTAssertFalse(GitRules.autoPullAllowed(branch: "main", status: " M scripts/build_ipa_from_nsp.py\n"))
        XCTAssertFalse(GitRules.autoPullAllowed(branch: "HEAD", status: ""), "a detached HEAD is not main")
    }

    func testTheZipCopyBranchCarriesTheDate() {
        let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!
        XCTAssertEqual(GitRules.zipCopyBranch(date: date), "zip-copy-2026-11-01")
    }

    func testAZipCopyIsAdoptedOnlyWhenNothingElseRunsAndTheAutomaticUpdateIsOn() {
        func decide(isRepo: Bool = true, isGit: Bool = false, running: Bool = false, busy: Bool = false, auto: Bool = true) -> GitRules.ZipAdoption {
            GitRules.zipAdoption(isRepo: isRepo, isGit: isGit, buildRunning: running, repoBusy: busy, autoUpdate: auto)
        }
        XCTAssertEqual(decide(), .adopt)
        XCTAssertEqual(decide(isGit: true), .notNeeded)
        XCTAssertEqual(decide(isRepo: false), .notNeeded)
        XCTAssertEqual(decide(running: true), .waitsForBuild)
        XCTAssertEqual(decide(busy: true), .waitsForBuild)
        XCTAssertEqual(decide(auto: false), .autoUpdateOff)
        XCTAssertEqual(decide(running: true, auto: false), .waitsForBuild)
    }

    private func temporaryFolder() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gitcheckout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }
}
