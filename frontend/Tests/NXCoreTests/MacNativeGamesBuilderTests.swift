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

    func testRouteForTitleIDKnownAndFallback() throws {
        let tree = try makeFakeMNGTree()

        XCTAssertEqual(MacNativeGamesBuilder.route(forTitleID: nil, in: tree), .unifiedBuildApp)
        XCTAssertEqual(MacNativeGamesBuilder.route(forTitleID: "", in: tree), .unifiedBuildApp)

        let unified = [
            "0100F2C0115B6000",
            "01007EF00011E000",
            "0400486024DEC000",
            "040074A01BF12000",
            "0400A3A01EE4C000"
        ]
        for tid in unified {
            XCTAssertEqual(
                MacNativeGamesBuilder.route(forTitleID: tid, in: tree),
                .unifiedBuildApp,
                "\(tid) should route to unifiedBuildApp"
            )
        }

        XCTAssertEqual(
            MacNativeGamesBuilder.route(forTitleID: "010093801237C000", in: tree),
            .perGameScript(relativePath: "games/dread/build.py", supportsPlatformFlag: true, supportsUpdateFlag: true)
        )
        XCTAssertEqual(
            MacNativeGamesBuilder.route(forTitleID: "01002DA013484000", in: tree),
            .perGameScript(relativePath: "games/ss/build.py", supportsPlatformFlag: false, supportsUpdateFlag: true)
        )
        XCTAssertEqual(
            MacNativeGamesBuilder.route(forTitleID: "010048900CF64000", in: tree),
            .perGameScript(relativePath: "games/worldend/build.py", supportsPlatformFlag: false, supportsUpdateFlag: false)
        )

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

        let dynamicRoute = MacNativeGamesBuilder.route(forTitleID: "0100ABC001234000", in: tree)
        XCTAssertEqual(
            dynamicRoute,
            .perGameScript(relativePath: "games/custom/build.py", supportsPlatformFlag: true, supportsUpdateFlag: true)
        )

        XCTAssertNil(MacNativeGamesBuilder.route(forTitleID: "0100000000010000", in: tree))
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
        XCTAssertEqual(
            MacNativeGamesBuilder.scriptPath(
                for: .perGameScript(relativePath: "games/dread/build.py", supportsPlatformFlag: true, supportsUpdateFlag: true),
                in: "/opt/mng"
            ),
            "/opt/mng/games/dread/build.py"
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

        let ssRoute = MacNativeGamesBuilder.perGameRoutes["01002DA013484000"]!
        let ssArgs = MacNativeGamesBuilder.arguments(
            route: ssRoute,
            tree: "/opt/mng",
            gameInput: "/games/ss.nsp",
            keysPath: "/keys/prod.keys",
            isUnencryptedInput: false,
            updatePath: "/games/ss_update.nsp",
            dlcPaths: [],
            outputAppPath: "/out/SS.app",
            workDir: "/work"
        )
        XCTAssertFalse(ssArgs.contains("--platform"))
        XCTAssertTrue(ssArgs.contains("--update"))
        XCTAssertEqual(ssArgs.first, "/opt/mng/games/ss/build.py")

        let worldendRoute = MacNativeGamesBuilder.perGameRoutes["010048900CF64000"]!
        let worldendArgs = MacNativeGamesBuilder.arguments(
            route: worldendRoute,
            tree: "/opt/mng",
            gameInput: "/games/we.nsp",
            keysPath: "/keys/prod.keys",
            isUnencryptedInput: false,
            updatePath: "/games/we_update.nsp",
            dlcPaths: [],
            outputAppPath: "/out/WE.app",
            workDir: "/work"
        )
        XCTAssertFalse(worldendArgs.contains("--platform"))
        XCTAssertFalse(worldendArgs.contains("--update"))
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

        let ssRoute = MacNativeGamesBuilder.perGameRoutes["01002DA013484000"]!
        let perGameUnencryptedArgs = MacNativeGamesBuilder.arguments(
            route: ssRoute,
            tree: "/opt/mng",
            gameInput: "/games/ss_dump/",
            keysPath: "/keys/prod.keys",
            isUnencryptedInput: true,
            updatePath: "/games/ss_dump/updates/65536",
            dlcPaths: [],
            outputAppPath: "/out/SS.app",
            workDir: "/work"
        )
        XCTAssertFalse(perGameUnencryptedArgs.contains("-k"))
        XCTAssertFalse(perGameUnencryptedArgs.contains("--update"))

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

        let nupEvenWithFalseFlag = MacNativeGamesBuilder.arguments(
            route: ssRoute,
            tree: "/opt/mng",
            gameInput: nupPath,
            keysPath: "/keys/prod.keys",
            isUnencryptedInput: false,
            updatePath: "/games/other_update.nsp",
            dlcPaths: [],
            outputAppPath: "/out/OOT.app",
            workDir: "/work"
        )
        XCTAssertFalse(nupEvenWithFalseFlag.contains("-k"))
        XCTAssertFalse(nupEvenWithFalseFlag.contains("--update"))
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
}
