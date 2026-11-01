import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

/// #87: a ZIP copy of the repository is connected to git when the app opens, and a build does not start with build tools
/// older than the app. Temporary folders and a local repository stand in for the user's copy and for GitHub.
final class RepoToolsTests: XCTestCase {
    private var temporary: URL!
    private var saved: [(String, Any?)] = []

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-tools87-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        saved = ["repoPath", "autoUpdateRepo"].map { ($0, UserDefaults.standard.object(forKey: $0)) }
    }

    override func tearDownWithError() throws {
        for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) }
        try? FileManager.default.removeItem(at: temporary)
    }

    private func write(_ files: [String], in dir: URL, text: String = "x") throws {
        for f in files {
            let url = dir.appendingPathComponent(f)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @discardableResult private func git(_ args: String..., in dir: URL) throws -> String {
        let r = BuildModel.runQuiet(["/usr/bin/git", "-C", dir.path] + args, env: BuildModel.gitEnv())
        guard r.ok else { throw NSError(domain: "git", code: 1, userInfo: [NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")): \(r.out)"]) }
        return r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: the decision

    func testAdoptionDecision() {
        func decide(isRepo: Bool = true, isGit: Bool = false, running: Bool = false, busy: Bool = false, auto: Bool = true) -> BuildModel.ZipAdoption {
            BuildModel.zipAdoption(isRepo: isRepo, isGit: isGit, buildRunning: running, repoBusy: busy, autoUpdate: auto)
        }
        XCTAssertEqual(decide(), .adopt, "a ZIP copy is connected")
        XCTAssertEqual(decide(isGit: true), .notNeeded, "a git checkout is the normal update's business")
        XCTAssertEqual(decide(isRepo: false), .notNeeded, "no valid repository, nothing to adopt")
        XCTAssertEqual(decide(running: true), .waitsForBuild, "never while a build runs")
        XCTAssertEqual(decide(busy: true), .waitsForBuild)
        XCTAssertEqual(decide(auto: false), .autoUpdateOff, "the player turned the automatic update off")
        XCTAssertEqual(decide(running: true, auto: false), .waitsForBuild)
    }

    // MARK: the missing-tool check

    func testMissingToolsAreListed() throws {
        let repo = temporary.appendingPathComponent("NX2Apple-0.4.5")
        try write(["dm/tools/nx_extract/Program.cs", BuildModel.buildScript], in: repo)   // the v0.4.5 copy of the report
        XCTAssertEqual(BuildModel.missingTools(in: repo.path), [BuildModel.romfsImageTool])
        try write([BuildModel.romfsImageTool], in: repo)
        XCTAssertEqual(BuildModel.missingTools(in: repo.path), [])
        XCTAssertEqual(BuildModel.missingTools(in: temporary.appendingPathComponent("nothing").path), BuildModel.requiredTools)
    }

    func testEveryToolTheLauncherCallsExistsInThisCheckout() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard BuildModel.isRepo(root.path) else { throw XCTSkip("not run inside a checkout") }
        XCTAssertEqual(BuildModel.missingTools(in: root.path), [])
    }

    @MainActor func testABuildWithOldToolsRefusesToStart() throws {
        let repo = temporary.appendingPathComponent("old")
        try write(["dm/tools/nx_extract/Program.cs", BuildModel.buildScript], in: repo)
        let m = BuildModel()
        m.repoPath = repo.path
        m.target = BuildTarget.mac
        m.startBuild()
        XCTAssertFalse(m.running, "no build was started")
        XCTAssertTrue(m.doneNote.contains(BuildModel.romfsImageTool), m.doneNote)
        XCTAssertEqual(m.doneNote, String(format: m.t("msg.toolsOld"), BuildModel.romfsImageTool))
    }

    // MARK: the adoption itself (local repository as origin)

    /// origin (bare) with the two tools on main, and a ZIP-like copy of an older state: no .git, the romfs tool missing
    private func fixture() throws -> (origin: URL, zip: URL) {
        let origin = temporary.appendingPathComponent("origin.git"), work = temporary.appendingPathComponent("work")
        let zip = temporary.appendingPathComponent("NX2Apple-0.4.5")
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try git("init", "--bare", "-b", "main", in: origin)
        try git("clone", origin.path, work.path, in: temporary)
        try write(["dm/tools/nx_extract/Program.cs", BuildModel.buildScript, BuildModel.romfsImageTool], in: work, text: "new")
        try git("add", ".", in: work)
        try git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "main", in: work)
        try git("push", "origin", "HEAD:main", in: work)
        try write(["dm/tools/nx_extract/Program.cs", BuildModel.buildScript], in: zip, text: "old")
        return (origin, zip)
    }

    @MainActor private func openZip(_ f: (origin: URL, zip: URL), auto: Bool, remote: String? = nil) -> BuildModel {
        let m = BuildModel()
        m.repoPath = f.zip.path
        m.autoUpdateRepo = auto
        m.adoptAtLaunch(remote: remote ?? "file://" + f.origin.path)
        guard auto else { return m }   // nothing runs, nothing to wait for
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !m.repoBusy && !m.repoStatus.isEmpty && m.repoStatus != m.t("repo.adopting") }, object: nil)
        wait(for: [settled], timeout: 20)
        return m
    }

    @MainActor func testAZipCopyIsConnectedAndUpdatedAtLaunch() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { throw XCTSkip("git is required for the fixture") }
        let f = try fixture()
        XCTAssertEqual(BuildModel.missingTools(in: f.zip.path), [BuildModel.romfsImageTool])
        let m = openZip(f, auto: true)
        XCTAssertTrue(m.repoIsGit)
        XCTAssertTrue(m.autoAdopted)
        XCTAssertEqual(m.repoStatus, String(format: m.t("repo.adoptedAuto"), BuildModel.zipCopyBranch()))
        XCTAssertEqual(BuildModel.missingTools(in: f.zip.path), [], "the tools of origin/main are there now")
        XCTAssertEqual(try git("rev-parse", "--abbrev-ref", "HEAD", in: f.zip), "main")
        XCTAssertEqual(try String(contentsOf: f.zip.appendingPathComponent(BuildModel.buildScript), encoding: .utf8), "new")
    }

    @MainActor func testTheCopyIsKeptOnABranchBeforeTheCheckoutOverwritesIt() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { throw XCTSkip("git is required for the fixture") }
        let f = try fixture()
        try "my tweak".write(to: f.zip.appendingPathComponent(BuildModel.buildScript), atomically: true, encoding: .utf8)   // an edited tracked file
        try write(["dm/mine/notes.txt"], in: f.zip, text: "mine")                                       // a file origin does not have
        try write(["dm/tools/build/huge.bin"], in: f.zip, text: "build output")
        let m = openZip(f, auto: true)
        let branch = BuildModel.zipCopyBranch()
        XCTAssertEqual(try git("show", "main:" + BuildModel.buildScript, in: f.zip), "new", "main has origin's version")
        XCTAssertEqual(try String(contentsOf: f.zip.appendingPathComponent(BuildModel.buildScript), encoding: .utf8), "new")
        XCTAssertEqual(try git("show", branch + ":" + BuildModel.buildScript, in: f.zip), "my tweak", "the branch has the edit")
        XCTAssertEqual(try git("ls-tree", "-r", "--name-only", branch, in: f.zip).split(separator: "\n").map(String.init).sorted(),
                       ["dm/tools/nx_extract/Program.cs", BuildModel.buildScript].sorted(), "only paths origin tracks are recorded")
        XCTAssertEqual(try git("log", "-1", "--format=%an", branch, in: f.zip), "NX2Apple")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.zip.appendingPathComponent("dm/mine/notes.txt").path), "untracked files stay where they are")
        XCTAssertTrue(m.repoStatus.contains(branch), m.repoStatus)
    }

    @MainActor func testWithTheAutomaticUpdateOffTheZipCopyIsLeftAlone() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { throw XCTSkip("git is required for the fixture") }
        let f = try fixture()
        let m = openZip(f, auto: false)
        XCTAssertFalse(m.repoIsGit)
        XCTAssertFalse(m.autoAdopted)
        XCTAssertTrue(m.repoStatus.isEmpty, "Settings says it next to the repository (repo.zipNoAuto), not as a status")
        XCTAssertEqual(BuildModel.missingTools(in: f.zip.path), [BuildModel.romfsImageTool])
    }

    @MainActor func testAnUnreachableOriginSaysWhyAndLeavesTheCopyUsable() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { throw XCTSkip("git is required for the fixture") }
        let f = try fixture()
        let m = openZip(f, auto: true, remote: "file://" + temporary.appendingPathComponent("does-not-exist.git").path)
        XCTAssertEqual(m.repoStatus, m.t("repo.adoptFailAuto"))
        XCTAssertFalse(m.autoAdopted)
        XCTAssertTrue(BuildModel.isRepo(f.zip.path), "the files are still there")
        XCTAssertEqual(try String(contentsOf: f.zip.appendingPathComponent(BuildModel.buildScript), encoding: .utf8), "old", "nothing was changed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.zip.appendingPathComponent(".git").path))
    }
}
