import Combine
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

/// Games built with older build tools (ToolsAge, #65): a local git repository stands in for the checkout; a game is marked
/// only when files a build uses changed since the commit its build recorded.
final class OlderToolsTests: IsolatedDefaultsTestCase {
    private var temporary: URL!
    private let titleID = "0100535012974000"

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { throw XCTSkip("git is required for the fixture") }
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-tools-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    @discardableResult private func git(_ args: String..., in dir: URL) throws -> String {
        let r = SystemProcessRunner().runQuiet(["/usr/bin/git", "-C", dir.path] + args, env: SystemGitCheckout.environment())
        guard r.ok else { throw NSError(domain: "git", code: 1, userInfo: [NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")): \(r.out)"]) }
        return r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult private func commit(_ files: [String: String], in repo: URL) throws -> String {
        for (path, text) in files {
            let url = repo.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try git("add", ".", in: repo)
        try git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "change", in: repo)
        return try git("rev-parse", "HEAD", in: repo)
    }

    /// A checkout with the folders a build reads and a note; returns it and its first commit (the one the game was built with).
    private func fixture() throws -> (repo: URL, built: String) {
        let repo = temporary.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git("init", "-b", "main", in: repo)
        let built = try commit(["dm/tools/nx_extract/Program.cs": "one", "dm/host/hle_fs.c": "one", "docs/development.md": "one",
                                "dm/games/\(titleID)/game.tsv": "name\tHades", "dm/games/01007EF00011E000/game.tsv": "name\tZelda"], in: repo)
        return (repo, built)
    }

    private func game(_ commit: String) -> (id: UUID, titleID: String, commit: String) { (UUID(), titleID, commit) }

    func testAChangeToTheHostMarksTheGame() throws {
        let (repo, built) = try fixture()
        try commit(["dm/host/hle_fs.c": "two"], in: repo)
        let hades = game(built)
        XCTAssertEqual(ToolsAge.olderGames([hades], repo: repo.path), [hades.id])
    }

    func testAChangeOnlyInTheDocsMarksNothing() throws {
        let (repo, built) = try fixture()
        try commit(["docs/development.md": "two", "dm/host/README.md": "notes"], in: repo)
        XCTAssertEqual(ToolsAge.olderGames([game(built)], repo: repo.path), [])
    }

    func testAGameWithNoRecordedCommitIsNotMarked() throws {
        let (repo, _) = try fixture()
        try commit(["dm/host/hle_fs.c": "two"], in: repo)
        XCTAssertEqual(ToolsAge.olderGames([game("")], repo: repo.path), [])
    }

    func testOnlyTheGamesOwnProfileCounts() throws {
        let (repo, built) = try fixture()
        try commit(["dm/games/01007EF00011E000/game.tsv": "name\tZelda 2"], in: repo)
        XCTAssertEqual(ToolsAge.olderGames([game(built)], repo: repo.path), [], "another game's profile")
        try commit(["dm/games/\(titleID)/game.tsv": "name\tHades 2"], in: repo)
        let hades = game(built)
        XCTAssertEqual(ToolsAge.olderGames([hades], repo: repo.path), [hades.id])
    }

    func testABuildAtHeadOrFromAnUnknownCommitIsNotMarked() throws {
        let (repo, _) = try fixture()
        let head = try commit(["dm/host/hle_fs.c": "two"], in: repo)
        XCTAssertEqual(ToolsAge.olderGames([game(head)], repo: repo.path), [])
        XCTAssertEqual(ToolsAge.olderGames([game(String(repeating: "0", count: 40))], repo: repo.path), [], "a commit the checkout does not have")
    }

    /// A checkout of this repository: tools/engine.py and .upstream-ref at its root, the engine in engine/ as a git repository of its own.
    /// What counts is the engine's history (the pin and the series), never the launcher's own commits (#214, step 2).
    func testTheEnginesHistoryCountsAndTheCheckoutsDoesNot() throws {
        let checkout = temporary.appendingPathComponent("nx2apple")
        let engine = checkout.appendingPathComponent("engine")
        try FileManager.default.createDirectory(at: engine, withIntermediateDirectories: true)
        try git("init", "-b", "main", in: checkout)
        try commit(["tools/engine.py": "x", ".upstream-ref": String(repeating: "a", count: 40) + "\n", "frontend/a.swift": "one"], in: checkout)
        try git("init", "-b", "main", in: engine)
        let built = try commit(["dm/tools/nx_extract/Program.cs": "one", "dm/host/hle_fs.c": "one"], in: engine)
        XCTAssertEqual(ToolsAge.head(repo: checkout.path), built, "the commit a build records is the engine's")
        try commit(["frontend/a.swift": "two", "dm/host/hle_fs.c": "launcher file with an engine-looking name"], in: checkout)
        XCTAssertEqual(ToolsAge.olderGames([game(built)], repo: checkout.path), [], "the checkout moved, the engine did not")
        try commit(["dm/host/hle_fs.c": "two"], in: engine)   // a new pin or a changed patch
        let hades = game(built)
        XCTAssertEqual(ToolsAge.olderGames([hades], repo: checkout.path), [hades.id])
    }

    func testAFolderThatIsNotAGitCheckoutMarksNothing() throws {
        let zip = temporary.appendingPathComponent("zip")
        try FileManager.default.createDirectory(at: zip.appendingPathComponent("dm/host"), withIntermediateDirectories: true)
        XCTAssertNil(ToolsAge.head(repo: zip.path))
        XCTAssertEqual(ToolsAge.olderGames([game("abc")], repo: zip.path), [])
    }

    private let currentChain = "95ba69b5403e"
    private let previousChain = "e047be1b6829"

    private func macGame(_ name: String, chain: String?, bundleTitleID: String? = nil,
                         hasHost: Bool = true) throws -> LibraryGame {
        let app = temporary.appendingPathComponent(name + ".app")
        let executables = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
        for executable in hasHost ? ["nxnative", "dmhost"] : ["nxnative"] {
            try FileManager.default.createSymbolicLink(at: executables.appendingPathComponent(executable),
                                                       withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        }
        var info = ["DMTitleID": bundleTitleID ?? titleID, "CFBundleExecutable": "nxnative"]
        info["DMChain"] = chain
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        return LibraryGame(titleID: titleID, name: name, appPath: app.path)
    }

    private func check(_ age: ToolsAge, games: [LibraryGame], repo: URL, marks: Set<UUID>) {
        let updated = expectation(description: "Tools age is published")
        let subscription = age.$older.dropFirst().sink { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(result, marks)
            updated.fulfill()
        }
        age.check(games: games, repo: repo.path)
        withExtendedLifetime(subscription) { wait(for: [updated], timeout: 3) }
    }

    func testAReleaseMarksOnlyValidMacGamesWithADifferentShaderChain() throws {
        let engine = temporary.appendingPathComponent("release-engine")
        let chainHeader = engine.appendingPathComponent("dm/gfx/nvn/dmsh_chain.h")
        let marker = engine.appendingPathComponent(EngineLayout.marker)
        for file in [chainHeader, marker] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data().write(to: marker)
        try "#define DMSH_CHAIN \"\(currentChain)\"\n".write(to: chainHeader, atomically: true, encoding: .utf8)
        XCTAssertNil(ToolsAge.head(repo: engine.path), "a release engine has no Git history")

        var old = try macGame("Old", chain: previousChain)
        let matching = try macGame("Matching", chain: currentChain)
        let unstamped = try macGame("Unstamped", chain: nil)
        let malformed = try macGame("Malformed", chain: "not-a-shader-chain")
        let trailingNewline = try macGame("Trailing newline", chain: previousChain + "\n")
        let wrongGame = try macGame("Wrong title", chain: previousChain, bundleTitleID: "01007EF00011E000")
        let invalid = try macGame("Missing host", chain: previousChain, hasHost: false)
        let age = ToolsAge()
        check(age, games: [old, matching, unstamped, malformed, trailingNewline, wrongGame, invalid], repo: engine, marks: [old.id])

        guard age.older == [old.id] else { return }
        old.appPath = matching.appPath
        check(age, games: [old], repo: engine, marks: [])

        // Switching back to the earlier engine also makes a valid build differ from the selected tools.
        try "#define DMSH_CHAIN \"\(previousChain)\"\n".write(to: chainHeader, atomically: true, encoding: .utf8)
        check(age, games: [matching], repo: engine, marks: [matching.id])
    }

    func testShaderChainAndGitMarksAreCombined() throws {
        let (repo, built) = try fixture()
        try commit(["dm/host/hle_fs.c": "two", "dm/gfx/nvn/dmsh_chain.h": "#define DMSH_CHAIN \"\(currentChain)\"\n"], in: repo)
        let changedHost = LibraryGame(titleID: titleID, name: "Older host", toolsCommit: built)
        let changedChain = try macGame("Older shader chain", chain: previousChain)
        check(ToolsAge(), games: [changedHost, changedChain], repo: repo, marks: [changedHost.id, changedChain.id])
    }

    func testWhatABuildReads() {
        for path in ["dm/host/hle_fs.c", "dm/gfx/nvn/dmsh_chain.h", "dm/tools/patch_nso.py", "dm/ios/tools/build_ipa.sh", "dm/mac/pack_app.py",
                     "scripts/build_ipa_from_nsp.py", "dm/games/game.py", "dm/games/settings.tsv", "dm/games/\(titleID)/shader_map.tsv"] {
            XCTAssertTrue(ToolsAge.affects(path, titleID: titleID), path)
        }
        for path in ["README.md", "docs/agents/04-graphics.md", "dm/games/\(titleID)/README.md", "dm/tools/tests/test_docs.py",
                     "dm/games/01007EF00011E000/game.tsv", "frontend/Sources/NX2Apple/LauncherView.swift", "scripts/regress.py"] {
            XCTAssertFalse(ToolsAge.affects(path, titleID: titleID), path)
        }
    }

    /// The check runs off the main thread and publishes the marked games.
    func testTheCheckPublishesTheMarkedGames() throws {
        let (repo, built) = try fixture()
        try commit(["dm/gfx/nvn/nvn.c": "new"], in: repo)
        let marked = LibraryGame(titleID: titleID, name: "Hades", toolsCommit: built)
        let unmarked = LibraryGame(titleID: titleID, name: "Old build")
        let age = ToolsAge()
        age.check(games: [marked, unmarked], repo: repo.path)
        let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !age.older.isEmpty }, object: nil)
        wait(for: [done], timeout: 10)
        XCTAssertEqual(age.older, [marked.id])
    }

    /// A library file from before the commit was recorded still loads; a finished build records its commit.
    func testTheCommitIsRecordedAndOldLibrariesLoad() throws {
        let file = temporary.appendingPathComponent("library.json")
        let id = UUID()
        try #"{"games":[{"id":"\#(id.uuidString)","titleID":"\#(titleID)","name":"Hades"}],"folder":""}"#.write(to: file, atomically: true, encoding: .utf8)
        let library = GameLibrary(file: file)
        XCTAssertNil(library.error)
        XCTAssertEqual(library.games.first?.toolsCommit, "")
        let app = temporary.appendingPathComponent("DmShell.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("plist".utf8).write(to: app.appendingPathComponent("Info.plist"))
        library.recordCompletedIOS(archive: "", app: app.path, commit: "abc123", for: id)
        XCTAssertEqual(GameLibrary(file: file).games.first?.toolsCommit, "abc123")
        library.recordCompletedIOS(archive: "", app: app.path, for: id)   // a build from a checkout without git: nothing to compare
        XCTAssertEqual(GameLibrary(file: file).games.first?.toolsCommit, "")
    }

    func testPureIOSFrameworkWithOlderShaderChainAndEmptyCommitIsMarkedAndAssessed() throws {
        let fm = FileManager.default
        let engine = temporary.appendingPathComponent("ios-release-engine")
        let chainHeader = engine.appendingPathComponent("dm/gfx/nvn/dmsh_chain.h")
        let marker = engine.appendingPathComponent(EngineLayout.marker)
        for file in [chainHeader, marker] {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data().write(to: marker)
        try "#define DMSH_CHAIN \"\(currentChain)\"\n".write(to: chainHeader, atomically: true, encoding: .utf8)

        let shellRoot = temporary.appendingPathComponent("shell-root")
        func writeMirroredFramework(tid: String, chain: String, gfxAPI: String, includeBinary: Bool = true) throws {
            let fw = URL(fileURLWithPath: ShellInstall.mirroredFramework(root: shellRoot.path, titleID: tid))
            try fm.createDirectory(at: fw, withIntermediateDirectories: true)
            let manifest = """
            {"schema":1,"title_id":"\(tid)","chain":"b-\(chain)","framework_executable":"DmGame\(tid)","gfx_api":"\(gfxAPI)"}
            """
            try manifest.write(to: fw.appendingPathComponent("game.manifest.json"), atomically: true, encoding: .utf8)
            if includeBinary {
                try Data("bin".utf8).write(to: fw.appendingPathComponent("DmGame\(tid)"))
            }
        }

        let oldTID = "010000000000A001"
        let matchTID = "010000000000A002"
        let vulkanTID = "010000000000A003"
        let brokenTID = "010000000000A004"

        try writeMirroredFramework(tid: oldTID, chain: previousChain, gfxAPI: "nvn")
        try writeMirroredFramework(tid: matchTID, chain: currentChain, gfxAPI: "nvn")
        try writeMirroredFramework(tid: vulkanTID, chain: previousChain, gfxAPI: "vulkan")
        try writeMirroredFramework(tid: brokenTID, chain: previousChain, gfxAPI: "nvn", includeBinary: false)

        let oldGame = LibraryGame(titleID: oldTID, name: "Pure iOS Old")
        let matchingGame = LibraryGame(titleID: matchTID, name: "Pure iOS Current")
        let vulkanGame = LibraryGame(titleID: vulkanTID, name: "Pure iOS Vulkan")
        let brokenGame = LibraryGame(titleID: brokenTID, name: "Pure iOS Incomplete")

        let age = ToolsAge()
        let updated = expectation(description: "Tools age assesses pure iOS frameworks")
        let sub = age.$assessments.dropFirst().sink { assessments in
            guard assessments.count == 4 else { return }
            updated.fulfill()
        }
        age.check(
            games: [oldGame, matchingGame, vulkanGame, brokenGame],
            repo: engine.path,
            appVersion: "1.5.0",
            seedRoot: temporary.appendingPathComponent("empty-seeds").path,
            shellRoot: shellRoot.path
        )
        withExtendedLifetime(sub) { wait(for: [updated], timeout: 5) }

        XCTAssertEqual(age.older, [oldGame.id])
        let oldAssessment = try XCTUnwrap(age.assessments[oldGame.id])
        XCTAssertEqual(oldAssessment.heroState, .generalSync(fast: false))
        XCTAssertTrue(oldAssessment.missingOriginalPackage)
        XCTAssertFalse(oldAssessment.hasUsableSeed)
        XCTAssertEqual(age.assessments[matchingGame.id]?.heroState, .upToDate)
        XCTAssertEqual(age.assessments[vulkanGame.id]?.heroState, .upToDate)
        XCTAssertEqual(age.assessments[brokenGame.id]?.heroState, .upToDate)
    }

    func testStandaloneDmIOSAppInfoPlistChainAndFallback() throws {
        let fm = FileManager.default
        let engine = temporary.appendingPathComponent("standalone-ios-engine")
        let chainHeader = engine.appendingPathComponent("dm/gfx/nvn/dmsh_chain.h")
        let marker = engine.appendingPathComponent(EngineLayout.marker)
        for file in [chainHeader, marker] {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data().write(to: marker)
        try "#define DMSH_CHAIN \"\(currentChain)\"\n".write(to: chainHeader, atomically: true, encoding: .utf8)

        func makeStandaloneApp(name: String, tid: String, plist: [String: Any]? = nil, rawPlistData: Data? = nil) throws -> LibraryGame {
            let app = temporary.appendingPathComponent(name + ".app")
            try fm.createDirectory(at: app, withIntermediateDirectories: true)
            if let rawPlistData {
                try rawPlistData.write(to: app.appendingPathComponent("Info.plist"))
            } else if let plist {
                try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                    .write(to: app.appendingPathComponent("Info.plist"))
            }
            return LibraryGame(titleID: tid, name: name, iosAppPath: app.path)
        }

        let oldGame = try makeStandaloneApp(
            name: "StandaloneOld",
            tid: "010000000000B001",
            plist: ["CFBundleExecutable": "DmIOS", "DMChain": "  B-\(previousChain.uppercased()) \n"]
        )
        let matchingGame = try makeStandaloneApp(
            name: "StandaloneMatch",
            tid: "010000000000B002",
            plist: ["CFBundleExecutable": "DmIOS", "DMChain": currentChain]
        )
        let vulkanGame = try makeStandaloneApp(
            name: "StandaloneVulkan",
            tid: "010000000000B003",
            plist: ["CFBundleExecutable": "DmIOS", "DMChain": previousChain, "DMGfxAPI": "vulkan"]
        )
        let missingPlistGame = try makeStandaloneApp(
            name: "StandaloneMissingPlist",
            tid: "010000000000B004"
        )
        let corruptPlistGame = try makeStandaloneApp(
            name: "StandaloneCorruptPlist",
            tid: "010000000000B005",
            rawPlistData: Data("not a valid plist".utf8)
        )

        let games = [oldGame, matchingGame, vulkanGame, missingPlistGame, corruptPlistGame]
        let age = ToolsAge()
        let updated = expectation(description: "Tools age assesses standalone DmIOS apps")
        let sub = age.$assessments.dropFirst().sink { assessments in
            guard assessments.count == games.count else { return }
            updated.fulfill()
        }
        age.check(
            games: games,
            repo: engine.path,
            appVersion: "1.5.0",
            seedRoot: temporary.appendingPathComponent("empty-seeds-standalone").path,
            shellRoot: temporary.appendingPathComponent("empty-shell-standalone").path
        )
        withExtendedLifetime(sub) { wait(for: [updated], timeout: 5) }

        XCTAssertEqual(age.older, [oldGame.id])
        XCTAssertEqual(age.assessments[matchingGame.id]?.heroState, .upToDate)
        XCTAssertEqual(age.assessments[vulkanGame.id]?.heroState, .upToDate)
        XCTAssertEqual(age.assessments[missingPlistGame.id]?.heroState, .upToDate)
        XCTAssertEqual(age.assessments[corruptPlistGame.id]?.heroState, .upToDate)
    }
}
