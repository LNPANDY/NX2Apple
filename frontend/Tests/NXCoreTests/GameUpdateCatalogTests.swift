import Darwin
import Foundation
import XCTest
@testable import NXCore

final class GameUpdateCatalogTests: XCTestCase {
    private var tempDir: URL!
    private let fm = FileManager.default
    private let tidSpecific150 = "0100152000022000"
    private let tidUnlisted = "0100111100001111"

    override func setUpWithError() throws {
        tempDir = fm.temporaryDirectory.appendingPathComponent("nx-catalog-tests-" + UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tempDir)
    }

    private func path(_ parts: String...) -> String {
        parts.reduce(tempDir.path) { ($0 as NSString).appendingPathComponent($1) }
    }

    private func engineRomfsTool() throws -> String {
        let toolURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("engine/" + RepoLayout.romfsImageTool)
        XCTAssertTrue(fm.fileExists(atPath: toolURL.path), "Expected synced engine romfs_image.py at \(toolURL.path)")
        return toolURL.path
    }

    private func runPython(_ tool: String, args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [tool] + args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, "Command failed: \(args) stdout=\(out) stderr=\(err)")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeMockRepo(chain: String = "a5e7fb6e4fa4") throws -> String {
        let repo = path("repo-\(UUID().uuidString)")
        let headerDir = repo + "/dm/gfx/nvn"
        try fm.createDirectory(atPath: headerDir, withIntermediateDirectories: true)
        let content = "#define DMSH_CHAIN \"\(chain)\"\n"
        try content.write(toFile: headerDir + "/dmsh_chain.h", atomically: true, encoding: .utf8)
        return repo
    }

    private func createSeed(
        seedRoot: String,
        tid: String,
        chain: String = "a5e7fb6e4fa4",
        romfsIdentity: String = "DMROMFSID1 test size=1 index=1",
        withMetalSources: Bool = false
    ) throws {
        let seedDir = BuildSeedCache.seedDirectory(for: tid, seedRoot: seedRoot)
        try fm.createDirectory(atPath: seedDir + "/ExeFS", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: seedDir + "/shader/pkg", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: seedDir + "/shader/tables", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: seedDir + "/shader/ios", withIntermediateDirectories: true)
        if withMetalSources {
            try fm.createDirectory(atPath: seedDir + "/metal-sources", withIntermediateDirectories: true)
        }
        try Data("bin".utf8).write(to: URL(fileURLWithPath: seedDir + "/ExeFS/main"))
        try Data("c1".utf8).write(to: URL(fileURLWithPath: seedDir + "/shader/tables/c1_full.tsv"))
        try Data("cb".utf8).write(to: URL(fileURLWithPath: seedDir + "/shader/tables/cb_extent.tsv"))
        try Data("msl".utf8).write(to: URL(fileURLWithPath: seedDir + "/shader/ios/b-" + chain + ".img"))

        let record = BuildSeedRecord(
            titleID: tid,
            baseTitleID: tid,
            appName: "Sample Game",
            gfxAPI: "nvn",
            chain: chain,
            romfsIdentity: romfsIdentity
        )
        let data = try JSONEncoder().encode(record)
        try data.write(to: URL(fileURLWithPath: seedDir + "/seed.json"))
    }

    func testCatalogVersionCountsDefaultsAndReleaseBaseStripping() {
        XCTAssertEqual(GameUpdateCatalog.updatedVersions.count, 48)
        let grouped = Dictionary(grouping: GameUpdateCatalog.updatedVersions.values, by: { $0 }).mapValues(\.count)
        XCTAssertEqual(grouped["1.5.0"], 18)
        XCTAssertEqual(grouped["1.4.0"], 19)
        XCTAssertEqual(grouped["1.3.0"], 8)
        XCTAssertEqual(grouped["1.2.2"], 3)

        XCTAssertEqual(GameUpdateCatalog.releaseBaseVersion(" v1.5.0-local "), "1.5.0")
        XCTAssertEqual(GameUpdateCatalog.releaseBaseVersion("1.5.0-rc2"), "1.5.0")
        XCTAssertEqual(GameUpdateCatalog.releaseBaseVersion("1.4.0"), "1.4.0")

        let unlisted = GameUpdateCatalog.hasSpecificUpdate(titleID: tidUnlisted, appVersion: "1.5.0", gitSpecificChanged: nil)
        XCTAssertFalse(unlisted.hasSpecific)
        XCTAssertEqual(unlisted.versionLabel, "1.5.0")

        let listed150 = GameUpdateCatalog.hasSpecificUpdate(titleID: tidSpecific150, appVersion: "1.5.0-local", gitSpecificChanged: nil)
        XCTAssertTrue(listed150.hasSpecific)
        XCTAssertEqual(listed150.versionLabel, "1.5.0")

        let gitOverrideTrue = GameUpdateCatalog.hasSpecificUpdate(titleID: tidUnlisted, appVersion: "1.5.0", gitSpecificChanged: true)
        XCTAssertTrue(gitOverrideTrue.hasSpecific)
        XCTAssertEqual(gitOverrideTrue.versionLabel, "1.5.0")

        let gitOverrideFalse = GameUpdateCatalog.hasSpecificUpdate(titleID: tidSpecific150, appVersion: "1.5.0", gitSpecificChanged: false)
        XCTAssertFalse(gitOverrideFalse.hasSpecific)
    }

    func testAssessFourStatesAndMissingImgGuidePosture() throws {
        let repo = try makeMockRepo(chain: "newchain0001")
        let seedRoot = path("seeds")
        let outDir = path("out")
        try fm.createDirectory(atPath: outDir + "/games", withIntermediateDirectories: true)

        let upToDate = GameUpdateCatalog.assess(
            titleID: tidSpecific150,
            isMarkedOlder: false,
            hasMacBuild: true,
            macAppPath: path("Game.app"),
            hasIOSBuild: true,
            hasReadableSourceInputs: true,
            outDir: outDir,
            gameName: "Mario Kart 8",
            appVersion: "1.5.0",
            gitSpecificChanged: nil,
            seedRoot: seedRoot,
            repoPath: repo
        )
        XCTAssertEqual(upToDate.heroState, .upToDate)

        let specificFull = GameUpdateCatalog.assess(
            titleID: tidSpecific150,
            isMarkedOlder: true,
            hasMacBuild: true,
            macAppPath: path("Missing.app"),
            hasIOSBuild: true,
            hasReadableSourceInputs: false,
            outDir: outDir,
            gameName: "Mario Kart 8",
            appVersion: "1.5.0",
            gitSpecificChanged: nil,
            seedRoot: seedRoot,
            repoPath: repo
        )
        XCTAssertEqual(specificFull.heroState, .specificFull(version: "1.5.0"))
        XCTAssertFalse(specificFull.canFastRefreshAny)
        XCTAssertFalse(specificFull.needsMissingImgGuideIOS)
        XCTAssertTrue(specificFull.missingOriginalPackage)

        try createSeed(seedRoot: seedRoot, tid: tidSpecific150, chain: "oldchain0001", withMetalSources: true)
        let pathBMissingImg = GameUpdateCatalog.assess(
            titleID: tidSpecific150,
            isMarkedOlder: true,
            hasMacBuild: false,
            macAppPath: "",
            hasIOSBuild: true,
            hasReadableSourceInputs: false,
            outDir: outDir,
            gameName: "Sample Game",
            appVersion: "1.5.0",
            gitSpecificChanged: true,
            seedRoot: seedRoot,
            repoPath: repo
        )
        XCTAssertEqual(pathBMissingImg.heroState, .specificFull(version: "1.5.0"))
        XCTAssertFalse(pathBMissingImg.canFastRefreshIOS)
        XCTAssertTrue(pathBMissingImg.needsMissingImgGuideIOS)
        XCTAssertTrue(pathBMissingImg.missingOriginalPackage)

        let localImg = outDir + "/games/Sample Game/Sample Game.img"
        try fm.createDirectory(atPath: (localImg as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("stub".utf8).write(to: URL(fileURLWithPath: localImg))
        let pathBFast = GameUpdateCatalog.assess(
            titleID: tidSpecific150,
            isMarkedOlder: true,
            hasMacBuild: false,
            macAppPath: "",
            hasIOSBuild: true,
            hasReadableSourceInputs: false,
            outDir: outDir,
            gameName: "Sample Game",
            appVersion: "1.5.0",
            gitSpecificChanged: nil,
            seedRoot: seedRoot,
            repoPath: repo
        )
        XCTAssertEqual(pathBFast.heroState, .specificFast(version: "1.5.0"))
        XCTAssertTrue(pathBFast.canFastRefreshIOS)
        XCTAssertFalse(pathBFast.needsMissingImgGuideIOS)
        XCTAssertFalse(pathBFast.missingOriginalPackage)

        let generalFast = GameUpdateCatalog.assess(
            titleID: tidUnlisted,
            isMarkedOlder: true,
            hasMacBuild: true,
            macAppPath: "",
            hasIOSBuild: false,
            hasReadableSourceInputs: true,
            outDir: outDir,
            gameName: "Sample Game",
            appVersion: "1.5.0",
            gitSpecificChanged: false,
            seedRoot: path("seeds-a"),
            repoPath: repo
        )
        XCTAssertEqual(generalFast.heroState, .generalSync(fast: false))

        try createSeed(seedRoot: seedRoot, tid: tidUnlisted, chain: "newchain0001")
        let generalPathA = GameUpdateCatalog.assess(
            titleID: tidUnlisted,
            isMarkedOlder: true,
            hasMacBuild: false,
            macAppPath: "",
            hasIOSBuild: true,
            hasReadableSourceInputs: false,
            outDir: outDir,
            gameName: "Unlisted",
            appVersion: "1.5.0",
            gitSpecificChanged: false,
            seedRoot: seedRoot,
            repoPath: repo
        )
        XCTAssertEqual(generalPathA.heroState, .generalSync(fast: true))
        XCTAssertTrue(generalPathA.canFastRefreshIOS)
        XCTAssertFalse(generalPathA.needsMissingImgGuideIOS)
    }

    func testRomfsIdentityMatchesRealEngineToolWithAndWithoutTrailerAndRejectsCorruptOrOverflowInputs() throws {
        let tool = try engineRomfsTool()
        let srcDir = path("romfs-src")
        try fm.createDirectory(atPath: srcDir + "/sub", withIntermediateDirectories: true)
        try Data("hello switch world\n".utf8).write(to: URL(fileURLWithPath: srcDir + "/boot.txt"))
        try Data(repeating: 0x5A, count: 129).write(to: URL(fileURLWithPath: srcDir + "/sub/blob.bin"))

        let imgPath = path("game.img")
        _ = try runPython(tool, args: [srcDir, imgPath])
        let baseIdentityLine = try runPython(tool, args: ["--identity", imgPath, tidSpecific150, "1.0.0", "deadbeef"])

        let parsed = try XCTUnwrap(RomfsImageIdentity.parseIdentityLine(baseIdentityLine))
        XCTAssertEqual(parsed.title, tidSpecific150)

        let swiftBaseDigest = try XCTUnwrap(RomfsImageIdentity.computeIdentity(of: imgPath))
        XCTAssertEqual(swiftBaseDigest.size, parsed.size)
        XCTAssertEqual(swiftBaseDigest.index, parsed.index)
        XCTAssertTrue(RomfsImageIdentity.matches(imagePath: imgPath, expectedIdentityLine: baseIdentityLine))

        let mslDir = path("msl-src")
        try fm.createDirectory(atPath: mslDir, withIntermediateDirectories: true)
        try Data("metal shader payload".utf8).write(to: URL(fileURLWithPath: mslDir + "/shader.metallib"))
        _ = try runPython(
            tool,
            args: ["--append-msl", "--gfx-api", "nvn", "--chain", "b-a5e7fb6e4fa4", imgPath, mslDir]
        )

        let trailerIdentityLine = try runPython(tool, args: ["--identity", imgPath, tidSpecific150])
        XCTAssertTrue(RomfsImageIdentity.matches(imagePath: imgPath, expectedIdentityLine: baseIdentityLine))
        XCTAssertTrue(RomfsImageIdentity.matches(imagePath: imgPath, expectedIdentityLine: trailerIdentityLine))

        // Corrupt trailing footer byte must cause matches/computeIdentity to fail cleanly without permanent failure caching
        let originalData = try Data(contentsOf: URL(fileURLWithPath: imgPath))
        var corruptTrailer = originalData
        corruptTrailer[corruptTrailer.count - 1] = 0xFF
        try corruptTrailer.write(to: URL(fileURLWithPath: imgPath))
        XCTAssertNil(RomfsImageIdentity.computeIdentity(of: imgPath))
        XCTAssertFalse(RomfsImageIdentity.matches(imagePath: imgPath, expectedIdentityLine: baseIdentityLine))

        // Restoring valid bytes + different size/mtime must recover cleanly
        try originalData.write(to: URL(fileURLWithPath: imgPath))
        XCTAssertTrue(RomfsImageIdentity.matches(imagePath: imgPath, expectedIdentityLine: baseIdentityLine))

        // Truncated header, symlink rejection, and overflow bounds
        let truncated = path("trunc.img")
        try Data("DMROMFS1short".utf8).write(to: URL(fileURLWithPath: truncated))
        XCTAssertNil(RomfsImageIdentity.computeIdentity(of: truncated))

        let overflowImg = path("overflow.img")
        var overflowData = Data("DMROMFS1".utf8)
        let maxU64: UInt64 = UInt64.max
        let sixteen: UInt64 = 16
        overflowData.append(contentsOf: withUnsafeBytes(of: maxU64.littleEndian, Array.init))
        overflowData.append(contentsOf: withUnsafeBytes(of: sixteen.littleEndian, Array.init))
        overflowData.append(contentsOf: withUnsafeBytes(of: UInt64(1).littleEndian, Array.init))
        try overflowData.write(to: URL(fileURLWithPath: overflowImg))
        XCTAssertNil(RomfsImageIdentity.computeIdentity(of: overflowImg))

        let linkImg = path("link.img")
        try fm.createSymbolicLink(atPath: linkImg, withDestinationPath: imgPath)
        XCTAssertNil(RomfsImageIdentity.computeIdentity(of: linkImg))

        XCTAssertNil(RomfsImageIdentity.parseIdentityLine("DMROMFSID1 title=x size= index=1"))
        XCTAssertNil(RomfsImageIdentity.parseIdentityLine("DMROMFSID1 size=10"))
    }

    func testIdentityCacheInvalidatesWhenIndexMutatesInPlaceAtDifferentSizeOrMtime() throws {
        let tool = try engineRomfsTool()
        let srcA = path("src-a")
        let srcB = path("src-b")
        try fm.createDirectory(atPath: srcA, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: srcB, withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: URL(fileURLWithPath: srcA + "/a.bin"))
        try Data("bravo-longer-file".utf8).write(to: URL(fileURLWithPath: srcB + "/b.bin"))

        let targetImg = path("mutated.img")
        let imgB = path("other.img")
        _ = try runPython(tool, args: [srcA, targetImg])
        _ = try runPython(tool, args: [srcB, imgB])

        let first = try XCTUnwrap(RomfsImageIdentity.computeIdentity(of: targetImg))
        try fm.removeItem(atPath: targetImg)
        try fm.copyItem(atPath: imgB, toPath: targetImg)
        let second = try XCTUnwrap(RomfsImageIdentity.computeIdentity(of: targetImg))
        XCTAssertNotEqual(first.index, second.index)
    }

    func testExternalDriveScanCompletesDepth1WithoutDepth0EarlyExitAndPrefersDepth0OnTie() throws {
        let tool = try engineRomfsTool()
        let srcMatch = path("scan-src-match")
        let srcOther = path("scan-src-other")
        try fm.createDirectory(atPath: srcMatch, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: srcOther, withIntermediateDirectories: true)
        try Data("match-payload".utf8).write(to: URL(fileURLWithPath: srcMatch + "/m.dat"))
        try Data("other-payload-123".utf8).write(to: URL(fileURLWithPath: srcOther + "/o.dat"))

        let drive = path("usb-drive")
        let depth1Dir = drive + "/Mario Kart (\(tidSpecific150))"
        try fm.createDirectory(atPath: depth1Dir, withIntermediateDirectories: true)

        let staleDepth0 = drive + "/stale.img"
        let validDepth1 = depth1Dir + "/Mario Kart.img"
        _ = try runPython(tool, args: [srcOther, staleDepth0])
        _ = try runPython(tool, args: [srcMatch, validDepth1])
        let expectedLine = try runPython(tool, args: ["--identity", validDepth1, tidSpecific150])

        let foundDepth1 = RomfsImageIdentity.scanExternalDriveForMatchingImage(
            driveFolder: drive,
            titleID: tidSpecific150,
            expectedIdentity: expectedLine
        )
        XCTAssertEqual(foundDepth1, validDepth1)

        // When both depth 0 and depth 1 contain matching images, depth 0 wins over depth 1 even if depth 1 is newer
        let validDepth0 = drive + "/\(tidSpecific150).img"
        try fm.copyItem(atPath: validDepth1, toPath: validDepth0)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: validDepth0)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)], ofItemAtPath: validDepth1)

        let preferredDepth0 = RomfsImageIdentity.scanExternalDriveForMatchingImage(
            driveFolder: drive,
            titleID: tidSpecific150,
            expectedIdentity: expectedLine
        )
        XCTAssertEqual(preferredDepth0, validDepth0)
    }

    func testDeviceImgPullerSuccessDirectoryNestedAndFailureCleanup() throws {
        let tool = try engineRomfsTool()
        let srcDir = path("pull-src")
        try fm.createDirectory(atPath: srcDir, withIntermediateDirectories: true)
        try Data("romfs-pull-data".utf8).write(to: URL(fileURLWithPath: srcDir + "/data.bin"))
        let masterImg = path("master.img")
        _ = try runPython(tool, args: [srcDir, masterImg])
        let expectedLine = try runPython(tool, args: ["--identity", masterImg, tidSpecific150])

        // 1. Direct file copy success
        let outA = path("pull-out-a")
        let pullerA = DeviceImgPuller(control: DeviceControl { args in
            if args.starts(with: ["device", "info", "files"]),
               let idx = args.firstIndex(of: "--json-output") {
                let jsonObj: [String: Any] = [
                    "result": [
                        "files": [
                            [
                                "relativePath": "Mario Kart 8.img",
                                "metadata": ["size": 128],
                                "resources": ["isDirectory": false],
                            ]
                        ]
                    ]
                ]
                if let data = try? JSONSerialization.data(withJSONObject: jsonObj) {
                    try? data.write(to: URL(fileURLWithPath: args[idx + 1]))
                }
                return (true, "")
            }
            if args.starts(with: ["device", "copy", "from"]),
               let idx = args.firstIndex(of: "--destination") {
                try? FileManager.default.copyItem(atPath: masterImg, toPath: args[idx + 1])
                return (true, "100%")
            }
            return (false, "unexpected")
        })

        let resA = pullerA.pullImage(
            device: "UDID-1",
            titleID: tidSpecific150,
            gameName: "Mario Kart 8",
            outDir: outA,
            expectedIdentity: expectedLine
        )
        switch resA {
        case .success(let committed):
            XCTAssertTrue(fm.fileExists(atPath: committed))
            XCTAssertTrue(fm.fileExists(atPath: committed + ".id"))
            XCTAssertEqual(
                try? String(contentsOfFile: (committed as NSString).deletingLastPathComponent + "/.titleid", encoding: .utf8),
                tidSpecific150 + "\n"
            )
        case .failure(let err):
            XCTFail("Unexpected pull failure: \(err)")
        }

        // 2. Directory-wrapped devicectl copy success
        let outB = path("pull-out-b")
        let pullerB = DeviceImgPuller(control: DeviceControl { args in
            if args.starts(with: ["device", "info", "files"]),
               let idx = args.firstIndex(of: "--json-output") {
                let jsonObj: [String: Any] = [
                    "result": [
                        "files": [
                            ["relativePath": "romfs.img", "metadata": ["size": 128], "resources": ["isDirectory": false]]
                        ]
                    ]
                ]
                if let data = try? JSONSerialization.data(withJSONObject: jsonObj) {
                    try? data.write(to: URL(fileURLWithPath: args[idx + 1]))
                }
                return (true, "")
            }
            if args.starts(with: ["device", "copy", "from"]),
               let idx = args.firstIndex(of: "--destination") {
                let destDir = args[idx + 1]
                try? FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)
                try? FileManager.default.copyItem(atPath: masterImg, toPath: destDir + "/romfs.img")
                return (true, "100%")
            }
            return (false, "unexpected")
        })
        if case .failure(let err) = pullerB.pullImage(
            device: "UDID-1",
            titleID: tidSpecific150,
            gameName: "Mario Kart 8",
            outDir: outB,
            expectedIdentity: expectedLine
        ) {
            XCTFail("Directory-wrapped pull should succeed: \(err)")
        }

        // 3. Corrupt pulled image cleans up `.pull.tmp` and fails with .invalidPulledImage
        let outC = path("pull-out-c")
        let pullerC = DeviceImgPuller(control: DeviceControl { args in
            if args.starts(with: ["device", "info", "files"]),
               let idx = args.firstIndex(of: "--json-output") {
                let jsonObj: [String: Any] = [
                    "result": ["files": [["relativePath": "romfs.img", "metadata": ["size": 8], "resources": ["isDirectory": false]]]]
                ]
                if let data = try? JSONSerialization.data(withJSONObject: jsonObj) {
                    try? data.write(to: URL(fileURLWithPath: args[idx + 1]))
                }
                return (true, "")
            }
            if args.starts(with: ["device", "copy", "from"]),
               let idx = args.firstIndex(of: "--destination") {
                try? Data("corrupt".utf8).write(to: URL(fileURLWithPath: args[idx + 1]))
                return (true, "")
            }
            return (false, "copy failed")
        })
        let resC = pullerC.pullImage(
            device: "UDID-1",
            titleID: tidSpecific150,
            gameName: "Mario Kart 8",
            outDir: outC,
            expectedIdentity: expectedLine
        )
        XCTAssertEqual(resC, .failure(.invalidPulledImage))
        let remaining = (try? fm.contentsOfDirectory(atPath: outC + "/games/Mario Kart 8")) ?? []
        XCTAssertFalse(remaining.contains { $0.contains(".pull.tmp") || $0.hasSuffix(".img") })
    }
}
