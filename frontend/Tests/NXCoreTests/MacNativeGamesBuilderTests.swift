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

    func testRouteAndSupportsTitleIDStrictlyEnforceFiveSupportedGames() throws {
        let tree = try makeFakeMNGTree()

        XCTAssertFalse(MacNativeGamesBuilder.supportsTitleID(nil))
        XCTAssertFalse(MacNativeGamesBuilder.supportsTitleID(""))
        XCTAssertFalse(MacNativeGamesBuilder.supportsTitleID("   "))
        XCTAssertNil(MacNativeGamesBuilder.route(forTitleID: nil, in: tree))
        XCTAssertNil(MacNativeGamesBuilder.route(forTitleID: "", in: tree))

        let supportedFive = [
            "0100F2C0115B6000",
            "01007EF00011E000",
            "0400486024DEC000",
            "040074A01BF12000",
            "0400A3A01EE4C000",
        ]
        XCTAssertEqual(MacNativeGamesBuilder.supportedTitleIDs, Set(supportedFive))
        for tid in supportedFive {
            XCTAssertTrue(MacNativeGamesBuilder.supportsTitleID(tid.lowercased()), "\(tid) lowercase should be supported")
            XCTAssertEqual(
                MacNativeGamesBuilder.route(forTitleID: tid, in: tree),
                .unifiedBuildApp,
                "\(tid) should route to unifiedBuildApp"
            )
        }

        // Former per-game community entries and arbitrary titles must be blocked.
        for blocked in ["010093801237C000", "01002DA013484000", "010048900CF64000", "0100000000010000"] {
            XCTAssertFalse(MacNativeGamesBuilder.supportsTitleID(blocked))
            XCTAssertNil(MacNativeGamesBuilder.route(forTitleID: blocked, in: tree))
        }

        // Dynamic games/*/game.json entries must NOT bypass the 5-title allowlist.
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

    func testEngineUpstreamBundleTitleIDs() {
        let ids = EngineUpstream.macNativeGamesBundleTitleIDs
        XCTAssertEqual(ids["org.macnativegames.totk-native"], "0100F2C0115B6000")
        XCTAssertEqual(ids["org.macnativegames.oot-native"], "0400486024DEC000")
        XCTAssertEqual(ids["org.macnativegames.pkp"], "0400A3A01EE4C000")
        XCTAssertEqual(ids["org.macnativegames.alc"], "01007300020FA000")
        XCTAssertEqual(ids["org.macnativegames.by3"], "01004A4010FEA000")
        XCTAssertEqual(ids["org.macnativegames.unicorn"], "010054B01AD92000")
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
