import XCTest
@testable import NXCore

final class MacNativeGamesBuilderTests: XCTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("mng-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    private func makeFakeMNGTree() throws -> String {
        let root = temporary.appendingPathComponent("mng")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("games/totk"), withIntermediateDirectories: true)
        try Data("#!/usr/bin/env python3\n".utf8).write(to: root.appendingPathComponent("build_app.py"))
        return root.path
    }

    func testIsUsableTree() throws {
        XCTAssertFalse(MacNativeGamesBuilder.isUsableTree(""))
        let validTree = try makeFakeMNGTree()
        XCTAssertTrue(MacNativeGamesBuilder.isUsableTree(validTree))

        let incompleteTree = temporary.appendingPathComponent("incomplete")
        try FileManager.default.createDirectory(at: incompleteTree, withIntermediateDirectories: true)
        try Data("#!/usr/bin/env python3\n".utf8).write(to: incompleteTree.appendingPathComponent("build_app.py"))
        XCTAssertFalse(MacNativeGamesBuilder.isUsableTree(incompleteTree.path))
    }

    func testRouteAndSupportsTitleIDStrictlyEnforceTwelveSupportedGames() throws {
        let tree = try makeFakeMNGTree()

        XCTAssertFalse(MacNativeGamesBuilder.supportsTitleID(nil))
        XCTAssertFalse(MacNativeGamesBuilder.supportsTitleID(""))
        XCTAssertFalse(MacNativeGamesBuilder.supportsTitleID("   "))
        XCTAssertNil(MacNativeGamesBuilder.route(forTitleID: nil, in: tree))
        XCTAssertNil(MacNativeGamesBuilder.route(forTitleID: "", in: tree))

        let unifiedFive = [
            "0100F2C0115B6000",
            "01007EF00011E000",
            "0400486024DEC000",
            "040074A01BF12000",
            "0400A3A01EE4C000",
        ]
        let perGameSeven: [(String, MacNativeGamesBuilder.PerGamePort)] = [
            ("010093801237C000", .dread),
            ("01002DA013484000", .ss),
            ("010048900CF64000", .worldend),
            ("0100FE701475A000", .tmnt),
            ("01006F8002326000", .acnh),
            ("01008CF01BAAC000", .eow),
            ("0100000000010000", .odyssey),
        ]
        let allTwelve = Set(unifiedFive + perGameSeven.map(\.0))
        XCTAssertEqual(MacNativeGamesBuilder.supportedTitleIDs.count, 12)
        XCTAssertEqual(MacNativeGamesBuilder.supportedTitleIDs, allTwelve)

        for tid in unifiedFive {
            XCTAssertTrue(MacNativeGamesBuilder.supportsTitleID(tid.lowercased()), "\(tid) lowercase should be supported")
            XCTAssertEqual(
                MacNativeGamesBuilder.route(forTitleID: tid, in: tree),
                .unifiedBuildApp,
                "\(tid) should route to unifiedBuildApp"
            )
        }
        for (tid, port) in perGameSeven {
            XCTAssertTrue(MacNativeGamesBuilder.supportsTitleID(tid.lowercased()), "\(tid) lowercase should be supported")
            XCTAssertEqual(
                MacNativeGamesBuilder.route(forTitleID: tid, in: tree),
                .perGameScript(port),
                "\(tid) should route to perGameScript(\(port.rawValue))"
            )
            XCTAssertEqual(
                MacNativeGamesBuilder.scriptPath(for: .perGameScript(port), in: tree),
                "\(tree)/games/\(port.rawValue)/build.py"
            )
        }

        // Titles outside the 12 official MNG ports must remain blocked.
        for blocked in ["0100152000022000", "010015100B514000", "01006A800016E000", "040077201BE50000"] {
            XCTAssertFalse(MacNativeGamesBuilder.supportsTitleID(blocked))
            XCTAssertNil(MacNativeGamesBuilder.route(forTitleID: blocked, in: tree))
        }

        // Dynamic games/*/game.json entries must NOT bypass the 12-title allowlist.
        let customDir = URL(fileURLWithPath: tree).appendingPathComponent("games/custom")
        try FileManager.default.createDirectory(at: customDir, withIntermediateDirectories: true)
        let gameJSON = """
        {
            "title_id": "0100ABC001234000",
            "build": "games/custom/build.py",
            "files": {
                "update": ["update.nsp"]
            }
        }
        """
        try Data(gameJSON.utf8).write(to: customDir.appendingPathComponent("game.json"))
        let scriptContent = "#!/usr/bin/env python3\n# parser.add_argument('--platform')\n"
        try Data(scriptContent.utf8).write(to: customDir.appendingPathComponent("build.py"))

        XCTAssertFalse(MacNativeGamesBuilder.supportsTitleID("0100ABC001234000"))
        XCTAssertNil(MacNativeGamesBuilder.route(forTitleID: "0100ABC001234000", in: tree))
    }

    func testPerGameScriptArgumentsStrictlyMatchUpstreamArgparseContracts() {
        for port in MacNativeGamesBuilder.PerGamePort.allCases {
            let args = MacNativeGamesBuilder.arguments(
                route: .perGameScript(port),
                tree: "/opt/mng",
                gameInput: "/games/base.nsp",
                keysPath: "/keys/prod.keys",
                isUnencryptedInput: false,
                updatePath: "/games/update.nsp",
                dlcPaths: ["/games/dlc1.nsp", "/games/dlc2.nsp"],
                outputAppPath: "/out/Game.app",
                workDir: "/work",
                sharedFontsPath: "/fonts/shared"
            )
            XCTAssertEqual(args.first, "/opt/mng/games/\(port.rawValue)/build.py")
            XCTAssertFalse(args.contains("--platform"), "\(port.rawValue) must never pass --platform")
            XCTAssertTrue(args.contains("-k"))
            XCTAssertTrue(args.contains("--work"))
            XCTAssertTrue(args.contains("-o"))
            XCTAssertEqual(args.contains("--update"), port.supportsUpdate, "\(port.rawValue) --update mismatch")
            XCTAssertEqual(args.contains("--dlc"), port.supportsDLC, "\(port.rawValue) --dlc mismatch")
            XCTAssertEqual(args.contains("--shared-fonts"), port.supportsSharedFonts, "\(port.rawValue) --shared-fonts mismatch")
            if port == .acnh {
                XCTAssertEqual(args.filter { $0 == "--dlc" }.count, 2)
            }
        }
    }

    func testNeedsPreDecompressAndManagedUVPythonDetection() {
        XCTAssertFalse(MacNativeGamesBuilder.needsPreDecompress(route: .unifiedBuildApp, path: "/roms/totk.nsz"))
        XCTAssertTrue(MacNativeGamesBuilder.needsPreDecompress(route: .unifiedBuildApp, path: "/roms/totk.xcz"))
        XCTAssertTrue(MacNativeGamesBuilder.needsPreDecompress(route: .perGameScript(.dread), path: "/roms/dread.nsz"))
        XCTAssertTrue(MacNativeGamesBuilder.needsPreDecompress(route: .perGameScript(.odyssey), path: "/roms/odyssey.XCZ"))
        XCTAssertFalse(MacNativeGamesBuilder.needsPreDecompress(route: .perGameScript(.dread), path: "/roms/dread.nsp"))

        let uvPy = "/Users/tester/Library/Application Support/NX2Apple/tools/uv-python/cpython-3.14.0/bin/python3.14"
        XCTAssertTrue(MacNativeGamesBuilder.isManagedUVPython(uvPy, home: "/Users/tester"))
        XCTAssertTrue(MacNativeGamesBuilder.isManagedUVPython(uvPy, home: "/Users/other"))
        XCTAssertFalse(MacNativeGamesBuilder.isManagedUVPython("/opt/homebrew/bin/python3.13", home: "/Users/tester"))
    }

    func testScriptPath() {
        XCTAssertEqual(
            MacNativeGamesBuilder.scriptPath(for: .unifiedBuildApp, in: "/opt/mng"),
            "/opt/mng/build_app.py"
        )
        XCTAssertEqual(
            MacNativeGamesBuilder.scriptPath(for: .unifiedBuildApp, in: "/opt/mng/"),
            "/opt/mng/build_app.py"
        )
    }

    func testArguments() {
        let encryptedArgs = MacNativeGamesBuilder.arguments(
            route: .unifiedBuildApp,
            tree: "/opt/mng",
            gameInput: "/games/totk.xci",
            keysPath: "/keys/prod.keys",
            isUnencryptedInput: false,
            updatePath: "/games/update.nsp",
            dlcPaths: ["/games/dlc1.nsp", "/games/dlc2.nsp"],
            outputAppPath: "/out/TOTK.app",
            workDir: "/work"
        )
        let expectedEncrypted = [
            "/opt/mng/build_app.py",
            "/games/totk.xci",
            "-k", "/keys/prod.keys",
            "--platform", "macos",
            "-o", "/out/TOTK.app",
            "--work", "/work",
            "--update", "/games/update.nsp",
            "--dlc", "/games/dlc1.nsp",
            "--dlc", "/games/dlc2.nsp"
        ]
        XCTAssertEqual(encryptedArgs, expectedEncrypted)

        let unencryptedArgs = MacNativeGamesBuilder.arguments(
            route: .unifiedBuildApp,
            tree: "/opt/mng",
            gameInput: "/games/totk.nup",
            keysPath: "/keys/prod.keys",
            isUnencryptedInput: true,
            updatePath: "",
            dlcPaths: [],
            outputAppPath: "/out/TOTK.app",
            workDir: "/work"
        )
        XCTAssertFalse(unencryptedArgs.contains("-k"))
        XCTAssertFalse(unencryptedArgs.contains("--update"))
        XCTAssertFalse(unencryptedArgs.contains("--dlc"))
    }

    func testArgumentsOmitEmbeddedAddonsForUnencryptedAndContainedInputs() {
        let nupPath = "/games/Ocarina [0400486024DEC000][v131072].nup"
        let nupArgs = MacNativeGamesBuilder.arguments(
            route: .unifiedBuildApp,
            tree: "/opt/mng",
            gameInput: nupPath,
            keysPath: "/keys/prod.keys",
            isUnencryptedInput: true,
            updatePath: nupPath,
            dlcPaths: [nupPath],
            outputAppPath: "/out/OOT.app",
            workDir: "/work"
        )
        XCTAssertEqual(nupArgs, ["/opt/mng/build_app.py", nupPath, "--platform", "macos", "-o", "/out/OOT.app", "--work", "/work"])

        let dumpArgs = MacNativeGamesBuilder.arguments(
            route: .unifiedBuildApp,
            tree: "/opt/mng",
            gameInput: "/games/oot_dump",
            keysPath: "/keys/prod.keys",
            isUnencryptedInput: true,
            updatePath: "/games/oot_dump/updates/131072",
            dlcPaths: ["/games/oot_dump/dlc/0400486024DED001"],
            outputAppPath: "/out/OOT.app",
            workDir: "/work"
        )
        XCTAssertFalse(dumpArgs.contains("-k"))
        XCTAssertFalse(dumpArgs.contains("--update"))
        XCTAssertFalse(dumpArgs.contains("--dlc"))

        // Even if a caller leaves isUnencryptedInput false, a .nup or contained/same addon path must not be emitted.
        let containedAddonArgs = MacNativeGamesBuilder.arguments(
            route: .unifiedBuildApp,
            tree: "/opt/mng",
            gameInput: "/games/oot_dump/",
            keysPath: "/keys/prod.keys",
            isUnencryptedInput: false,
            updatePath: "/games/oot_dump/updates/131072",
            dlcPaths: ["/games/oot_dump/dlc/0400486024DED001", "/games/oot_dump_extra/dlc.nsp"],
            outputAppPath: "/out/OOT.app",
            workDir: "/work"
        )
        XCTAssertFalse(containedAddonArgs.contains("--update"))
        XCTAssertEqual(containedAddonArgs.filter { $0 == "--dlc" }.count, 1)
        XCTAssertTrue(containedAddonArgs.contains("/games/oot_dump_extra/dlc.nsp"))
        XCTAssertFalse(containedAddonArgs.contains("/games/oot_dump/dlc/0400486024DED001"))
    }

    func testEnvironment() {
        let env = MacNativeGamesBuilder.environment(languageCode: "zh-Hans")
        XCTAssertEqual(env["MNG_LANG"], "zh-Hans")
        XCTAssertEqual(env["PYTHONUNBUFFERED"], "1")
    }

    func testLastError() {
        let logWithError = "step 1\nERROR: shader compilation failed\ncleaning up\n"
        XCTAssertEqual(MacNativeGamesBuilder.lastError(in: logWithError), "ERROR: shader compilation failed")

        let logWithBuildError = "step 1\nBuildError: missing asset file\ndone\n"
        XCTAssertEqual(MacNativeGamesBuilder.lastError(in: logWithBuildError), "BuildError: missing asset file")

        let logNormal = "step 1\nfinished step 2\n"
        XCTAssertEqual(MacNativeGamesBuilder.lastError(in: logNormal), "finished step 2")
    }

    func testEngineUpstreamBundleTitleIDsAndMacGameBundleRecognitionForAllTwelve() throws {
        let ids = EngineUpstream.macNativeGamesBundleTitleIDs
        let expected: [String: String] = [
            "org.macnativegames.totk": "0100F2C0115B6000",
            "org.macnativegames.totk-native": "0100F2C0115B6000",
            "org.macnativegames.botw": "01007EF00011E000",
            "org.macnativegames.oot": "0400486024DEC000",
            "org.macnativegames.oot-native": "0400486024DEC000",
            "org.macnativegames.bananza": "040074A01BF12000",
            "org.macnativegames.pokopia": "0400A3A01EE4C000",
            "org.macnativegames.pkp": "0400A3A01EE4C000",
            "org.macnativegames.dread": "010093801237C000",
            "org.macnativegames.ss": "01002DA013484000",
            "org.macnativegames.worldend": "010048900CF64000",
            "org.macnativegames.tmnt.private": "0100FE701475A000",
            "org.macnativegames.acnh": "01006F8002326000",
            "org.macnativegames.eow": "01008CF01BAAC000",
            "org.macnativegames.odyssey": "0100000000010000",
        ]
        for (bundleID, tid) in expected {
            XCTAssertEqual(ids[bundleID], tid, "Missing bundle mapping for \(bundleID)")
        }

        // Verify MacGameBundle.read recognizes native MNG bundles without DMUpstream/DMTitleID keys.
        for (bundleID, tid) in [
            ("org.macnativegames.tmnt.private", "0100FE701475A000"),
            ("org.macnativegames.dread", "010093801237C000"),
            ("org.macnativegames.acnh", "01006F8002326000"),
            ("org.macnativegames.eow", "01008CF01BAAC000"),
            ("org.macnativegames.odyssey", "0100000000010000"),
        ] {
            let appURL = temporary.appendingPathComponent("\(bundleID).app")
            try FileManager.default.createDirectory(at: appURL.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            let exeURL = appURL.appendingPathComponent("Contents/MacOS/game")
            try Data("#!/bin/sh\n".utf8).write(to: exeURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exeURL.path)
            let plist: [String: Any] = [
                "CFBundleIdentifier": bundleID,
                "CFBundleExecutable": "game",
                "CFBundlePackageType": "APPL",
                "CFBundleName": "Game"
            ]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: appURL.appendingPathComponent("Contents/Info.plist"))
            let bundle = try MacGameBundle.read(appURL)
            XCTAssertEqual(bundle.upstream, .macNativeGames, bundleID)
            XCTAssertEqual(bundle.titleID, tid, bundleID)
        }
    }

    func testPackageHeaderTitleIDReadsEncryptedPFS0AndToolchainNszClassification() throws {
        // Build a synthetic encrypted PFS0 with a meta NCA header carrying 0100F2C0115B6000.
        let headerKey = [UInt8](0..<32)
        let keysHex = headerKey.map { String(format: "%02x", $0) }.joined()
        let keysURL = temporary.appendingPathComponent("prod.keys")
        try "header_key = \(keysHex)\n".write(to: keysURL, atomically: true, encoding: .utf8)

        var plainHeader = [UInt8](repeating: 0, count: 0x400)
        plainHeader.replaceSubrange(0x200..<0x204, with: Array("NCA3".utf8))
        plainHeader[0x205] = 1 // meta NCA
        let tid: UInt64 = 0x0100_F2C0_115B_6000
        for i in 0..<8 {
            plainHeader[0x210 + i] = UInt8((tid >> (8 * UInt64(i))) & 0xFF)
        }
        let encHeader = try XCTUnwrap(PackageHeaderTitleID.aesXTS(plainHeader, key: headerKey, encrypt: true))
        let ncaName = Array("meta.cnmt.nca\0".utf8)
        var pfs0 = Array("PFS0".utf8)
        func appendLE32(_ v: UInt32) { pfs0 += (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        func appendLE64(_ v: UInt64) { pfs0 += (0..<8).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        appendLE32(1)
        appendLE32(UInt32(ncaName.count))
        appendLE32(0)
        appendLE64(0)
        appendLE64(UInt64(encHeader.count))
        appendLE32(0)
        appendLE32(0)
        pfs0 += ncaName
        pfs0 += encHeader

        let renamedNSP = temporary.appendingPathComponent("RenamedGame.nsp")
        try Data(pfs0).write(to: renamedNSP)
        XCTAssertEqual(PackageHeaderTitleID.readHex16(path: renamedNSP.path, keysPath: keysURL.path), "0100F2C0115B6000")
        XCTAssertNil(PackageHeaderTitleID.readHex16(path: renamedNSP.path, keysPath: ""))

        // Verify PEP 668 / permission / network classification and EXTERNALLY-MANAGED marker detection.
        XCTAssertEqual(Toolchain.classifyNszInstallFailure("error: externally-managed-environment\nPEP 668"), .pep668)
        XCTAssertEqual(Toolchain.classifyNszInstallFailure("PermissionError: [Errno 13] Permission denied"), .permissionDenied)
        XCTAssertEqual(Toolchain.classifyNszInstallFailure("Temporary failure in name resolution"), .network)

        let fakeBrew = temporary.appendingPathComponent("brew-py")
        try FileManager.default.createDirectory(at: fakeBrew.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeBrew.appendingPathComponent("lib/python3.13"), withIntermediateDirectories: true)
        let brewPy = fakeBrew.appendingPathComponent("bin/python3.13")
        try Data("#!/bin/sh\n".utf8).write(to: brewPy)
        try Data().write(to: fakeBrew.appendingPathComponent("lib/python3.13/EXTERNALLY-MANAGED"))
        XCTAssertTrue(Toolchain.isExternallyManagedPython(brewPy.path, home: temporary.path))

        let managedVenvDir = Toolchain.nszVenvDir(home: temporary.path)
        try FileManager.default.createDirectory(atPath: managedVenvDir + "/bin", withIntermediateDirectories: true)
        let managedPy = managedVenvDir + "/bin/python3"
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: managedPy))
        XCTAssertFalse(Toolchain.isExternallyManagedPython(managedPy, home: temporary.path))
    }

    func testFindMNGPython314StrictlyMatches314AndInstallCommandIsRootless() {
        let runner = FakeProcessRunner()
        runner.answer = { launch in
            switch launch.executable {
            case "/fake/python3.13": return ProcessResult(status: 0, out: "3.13\n")
            case "/fake/python3.15": return ProcessResult(status: 0, out: "3.15\n")
            case "/fake/python3.14": return ProcessResult(status: 0, out: "3.14\n")
            default: return ProcessResult(status: 1, out: "")
            }
        }
        let found = MacNativeGamesBuilder.findMNGPython314(
            candidates: ["/fake/python3.13", "/fake/python3.15", "/fake/python3.14"],
            runner: runner,
            exists: { _ in true }
        )
        XCTAssertEqual(found, "/fake/python3.14")

        let none = MacNativeGamesBuilder.findMNGPython314(
            candidates: ["/fake/python3.13", "/fake/python3.15"],
            runner: runner,
            exists: { _ in true }
        )
        XCTAssertNil(none)

        let cmd = MacNativeGamesBuilder.python314InstallCommand(home: "/Users/tester")
        XCTAssertEqual(cmd.first, "/bin/bash")
        let script = cmd.last ?? ""
        XCTAssertTrue(script.contains("UV_UNMANAGED_INSTALL=\"/Users/tester/Library/Application Support/NX2Apple/tools/uv\""))
        XCTAssertTrue(script.contains("python install 3.14 --install-dir \"/Users/tester/Library/Application Support/NX2Apple/tools/uv-python\""))
    }

    func testSharedFontsDetectionParsingAndArguments() throws {
        let workDir = temporary.appendingPathComponent("totk-work", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        XCTAssertTrue(MacNativeGamesBuilder.needsAutoSharedFonts(
            route: .unifiedBuildApp,
            gameInput: "/roms/totk.nsp",
            isUnencryptedInput: false,
            workDir: workDir.path
        ))
        XCTAssertTrue(MacNativeGamesBuilder.needsAutoSharedFonts(
            route: .unifiedBuildApp,
            gameInput: "/roms/totk.nsz",
            isUnencryptedInput: false,
            workDir: workDir.path
        ))
        XCTAssertFalse(MacNativeGamesBuilder.needsAutoSharedFonts(
            route: .unifiedBuildApp,
            titleID: "0100F2C0115B6000",
            gameInput: "/roms/totk.xci",
            isUnencryptedInput: false,
            workDir: workDir.path
        ))
        // BOTW cartridges lack a system update partition, so .xci/.xcz must auto-generate shared fonts.
        XCTAssertTrue(MacNativeGamesBuilder.needsAutoSharedFonts(
            route: .unifiedBuildApp,
            titleID: "01007EF00011E000",
            gameInput: "/roms/botw.xci",
            isUnencryptedInput: false,
            workDir: workDir.path
        ))
        XCTAssertTrue(MacNativeGamesBuilder.needsAutoSharedFonts(
            route: .unifiedBuildApp,
            titleID: "01007EF00011E000",
            gameInput: "/roms/botw.xcz",
            isUnencryptedInput: false,
            workDir: workDir.path
        ))
        XCTAssertFalse(MacNativeGamesBuilder.needsAutoSharedFonts(
            route: .unifiedBuildApp,
            titleID: "01007EF00011E000",
            gameInput: "/roms/botw.nup",
            isUnencryptedInput: true,
            workDir: workDir.path
        ))

        let manifestDir = workDir.appendingPathComponent("totk/extracted/firmware/shared-fonts", isDirectory: true)
        try FileManager.default.createDirectory(at: manifestDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: manifestDir.appendingPathComponent("manifest.json"))
        XCTAssertFalse(MacNativeGamesBuilder.needsAutoSharedFonts(
            route: .unifiedBuildApp,
            gameInput: "/roms/totk.nsp",
            isUnencryptedInput: false,
            workDir: workDir.path
        ))

        let noisyStdout = """
        [mng] downloading NotoSans font pack...
        [mng] generated 6 shared fonts
        NX2APPLE_OPEN_FONTS=/tmp/open-fonts/shared-fonts
        """
        XCTAssertEqual(MacNativeGamesBuilder.parseOpenFontsOutput(noisyStdout), "/tmp/open-fonts/shared-fonts")
        XCTAssertNil(MacNativeGamesBuilder.parseOpenFontsOutput("just log output without marker\n"))

        let argsWithFonts = MacNativeGamesBuilder.arguments(
            route: .unifiedBuildApp,
            tree: "/opt/mng",
            gameInput: "/games/totk.nsp",
            keysPath: "/keys/prod.keys",
            isUnencryptedInput: false,
            updatePath: "",
            dlcPaths: [],
            outputAppPath: "/out/TOTK.app",
            workDir: "/work",
            sharedFontsPath: "/tmp/open-fonts/shared-fonts"
        )
        XCTAssertTrue(argsWithFonts.contains("--shared-fonts"))
        XCTAssertTrue(argsWithFonts.contains("/tmp/open-fonts/shared-fonts"))
    }

    func testParseStageLineRecognizesMNGProgressHeaders() {
        let s1 = MacNativeGamesBuilder.parseStageLine("1/4 code")
        XCTAssertEqual(s1?.index, 1)
        XCTAssertEqual(s1?.total, 4)
        XCTAssertEqual(s1?.name, "code")

        let s3 = MacNativeGamesBuilder.parseStageLine("=== 3/4 shaders ===")
        XCTAssertEqual(s3?.index, 3)
        XCTAssertEqual(s3?.total, 4)
        XCTAssertEqual(s3?.name, "shaders")

        XCTAssertNil(MacNativeGamesBuilder.parseStageLine("normal log line"))
    }

    func testUnpackCompressedPackageDisambiguatesSameStemAcrossDirectories() throws {
        let fm = FileManager.default
        let baseDir = temporary.appendingPathComponent("Base", isDirectory: true)
        let updateDir = temporary.appendingPathComponent("Update", isDirectory: true)
        let workDir = temporary.appendingPathComponent("work", isDirectory: true)
        let venvBin = temporary.appendingPathComponent("nsz-venv/bin", isDirectory: true)
        try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: updateDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: venvBin, withIntermediateDirectories: true)

        let baseNSZ = baseDir.appendingPathComponent("game.nsz")
        let updateNSZ = updateDir.appendingPathComponent("game.nsz")
        let keys = temporary.appendingPathComponent("prod.keys")
        try Data("base-compressed".utf8).write(to: baseNSZ)
        try Data("update-compressed".utf8).write(to: updateNSZ)
        try Data("keys".utf8).write(to: keys)

        let nszExe = venvBin.appendingPathComponent("nsz")
        try Data("#!/bin/sh\n".utf8).write(to: nszExe)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nszExe.path)
        let tool = ManagedNszTool(
            venvDir: venvBin.deletingLastPathComponent().path,
            binDir: venvBin.path,
            pythonPath: venvBin.appendingPathComponent("python3").path,
            executablePath: nszExe.path
        )

        var streamCount = 0
        final class UnpackRunner: ProcessRunner, @unchecked Sendable {
            var handler: (ProcessLaunch) -> Bool = { _ in true }
            func capture(_ launch: ProcessLaunch) -> ProcessResult { ProcessResult() }
            func stream(_ launch: ProcessLaunch, line: @escaping (String) -> Void) -> Bool { handler(launch) }
            func streamLines(_ launch: ProcessLaunch, started: @escaping (RunningProcess) -> Void, line: @escaping (String) -> Void) -> ProcessResult {
                started(FakeRunningProcess()); return ProcessResult()
            }
            func start(_ launch: ProcessLaunch, onOutput: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> RunningProcess {
                onExit(0); return FakeRunningProcess()
            }
        }
        let runner = UnpackRunner()
        runner.handler = { launch in
            streamCount += 1
            guard let oIdx = launch.arguments.firstIndex(of: "-o"), oIdx + 1 < launch.arguments.count,
                  let inputPath = launch.arguments.last else { return false }
            let staging = launch.arguments[oIdx + 1]
            let payload = inputPath.contains("/Base/") ? "UNPACKED-BASE" : "UNPACKED-UPDATE"
            try? Data(payload.utf8).write(to: URL(fileURLWithPath: staging + "/game.nsp"))
            return true
        }

        let resBase = Toolchain.unpackCompressedPackage(
            input: baseNSZ.path, keysPath: keys.path, workDir: workDir.path,
            tool: tool, environment: [:], runner: runner
        )
        let resUpdate = Toolchain.unpackCompressedPackage(
            input: updateNSZ.path, keysPath: keys.path, workDir: workDir.path,
            tool: tool, environment: [:], runner: runner
        )
        let unpackedBase = try resBase.get()
        let unpackedUpdate = try resUpdate.get()
        XCTAssertNotEqual(unpackedBase, unpackedUpdate, "Same-stem packages from distinct directories must not overwrite each other")
        XCTAssertEqual(try String(contentsOfFile: unpackedBase, encoding: .utf8), "UNPACKED-BASE")
        XCTAssertEqual(try String(contentsOfFile: unpackedUpdate, encoding: .utf8), "UNPACKED-UPDATE")
        XCTAssertEqual(streamCount, 2)

        // Both receipts hit cache on repeat calls without re-running nsz.
        XCTAssertEqual(try Toolchain.unpackCompressedPackage(
            input: baseNSZ.path, keysPath: keys.path, workDir: workDir.path,
            tool: tool, environment: [:], runner: runner
        ).get(), unpackedBase)
        XCTAssertEqual(try Toolchain.unpackCompressedPackage(
            input: updateNSZ.path, keysPath: keys.path, workDir: workDir.path,
            tool: tool, environment: [:], runner: runner
        ).get(), unpackedUpdate)
        XCTAssertEqual(streamCount, 2)
    }

    func testNUPSupportDependsOnTitleAndUpstreamGenericNUPCapability() throws {
        let oldTree = try makeFakeMNGTree()
        XCTAssertFalse(MacNativeGamesBuilder.supportsGenericNUP(in: oldTree))

        // Ocarina of Time accepts .nup directly on current MNG checkouts.
        XCTAssertTrue(MacNativeGamesBuilder.supportsInput(titleID: "0400486024DEC000", isNUP: true, tree: oldTree))
        // Pokopia and Donkey Kong Bananza require an unpacked dump folder when tools/nup_input.py is absent.
        XCTAssertFalse(MacNativeGamesBuilder.supportsInput(titleID: "0400A3A01EE4C000", isNUP: true, tree: oldTree))
        XCTAssertFalse(MacNativeGamesBuilder.supportsInput(titleID: "040074A01BF12000", isNUP: true, tree: oldTree))
        XCTAssertTrue(MacNativeGamesBuilder.supportsInput(titleID: "0400A3A01EE4C000", isNUP: false, tree: oldTree))
        XCTAssertTrue(MacNativeGamesBuilder.supportsInput(titleID: "040074A01BF12000", isNUP: false, tree: oldTree))

        // A folder wrapping a single .nup file is also detected as a .nup input.
        let wrapperDir = temporary.appendingPathComponent("PokopiaWrapper")
        try FileManager.default.createDirectory(at: wrapperDir, withIntermediateDirectories: true)
        let wrappedNUP = wrapperDir.appendingPathComponent("Pokopia [0400A3A01EE4C000].nup")
        try Data([0]).write(to: wrappedNUP)
        XCTAssertTrue(MacNativeGamesBuilder.isNUPInputPath(wrappedNUP.path))
        XCTAssertTrue(MacNativeGamesBuilder.isNUPInputPath(wrapperDir.path))
        XCTAssertFalse(MacNativeGamesBuilder.supportsInput(titleID: "0400A3A01EE4C000", gameFolder: wrapperDir.path, tree: oldTree))

        // Once MNG ships tools/nup_input.py (upstream PR #2339), Pokopia and Bananza .nup inputs unlock automatically,
        // while titles outside the 12-game allowlist stay blocked.
        let toolsDir = URL(fileURLWithPath: oldTree).appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: toolsDir, withIntermediateDirectories: true)
        try Data("# nup_input\n".utf8).write(to: toolsDir.appendingPathComponent("nup_input.py"))
        XCTAssertTrue(MacNativeGamesBuilder.supportsGenericNUP(in: oldTree))
        XCTAssertTrue(MacNativeGamesBuilder.supportsInput(titleID: "0400A3A01EE4C000", isNUP: true, tree: oldTree))
        XCTAssertTrue(MacNativeGamesBuilder.supportsInput(titleID: "040074A01BF12000", isNUP: true, tree: oldTree))
        XCTAssertFalse(MacNativeGamesBuilder.supportsInput(titleID: "0400C3F00006E000", isNUP: true, tree: oldTree))
    }
}
