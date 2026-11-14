import Foundation
import XCTest
@testable import NXCore

final class FastRefreshBuildCacheTests: XCTestCase {
    private var tempDir: URL!
    private let fm = FileManager.default
    private let titleID = "0100111100001111"

    override func setUpWithError() throws {
        tempDir = fm.temporaryDirectory.appendingPathComponent("nxnative-fastrefresh-" + UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tempDir)
    }

    private func createSeedDir(
        tid: String = "0100111100001111",
        chain: String = "a5e7fb6e4fa4",
        gfxAPI: String = "nvn",
        corruptJSON: Bool = false,
        missingExeFS: Bool = false,
        emptyExeFS: Bool = false,
        missingTables: Bool = false,
        missingIOSShader: Bool = false
    ) throws -> String {
        let seedDir = tempDir.appendingPathComponent(tid.uppercased()).path
        try fm.createDirectory(atPath: seedDir, withIntermediateDirectories: true)

        if corruptJSON {
            try "{ invalid json".write(toFile: seedDir + "/seed.json", atomically: true, encoding: .utf8)
        } else {
            let record = BuildSeedRecord(
                schema: 1,
                titleID: tid,
                baseTitleID: tid,
                pkgVer: "1.0.0",
                appName: "Test Game",
                appVersion: "1.0.0",
                bundleID: "com.test.game",
                lang: "en",
                langsAvailable: ["en", "ja"],
                gfxAPI: gfxAPI,
                chain: chain,
                profileID: "1111",
                profileKind: "game",
                isMultiProgram: false,
                usesJIT: false,
                hasAOC: false,
                hasHTML: false,
                hasIcon: true,
                inputsDigest: "sha256:abc",
                romfsIdentity: "DMROMFSID1 test",
                updatedAt: "2026-11-14T00:00:00Z"
            )
            let data = try JSONEncoder().encode(record)
            try data.write(to: URL(fileURLWithPath: seedDir + "/seed.json"))
        }

        if !missingExeFS {
            let exefs = seedDir + "/ExeFS"
            try fm.createDirectory(atPath: exefs, withIntermediateDirectories: true)
            if !emptyExeFS {
                try "binary".write(toFile: exefs + "/main", atomically: true, encoding: .utf8)
            }
        }

        let pkg = seedDir + "/shader/pkg"
        try fm.createDirectory(atPath: pkg, withIntermediateDirectories: true)

        if !missingTables {
            let tables = seedDir + "/shader/tables"
            try fm.createDirectory(atPath: tables, withIntermediateDirectories: true)
            try "tsv1".write(toFile: tables + "/c1_full.tsv", atomically: true, encoding: .utf8)
            try "tsv2".write(toFile: tables + "/cb_extent.tsv", atomically: true, encoding: .utf8)
        }

        if !missingIOSShader {
            let ios = seedDir + "/shader/ios"
            try fm.createDirectory(atPath: ios, withIntermediateDirectories: true)
            try "msl".write(toFile: ios + "/b-" + chain + ".img", atomically: true, encoding: .utf8)
        }

        return seedDir
    }

    private func createMockRepo(chain: String = "a5e7fb6e4fa4") throws -> String {
        let repo = tempDir.appendingPathComponent("mock-repo").path
        let headerDir = repo + "/dm/gfx/nvn"
        try fm.createDirectory(atPath: headerDir, withIntermediateDirectories: true)
        let header = """
        #define DMSH_CHAIN "\(chain)"
        """
        try header.write(toFile: headerDir + "/dmsh_chain.h", atomically: true, encoding: .utf8)
        return repo
    }

    func testDefaultRoot() {
        let customHome = "/Users/testuser"
        let root = BuildSeedCache.defaultRoot(home: customHome, env: [:])
        XCTAssertEqual(root, "/Users/testuser/Library/Application Support/nxnative/build-seeds")

        let envRoot = BuildSeedCache.defaultRoot(home: customHome, env: ["DM_SEED_CACHE_DIR": "/custom/seeds"])
        XCTAssertEqual(envRoot, "/custom/seeds")
    }

    func testBuildSeedRecordEncodingDecoding() throws {
        let record = BuildSeedRecord(
            schema: 1,
            titleID: titleID,
            baseTitleID: titleID,
            pkgVer: "1.0.0",
            appName: "Sample Game",
            appVersion: "1.0.0",
            bundleID: "com.sample.game",
            lang: "en",
            langsAvailable: ["en", "zh-Hans"],
            gfxAPI: "nvn",
            chain: "b-abcdef123456",
            profileID: "1111",
            profileKind: "provisional",
            isMultiProgram: false,
            usesJIT: true,
            hasAOC: true,
            hasHTML: false,
            hasIcon: true,
            inputsDigest: "digest-123",
            romfsIdentity: "DMROMFSID1 sample",
            updatedAt: "2026-11-14T00:00:00Z"
        )
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(BuildSeedRecord.self, from: data)
        XCTAssertEqual(record, decoded)
        XCTAssertEqual(decoded.titleID, titleID)
        XCTAssertEqual(decoded.chain, "b-abcdef123456")
        XCTAssertEqual(decoded.usesJIT, true)
    }

    func testInspectValidPathA() throws {
        _ = try createSeedDir(tid: titleID, chain: "a5e7fb6e4fa4")
        let repo = try createMockRepo(chain: "a5e7fb6e4fa4")

        let inspection = BuildSeedCache.inspect(
            titleID: titleID,
            seedRoot: tempDir.path,
            repoPath: repo,
            fm: fm
        )
        XCTAssertTrue(inspection.isValid)
        XCTAssertTrue(inspection.isUsable)
        XCTAssertEqual(inspection.path, .pathA)
        XCTAssertEqual(inspection.record?.titleID, titleID)
    }

    func testInspectValidPathBOnChainDifference() throws {
        _ = try createSeedDir(tid: titleID, chain: "oldchain1111")
        let repo = try createMockRepo(chain: "newchain2222")

        let inspection = BuildSeedCache.inspect(
            titleID: titleID,
            seedRoot: tempDir.path,
            repoPath: repo,
            fm: fm
        )
        XCTAssertTrue(inspection.isValid)
        XCTAssertTrue(inspection.isUsable)
        XCTAssertEqual(inspection.path, .pathB)
    }

    func testInspectCorruptJSON() throws {
        _ = try createSeedDir(tid: titleID, corruptJSON: true)
        let repo = try createMockRepo()

        let inspection = BuildSeedCache.inspect(
            titleID: titleID,
            seedRoot: tempDir.path,
            repoPath: repo,
            fm: fm
        )
        XCTAssertFalse(inspection.isValid)
        XCTAssertFalse(inspection.isUsable)
        XCTAssertNil(inspection.record)
    }

    func testInspectMissingExeFS() throws {
        _ = try createSeedDir(tid: titleID, missingExeFS: true)
        let repo = try createMockRepo()

        let inspection = BuildSeedCache.inspect(
            titleID: titleID,
            seedRoot: tempDir.path,
            repoPath: repo,
            fm: fm
        )
        XCTAssertFalse(inspection.isValid)
        XCTAssertEqual(inspection.reason, "missing or empty ExeFS directory")
    }

    func testInspectEmptyExeFS() throws {
        _ = try createSeedDir(tid: titleID, emptyExeFS: true)
        let repo = try createMockRepo()

        let inspection = BuildSeedCache.inspect(
            titleID: titleID,
            seedRoot: tempDir.path,
            repoPath: repo,
            fm: fm
        )
        XCTAssertFalse(inspection.isValid)
        XCTAssertEqual(inspection.reason, "missing or empty ExeFS directory")
    }

    func testInspectMissingShaderTablesForNVN() throws {
        _ = try createSeedDir(tid: titleID, gfxAPI: "nvn", missingTables: true)
        let repo = try createMockRepo()

        let inspection = BuildSeedCache.inspect(
            titleID: titleID,
            seedRoot: tempDir.path,
            repoPath: repo,
            fm: fm
        )
        XCTAssertFalse(inspection.isValid)
        XCTAssertTrue(inspection.reason?.contains("missing shader/tables") == true)
    }

    func testPrefillCandidates() throws {
        let outDir = tempDir.appendingPathComponent("output").path
        let gameName = "Super Mario Odyssey"
        let safeName = RomFSArchive.sanitizeGameName(gameName, fallback: titleID)

        let macApp = outDir + "/" + safeName + ".app"
        try fm.createDirectory(atPath: macApp, withIntermediateDirectories: true)

        let targetImg = outDir + "/games/" + safeName + "/" + safeName + ".img"
        try fm.createDirectory(atPath: (targetImg as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "img".write(toFile: targetImg, atomically: true, encoding: .utf8)

        let legacyImg = outDir + "/games/" + titleID + "/romfs.img"
        try fm.createDirectory(atPath: (legacyImg as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "legacy".write(toFile: legacyImg, atomically: true, encoding: .utf8)

        let workDir = tempDir.appendingPathComponent("work").path
        let workIOS = workDir + "/shader/ios"
        try fm.createDirectory(atPath: workIOS, withIntermediateDirectories: true)

        let candidates = BuildSeedCache.prefillCandidates(
            titleID: titleID,
            outDir: outDir,
            gameName: gameName,
            macAppPath: macApp,
            workDir: workDir,
            fm: fm
        )

        XCTAssertTrue(candidates.contains(macApp))
        XCTAssertTrue(candidates.contains(targetImg))
        XCTAssertTrue(candidates.contains(legacyImg))
        XCTAssertTrue(candidates.contains(workIOS))
        XCTAssertFalse(candidates.contains(outDir + "/nonexistent.img"))
    }

    func testTrailerStatusAndAction() {
        let matchJSON = """
        {
          "has_trailer": true,
          "version": 1,
          "gfx_api": "nvn",
          "flags": 0,
          "multi_program": false,
          "chain": "b-a5e7fb6e4fa4",
          "base_romfs_size": 1000,
          "msl_offset": 16384,
          "msl_size": 500,
          "file_size": 16884,
          "files": 12
        }
        """

        let status = BuildSeedCache.parseTrailerStatus(from: matchJSON)
        XCTAssertNotNil(status)
        XCTAssertTrue(status?.hasTrailer == true)

        // Matching: 0-I/O skip
        let skip = BuildSeedCache.shouldSkipTrailerInjection(
            status: status!,
            gfxAPI: "nvn",
            chain: "a5e7fb6e4fa4",
            multiProgram: false
        )
        XCTAssertTrue(skip)
        XCTAssertEqual(
            BuildSeedCache.trailerAction(status: status!, gfxAPI: "nvn", chain: "a5e7fb6e4fa4", multiProgram: false),
            .skip
        )

        // Chain mismatch: replace
        let skipDiffChain = BuildSeedCache.shouldSkipTrailerInjection(
            status: status!,
            gfxAPI: "nvn",
            chain: "b-ffffffffffff",
            multiProgram: false
        )
        XCTAssertFalse(skipDiffChain)
        XCTAssertEqual(
            BuildSeedCache.trailerAction(status: status!, gfxAPI: "nvn", chain: "b-ffffffffffff", multiProgram: false),
            .replace
        )

        // Empty chain on NVN: must never skip
        XCTAssertFalse(BuildSeedCache.shouldSkipTrailerInjection(
            status: status!,
            gfxAPI: "nvn",
            chain: nil,
            multiProgram: false
        ))
        XCTAssertEqual(
            BuildSeedCache.trailerAction(status: status!, gfxAPI: "nvn", chain: nil, multiProgram: false),
            .replace
        )

        // Gfx API mismatch: replace
        XCTAssertFalse(BuildSeedCache.shouldSkipTrailerInjection(
            status: status!,
            gfxAPI: "gl",
            chain: "a5e7fb6e4fa4",
            multiProgram: false
        ))
        XCTAssertEqual(
            BuildSeedCache.trailerAction(status: status!, gfxAPI: "gl", chain: "a5e7fb6e4fa4", multiProgram: false),
            .replace
        )

        // No trailer: append
        let noTrailerJSON = """
        {
          "has_trailer": false,
          "version": 0,
          "gfx_api": null,
          "flags": 0,
          "multi_program": false,
          "chain": "",
          "base_romfs_size": 1000,
          "msl_offset": 0,
          "msl_size": 0,
          "file_size": 1000,
          "files": 0
        }
        """
        let noTrailerStatus = BuildSeedCache.parseTrailerStatus(from: noTrailerJSON)!
        XCTAssertFalse(BuildSeedCache.shouldSkipTrailerInjection(
            status: noTrailerStatus,
            gfxAPI: "nvn",
            chain: "a5e7fb6e4fa4",
            multiProgram: false
        ))
        XCTAssertEqual(
            BuildSeedCache.trailerAction(status: noTrailerStatus, gfxAPI: "nvn", chain: "a5e7fb6e4fa4", multiProgram: false),
            .append
        )
    }

    func testRepoLayoutSupportsBuildSeedAndExtractMsl() throws {
        let repo = tempDir.appendingPathComponent("layout-repo").path
        let scriptsDir = repo + "/scripts"
        let dmToolsDir = repo + "/dm/tools"
        try fm.createDirectory(atPath: scriptsDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: dmToolsDir, withIntermediateDirectories: true)

        let script = scriptsDir + "/build_ipa_from_nsp.py"
        let romfsTool = dmToolsDir + "/romfs_image.py"

        try "# no flags".write(toFile: script, atomically: true, encoding: .utf8)
        try "# no flags".write(toFile: romfsTool, atomically: true, encoding: .utf8)
        XCTAssertFalse(RepoLayout.supportsBuildSeed(repo))
        XCTAssertFalse(RepoLayout.supportsExtractMsl(repo))

        try "ap.add_argument('--from-seed')".write(toFile: script, atomically: true, encoding: .utf8)
        try "ap.add_argument('--extract-msl')".write(toFile: romfsTool, atomically: true, encoding: .utf8)
        XCTAssertTrue(RepoLayout.supportsBuildSeed(repo))
        XCTAssertTrue(RepoLayout.supportsExtractMsl(repo))
    }
}
