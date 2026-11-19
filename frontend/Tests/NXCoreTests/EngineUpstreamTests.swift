import XCTest
@testable import NXCore

final class EngineUpstreamTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("upstream-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    private func createFiles(_ relativePaths: [String], in base: URL? = nil) throws {
        let root = base ?? tempDir!
        let fm = FileManager.default
        for rel in relativePaths {
            let fileURL = root.appendingPathComponent(rel)
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("test".utf8).write(to: fileURL)
        }
    }

    func testDetectAndIsTreeForNxnative() throws {
        XCTAssertNil(EngineUpstream.detect(in: ""))
        XCTAssertFalse(EngineUpstream.isTree("", kind: .nxnative))

        let emptyFolder = tempDir.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
        XCTAssertNil(EngineUpstream.detect(in: emptyFolder.path))
        XCTAssertFalse(EngineUpstream.isTree(emptyFolder.path, kind: .nxnative))
        XCTAssertNil(EngineLayout.detectedUpstream(emptyFolder.path))
        XCTAssertFalse(EngineLayout.isUpstreamTree(emptyFolder.path, kind: .nxnative))

        let nxnativeTree = tempDir.appendingPathComponent("nxnative-tree")
        try createFiles(["dm/tools/nx_extract/Program.cs"], in: nxnativeTree)
        XCTAssertTrue(EngineUpstream.isTree(nxnativeTree.path, kind: .nxnative))
        XCTAssertEqual(EngineUpstream.detect(in: nxnativeTree.path), .nxnative)
        XCTAssertEqual(EngineLayout.detectedUpstream(nxnativeTree.path), .nxnative)
        XCTAssertTrue(EngineLayout.isUpstreamTree(nxnativeTree.path, kind: .nxnative))
        XCTAssertTrue(EngineLayout.isCheckout(nxnativeTree.path))

        let checkoutWithEngineTool = tempDir.appendingPathComponent("checkout")
        try createFiles(["tools/engine.py", ".upstream-ref"], in: checkoutWithEngineTool)
        XCTAssertEqual(EngineUpstream.detect(in: checkoutWithEngineTool.path), .nxnative)
        XCTAssertEqual(EngineLayout.detectedUpstream(checkoutWithEngineTool.path), .nxnative)
        XCTAssertTrue(EngineLayout.isCheckout(checkoutWithEngineTool.path))

        let syncedCheckout = tempDir.appendingPathComponent("synced-checkout")
        try createFiles(["engine/dm/tools/nx_extract/Program.cs"], in: syncedCheckout)
        XCTAssertEqual(EngineUpstream.detect(in: syncedCheckout.path), .nxnative)
        XCTAssertTrue(EngineLayout.isCheckout(syncedCheckout.path))
    }

    func testDetectAndIsTreeForS2Arm() throws {
        let s2armTree = tempDir.appendingPathComponent("s2arm-tree")
        try createFiles(["pack/jobs/main.py", "runtime/rewriter/rewriter.c"], in: s2armTree)
        XCTAssertTrue(EngineUpstream.isTree(s2armTree.path, kind: .s2arm))
        XCTAssertFalse(EngineUpstream.isTree(s2armTree.path, kind: .nxnative))
        XCTAssertFalse(EngineUpstream.isTree(s2armTree.path, kind: .macNativeGames))
        XCTAssertEqual(EngineUpstream.detect(in: s2armTree.path), .s2arm)
        XCTAssertEqual(EngineLayout.detectedUpstream(s2armTree.path), .s2arm)
        XCTAssertFalse(EngineLayout.isCheckout(s2armTree.path))
    }

    func testDetectAndIsTreeForMacNativeGames() throws {
        let mngTree = tempDir.appendingPathComponent("mng-tree")
        try createFiles(["build_app.py", "games/totk/README.md"], in: mngTree)
        XCTAssertTrue(EngineUpstream.isTree(mngTree.path, kind: .macNativeGames))
        XCTAssertFalse(EngineUpstream.isTree(mngTree.path, kind: .nxnative))
        XCTAssertFalse(EngineUpstream.isTree(mngTree.path, kind: .s2arm))
        XCTAssertEqual(EngineUpstream.detect(in: mngTree.path), .macNativeGames)
        XCTAssertEqual(EngineLayout.detectedUpstream(mngTree.path), .macNativeGames)
        XCTAssertFalse(EngineLayout.isCheckout(mngTree.path))
    }

    func testMissingToolsForUpstreams() throws {
        let repo = tempDir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

        XCTAssertEqual(RepoLayout.missingTools(in: repo.path), [RepoLayout.buildScript, RepoLayout.romfsImageTool])
        XCTAssertEqual(RepoLayout.missingTools(in: repo.path, for: .nxnative), [RepoLayout.buildScript, RepoLayout.romfsImageTool])
        XCTAssertEqual(RepoLayout.missingTools(in: repo.path, for: .s2arm), ["pack/jobs/main.py"])
        XCTAssertEqual(RepoLayout.missingTools(in: repo.path, for: .macNativeGames), ["build_app.py"])

        try createFiles([RepoLayout.buildScript, RepoLayout.romfsImageTool], in: repo)
        XCTAssertEqual(RepoLayout.missingTools(in: repo.path, for: .nxnative), [])

        try createFiles(["pack/jobs/main.py"], in: repo)
        XCTAssertEqual(RepoLayout.missingTools(in: repo.path, for: .s2arm), [])

        try createFiles(["build_app.py"], in: repo)
        XCTAssertEqual(RepoLayout.missingTools(in: repo.path, for: .macNativeGames), [])
    }

    private func createFakeApp(
        name: String,
        plist: [String: Any],
        executables: [String],
        plainFiles: [String] = []
    ) throws -> URL {
        let appURL = tempDir.appendingPathComponent(name + ".app")
        let contents = appURL.appendingPathComponent("Contents")
        let macos = contents.appendingPathComponent("MacOS")
        let fm = FileManager.default
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)

        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))

        for exe in executables {
            let exeURL = macos.appendingPathComponent(exe)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: exeURL)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exeURL.path)
        }
        for file in plainFiles {
            let fileURL = macos.appendingPathComponent(file)
            try Data("binary".utf8).write(to: fileURL)
        }
        return appURL
    }

    func testMacGameBundleReadsNxnativeApp() throws {
        let app = try createFakeApp(
            name: "NxnativeGame",
            plist: [
                "DMTitleID": "0100000000010000",
                "CFBundleExecutable": "nxnative",
                "CFBundleName": "Nxnative Game"
            ],
            executables: ["nxnative", "dmhost"]
        )
        let bundle = try MacGameBundle.read(app)
        XCTAssertEqual(bundle.titleID, "0100000000010000")
        XCTAssertEqual(bundle.name, "Nxnative Game")
        XCTAssertEqual(bundle.upstream, .nxnative)

        try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/MacOS/dmhost"))
        XCTAssertThrowsError(try MacGameBundle.read(app))
    }

    func testMacGameBundleReadsMacNativeGames() throws {
        let totkApp = try createFakeApp(
            name: "TOTK",
            plist: [
                "CFBundleIdentifier": "org.macnativegames.totk",
                "CFBundleExecutable": "TOTK",
                "CFBundleDisplayName": "Tears of the Kingdom",
                "DMUpstream": "   "
            ],
            executables: ["TOTK"]
        )
        let totkBundle = try MacGameBundle.read(totkApp)
        XCTAssertEqual(totkBundle.titleID, "0100F2C0115B6000")
        XCTAssertEqual(totkBundle.name, "Tears of the Kingdom")
        XCTAssertEqual(totkBundle.upstream, .macNativeGames)

        let ootApp = try createFakeApp(
            name: "OOT",
            plist: [
                "CFBundleIdentifier": "org.macnativegames.oot",
                "CFBundleExecutable": "OOT",
                "CFBundleName": "Ocarina of Time"
            ],
            executables: ["OOT"]
        )
        let ootBundle = try MacGameBundle.read(ootApp)
        XCTAssertEqual(ootBundle.titleID, "0400486024DEC000")
        XCTAssertEqual(ootBundle.upstream, .macNativeGames)

        let subBundle = try createFakeApp(
            name: "Shaders",
            plist: [
                "CFBundleIdentifier": "org.macnativegames.totk.shaders.v0",
                "CFBundleExecutable": "Shaders",
                "CFBundlePackageType": "BNDL"
            ],
            executables: ["Shaders"]
        )
        XCTAssertThrowsError(try MacGameBundle.read(subBundle))

        let launcherSub = try createFakeApp(
            name: "Launcher",
            plist: [
                "CFBundleIdentifier": "org.macnativegames.launcher",
                "CFBundleExecutable": "launcher"
            ],
            executables: ["launcher"]
        )
        XCTAssertThrowsError(try MacGameBundle.read(launcherSub))
    }

    func testMacGameBundleReadsS2Arm() throws {
        let s2aApp = try createFakeApp(
            name: "S2AGame",
            plist: [
                "CFBundleIdentifier": "org.s2arm.macos.game",
                "CFBundleExecutable": "s2arm-host",
                "S2ATitleID": "0100F2C0115B6000",
                "CFBundleName": "S2A Game"
            ],
            executables: ["s2arm-host"],
            plainFiles: ["libs2a_vaguard.dylib"]
        )
        let bundle = try MacGameBundle.read(s2aApp)
        XCTAssertEqual(bundle.titleID, "0100F2C0115B6000")
        XCTAssertEqual(bundle.name, "S2A Game")
        XCTAssertEqual(bundle.upstream, .s2arm)

        try FileManager.default.removeItem(at: s2aApp.appendingPathComponent("Contents/MacOS/libs2a_vaguard.dylib"))
        XCTAssertThrowsError(try MacGameBundle.read(s2aApp))
    }

    func testMacGameBundleRejectsNonGameApp() throws {
        let safariApp = try createFakeApp(
            name: "Safari",
            plist: [
                "CFBundleIdentifier": "com.apple.Safari",
                "CFBundleExecutable": "Safari"
            ],
            executables: ["Safari"]
        )
        XCTAssertThrowsError(try MacGameBundle.read(safariApp))
    }
}
