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
            gameInput: "/roms/totk.xci",
            isUnencryptedInput: false,
            workDir: workDir.path
        ))
        XCTAssertFalse(MacNativeGamesBuilder.needsAutoSharedFonts(
            route: .unifiedBuildApp,
            gameInput: "/roms/totk.nup",
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
}
