import Foundation
import XCTest
@testable import NXCore

final class RefreshPrecheckTests: XCTestCase {
    private var tempDir: URL!
    private let fm = FileManager.default
    private let stardewTID = "0100E65002BB8000"

    override func setUpWithError() throws {
        tempDir = fm.temporaryDirectory.appendingPathComponent("nx-refresh-precheck-" + UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tempDir)
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func engineRoot() throws -> URL {
        let url = repoRoot.appendingPathComponent("engine")
        XCTAssertTrue(fm.fileExists(atPath: url.appendingPathComponent("dm/tools/shader_lib.py").path))
        return url
    }

    private func runPython(_ script: String, args: [String], env: [String: String] = [:]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [script] + args
        var merged = ProcessInfo.processInfo.environment
        for (k, v) in env { merged[k] = v }
        p.environment = merged
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(p.terminationStatus, 0, "python \(script) \(args) failed: stdout=\(stdout) stderr=\(stderr)")
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func copyProfile(tid: String, to repo: URL) throws -> URL {
        let src = try engineRoot().appendingPathComponent("dm/games/" + tid.lowercased())
        let dst = repo.appendingPathComponent("dm/games/" + tid.lowercased())
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: src, to: dst)
        return dst
    }

    private func makeMockRepo(chain: String, copyTIDs: [String] = []) throws -> URL {
        let repo = tempDir.appendingPathComponent("repo-" + UUID().uuidString)
        let nvnDir = repo.appendingPathComponent("dm/gfx/nvn")
        let toolsDir = repo.appendingPathComponent("dm/gfx/tools")
        try fm.createDirectory(at: nvnDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: toolsDir, withIntermediateDirectories: true)
        try "#define DMSH_CHAIN \"\(chain)\"\n".write(
            to: nvnDir.appendingPathComponent("dmsh_chain.h"),
            atomically: true,
            encoding: .utf8
        )
        for tid in copyTIDs {
            _ = try copyProfile(tid: tid, to: repo)
        }
        return repo
    }

    private func packShaderLibDirect(
        at libDir: URL,
        gameID: String,
        inputsDigest: String,
        leaveOutPulling: Bool = false
    ) throws {
        try fm.createDirectory(at: libDir, withIntermediateDirectories: true)
        try Data("metallib".utf8).write(to: libDir.appendingPathComponent("0000000000000001_b.metallib"))
        if leaveOutPulling {
            try Data("pull".utf8).write(to: libDir.appendingPathComponent("0000000000000001_bp.metallib"))
        }
        let stamp = "game\t\(gameID)\ninputs\t\(inputsDigest)\n"
        try Data(stamp.utf8).write(to: libDir.appendingPathComponent("inputs.tsv"))
        let toolsDir = try engineRoot().appendingPathComponent("dm/tools").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [
            "-c",
            "import sys; sys.path.insert(0, sys.argv[1]); import shader_lib; assert shader_lib.pack(sys.argv[2], leave_out=(sys.argv[3]=='1'))",
            toolsDir,
            libDir.path,
            leaveOutPulling ? "1" : "0",
        ]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }

    private func writeNVNSeed(
        seedRoot: URL,
        tid: String,
        chain: String,
        inputsDigest: String,
        tableChain: String? = nil,
        tableInputs: String? = nil,
        leaveOutPulling: Bool = false,
        withMetalSources: Bool = true
    ) throws -> URL {
        let seedDir = URL(fileURLWithPath: BuildSeedCache.seedDirectory(for: tid, seedRoot: seedRoot.path))
        try fm.createDirectory(at: seedDir.appendingPathComponent("ExeFS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: seedDir.appendingPathComponent("shader/pkg"), withIntermediateDirectories: true)
        try fm.createDirectory(at: seedDir.appendingPathComponent("shader/tables"), withIntermediateDirectories: true)
        try fm.createDirectory(at: seedDir.appendingPathComponent("shader/ios"), withIntermediateDirectories: true)
        if withMetalSources {
            try fm.createDirectory(at: seedDir.appendingPathComponent("metal-sources"), withIntermediateDirectories: true)
        }
        try Data("exefs".utf8).write(to: seedDir.appendingPathComponent("ExeFS/main"))

        let tChain = tableChain ?? chain
        let tInputs = tableInputs ?? inputsDigest
        let head = "# chain b-\(tChain) inputs \(tInputs) fixture\n"
        try Data(head.utf8).write(to: seedDir.appendingPathComponent("shader/tables/c1_full.tsv"))
        try Data(head.utf8).write(to: seedDir.appendingPathComponent("shader/tables/cb_extent.tsv"))

        let libDir = seedDir.appendingPathComponent("shader/ios/b-" + chain)
        try packShaderLibDirect(at: libDir, gameID: tid.lowercased(), inputsDigest: inputsDigest, leaveOutPulling: leaveOutPulling)

        let record = BuildSeedRecord(
            titleID: tid,
            baseTitleID: tid,
            appName: "Test Game",
            gfxAPI: "nvn",
            chain: chain,
            profileID: tid.lowercased(),
            profileKind: "registered",
            romfsIdentity: "DMROMFSID1 title=\(tid) size=64 index=deadbeef"
        )
        try JSONEncoder().encode(record).write(to: seedDir.appendingPathComponent("seed.json"))
        return seedDir
    }

    func testProfileInputsDigestMatchesRealDmshChainTool() throws {
        let engine = try engineRoot()
        let dmshChainTool = engine.appendingPathComponent("dm/gfx/tools/dmsh_chain.py").path
        for tid in [stardewTID, "0100152000022000", "01007ef00011e000"] {
            let profileDir = engine.appendingPathComponent("dm/games/" + tid.lowercased()).path
            let swiftDigest = try XCTUnwrap(RefreshPrecheck.computeProfileInputsDigest(profileDir: profileDir))
            let pyDigest = try runPython(dmshChainTool, args: ["--inputs"], env: ["DM_GAME": tid.lowercased()])
            XCTAssertEqual(swiftDigest, pyDigest, "Inputs digest must match dmsh_chain.py --inputs for \(tid)")
        }
    }

    func testStardewPathBChainChangeWithLocalImgIsNeverFastAndReportsChainChanged() throws {
        let oldChain = "111122223333"
        let newChain = "108c5f92c3c4"
        let repo = try makeMockRepo(chain: newChain, copyTIDs: [stardewTID])
        let profileDir = repo.appendingPathComponent("dm/games/" + stardewTID.lowercased()).path
        let inputsDigest = try XCTUnwrap(RefreshPrecheck.computeProfileInputsDigest(profileDir: profileDir))

        let seedRoot = tempDir.appendingPathComponent("seeds")
        let outDir = tempDir.appendingPathComponent("out")
        _ = try writeNVNSeed(seedRoot: seedRoot, tid: stardewTID, chain: oldChain, inputsDigest: inputsDigest)

        let localImg = outDir.appendingPathComponent("games/Stardew Valley/Stardew Valley.img")
        try fm.createDirectory(at: localImg.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("img".utf8).write(to: localImg)

        let assessment = GameUpdateCatalog.assess(
            titleID: stardewTID,
            isMarkedOlder: true,
            hasMacBuild: false,
            macAppPath: "",
            hasIOSBuild: true,
            hasReadableSourceInputs: false,
            outDir: outDir.path,
            gameName: "Stardew Valley",
            appVersion: "1.5.1",
            gitSpecificChanged: false,
            seedRoot: seedRoot.path,
            repoPath: repo.path
        )

        XCTAssertFalse(assessment.canFastRefreshIOS, "Path B chain mismatch must never be marked fast refresh")
        XCTAssertTrue(assessment.canSeedRefreshIOS, "Local .img still allows --from-seed prefill refresh without original NSP")
        XCTAssertTrue(assessment.needsShaderRebuildIOS)
        XCTAssertEqual(assessment.shaderRebuildReasonIOS, .chainChanged)
        XCTAssertFalse(assessment.missingOriginalPackage)
        XCTAssertEqual(assessment.heroState, .generalSync(fast: false))
    }

    func testMatchingChainButChangedProfileInputsRequiresShaderRebuild() throws {
        let chain = "108c5f92c3c4"
        let repo = try makeMockRepo(chain: chain, copyTIDs: [stardewTID])
        let profileDir = repo.appendingPathComponent("dm/games/" + stardewTID.lowercased())
        let oldInputsDigest = try XCTUnwrap(RefreshPrecheck.computeProfileInputsDigest(profileDir: profileDir.path))

        let seedRoot = tempDir.appendingPathComponent("seeds-inputs")
        let outDir = tempDir.appendingPathComponent("out-inputs")
        _ = try writeNVNSeed(seedRoot: seedRoot, tid: stardewTID, chain: chain, inputsDigest: oldInputsDigest)

        let localImg = outDir.appendingPathComponent("games/Stardew Valley/Stardew Valley.img")
        try fm.createDirectory(at: localImg.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("img".utf8).write(to: localImg)

        // Mutate shader_map.tsv in repo profile to simulate a game shader input change under the same dmsh_chain
        let shaderMap = profileDir.appendingPathComponent("shader_map.tsv")
        let existing = (try? String(contentsOf: shaderMap, encoding: .utf8)) ?? ""
        try (existing + "# simulated shader table tweak\n").write(to: shaderMap, atomically: true, encoding: .utf8)

        let plan = RefreshPrecheck.evaluate(
            titleID: stardewTID,
            hasMacBuild: false,
            macAppPath: "",
            hasIOSBuild: true,
            hasReadableSourceInputs: false,
            outDir: outDir.path,
            gameName: "Stardew Valley",
            seedRoot: seedRoot.path,
            repoPath: repo.path
        )

        XCTAssertFalse(plan.canFastRefreshIOS)
        XCTAssertTrue(plan.canSeedRefreshIOS)
        XCTAssertTrue(plan.needsShaderRebuildIOS)
        XCTAssertEqual(plan.shaderRebuildReasonIOS, .inputsChanged)
    }

    func testPlatformDimensionMacCacheMissingVsPresentWithMatchingIOSPathA() throws {
        let chain = "108c5f92c3c4"
        let repo = try makeMockRepo(chain: chain, copyTIDs: [stardewTID])
        let profileDir = repo.appendingPathComponent("dm/games/" + stardewTID.lowercased()).path
        let inputsDigest = try XCTUnwrap(RefreshPrecheck.computeProfileInputsDigest(profileDir: profileDir))

        let seedRoot = tempDir.appendingPathComponent("seeds-mac")
        let outDir = tempDir.appendingPathComponent("out-mac")
        _ = try writeNVNSeed(seedRoot: seedRoot, tid: stardewTID, chain: chain, inputsDigest: inputsDigest)

        let macApp = outDir.appendingPathComponent("Stardew Valley.app")
        try fm.createDirectory(at: macApp.appendingPathComponent("Contents"), withIntermediateDirectories: true)

        // No workDir/shader/cache/b-<chain> yet -> iOS is fastReuse, Mac must rebuild from metal-sources
        let withoutMacCache = RefreshPrecheck.evaluate(
            titleID: stardewTID,
            hasMacBuild: true,
            macAppPath: macApp.path,
            hasIOSBuild: true,
            hasReadableSourceInputs: false,
            outDir: outDir.path,
            gameName: "Stardew Valley",
            seedRoot: seedRoot.path,
            repoPath: repo.path
        )
        XCTAssertTrue(withoutMacCache.canFastRefreshIOS)
        XCTAssertFalse(withoutMacCache.needsShaderRebuildIOS)
        XCTAssertFalse(withoutMacCache.canFastRefreshMac)
        XCTAssertTrue(withoutMacCache.canSeedRefreshMac)
        XCTAssertTrue(withoutMacCache.needsShaderRebuildMac)
        XCTAssertEqual(withoutMacCache.shaderRebuildReasonMac, .cacheMissing)

        // Create real packed Mac shader cache b-<chain>.img -> Mac becomes fastReuse too
        let macCacheLib = outDir.appendingPathComponent("\(stardewTID)_build/shader/cache/b-" + chain)
        try packShaderLibDirect(at: macCacheLib, gameID: stardewTID.lowercased(), inputsDigest: inputsDigest)

        let withMacCache = RefreshPrecheck.evaluate(
            titleID: stardewTID,
            hasMacBuild: true,
            macAppPath: macApp.path,
            hasIOSBuild: true,
            hasReadableSourceInputs: false,
            outDir: outDir.path,
            gameName: "Stardew Valley",
            seedRoot: seedRoot.path,
            repoPath: repo.path
        )
        XCTAssertTrue(withMacCache.canFastRefreshMac)
        XCTAssertFalse(withMacCache.needsShaderRebuildMac)
        XCTAssertTrue(withMacCache.canFastRefreshIOS)
        XCTAssertFalse(withMacCache.needsShaderRebuildIOS)
    }

    func testPullingLeftOutAndTablesMismatchPreventFastRefresh() throws {
        let chain = "108c5f92c3c4"
        let repo = try makeMockRepo(chain: chain, copyTIDs: [stardewTID])
        let profileDir = repo.appendingPathComponent("dm/games/" + stardewTID.lowercased()).path
        let inputsDigest = try XCTUnwrap(RefreshPrecheck.computeProfileInputsDigest(profileDir: profileDir))

        let outDir = tempDir.appendingPathComponent("out-edge")
        let localImg = outDir.appendingPathComponent("games/Stardew Valley/Stardew Valley.img")
        try fm.createDirectory(at: localImg.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("img".utf8).write(to: localImg)

        let pullSeeds = tempDir.appendingPathComponent("seeds-pull")
        _ = try writeNVNSeed(
            seedRoot: pullSeeds,
            tid: stardewTID,
            chain: chain,
            inputsDigest: inputsDigest,
            leaveOutPulling: true
        )
        let pullPlan = RefreshPrecheck.evaluate(
            titleID: stardewTID,
            hasMacBuild: false,
            macAppPath: "",
            hasIOSBuild: true,
            hasReadableSourceInputs: false,
            outDir: outDir.path,
            gameName: "Stardew Valley",
            seedRoot: pullSeeds.path,
            repoPath: repo.path
        )
        XCTAssertFalse(pullPlan.canFastRefreshIOS)
        XCTAssertEqual(pullPlan.shaderRebuildReasonIOS, .pullingMissing)

        let tableSeeds = tempDir.appendingPathComponent("seeds-tables")
        _ = try writeNVNSeed(
            seedRoot: tableSeeds,
            tid: stardewTID,
            chain: chain,
            inputsDigest: inputsDigest,
            tableInputs: "000000000000"
        )
        let tablePlan = RefreshPrecheck.evaluate(
            titleID: stardewTID,
            hasMacBuild: false,
            macAppPath: "",
            hasIOSBuild: true,
            hasReadableSourceInputs: false,
            outDir: outDir.path,
            gameName: "Stardew Valley",
            seedRoot: tableSeeds.path,
            repoPath: repo.path
        )
        XCTAssertFalse(tablePlan.canFastRefreshIOS)
        XCTAssertEqual(tablePlan.shaderRebuildReasonIOS, .tablesMismatch)
    }
}
