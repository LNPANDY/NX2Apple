import XCTest
@testable import NXCore

final class FrameworkRefreshTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("fw-refresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFakeRepo(chain: String = "c1a2b3c4", includeGameID: String = "0100535012974000") throws -> String {
        let repo = root.appendingPathComponent("repo")
        let fm = FileManager.default
        let chainHeader = repo.appendingPathComponent("dm/gfx/nvn/dmsh_chain.h")
        try fm.createDirectory(at: chainHeader.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#define DMSH_CHAIN \"\(chain)\"\n".utf8).write(to: chainHeader)
        let gameDir = repo.appendingPathComponent("dm/games/\(includeGameID.lowercased())")
        try fm.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try Data("id\t\(includeGameID)\n".utf8).write(to: gameDir.appendingPathComponent("game.tsv"))
        return repo.path
    }

    private func makeWorkDir(name: String = "0100535012974000_build", versions: [String] = ["v0"]) throws -> URL {
        let workDir = root.appendingPathComponent(name)
        let fm = FileManager.default
        for version in versions {
            let exe = workDir.appendingPathComponent("extract/\(version)/ExeFS")
            try fm.createDirectory(at: exe, withIntermediateDirectories: true)
            try Data("NSO0".utf8).write(to: exe.appendingPathComponent("main"))
            try Data("ctrl".utf8).write(to: workDir.appendingPathComponent("extract/\(version)/control.nacp"))
        }
        return workDir
    }

    private func makeRomFS(_ url: URL) throws -> String {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var bytes = Data("DMROMFS1".utf8)
        bytes.append(Data(repeating: 0, count: 64))
        try bytes.write(to: url)
        return url.path
    }

    func testVulkanAndGLShadersReportReadyAndPickLatestExtractedVersion() throws {
        let titleID = "0100535012974000"
        let repo = try makeFakeRepo()
        let workDir = try makeWorkDir(versions: ["v0", "v2"])
        let vkLib = workDir.appendingPathComponent("shader/ios/vk/vk_shaders.metallib")
        try FileManager.default.createDirectory(at: vkLib.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("lib".utf8).write(to: vkLib)
        let romfs = try makeRomFS(root.appendingPathComponent("games/\(titleID)/romfs.img"))

        XCTAssertTrue(FrameworkRefresh.canAttempt(workDirs: [workDir.path], romfsCandidates: [romfs], repo: repo, titleID: titleID))
        let status = FrameworkRefresh.inspect(
            workDirs: [workDir.path],
            romfsCandidates: [romfs],
            fallbackArchiveDir: root.appendingPathComponent("games/\(titleID)").path,
            repo: repo,
            titleID: titleID
        )
        guard case .ready(let plan) = status else {
            return XCTFail("Expected ready plan, got \(status)")
        }
        XCTAssertEqual(plan.version, "v2")
        XCTAssertEqual(plan.graphicsAPI, "vulkan")
        XCTAssertEqual(plan.romfsPath, URL(fileURLWithPath: romfs).standardizedFileURL.path)
        XCTAssertEqual(plan.archiveDir, root.appendingPathComponent("games/\(titleID)").standardizedFileURL.path)

        try FileManager.default.removeItem(at: vkLib)
        let glLib = workDir.appendingPathComponent("shader/ios/gl/gl_shaders.metallib")
        try FileManager.default.createDirectory(at: glLib.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("lib".utf8).write(to: glLib)
        guard case .ready(let glPlan) = FrameworkRefresh.inspect(
            workDirs: [workDir.path],
            romfsCandidates: [romfs],
            fallbackArchiveDir: root.appendingPathComponent("games/\(titleID)").path,
            repo: repo,
            titleID: titleID
        ) else {
            return XCTFail("Expected GL plan to be ready")
        }
        XCTAssertEqual(glPlan.graphicsAPI, "gl")
    }

    func testNVNShaderChainStatesMatchAndDetectStaleChains() throws {
        let titleID = "0100535012974000"
        let repo = try makeFakeRepo(chain: "newchain")
        let workDir = try makeWorkDir()
        let romfs = try makeRomFS(workDir.appendingPathComponent("extract/v0/RomFS.img"))
        let fm = FileManager.default

        let oldChain = workDir.appendingPathComponent("shader/ios/b-oldchain")
        try fm.createDirectory(at: oldChain, withIntermediateDirectories: true)
        XCTAssertEqual(
            FrameworkRefresh.inspect(workDirs: [workDir.path], romfsCandidates: [romfs], fallbackArchiveDir: root.appendingPathComponent("out").path, repo: repo, titleID: titleID),
            .shadersStale(.chainMismatch(have: "b-oldchain", want: "b-newchain"))
        )

        try fm.removeItem(at: oldChain)
        XCTAssertEqual(
            FrameworkRefresh.inspect(workDirs: [workDir.path], romfsCandidates: [romfs], fallbackArchiveDir: root.appendingPathComponent("out").path, repo: repo, titleID: titleID),
            .shadersStale(.missingShaders)
        )

        let iosChain = workDir.appendingPathComponent("shader/ios/b-newchain.img")
        let cacheChain = workDir.appendingPathComponent("shader/cache/b-newchain")
        try Data("img".utf8).write(to: iosChain)
        try fm.createDirectory(at: cacheChain, withIntermediateDirectories: true)
        guard case .ready(let nvnPlan) = FrameworkRefresh.inspect(
            workDirs: [workDir.path],
            romfsCandidates: [romfs],
            fallbackArchiveDir: root.appendingPathComponent("fallback-archive").path,
            repo: repo,
            titleID: titleID
        ) else {
            return XCTFail("Expected NVN plan to be ready")
        }
        XCTAssertEqual(nvnPlan.graphicsAPI, "nvn")
        XCTAssertEqual(nvnPlan.chain, "newchain")
        XCTAssertEqual(nvnPlan.archiveDir, root.appendingPathComponent("fallback-archive").path)
    }

    func testProfileOverrideAndMakeLaunchAgainstSyncedEngine() throws {
        let titleID = "0100535012974000"
        let workDir = try makeWorkDir()
        let profileGameDir = workDir.appendingPathComponent("profile/\(titleID)")
        try FileManager.default.createDirectory(at: profileGameDir, withIntermediateDirectories: true)
        try Data("id\t\(titleID)\n".utf8).write(to: profileGameDir.appendingPathComponent("game.tsv"))
        let vkLib = workDir.appendingPathComponent("shader/ios/vk/vk_shaders.metallib")
        try FileManager.default.createDirectory(at: vkLib.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("lib".utf8).write(to: vkLib)
        let romfs = try makeRomFS(root.appendingPathComponent("games/\(titleID)/romfs.img"))

        let realRepo = RepoLayout.find()
        let repoPath: String
        if !realRepo.isEmpty, FileManager.default.fileExists(atPath: EngineLayout.root(realRepo) + "/dm/games/0100535012974000/game.tsv") {
            repoPath = realRepo
            XCTAssertNotNil(EngineLayout.shaderChain(repo: repoPath))
        } else {
            repoPath = try makeFakeRepo()
        }

        guard case .ready(let plan) = FrameworkRefresh.inspect(
            workDirs: [workDir.path],
            romfsCandidates: [romfs],
            fallbackArchiveDir: root.appendingPathComponent("games/\(titleID)").path,
            repo: repoPath,
            titleID: titleID
        ) else {
            return XCTFail("Expected plan to be ready")
        }
        XCTAssertEqual(plan.profileDir, workDir.appendingPathComponent("profile").standardizedFileURL.path)

        let launch = FrameworkRefresh.makeLaunch(
            plan: plan,
            repo: repoPath,
            python: "/usr/bin/python3",
            teamID: "TEAM123",
            fallbackName: "Hades",
            envFile: "/tmp/env.txt",
            environment: ["PATH": "/usr/bin"]
        )
        XCTAssertEqual(launch.executable, "/usr/bin/python3")
        XCTAssertEqual(launch.arguments.first, "-c")
        XCTAssertEqual(launch.arguments[2], EngineLayout.root(repoPath))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(launch.arguments[3].utf8)) as? [String: Any])
        XCTAssertEqual(payload["title_id"] as? String, titleID)
        XCTAssertEqual(payload["team_id"] as? String, "TEAM123")
        XCTAssertEqual(payload["env_file"] as? String, "/tmp/env.txt")
    }
}
