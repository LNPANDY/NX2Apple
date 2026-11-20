import XCTest
@testable import NXCore

final class S2ArmBuilderTests: XCTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    private func makeFakeS2ArmTree(name: String = "s2arm", hasScript: Bool = true) throws -> String {
        let root = temporary.appendingPathComponent(name)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("pack/jobs"), withIntermediateDirectories: true)
        try Data("#!/usr/bin/env python3\n".utf8).write(to: root.appendingPathComponent("pack/jobs/main.py"))
        try fm.createDirectory(at: root.appendingPathComponent("runtime/rewriter"), withIntermediateDirectories: true)
        try Data("/* rewriter */\n".utf8).write(to: root.appendingPathComponent("runtime/rewriter/rewriter.c"))
        if hasScript {
            try fm.createDirectory(at: root.appendingPathComponent("pack/oneclick"), withIntermediateDirectories: true)
            try Data("#!/bin/bash\n".utf8).write(to: root.appendingPathComponent("pack/oneclick/oneclick.sh"))
        }
        return root.path
    }

    func testIsUsableTree() throws {
        XCTAssertFalse(S2ArmBuilder.isUsableTree(""))
        let validTree = try makeFakeS2ArmTree(name: "s2arm-valid", hasScript: true)
        XCTAssertTrue(S2ArmBuilder.isUsableTree(validTree))

        let incompleteTree = try makeFakeS2ArmTree(name: "s2arm-incomplete", hasScript: false)
        XCTAssertFalse(S2ArmBuilder.isUsableTree(incompleteTree))
    }

    func testArguments() {
        let encryptedArgs = S2ArmBuilder.arguments(
            tree: "/opt/s2arm",
            sourceInput: "/games/zelda",
            keysPath: "/keys/prod.keys",
            isUnencryptedInput: false,
            workDir: "/work",
            isMacTarget: false,
            titleID: "0100F2C0115B6000",
            deviceUDID: "udid-123",
            eventsFile: "/work/s2a-events.jsonl"
        )
        let expectedEncrypted = [
            "/opt/s2arm/pack/oneclick/oneclick.sh",
            "/games/zelda",
            "--keys", "/keys/prod.keys",
            "--out", "/work",
            "--target", "ios",
            "--title-id", "0100F2C0115B6000",
            "--device", "udid-123",
            "--events", "/work/s2a-events.jsonl"
        ]
        XCTAssertEqual(encryptedArgs, expectedEncrypted)

        let macUnencryptedArgs = S2ArmBuilder.arguments(
            tree: "/opt/s2arm",
            sourceInput: "/games/zelda.nup",
            keysPath: "/keys/prod.keys",
            isUnencryptedInput: true,
            workDir: "/work",
            isMacTarget: true,
            titleID: nil,
            deviceUDID: "udid-123",
            eventsFile: ""
        )
        XCTAssertEqual(macUnencryptedArgs[0], "/opt/s2arm/pack/oneclick/oneclick.sh")
        XCTAssertEqual(macUnencryptedArgs[1], "/games/zelda.nup")
        XCTAssertFalse(macUnencryptedArgs.contains("--keys"))
        XCTAssertFalse(macUnencryptedArgs.contains("--title-id"))
        XCTAssertFalse(macUnencryptedArgs.contains("--device"))
        XCTAssertFalse(macUnencryptedArgs.contains("--events"))
        XCTAssertTrue(macUnencryptedArgs.contains("--target"))
        XCTAssertTrue(macUnencryptedArgs.contains("mac"))
    }

    func testEnvironment() {
        let encryptedEnv = S2ArmBuilder.environment(pythonPath: "/usr/bin/python3", keysPath: "/keys/prod.keys", isUnencryptedInput: false)
        XCTAssertEqual(encryptedEnv["S2A_PYTHON"], "/usr/bin/python3")
        XCTAssertEqual(encryptedEnv["PYTHONUNBUFFERED"], "1")
        XCTAssertEqual(encryptedEnv["S2A_KEYS"], "/keys/prod.keys")

        let unencryptedEnv = S2ArmBuilder.environment(pythonPath: "/usr/bin/python3", keysPath: "/keys/prod.keys", isUnencryptedInput: true)
        XCTAssertEqual(unencryptedEnv["S2A_PYTHON"], "/usr/bin/python3")
        XCTAssertEqual(unencryptedEnv["PYTHONUNBUFFERED"], "1")
        XCTAssertNil(unencryptedEnv["S2A_KEYS"])
    }

    func testParseEvents() {
        XCTAssertNil(S2ArmBuilder.parseEvents(""))
        XCTAssertNil(S2ArmBuilder.parseEvents("not a json\n"))
        XCTAssertNil(S2ArmBuilder.parseEvents("{\"ev\": \"stage\", \"name\": \"extract\"}\n"))

        let successJSONL = """
        {"ev": "stage", "name": "extract"}
        {"ev": "result", "ok": true, "ipa": "/out/app.ipa", "pack": "/out/pack.romfs"}
        {"ev": "say", "msg": "done"}
        """
        let summary = S2ArmBuilder.parseEvents(successJSONL)
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.ok == true)
        XCTAssertEqual(summary?.ipaPath, "/out/app.ipa")
        XCTAssertEqual(summary?.packPath, "/out/pack.romfs")
        XCTAssertNil(summary?.macRootPath)

        let macSuccessJSONL = """
        {"ev": "result", "ok": true, "root": "/out/AppRoot"}
        """
        let macSummary = S2ArmBuilder.parseEvents(macSuccessJSONL)
        XCTAssertNotNil(macSummary)
        XCTAssertTrue(macSummary?.ok == true)
        XCTAssertEqual(macSummary?.macRootPath, "/out/AppRoot")

        let failJSONL = """
        {"ev": "result", "ok": false, "msg": "Packaging failed due to missing keys"}
        """
        let failSummary = S2ArmBuilder.parseEvents(failJSONL)
        XCTAssertNotNil(failSummary)
        XCTAssertFalse(failSummary?.ok == true)
        XCTAssertEqual(failSummary?.message, "Packaging failed due to missing keys")
    }

    func testLastError() {
        let eventsFail = "{\"ev\": \"result\", \"ok\": false, \"msg\": \"Decryption error from events\"}\n"
        let logText = "stage 1\n🔴 fatal shader failure\ncleaning up\n"
        XCTAssertEqual(
            S2ArmBuilder.lastError(in: logText, eventsText: eventsFail),
            "Decryption error from events",
            "Error from events should take priority"
        )

        XCTAssertEqual(
            S2ArmBuilder.lastError(in: logText, eventsText: nil),
            "🔴 fatal shader failure"
        )

        let redChineseLog = "stage 1\n【红】 代码重写失败\ncleaning up\n"
        XCTAssertEqual(
            S2ArmBuilder.lastError(in: redChineseLog, eventsText: nil),
            "【红】 代码重写失败"
        )

        let errorPrefixLog = "stage 1\nERROR: out of memory\ncleaning up\n"
        XCTAssertEqual(
            S2ArmBuilder.lastError(in: errorPrefixLog, eventsText: nil),
            "ERROR: out of memory"
        )

        let normalLog = "stage 1\nfinished step 2\n"
        XCTAssertEqual(
            S2ArmBuilder.lastError(in: normalLog, eventsText: nil),
            "finished step 2"
        )
    }

    func testSdkRequirementReadsGlobalJsonAndFallsBack() throws {
        let fallback = S2ArmBuilder.sdkRequirement(in: "")
        XCTAssertEqual(fallback.version, "10.0.403")
        XCTAssertEqual(fallback.rollForward, "latestFeature")

        let tree = try makeFakeS2ArmTree(name: "s2arm-global-json")
        let missingGlobal = S2ArmBuilder.sdkRequirement(in: tree)
        XCTAssertEqual(missingGlobal.version, "10.0.403")
        XCTAssertEqual(missingGlobal.rollForward, "latestFeature")

        let compatDir = URL(fileURLWithPath: tree).appendingPathComponent("compat/tree")
        try FileManager.default.createDirectory(at: compatDir, withIntermediateDirectories: true)
        let json = """
        {
          "sdk": {
            "version": "10.0.405",
            "rollForward": "latestFeature"
          }
        }
        """
        try Data(json.utf8).write(to: compatDir.appendingPathComponent("global.json"))
        let custom = S2ArmBuilder.sdkRequirement(in: tree)
        XCTAssertEqual(custom.version, "10.0.405")
        XCTAssertEqual(custom.rollForward, "latestFeature")
    }

    func testSdkSatisfiesAndFindDotnetRejects10_0_402AndAccepts10_0_403() throws {
        XCTAssertFalse(S2ArmBuilder.sdkSatisfies("10.0.402", required: "10.0.403", rollForward: "latestFeature"))
        XCTAssertFalse(S2ArmBuilder.sdkSatisfies("9.0.405", required: "10.0.403", rollForward: "latestFeature"))
        XCTAssertTrue(S2ArmBuilder.sdkSatisfies("10.0.403", required: "10.0.403", rollForward: "latestFeature"))
        XCTAssertTrue(S2ArmBuilder.sdkSatisfies("10.0.404", required: "10.0.403", rollForward: "latestFeature"))
        XCTAssertTrue(S2ArmBuilder.sdkSatisfies("10.0.500", required: "10.0.403", rollForward: "latestFeature"))

        let tree = try makeFakeS2ArmTree(name: "s2arm-dotnet-check")
        let runner = FakeProcessRunner()
        runner.answer = { launch in
            if launch.executable == "/fake/dotnet-old" {
                return ProcessResult(status: 0, out: "8.0.404 [/fake/sdk]\n10.0.402 [/fake/sdk]\n")
            }
            if launch.executable == "/fake/dotnet-new" {
                return ProcessResult(status: 0, out: "10.0.403 [/fake/sdk]\n")
            }
            return ProcessResult(status: 1, out: "")
        }

        let rejected = S2ArmBuilder.findDotnet(
            ["/fake/dotnet-old"],
            tree: tree,
            runner: runner,
            exists: { _ in true }
        )
        XCTAssertFalse(rejected.ok)
        XCTAssertEqual(rejected.requiredVersion, "10.0.403")
        XCTAssertEqual(rejected.foundOldVersion, "10.0.402")

        let accepted = S2ArmBuilder.findDotnet(
            ["/fake/dotnet-old", "/fake/dotnet-new"],
            tree: tree,
            runner: runner,
            exists: { _ in true }
        )
        XCTAssertTrue(accepted.ok)
        XCTAssertEqual(accepted.path, "/fake/dotnet-new")
        XCTAssertNil(accepted.foundOldVersion)
    }

    func testMissingPythonPackagesReportsAbsentImports() {
        let runner = FakeProcessRunner()
        runner.answer = { _ in ProcessResult(status: 0, out: "Pillow,skia-pathops\n") }
        let missing = S2ArmBuilder.missingPythonPackages(python: "/fake/python3", runner: runner)
        XCTAssertEqual(missing, ["Pillow", "skia-pathops"])

        runner.answer = { _ in ProcessResult(status: 0, out: "\n") }
        XCTAssertEqual(S2ArmBuilder.missingPythonPackages(python: "/fake/python3", runner: runner), [])
    }

    func testZstdWrapperCreationAndToolPathInjection() throws {
        let workDir = temporary.appendingPathComponent("zstd-work", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        // When PATH points to an empty directory and system paths lack zstd, wrapper is created;
        // verify environmentWithToolPaths prepends wrapper and dotnet paths cleanly.
        let fakeBin = workDir.appendingPathComponent(".nx2a-bin")
        let env = S2ArmBuilder.environmentWithToolPaths(
            base: ["PATH": "/usr/bin:/bin"],
            dotnetPath: "/Users/tester/.dotnet/dotnet",
            extraBinDirs: [fakeBin.path],
            home: "/Users/tester",
            runner: FakeProcessRunner()
        )
        XCTAssertEqual(env["DOTNET_ROOT"], "/Users/tester/.dotnet")
        XCTAssertEqual(env["DOTNET_ROOT_ARM64"], "/Users/tester/.dotnet")
        let parts = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        XCTAssertEqual(parts.first, fakeBin.path)
        XCTAssertTrue(parts.contains("/Users/tester/.dotnet"))
        XCTAssertTrue(parts.contains("/usr/local/share/dotnet"))
        XCTAssertTrue(parts.contains("/opt/homebrew/bin"))
    }

    func testEnsureHostBinariesInjectsDotnetRootAndHomeDotnetPathForMakeHost() throws {
        let s2armTree = temporary.appendingPathComponent("s2arm-make-env", isDirectory: true)
        let fakeHome = temporary.appendingPathComponent("home-make", isDirectory: true)
        let dotnetDir = fakeHome.appendingPathComponent(".dotnet", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: s2armTree.appendingPathComponent("launchers/macos"), withIntermediateDirectories: true)
        try Data("all:\n\t@true\n".utf8).write(to: s2armTree.appendingPathComponent("Makefile"))
        try Data("# build.mk\n".utf8).write(to: s2armTree.appendingPathComponent("launchers/macos/build.mk"))
        try fm.createDirectory(at: dotnetDir, withIntermediateDirectories: true)
        let fakeDotnet = dotnetDir.appendingPathComponent("dotnet")
        try Data("#!/bin/sh\n".utf8).write(to: fakeDotnet)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeDotnet.path)

        var makeEnv: [String: String] = [:]
        let runner = FakeProcessRunner()
        runner.answer = { launch in
            if launch.arguments.contains("--list-sdks") {
                return ProcessResult(status: 0, out: "10.0.403 [\(dotnetDir.path)/sdk]\n")
            }
            if launch.arguments.contains("--list-runtimes") {
                return ProcessResult(status: 0, out: "Microsoft.NETCore.App 10.0.0 [\(dotnetDir.path)/shared/Microsoft.NETCore.App]\n")
            }
            if launch.executable == "/usr/bin/make" {
                makeEnv = launch.environment ?? [:]
                if let buildArg = launch.arguments.first(where: { $0.hasPrefix("BUILD=") }) {
                    let dir = URL(fileURLWithPath: String(buildArg.dropFirst("BUILD=".count)))
                    try? Data("#!/bin/sh\n".utf8).write(to: dir.appendingPathComponent("s2arm-host"))
                    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("s2arm-host").path)
                    try? Data("dylib".utf8).write(to: dir.appendingPathComponent("libs2a_vaguard.dylib"))
                }
                return ProcessResult(status: 0, out: "")
            }
            return ProcessResult(status: 0, out: "/Applications/Xcode.app/Contents/Developer\n")
        }

        let upstreamsRoot = temporary.appendingPathComponent("upstreams-env", isDirectory: true)
        let res = S2ArmMacAppPacker.ensureHostBinaries(
            s2armTree: s2armTree.path,
            upstreamsRoot: upstreamsRoot,
            home: fakeHome.path,
            runner: runner
        )
        switch res {
        case .success:
            XCTAssertEqual(makeEnv["DOTNET_ROOT"], dotnetDir.path)
            XCTAssertEqual(makeEnv["DOTNET_ROOT_ARM64"], dotnetDir.path)
            XCTAssertTrue((makeEnv["PATH"] ?? "").contains(dotnetDir.path))
            XCTAssertTrue((makeEnv["PATH"] ?? "").contains("/usr/local/share/dotnet"))
        case .failure(let err):
            XCTFail("Expected ensureHostBinaries success, got \(err)")
        }
    }

    func testS2ArmMacAppPackerCompilesRealLauncherSignsAndPassesMacGameBundleRead() throws {
        let s2armTree = temporary.appendingPathComponent("s2arm-real", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: s2armTree.appendingPathComponent("launchers/macos"), withIntermediateDirectories: true)
        try Data("all:\n\t@true\n".utf8).write(to: s2armTree.appendingPathComponent("Makefile"))
        try Data("# build.mk\n".utf8).write(to: s2armTree.appendingPathComponent("launchers/macos/build.mk"))
        try UpstreamVersion.writeReceipt(
            UpstreamVersionReceipt(commit: "abcdef1234567890abcdef1234567890abcdef12", version: "v0.5.8", installedAt: "2026.11.19"),
            to: s2armTree
        )
        XCTAssertTrue(S2ArmMacAppPacker.canPackHost(in: s2armTree.path))
        XCTAssertEqual(S2ArmMacAppPacker.hostCacheKey(s2armTree: s2armTree.path), "abcdef123456")

        // Pre-populate cached host binaries: a tiny shell stub as s2arm-host that dumps env + args
        let upstreamsRoot = temporary.appendingPathComponent("upstreams", isDirectory: true)
        let cacheDir = upstreamsRoot.appendingPathComponent("s2arm-host-cache/abcdef123456", isDirectory: true)
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let probeOut = temporary.appendingPathComponent("host-probe.txt")
        let hostStub = """
        #!/bin/sh
        {
          echo "ARG1=$1"
          echo "S2A_IPHONE_VA=$S2A_IPHONE_VA"
          echo "S2A_GAME_DATA=$S2A_GAME_DATA"
          echo "S2A_SAVE_FOLDER=$S2A_SAVE_FOLDER"
          echo "S2A_DOCS=$S2A_DOCS"
          echo "S2A_DOCKED=$S2A_DOCKED"
          echo "S2A_AUTOPLAY=$S2A_AUTOPLAY"
          echo "S2A_GAME_NAME=$S2A_GAME_NAME"
          echo "S2A_GAME_ID=$S2A_GAME_ID"
          echo "NXGAL_SHADER_CACHE_DIR=$NXGAL_SHADER_CACHE_DIR"
        } > "\(probeOut.path)"
        """
        let cachedHost = cacheDir.appendingPathComponent("s2arm-host")
        try Data(hostStub.utf8).write(to: cachedHost)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cachedHost.path)

        // Build a real tiny dylib so codesign --force --sign - succeeds genuinely on macOS
        let dylibC = temporary.appendingPathComponent("stub.c")
        try Data("int s2a_vaguard_stub(void) { return 0; }\n".utf8).write(to: dylibC)
        let cachedDylib = cacheDir.appendingPathComponent("libs2a_vaguard.dylib")
        let buildDylib = SystemProcessRunner().capture(ProcessLaunch(
            executable: "/usr/bin/xcrun",
            arguments: ["clang", "-dynamiclib", "-arch", "arm64", "-o", cachedDylib.path, dylibC.path]
        ))
        XCTAssertTrue(buildDylib.ok, "Expected real stub dylib compile to succeed: \(buildDylib.err)")

        let macRoot = temporary.appendingPathComponent("mac-root", isDirectory: true)
        try fm.createDirectory(at: macRoot, withIntermediateDirectories: true)
        let destApp = temporary.appendingPathComponent("out/Tears.app", isDirectory: true)
        let tid = "0100F2C0115B6000"
        let res = S2ArmMacAppPacker.packApp(
            s2armTree: s2armTree.path,
            macRootPath: macRoot.path,
            titleID: tid,
            gameName: "Tears of the Kingdom",
            destinationAppURL: destApp,
            upstreamsRoot: upstreamsRoot,
            runner: SystemProcessRunner()
        )
        switch res {
        case .success(let appURL):
            let bundle = try MacGameBundle.read(appURL)
            XCTAssertEqual(bundle.upstream, .s2arm)
            XCTAssertEqual(bundle.titleID, tid)
            XCTAssertEqual(bundle.name, "Tears of the Kingdom")

            // Execute the compiled native arm64 Mach-O s2arm-launch and verify env vars + dirs
            let fakeHome = temporary.appendingPathComponent("fake-home", isDirectory: true)
            try fm.createDirectory(at: fakeHome, withIntermediateDirectories: true)
            let launchExe = appURL.appendingPathComponent("Contents/MacOS/s2arm-launch").path
            let runRes = SystemProcessRunner().capture(ProcessLaunch(
                executable: launchExe,
                arguments: [],
                environment: ["HOME": fakeHome.path, "PATH": "/usr/bin:/bin"]
            ))
            XCTAssertTrue(runRes.ok, "Compiled s2arm-launch failed: \(runRes.err)")
            let dump = try String(contentsOf: probeOut, encoding: .utf8)
            XCTAssertTrue(dump.contains("ARG1=\(macRoot.path)"))
            XCTAssertTrue(dump.contains("S2A_IPHONE_VA=0"))
            XCTAssertTrue(dump.contains("S2A_DOCKED=1"))
            XCTAssertTrue(dump.contains("S2A_AUTOPLAY=0"))
            XCTAssertTrue(dump.contains("S2A_GAME_NAME=Tears of the Kingdom"))
            XCTAssertTrue(dump.contains("S2A_GAME_ID=\(tid)"))
            let dataRoot = fakeHome.appendingPathComponent("Library/Application Support/NX2Apple/s2arm-data/\(tid)")
            XCTAssertTrue(fm.fileExists(atPath: dataRoot.appendingPathComponent("SaveData").path))
            XCTAssertTrue(fm.fileExists(atPath: dataRoot.appendingPathComponent("shader-cache").path))
            XCTAssertTrue(fm.fileExists(atPath: dataRoot.appendingPathComponent("docs").path))
        case .failure(let err):
            XCTFail("packApp failed: \(err)")
        }
    }

    func testParseStageEventRecognizesS2ArmStartAndFinishMarkers() {
        let start = S2ArmBuilder.parseStageEvent("▶ 解包游戏开始")
        XCTAssertEqual(start?.name, "解包游戏")
        XCTAssertEqual(start?.finished, false)

        let done = S2ArmBuilder.parseStageEvent("✓ 解包游戏完成，用时 4.2s")
        XCTAssertEqual(done?.name, "解包游戏")
        XCTAssertEqual(done?.finished, true)
        XCTAssertEqual(done?.detail, "4.2s")

        XCTAssertNil(S2ArmBuilder.parseStageEvent("ordinary output line"))
    }

    func testBootstrapGitRepoInitializesCleanCommitAndExcludesLauncherArtifacts() throws {
        let tree = temporary.appendingPathComponent("s2arm-git-init", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: tree.appendingPathComponent("graphics/widen/scan"), withIntermediateDirectories: true)
        try Data("scan\n".utf8).write(to: tree.appendingPathComponent("graphics/widen/scan/rules.txt"))
        try Data("ignored_input.bin\n".utf8).write(to: tree.appendingPathComponent(".gitignore"))
        try Data("keep-me\n".utf8).write(to: tree.appendingPathComponent("ignored_input.bin"))
        try fm.createDirectory(at: tree.appendingPathComponent(".venv/bin"), withIntermediateDirectories: true)
        try Data("venv\n".utf8).write(to: tree.appendingPathComponent(".venv/bin/python3"))
        try fm.createDirectory(at: tree.appendingPathComponent(".nx2apple-shims"), withIntermediateDirectories: true)
        try Data("shim\n".utf8).write(to: tree.appendingPathComponent(".nx2apple-shims/bash"))
        try Data("{\"version\":\"v0.5.8\"}\n".utf8).write(to: tree.appendingPathComponent(".upstream-version.json"))
        try fm.createDirectory(at: tree.appendingPathComponent("build"), withIntermediateDirectories: true)
        try Data("obj\n".utf8).write(to: tree.appendingPathComponent("build/out.o"))

        XCTAssertTrue(S2ArmBootstrap.ensureGitRepo(in: tree.path, runner: SystemProcessRunner()))

        let runner = SystemProcessRunner()
        let gitEnv = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        let scanTree = runner.capture(ProcessLaunch(
            executable: "/usr/bin/git",
            arguments: ["-C", tree.path, "rev-parse", "HEAD:graphics/widen/scan"],
            environment: gitEnv
        ))
        XCTAssertTrue(scanTree.ok, "HEAD:graphics/widen/scan must resolve: \(scanTree.err)")
        XCTAssertFalse(scanTree.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let lsFiles = runner.capture(ProcessLaunch(
            executable: "/usr/bin/git",
            arguments: ["-C", tree.path, "ls-files"],
            environment: gitEnv
        ))
        let tracked = Set(lsFiles.out.split(whereSeparator: \.isNewline).map(String.init))
        XCTAssertTrue(tracked.contains("graphics/widen/scan/rules.txt"))
        XCTAssertTrue(tracked.contains("ignored_input.bin"))
        XCTAssertFalse(tracked.contains(".venv/bin/python3"))
        XCTAssertFalse(tracked.contains(".nx2apple-shims/bash"))
        XCTAssertFalse(tracked.contains(".upstream-version.json"))
        XCTAssertFalse(tracked.contains("build/out.o"))

        let status = runner.capture(ProcessLaunch(
            executable: "/usr/bin/git",
            arguments: ["-C", tree.path, "status", "--porcelain"],
            environment: gitEnv
        ))
        XCTAssertEqual(status.out.trimmingCharacters(in: .whitespacesAndNewlines), "")

        // Directory with engine.json skips git init
        let bundled = temporary.appendingPathComponent("s2arm-engine-json", isDirectory: true)
        try fm.createDirectory(at: bundled, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: bundled.appendingPathComponent("engine.json"))
        XCTAssertTrue(S2ArmBootstrap.ensureGitRepo(in: bundled.path, runner: SystemProcessRunner()))
        XCTAssertFalse(fm.fileExists(atPath: bundled.appendingPathComponent(".git").path))
    }

    func testBootstrapModernBashDetectionBuildScriptShimAndMakeHostShell() throws {
        let runner = FakeProcessRunner()
        runner.answer = { launch in
            if launch.executable == "/old/bash" {
                return ProcessResult(status: 0, out: "3\n")
            }
            if launch.executable == "/new/bash" {
                return ProcessResult(status: 0, out: "5\n")
            }
            return ProcessResult(status: 1, out: "")
        }
        let found = S2ArmBootstrap.findModernBash(
            candidates: ["/old/bash", "/new/bash"],
            runner: runner,
            exists: { _ in true }
        )
        XCTAssertEqual(found, "/new/bash")

        let script = S2ArmBootstrap.bashBuildScript(installTarget: "/tmp/tools/bin/bash")
        XCTAssertTrue(script.contains("https://ftpmirror.gnu.org/gnu/bash/bash-5.2.37.tar.gz"))
        XCTAssertTrue(script.contains("https://ftp.gnu.org/gnu/bash/bash-5.2.37.tar.gz"))
        XCTAssertTrue(script.contains("./configure --without-bash-malloc --disable-nls"))
        XCTAssertTrue(script.contains("mv -f"))

        let tree = temporary.appendingPathComponent("s2arm-shim", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: tree.appendingPathComponent("launchers/macos"), withIntermediateDirectories: true)
        try Data("all:\n\t@true\n".utf8).write(to: tree.appendingPathComponent("Makefile"))
        try Data("# build.mk\n".utf8).write(to: tree.appendingPathComponent("launchers/macos/build.mk"))
        let fakeHome = temporary.appendingPathComponent("bash-home", isDirectory: true)
        let managedBash = URL(fileURLWithPath: S2ArmBootstrap.managedBashPath(home: fakeHome.path))
        try fm.createDirectory(at: managedBash.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho 5\n".utf8).write(to: managedBash)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: managedBash.path)

        let shimDir = try XCTUnwrap(S2ArmBootstrap.linkBashShim(modernBash: managedBash.path, in: tree.path))
        let dest = try fm.destinationOfSymbolicLink(atPath: shimDir + "/bash")
        XCTAssertEqual(dest, managedBash.path)

        var makeArgs: [String] = []
        var makeEnv: [String: String] = [:]
        let makeRunner = FakeProcessRunner()
        makeRunner.answer = { launch in
            if launch.executable == managedBash.path {
                return ProcessResult(status: 0, out: "5\n")
            }
            if launch.executable == "/usr/bin/make" {
                makeArgs = launch.arguments
                makeEnv = launch.environment ?? [:]
                if let buildArg = launch.arguments.first(where: { $0.hasPrefix("BUILD=") }) {
                    let dir = URL(fileURLWithPath: String(buildArg.dropFirst("BUILD=".count)))
                    try? Data("#!/bin/sh\n".utf8).write(to: dir.appendingPathComponent("s2arm-host"))
                    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("s2arm-host").path)
                    try? Data("dylib".utf8).write(to: dir.appendingPathComponent("libs2a_vaguard.dylib"))
                }
                return ProcessResult(status: 0, out: "")
            }
            return ProcessResult(status: 0, out: "/Applications/Xcode.app/Contents/Developer\n")
        }

        let res = S2ArmMacAppPacker.ensureHostBinaries(
            s2armTree: tree.path,
            upstreamsRoot: temporary.appendingPathComponent("upstreams-bash", isDirectory: true),
            home: fakeHome.path,
            runner: makeRunner
        )
        let bashAlias = S2ArmMacAppPacker.noSpaceAlias(for: managedBash.path)
        switch res {
        case .success:
            XCTAssertTrue(makeArgs.contains("SHELL=\(bashAlias)"))
            XCTAssertEqual(makeEnv["SHELL"], bashAlias)
            XCTAssertTrue((makeEnv["PATH"] ?? "").hasPrefix(shimDir + ":"))
        case .failure(let err):
            XCTFail("Expected ensureHostBinaries success, got \(err)")
        }
    }

    func testBootstrapVenvBuildToolsAndRewriterDepsPreparation() throws {
        for tool in ["cmake", "meson", "ninja"] {
            XCTAssertTrue(S2ArmBuilder.pipPackages.contains(tool))
            XCTAssertTrue(Toolchain.pipPackages((3, 13), includeS2Arm: true).contains(tool))
        }

        let fm = FileManager.default
        let venvBin = temporary.appendingPathComponent("venv/bin", isDirectory: true)
        try fm.createDirectory(at: venvBin, withIntermediateDirectories: true)
        let fakePy = venvBin.appendingPathComponent("python3")
        try Data("#!/bin/sh\n".utf8).write(to: fakePy)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakePy.path)

        let pyRunner = FakeProcessRunner()
        pyRunner.answer = { _ in ProcessResult(status: 0, out: "\n") }
        XCTAssertFalse(S2ArmBootstrap.isVenvReady(python: fakePy.path, runner: pyRunner))
        XCTAssertEqual(S2ArmBootstrap.missingVenvBuildTools(python: fakePy.path), ["cmake", "meson", "ninja"])

        for tool in ["cmake", "meson", "ninja"] {
            let p = venvBin.appendingPathComponent(tool)
            try Data("#!/bin/sh\n".utf8).write(to: p)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p.path)
        }
        XCTAssertTrue(S2ArmBootstrap.isVenvReady(python: fakePy.path, runner: pyRunner))

        // Rewriter deps: cleans stale partial directory before running prepare_deps.py
        let tree = temporary.appendingPathComponent("s2arm-rewriter-deps", isDirectory: true)
        try fm.createDirectory(at: tree.appendingPathComponent("runtime/rewriter"), withIntermediateDirectories: true)
        try Data("#!/usr/bin/env python3\n".utf8).write(to: tree.appendingPathComponent("runtime/rewriter/prepare_deps.py"))
        let staleFile = tree.appendingPathComponent("build/rewriter-deps/stale.txt")
        try fm.createDirectory(at: staleFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("partial\n".utf8).write(to: staleFile)

        var sawStaleRemoved = false
        var sawProxy = false
        let depsRunner = FakeProcessRunner()
        depsRunner.answer = { launch in
            sawStaleRemoved = !fm.fileExists(atPath: staleFile.path)
            sawProxy = launch.environment?["HTTPS_PROXY"] == "http://127.0.0.1:7890"
            let target = URL(fileURLWithPath: launch.arguments[1], isDirectory: true)
            try? fm.createDirectory(at: target.appendingPathComponent("capstone-5.0.7/src"), withIntermediateDirectories: true)
            try? fm.createDirectory(at: target.appendingPathComponent("lz4-4.4.5/lz4libs"), withIntermediateDirectories: true)
            try? Data("# cmake\n".utf8).write(to: target.appendingPathComponent("capstone-5.0.7/src/CMakeLists.txt"))
            try? Data("/* lz4 */\n".utf8).write(to: target.appendingPathComponent("lz4-4.4.5/lz4libs/lz4.c"))
            return ProcessResult(status: 0, out: "prepared\n")
        }

        let first = S2ArmBootstrap.ensureRewriterDeps(
            in: tree.path,
            python: fakePy.path,
            environment: ["https_proxy": "http://127.0.0.1:7890"],
            runner: depsRunner
        )
        XCTAssertTrue(first.ok)
        XCTAssertFalse(first.skipped)
        XCTAssertTrue(sawStaleRemoved)
        XCTAssertTrue(sawProxy)

        let second = S2ArmBootstrap.ensureRewriterDeps(
            in: tree.path,
            python: fakePy.path,
            environment: [:],
            runner: depsRunner
        )
        XCTAssertTrue(second.ok)
        XCTAssertTrue(second.skipped)
    }

    func testRequirementSpecsParsingExactVersionProbeAndZstandardOnPython314() throws {
        XCTAssertTrue(Toolchain.pipPackages((3, 14), includeS2Arm: true).contains("zstandard"))
        XCTAssertTrue(Toolchain.pipPackages((3, 13), includeS2Arm: true).contains("zstandard"))

        let fm = FileManager.default
        let tree = temporary.appendingPathComponent("s2arm-reqs", isDirectory: true)
        try fm.createDirectory(at: tree.appendingPathComponent("tools"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tree.appendingPathComponent("pack/fonts"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tree.appendingPathComponent("launchers/macos"), withIntermediateDirectories: true)
        try Data("# rewriter\ncapstone==5.0.7\nlz4==4.4.5\n".utf8).write(to: tree.appendingPathComponent("tools/rewriter-requirements.txt"))
        try Data("fonttools==4.67.0\nskia-pathops==0.9.2\n".utf8).write(to: tree.appendingPathComponent("pack/fonts/requirements.txt"))
        try Data("numpy==2.4.2\nPillow==12.3.0\nzstandard==0.25.0\n".utf8).write(to: tree.appendingPathComponent("launchers/macos/requirements-runtime.txt"))

        let parsed = S2ArmBootstrap.requirementSpecs(in: tree.path)
        XCTAssertTrue(parsed.specs.contains("fonttools==4.67.0"))
        XCTAssertTrue(parsed.specs.contains("skia-pathops==0.9.2"))
        XCTAssertTrue(parsed.specs.contains("zstandard==0.25.0"))
        XCTAssertTrue(parsed.specs.contains("cmake"))
        XCTAssertTrue(parsed.specs.contains("meson"))
        XCTAssertTrue(parsed.specs.contains("ninja"))
        XCTAssertEqual(parsed.pinned.first(where: { $0.name == "fonttools" })?.version, "4.67.0")
        XCTAssertEqual(parsed.pinned.first(where: { $0.name == "skia-pathops" })?.version, "0.9.2")

        var capturedProbe = ""
        let runner = FakeProcessRunner()
        runner.answer = { launch in
            capturedProbe = launch.arguments.last ?? ""
            return ProcessResult(status: 0, out: "fonttools==4.67.0\n")
        }
        let missing = S2ArmBuilder.missingPythonPackages(python: "/fake/python3", tree: tree.path, runner: runner)
        XCTAssertEqual(missing, ["fonttools==4.67.0"])
        XCTAssertTrue(capturedProbe.contains("importlib.metadata.version"))
        XCTAssertTrue(capturedProbe.contains("\"fonttools\", \"4.67.0\""))
        XCTAssertTrue(capturedProbe.contains("\"zstandard\""))
    }

    func testFindDotnetSkipsHomebrewCellarAndSymlinksToHomebrew() throws {
        let fm = FileManager.default
        let cellarDotnet = temporary.appendingPathComponent("Cellar/dotnet/10.0.403/bin/dotnet")
        try fm.createDirectory(at: cellarDotnet.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: cellarDotnet)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cellarDotnet.path)

        let symlinkDotnet = temporary.appendingPathComponent("usr-bin-dotnet")
        try fm.createSymbolicLink(atPath: symlinkDotnet.path, withDestinationPath: cellarDotnet.path)

        let officialDotnet = temporary.appendingPathComponent("official-dotnet/dotnet")
        try fm.createDirectory(at: officialDotnet.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: officialDotnet)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: officialDotnet.path)

        XCTAssertTrue(S2ArmBuilder.isHomebrewDotnetPath("/opt/homebrew/bin/dotnet"))
        XCTAssertTrue(S2ArmBuilder.isHomebrewDotnetPath(cellarDotnet.path))
        XCTAssertTrue(S2ArmBuilder.isHomebrewDotnetPath(symlinkDotnet.path))
        XCTAssertFalse(S2ArmBuilder.isHomebrewDotnetPath(officialDotnet.path))

        var probed: [String] = []
        let runner = FakeProcessRunner()
        runner.answer = { launch in
            probed.append(launch.executable)
            return ProcessResult(status: 0, out: "10.0.403 [/sdk]\n")
        }
        let res = S2ArmBuilder.findDotnet(
            ["/opt/homebrew/bin/dotnet", symlinkDotnet.path, officialDotnet.path],
            runner: runner,
            exists: { _ in true }
        )
        XCTAssertTrue(res.ok)
        XCTAssertEqual(res.path, officialDotnet.path)
        XCTAssertEqual(probed, [officialDotnet.path])

        let defaultCands = S2ArmBuilder.dotnetCandidates(home: "/Users/player")
        XCTAssertEqual(defaultCands.first, "/Users/player/.dotnet/dotnet")
        XCTAssertFalse(defaultCands.contains(where: { S2ArmBuilder.isHomebrewDotnetPath($0) }))
    }

    func testEnsureRuntimeToolsBuildsOrReusesSpirvAndPinnedZstd157() throws {
        let fm = FileManager.default
        let tree = temporary.appendingPathComponent("s2arm-rt", isDirectory: true)
        try fm.createDirectory(at: tree.appendingPathComponent("launchers/macos"), withIntermediateDirectories: true)
        try Data("# runtime_sources\n".utf8).write(to: tree.appendingPathComponent("launchers/macos/runtime_sources.py"))

        final class RuntimeStreamRunner: ProcessRunner, @unchecked Sendable {
            let builtPrefix: URL
            init(builtPrefix: URL) { self.builtPrefix = builtPrefix }
            func capture(_ launch: ProcessLaunch) -> ProcessResult { ProcessResult(status: 0, out: "") }
            func stream(_ launch: ProcessLaunch, line: @escaping (String) -> Void) -> Bool {
                if launch.arguments.contains(where: { $0.contains("runtime_sources.tools()") }) {
                    let fm = FileManager.default
                    try? fm.createDirectory(at: builtPrefix.appendingPathComponent("bin"), withIntermediateDirectories: true)
                    try? fm.createDirectory(at: builtPrefix.appendingPathComponent("lib"), withIntermediateDirectories: true)
                    for tool in S2ArmBootstrap.requiredRuntimeToolBinaries {
                        let p = builtPrefix.appendingPathComponent("bin/\(tool)")
                        try? Data("#!/bin/sh\n".utf8).write(to: p)
                        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p.path)
                    }
                    try? Data("dylib".utf8).write(to: builtPrefix.appendingPathComponent("lib/libzstd.1.dylib"))
                    line("building spirv")
                    line("\(S2ArmBootstrap.runtimeToolsMarker)\(builtPrefix.path)")
                    return true
                }
                return false
            }
            func streamLines(_ launch: ProcessLaunch, started: @escaping (RunningProcess) -> Void, line: @escaping (String) -> Void) -> ProcessResult {
                ProcessResult(status: 0)
            }
            func start(_ launch: ProcessLaunch, onOutput: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> RunningProcess {
                throw CocoaError(.fileNoSuchFile)
            }
        }

        let builtPrefix = URL(fileURLWithPath: S2ArmBootstrap.runtimeToolsPrefix(in: tree.path), isDirectory: true)
        var streamedLines: [String] = []
        let runner = RuntimeStreamRunner(builtPrefix: builtPrefix)

        let first = S2ArmBootstrap.ensureRuntimeTools(
            in: tree.path,
            python: "/fake/python3",
            environment: ["PATH": "/nonexistent"],
            runner: runner
        ) { line in
            streamedLines.append(line)
        }
        XCTAssertTrue(first.ok)
        XCTAssertFalse(first.skipped)
        XCTAssertEqual(first.binDir, builtPrefix.appendingPathComponent("bin").path)
        XCTAssertEqual(first.zstdLib, builtPrefix.appendingPathComponent("lib/libzstd.1.dylib").path)
        XCTAssertEqual(streamedLines, ["building spirv"])
        XCTAssertFalse(streamedLines.contains(where: { $0.contains(S2ArmBootstrap.runtimeToolsMarker) }))

        let second = S2ArmBootstrap.ensureRuntimeTools(
            in: tree.path,
            python: "/fake/python3",
            environment: ["PATH": "/nonexistent"],
            runner: runner
        )
        XCTAssertTrue(second.ok)
        XCTAssertTrue(second.skipped)
        XCTAssertEqual(second.zstdLib, builtPrefix.appendingPathComponent("lib/libzstd.1.dylib").path)
    }

    func testRecommendedConcurrencyFloorsAndExplicitEnvPrecedence() {
        let gib: UInt64 = 1024 * 1024 * 1024

        // Below 8 GiB -> nil (leave to cores.sh)
        XCTAssertNil(S2ArmBuilder.recommendedConcurrency(physicalMemoryBytes: 6 * gib, cpuCount: 8))

        // 8 / 16 / 24 / 32 GiB tiers with 12 cores
        let r8 = S2ArmBuilder.recommendedConcurrency(physicalMemoryBytes: 8 * gib, cpuCount: 12)
        XCTAssertEqual(r8?.directJ, 2)
        XCTAssertEqual(r8?.cpuBake, 1)

        let r16 = S2ArmBuilder.recommendedConcurrency(physicalMemoryBytes: 16 * gib, cpuCount: 8)
        XCTAssertEqual(r16?.directJ, 4)
        XCTAssertEqual(r16?.cpuBake, 2)

        let r24 = S2ArmBuilder.recommendedConcurrency(physicalMemoryBytes: 24 * gib, cpuCount: 10)
        XCTAssertEqual(r24?.directJ, 6)
        XCTAssertEqual(r24?.cpuBake, 3)

        let r32 = S2ArmBuilder.recommendedConcurrency(physicalMemoryBytes: 32 * gib, cpuCount: 12)
        XCTAssertEqual(r32?.directJ, 8)
        XCTAssertEqual(r32?.cpuBake, 4)

        // Clamped by logical CPU count
        let r32SmallCPU = S2ArmBuilder.recommendedConcurrency(physicalMemoryBytes: 32 * gib, cpuCount: 2)
        XCTAssertEqual(r32SmallCPU?.directJ, 2)
        XCTAssertEqual(r32SmallCPU?.cpuBake, 2)

        // Applies defaults when unset
        let defaulted = S2ArmBuilder.environmentWithConcurrencyDefaults(
            into: ["PATH": "/usr/bin"],
            processEnv: [:],
            physicalMemoryBytes: 16 * gib,
            cpuCount: 8
        )
        XCTAssertEqual(defaulted["S2A_DIRECT_J"], "4")
        XCTAssertEqual(defaulted["S2A_CPU_BAKE"], "2")

        // Never overrides explicit values from either env or processEnv
        let explicit = S2ArmBuilder.environmentWithConcurrencyDefaults(
            into: ["S2A_DIRECT_J": "1"],
            processEnv: ["S2A_CPU_BAKE": "3"],
            physicalMemoryBytes: 32 * gib,
            cpuCount: 12
        )
        XCTAssertEqual(explicit["S2A_DIRECT_J"], "1")
        XCTAssertEqual(explicit["S2A_CPU_BAKE"], "3")

        // Below 8 GiB leaves both unset unless explicitly provided
        let small = S2ArmBuilder.environmentWithConcurrencyDefaults(
            into: [:],
            processEnv: [:],
            physicalMemoryBytes: 4 * gib,
            cpuCount: 4
        )
        XCTAssertNil(small["S2A_DIRECT_J"])
        XCTAssertNil(small["S2A_CPU_BAKE"])
    }
}
