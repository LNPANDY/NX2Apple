import XCTest
@testable import NXCore

final class S2ArmMacAppPackerTests: XCTestCase {
    private var temporary: URL!
    private var originalVenvDir = ""

    override func setUpWithError() throws {
        originalVenvDir = Toolchain.venvDir
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("s2arm-packer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        Toolchain.venvDir = originalVenvDir
        try? FileManager.default.removeItem(at: temporary)
    }

    func testNoSpaceAliasReturnsPlainPathUnchangedAndCreatesIdempotentSymlinkForSpacedPaths() throws {
        let fm = FileManager.default
        let plain = temporary.appendingPathComponent("plain-dir", isDirectory: true)
        try fm.createDirectory(at: plain, withIntermediateDirectories: true)
        XCTAssertEqual(S2ArmMacAppPacker.noSpaceAlias(for: plain.path), plain.path)

        let spaced = temporary.appendingPathComponent("Application Support/NX2Apple/my tree", isDirectory: true)
        try fm.createDirectory(at: spaced, withIntermediateDirectories: true)
        let alias1 = S2ArmMacAppPacker.noSpaceAlias(for: spaced.path)
        let alias2 = S2ArmMacAppPacker.noSpaceAlias(for: spaced.path)
        XCTAssertEqual(alias1, alias2)
        XCTAssertNil(alias1.rangeOfCharacter(from: .whitespacesAndNewlines), "Alias must not contain whitespace: \(alias1)")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: alias1), spaced.path)
    }

    func testEnsureHostBinariesRewritesAllSpacedPathsToSpaceFreeMakeArgumentsAndSymlinks() throws {
        let fm = FileManager.default
        let fakeHome = temporary.appendingPathComponent("User Home", isDirectory: true)
        let appSupport = fakeHome.appendingPathComponent("Library/Application Support/NX2Apple", isDirectory: true)
        let upstreamsRoot = appSupport.appendingPathComponent("upstreams", isDirectory: true)
        let s2armTree = upstreamsRoot.appendingPathComponent("s2arm", isDirectory: true)
        try fm.createDirectory(at: s2armTree.appendingPathComponent("launchers/macos"), withIntermediateDirectories: true)
        try Data("all:\n\t@true\n".utf8).write(to: s2armTree.appendingPathComponent("Makefile"))
        try Data("# build.mk\n".utf8).write(to: s2armTree.appendingPathComponent("launchers/macos/build.mk"))

        // Dedicated .venv + runtime tools inside spaced s2arm tree
        let localVenv = s2armTree.appendingPathComponent(".venv", isDirectory: true)
        try fm.createDirectory(at: localVenv.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try Data("home = /usr/bin\n".utf8).write(to: localVenv.appendingPathComponent("pyvenv.cfg"))
        let rtPrefix = URL(fileURLWithPath: S2ArmBootstrap.runtimeToolsPrefix(in: s2armTree.path), isDirectory: true)
        try fm.createDirectory(at: rtPrefix.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: rtPrefix.appendingPathComponent("lib"), withIntermediateDirectories: true)
        for tool in S2ArmBootstrap.requiredRuntimeToolBinaries {
            let p = rtPrefix.appendingPathComponent("bin/\(tool)")
            try Data("#!/bin/sh\n".utf8).write(to: p)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p.path)
        }
        try Data("dylib".utf8).write(to: rtPrefix.appendingPathComponent("lib/libzstd.1.dylib"))

        // Managed venv under a spaced path
        let managedVenv = fakeHome.appendingPathComponent("Library/Application Support/NS Port Builder/venv", isDirectory: true)
        try fm.createDirectory(at: managedVenv.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try Data("home = /usr/bin\n".utf8).write(to: managedVenv.appendingPathComponent("pyvenv.cfg"))
        Toolchain.venvDir = managedVenv.path

        // Managed Bash 5 under spaced path
        let managedBash = URL(fileURLWithPath: S2ArmBootstrap.managedBashPath(home: fakeHome.path))
        try fm.createDirectory(at: managedBash.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho 5\n".utf8).write(to: managedBash)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: managedBash.path)

        // Spaced Xcode developer dir
        let spacedDevDir = temporary.appendingPathComponent("Xcode 27.app/Contents/Developer", isDirectory: true)
        try fm.createDirectory(at: spacedDevDir, withIntermediateDirectories: true)

        var capturedLaunch: ProcessLaunch?
        let runner = FakeProcessRunner()
        runner.answer = { launch in
            if launch.executable == managedBash.path {
                return ProcessResult(status: 0, out: "5\n")
            }
            if launch.executable == "/usr/bin/xcode-select" {
                return ProcessResult(status: 0, out: spacedDevDir.path + "\n")
            }
            if launch.executable == "/usr/bin/make" {
                capturedLaunch = launch
                if let buildArg = launch.arguments.first(where: { $0.hasPrefix("BUILD=") }) {
                    let dir = URL(fileURLWithPath: String(buildArg.dropFirst("BUILD=".count)))
                    try? Data("#!/bin/sh\n".utf8).write(to: dir.appendingPathComponent("s2arm-host"))
                    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("s2arm-host").path)
                    try? Data("dylib".utf8).write(to: dir.appendingPathComponent("libs2a_vaguard.dylib"))
                }
                return ProcessResult(status: 0, out: "")
            }
            return ProcessResult(status: 0, out: "")
        }

        let res = S2ArmMacAppPacker.ensureHostBinaries(
            s2armTree: s2armTree.path,
            upstreamsRoot: upstreamsRoot,
            home: fakeHome.path,
            runner: runner
        )
        switch res {
        case .success(let bins):
            XCTAssertTrue(fm.isExecutableFile(atPath: bins.hostExecutable.path))
            XCTAssertTrue(fm.fileExists(atPath: bins.vaGuardDylib.path))
        case .failure(let err):
            XCTFail("Expected ensureHostBinaries to succeed with spaced paths, got \(err)")
            return
        }

        let makeLaunch = try XCTUnwrap(capturedLaunch)
        let args = makeLaunch.arguments
        let env = makeLaunch.environment ?? [:]

        // Extract -C, ROOT=, BUILD=, SHELL=, DEVELOPER_DIR=
        let cIdx = try XCTUnwrap(args.firstIndex(of: "-C"))
        let cPath = args[cIdx + 1]
        let rootArg = try XCTUnwrap(args.first(where: { $0.hasPrefix("ROOT=") }))
        let rootPath = String(rootArg.dropFirst("ROOT=".count))
        let buildArg = try XCTUnwrap(args.first(where: { $0.hasPrefix("BUILD=") }))
        let buildPath = String(buildArg.dropFirst("BUILD=".count))
        let shellArg = try XCTUnwrap(args.first(where: { $0.hasPrefix("SHELL=") }))
        let shellPath = String(shellArg.dropFirst("SHELL=".count))
        let devArg = try XCTUnwrap(args.first(where: { $0.hasPrefix("DEVELOPER_DIR=") }))
        let devPath = String(devArg.dropFirst("DEVELOPER_DIR=".count))

        for (label, value) in [
            ("-C", cPath),
            ("ROOT", rootPath),
            ("BUILD", buildPath),
            ("SHELL", shellPath),
            ("DEVELOPER_DIR", devPath),
            ("directory", makeLaunch.directory ?? ""),
            ("env.SHELL", env["SHELL"] ?? ""),
            ("env.S2A_ZSTD_LIB", env["S2A_ZSTD_LIB"] ?? ""),
        ] {
            XCTAssertFalse(value.isEmpty, "\(label) must not be empty")
            XCTAssertNil(value.rangeOfCharacter(from: .whitespacesAndNewlines), "\(label) must not contain spaces: \(value)")
        }

        XCTAssertEqual(cPath, rootPath)
        XCTAssertEqual(makeLaunch.directory, cPath)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: cPath), s2armTree.path)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: shellPath), managedBash.path)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: devPath), spacedDevDir.path)

        let expectedCacheDir = upstreamsRoot
            .appendingPathComponent("s2arm-host-cache", isDirectory: true)
            .appendingPathComponent(S2ArmMacAppPacker.hostCacheKey(s2armTree: s2armTree.path), isDirectory: true)
            .path
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: buildPath), expectedCacheDir)

        // Verify prepended PATH entries are space-free and preserve venv pyvenv.cfg parent structure
        let pathParts = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        XCTAssertTrue(pathParts.contains("\(cPath)/.nx2apple-shims"))
        XCTAssertTrue(pathParts.contains("\(cPath)/.venv/bin"))
        XCTAssertTrue(pathParts.contains("\(cPath)/build/macos/runtime-sources/tools/bin"))
        let expectedManagedVenvAlias = S2ArmMacAppPacker.noSpaceAlias(for: managedVenv.path)
        XCTAssertNil(expectedManagedVenvAlias.rangeOfCharacter(from: .whitespacesAndNewlines))
        XCTAssertTrue(pathParts.contains(expectedManagedVenvAlias + "/bin"))
        XCTAssertTrue(fm.fileExists(atPath: expectedManagedVenvAlias + "/pyvenv.cfg"), "Managed venv alias must link the venv root so pyvenv.cfg resolves")
    }

    func testInfoPlistDisablesGameModeAndLauncherSetsRuntimeDirsAndChdirsToDocs() {
        let plist = S2ArmMacAppPacker.infoPlist(titleID: "0100F2C0115B6000", gameName: "TOTK", hasIcon: false)
        XCTAssertEqual(plist["LSSupportsGameMode"] as? Bool, false)

        let src = S2ArmMacAppPacker.launcherCSource
        XCTAssertTrue(src.contains("setenv(\"S2A_SNAPSHOT_DIR\", snapshot_dir, 1);"))
        XCTAssertTrue(src.contains("setenv(\"S2A_CHEATS_DIR\", cheats_dir, 1);"))
        XCTAssertTrue(src.contains("setenv(\"S2A_MODS_DIR\", mods_dir, 1);"))
        XCTAssertTrue(src.contains("(void)chdir(docs_dir);"))
    }
}
