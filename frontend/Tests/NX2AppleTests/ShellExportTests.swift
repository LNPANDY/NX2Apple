import XCTest
import Combine
@testable import NX2Apple
@testable import NXCore
import NXModel
@testable import NXLauncher

/// LNPANDY/NX2Apple#416: the shared app as an unsigned IPA. The commands are checked as pure functions. The export runs headless
/// against a stand-in `xcrun` (xcodebuild only: it makes an app folder) and a stand-in build_shell.sh, while ditto, xattr and codesign
/// are the system's. No test builds a real app, reaches a device or needs a signing team.
@MainActor final class ShellExportTests: IsolatedDefaultsTestCase {
    private var temporary: URL!
    private let fm = FileManager.default
    private let titleID = "0100535012974000"

    override func setUpWithError() throws {
        temporary = fm.temporaryDirectory.appendingPathComponent("nspb-export-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try fm.removeItem(at: temporary) }

    private func path(_ parts: String...) -> String { parts.reduce(temporary.path) { $0 + "/" + $1 } }
    private var state: String { path("state") }
    private func write(_ file: String, _ text: String) throws {
        try fm.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: file, atomically: true, encoding: .utf8)
    }
    private var calls: [String] { ((try? String(contentsOfFile: state + "/calls.txt", encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }

    // ---- the commands ----

    func testCommandsAreExact() {
        let root = "/R/NX2Apple-shell"
        XCTAssertEqual(ShellInstall.ipaPath(root: root), root + "/export/NX2Apple.ipa")
        XCTAssertEqual(ShellInstall.exportAppPath(root: root), root + "/export/derived-data/Build/Products/Release-iphoneos/DmShell.app")
        // not the install's derived data: the signed app of an install, a reinstall and a re-sign stays where it is
        XCTAssertNotEqual(ShellInstall.exportDerivedData(root: root), ShellInstall.derivedData(root: root))
        let build = ShellInstall.exportBuildCommand(xcrun: "/x", root: root, bundleID: "org.nxnative.shell")
        XCTAssertEqual(build, ["/x", "xcodebuild", "-project", root + "/project/DmShell.xcodeproj", "-scheme", "DmShell", "-configuration", "Release",
                               "-destination", "generic/platform=iOS", "-derivedDataPath", root + "/export/derived-data",
                               "PRODUCT_BUNDLE_IDENTIFIER=org.nxnative.shell", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO",
                               "CODE_SIGN_IDENTITY=", "build"])
        // no team, no device, no provisioning
        XCTAssertFalse(build.contains { $0.hasPrefix("DEVELOPMENT_TEAM") || $0 == "-allowProvisioningUpdates" || $0.hasPrefix("id=") })
        XCTAssertEqual(ShellInstall.entitlementsPath(root: root), root + "/project/Gen/DmShell.entitlements")
        let stagedApp = root + "/export/stage/Payload/DmShell.app"
        XCTAssertEqual(ShellInstall.entitlementsCommand(app: stagedApp, entitlements: "/e.plist"),
                       ["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", "/e.plist", stagedApp + "/DmShell"])
        XCTAssertEqual(ShellInstall.zipCommand(root: root),
                       ["/usr/bin/ditto", "-c", "-k", "--norsrc", "--keepParent", root + "/export/stage/Payload", root + "/export/NX2Apple.ipa"])
    }

    func testTheBuildScriptTakesNoTeamForAnExport() {
        XCTAssertEqual(ShellInstall.buildArguments(workDir: "/W", team: ""), ["--shell-framework", "/W/shell-framework"])
        XCTAssertEqual(ShellInstall.buildArguments(workDir: "/W", team: "T"), ["--shell-framework", "/W/shell-framework", "--team-id", "T"])
    }

    // ---- the stand-ins ----

    /// xcodebuild only: it makes the unsigned app (an executable and one embedded framework) in the derived data it is given.
    private func makeXcrun() throws -> String {
        try fm.createDirectory(atPath: state, withIntermediateDirectories: true)
        let xcrun = path("xcrun")
        try """
        #!/usr/bin/python3
        import sys, os, json
        a = sys.argv[1:]
        open('\(state)/calls.txt', 'a').write(' '.join(a) + '\\n')
        def val(flag): return a[a.index(flag) + 1] if flag in a else None
        if a[0] == 'xcodebuild':
            if os.path.exists('\(state)/xcode-fails'):
                print('error: Build input file cannot be found: DmShell.m', flush=True)
                sys.exit(65)
            app = val('-derivedDataPath') + '/Build/Products/Release-iphoneos/DmShell.app'
            os.makedirs(app + '/Frameworks/DmGame\(titleID).framework', exist_ok=True)
            if not os.path.exists(app + '/DmShell'):
                open(app + '/DmShell', 'w').write('not a real executable')
                open(app + '/Info.plist', 'w').write('plist')
            open(app + '/Frameworks/DmGame\(titleID).framework/DmGame\(titleID)', 'w').write('framework')
            print('Build succeeded', flush=True)
        elif a[:3] == ['devicectl', 'list', 'devices']:
            json.dump({'info': {'outcome': 'success'}, 'result': {'devices': [{
                'hardwareProperties': {'udid': 'DEV-1', 'reality': 'physical', 'platform': 'iOS', 'marketingName': 'iPhone'},
                'deviceProperties': {'name': 'Z', 'osVersionNumber': '27.0'},
                'connectionProperties': {'pairingState': 'paired', 'tunnelState': 'connected', 'transportType': 'wired'}}]}}, open(val('--json-output'), 'w'))
        elif a[:4] == ['devicectl', 'device', 'info', 'files']:
            listing = '\(state)/files.json'
            if os.path.exists(listing):
                open(val('--json-output'), 'w').write(open(listing).read())
            else:
                json.dump({'error': {'code': 6}, 'info': {'outcome': 'failed'}}, open(val('--json-output'), 'w'))
                sys.exit(1)
        elif a[:4] == ['devicectl', 'device', 'copy', 'from']:
            sys.exit(1)   # no shell log
        elif a[:4] == ['devicectl', 'device', 'copy', 'to']:
            if os.path.exists('\(state)/refuse'):
                words = open('\(state)/refuse').read()
                print(words or 'ERROR: Failed to copy: the app does not allow access to its data container (get-task-allow). (com.apple.dt.CoreDeviceError error 7)', flush=True)
                sys.exit(1)
            print('Copied', flush=True)
        elif a[:4] == ['devicectl', 'device', 'info', 'apps']:
            if os.path.exists('\(state)/apps-locked'):
                print('ERROR: The device is locked. (com.apple.dt.CoreDeviceError error 4)', flush=True)
                sys.exit(1)
            src = '\(state)/apps.json'
            if os.path.exists(src): open(val('--json-output'), 'w').write(open(src).read())
            else: json.dump({'result': {'apps': []}}, open(val('--json-output'), 'w'))
        else:
            print('unexpected: ' + ' '.join(a), flush=True)
            sys.exit(1)
        """.write(toFile: xcrun, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xcrun)
        return xcrun
    }

    /// A checkout with a stand-in build_shell.sh: it records its environment and writes the project with its entitlements file.
    private func makeRepo(entitlements: Bool = true) throws -> String {
        let repo = path("repo")
        try write(repo + "/dm/ios/tools/build_shell.sh", """
        #!/bin/bash
        [ "$1" = "--prepare-xcode" ] || { echo "FAIL: no --prepare-xcode"; exit 1; }
        mkdir -p "$SHELL_DIR/DmShell.xcodeproj" "$SHELL_DIR/Gen"
        env | sort > "\(state)/shell-env.txt"
        \(entitlements ? "echo '<plist/>' > \"$SHELL_DIR/Gen/DmShell.entitlements\"" : "true")
        """)
        try write(repo + "/frontend-ios/Package.swift", "// swift-tools-version: 5.9\n")
        return repo
    }

    private struct Fixture { var xcrun: String, repo: String, framework: String, root: String }

    private func makeFixture(entitlements: Bool = true) throws -> Fixture {
        guard fm.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("System Python is required for the process fixture") }
        let framework = path("work/shell-framework/DmGame\(titleID).framework")
        try write(framework + "/game.manifest.json", "{}")
        try write(framework + "/DmGame\(titleID)", "executable")
        return Fixture(xcrun: try makeXcrun(), repo: try makeRepo(entitlements: entitlements), framework: framework, root: path("shell-root"))
    }

    /// No device and no team: the installer is made the way the export needs it.
    private func installer(_ f: Fixture) -> ShellInstaller {
        var i = ShellInstaller(xcrun: f.xcrun, repo: f.repo, python: "/usr/bin/python3", root: f.root, device: "", team: "")
        i.resources = nil
        return i
    }

    private func entries(ofZip file: String) throws -> [String] {
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-Z1", file]
        let pipe = Pipe()
        unzip.standardOutput = pipe
        try unzip.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        unzip.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// Exercise the real packaging steps on a small fixture at a lowered ZIP entry limit.
    private func pack(_ f: Fixture, games: [String]? = nil, limit: Int, using customInstaller: ShellInstaller? = nil) -> ShellInstaller.Outcome {
        let names = games ?? [URL(fileURLWithPath: f.framework).lastPathComponent]
        let library = ShellLibrary(games: names.map {
            ShellLibrary.Game(titleID: ShellInstall.titleID(ofFramework: $0), name: "Test Game", framework: $0)
        })
        return (customInstaller ?? installer(f)).packExport(app: URL(fileURLWithPath: ShellInstall.exportAppPath(root: f.root)), library: library, entryLimit: limit)
    }

    // ---- the export ----

    func testExportMakesAnIPAWithPayloadAndTheFrameworksAndNeedsNoDeviceOrTeam() throws {
        let f = try makeFixture()
        let outcome = installer(f).export(framework: f.framework, titleID: titleID, name: "Test Game")
        XCTAssertTrue(outcome.ok, outcome.message)
        XCTAssertEqual(outcome.ipaPath, ShellInstall.ipaPath(root: f.root))
        XCTAssertEqual(outcome.message, String(format: L10n.string("shell.exportDone", .en), outcome.ipaPath))
        XCTAssertTrue(fm.fileExists(atPath: outcome.ipaPath))

        let names = try entries(ofZip: outcome.ipaPath)
        XCTAssertTrue(names.contains("Payload/DmShell.app/DmShell"), names.joined(separator: "\n"))
        XCTAssertTrue(names.contains("Payload/DmShell.app/Frameworks/DmGame\(titleID).framework/DmGame\(titleID)"), names.joined(separator: "\n"))
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("Payload/") && !$0.contains("__MACOSX") }, names.joined(separator: "\n"))

        let xcodebuild = try XCTUnwrap(calls.first { $0.hasPrefix("xcodebuild") })
        XCTAssertTrue(xcodebuild.contains("CODE_SIGNING_ALLOWED=NO") && xcodebuild.contains("-destination generic/platform=iOS"), xcodebuild)
        XCTAssertFalse(xcodebuild.contains("DEVELOPMENT_TEAM") || xcodebuild.contains("-allowProvisioningUpdates"), xcodebuild)
        XCTAssertFalse(calls.contains { $0.hasPrefix("devicectl") }, "no device is asked")
        XCTAssertFalse(fm.fileExists(atPath: ShellInstall.derivedData(root: f.root)), "the install's derived data stays untouched")
        XCTAssertFalse(fm.fileExists(atPath: ShellInstall.exportStage(root: f.root)), "the stage folder is removed")
        // the project script gets an empty team (it falls back to its placeholder) and this game's framework
        let env = try String(contentsOfFile: state + "/shell-env.txt", encoding: .utf8)
        XCTAssertTrue(env.contains("\nDM_TEAM_ID=\n") || env.hasPrefix("DM_TEAM_ID=\n"), env)
        XCTAssertTrue(env.contains("DM_SHELL_FRAMEWORKS=" + ShellInstall.mirroredFramework(root: f.root, titleID: titleID)), env)
        XCTAssertEqual(ShellLibrary.load(root: f.root).games.map(\.titleID), [titleID])
    }

    func testExportKeepsTheTeamAnEarlierInstallStored() throws {
        let f = try makeFixture()
        var library = ShellLibrary()
        library.team = "TEAM123456"
        try library.save(root: f.root)
        XCTAssertTrue(installer(f).export(framework: f.framework, titleID: titleID, name: "Test Game").ok)
        XCTAssertEqual(ShellLibrary.load(root: f.root).team, "TEAM123456")
    }

    func testSmallExportKeepsLooseShadersUntilTheEntirePayloadExceedsTheLimit() throws {
        let f = try makeFixture(entitlements: false)
        let shader = "Frameworks/DmGame\(titleID).framework/msl/b-test/shader.json"
        try write(ShellInstall.exportAppPath(root: f.root) + "/" + shader, "reflection")
        let original = installer(f).export(framework: f.framework, titleID: titleID, name: "Test Game")
        XCTAssertTrue(original.ok, original.message)
        let names = try entries(ofZip: original.ipaPath)
        XCTAssertTrue(names.contains("Payload/DmShell.app/" + shader))
        XCTAssertFalse(names.contains { $0.hasSuffix(".aar") })
        let atLimit = pack(f, limit: names.count)
        XCTAssertTrue(atLimit.ok, atLimit.message)
        XCTAssertEqual(Set(try entries(ofZip: atLimit.ipaPath)), Set(names))
        let overLimit = pack(f, limit: names.count - 1)
        XCTAssertTrue(overLimit.ok, overLimit.message)
        XCTAssertEqual(try entries(ofZip: overLimit.ipaPath).filter { $0.hasSuffix(".aar") }.count, 1)
    }

    func testExportPacksEachGamesShaderBytesAndPreservesTheBuiltFrameworks() throws {
        let f = try makeFixture(entitlements: false)
        let app = ShellInstall.exportAppPath(root: f.root)
        let games = ["DmGame\(titleID).framework", "DmGame0100000000000002.framework"]
        for (index, game) in games.enumerated() {
            let chain = app + "/Frameworks/\(game)/msl/b-test"
            try write(chain + "/shader.json", "{\"game\":\(index)}")
            try Data([0, 255, UInt8(index)]).write(to: URL(fileURLWithPath: chain + "/shader.metallib"))
        }
        let old = "msl-\(UUID().uuidString).aar"
        let builtGame = app + "/Frameworks/" + games[0]
        try write(builtGame + "/" + old, "previous packed copy")
        try write(builtGame + "/msl-custom.aar", "unrelated resource")
        let unrelated = "Frameworks/GraphicsSupport.framework/msl/library.bin"
        try write(app + "/" + unrelated, "third-party resource")

        let outcome = pack(f, games: games, limit: 2)
        XCTAssertTrue(outcome.ok, outcome.message)
        let unpacked = path("unpacked")
        let tool = SystemProcessRunner()
        let unzip = tool.capture(ProcessLaunch(["/usr/bin/ditto", "-x", "-k", outcome.ipaPath, unpacked], mergesErrors: true))
        XCTAssertTrue(unzip.ok, unzip.out)
        var names = Set<String>()
        for game in games {
            let fw = URL(fileURLWithPath: unpacked + "/Payload/DmShell.app/Frameworks/" + game)
            let archives = try fm.contentsOfDirectory(at: fw, includingPropertiesForKeys: nil).filter { $0.pathExtension == "aar" && $0.lastPathComponent != "msl-custom.aar" }
            XCTAssertEqual(archives.count, 1)
            let archive = try XCTUnwrap(archives.first)
            let stem = archive.deletingPathExtension().lastPathComponent
            XCTAssertTrue(stem.hasPrefix("msl-"))
            XCTAssertNotNil(UUID(uuidString: String(stem.dropFirst(4))))
            names.insert(stem)
            XCTAssertFalse(fm.fileExists(atPath: fw.appendingPathComponent("msl").path))
            let restored = URL(fileURLWithPath: path("restored", game))
            try fm.createDirectory(at: restored, withIntermediateDirectories: true)
            let extract = tool.capture(ProcessLaunch(["/usr/bin/aa", "extract", "-i", archive.path, "-d", restored.path], mergesErrors: true))
            XCTAssertTrue(extract.ok, extract.out)
            for file in ["shader.json", "shader.metallib"] {
                let original = URL(fileURLWithPath: app + "/Frameworks/\(game)/msl/b-test/" + file)
                XCTAssertEqual(try Data(contentsOf: restored.appendingPathComponent("b-test/" + file)), try Data(contentsOf: original))
            }
        }
        XCTAssertEqual(names.count, games.count)
        XCTAssertFalse(fm.fileExists(atPath: unpacked + "/Payload/DmShell.app/Frameworks/" + games[0] + "/" + old))
        XCTAssertEqual(try String(contentsOfFile: builtGame + "/" + old, encoding: .utf8), "previous packed copy")
        XCTAssertEqual(try String(contentsOfFile: unpacked + "/Payload/DmShell.app/Frameworks/" + games[0] + "/msl-custom.aar", encoding: .utf8), "unrelated resource")
        XCTAssertEqual(try String(contentsOfFile: unpacked + "/Payload/DmShell.app/" + unrelated, encoding: .utf8), "third-party resource")
        let again = pack(f, games: games, limit: 2)
        XCTAssertTrue(again.ok, again.message)
        let next = try entries(ofZip: again.ipaPath).map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
        XCTAssertTrue(names.isDisjoint(with: next))
        XCTAssertEqual(next.filter { $0.hasPrefix("msl-") && UUID(uuidString: String($0.dropFirst(4))) != nil }.count, games.count)
    }

    func testFailedShaderArchiveFailsTheExportAndClearsTheStage() throws {
        let f = try makeFixture(entitlements: false)
        let relative = "Frameworks/DmGame\(titleID).framework/msl"
        let built = ShellInstall.exportAppPath(root: f.root) + "/" + relative
        try write(built + "/shader.json", "reflection")
        var i = installer(f)
        let stage = ShellInstall.exportStage(root: f.root)
        // Lose the staged input just as aa runs to exercise a real archiver error.
        i.log = { line in
            if line.contains("/usr/bin/aa archive ") {
                try? self.fm.removeItem(atPath: stage + "/Payload/DmShell.app/" + relative)
            }
        }
        let outcome = pack(f, limit: 2, using: i)
        XCTAssertFalse(outcome.ok)
        XCTAssertFalse(fm.fileExists(atPath: ShellInstall.ipaPath(root: f.root)))
        XCTAssertFalse(fm.fileExists(atPath: stage))
        XCTAssertTrue(fm.fileExists(atPath: built + "/shader.json"))
    }

    func testSignatureSealsThePackedShadersWithoutSigningTheBuiltApp() throws {
        let f = try makeFixture(entitlements: false)
        let app = ShellInstall.exportAppPath(root: f.root)
        let framework = "Frameworks/DmGame\(titleID).framework"
        try write(app + "/" + framework + "/msl/b-test/shader.json", "reflection")
        let info = ["CFBundleIdentifier": "org.nxnative.shell", "CFBundleExecutable": "DmShell", "CFBundleName": "DmShell", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: URL(fileURLWithPath: app + "/Info.plist"))
        try write(ShellInstall.entitlementsPath(root: f.root),
                  "<plist version=\"1.0\"><dict><key>com.apple.developer.kernel.increased-memory-limit</key><true/></dict></plist>")
        try write(path("test.c"), "int main(void) { return 0; }")
        let tool = SystemProcessRunner()
        let compiled = tool.capture(ProcessLaunch(["/usr/bin/xcrun", "--sdk", "macosx", "clang", "-arch", "arm64", path("test.c"), "-o", app + "/DmShell"], mergesErrors: true))
        XCTAssertTrue(compiled.ok, compiled.out)
        let originalURL = URL(fileURLWithPath: app + "/DmShell")
        let original = try Data(contentsOf: originalURL)

        let outcome = pack(f, limit: 2)
        XCTAssertTrue(outcome.ok, outcome.message)
        XCTAssertEqual(try Data(contentsOf: originalURL), original)
        XCTAssertFalse(fm.fileExists(atPath: app + "/_CodeSignature"))
        let exported = path("unpacked", "Payload", "DmShell.app")
        let unpack = tool.capture(ProcessLaunch(["/usr/bin/ditto", "-x", "-k", outcome.ipaPath, path("unpacked")], mergesErrors: true))
        XCTAssertTrue(unpack.ok, unpack.out)
        let resources = try Data(contentsOf: URL(fileURLWithPath: exported + "/_CodeSignature/CodeResources"))
        let seal = try XCTUnwrap(PropertyListSerialization.propertyList(from: resources, format: nil) as? [String: Any])
        let files = try XCTUnwrap(seal["files2"] as? [String: Any])
        let archive = try XCTUnwrap(files.keys.first { $0.hasPrefix(framework + "/msl-") && $0.hasSuffix(".aar") })
        XCTAssertTrue(fm.fileExists(atPath: exported + "/" + archive))
        XCTAssertFalse(files.keys.contains { $0.hasPrefix(framework + "/msl/") })
        let verified = tool.capture(ProcessLaunch(["/usr/bin/codesign", "--verify", "--strict", exported + "/DmShell"], mergesErrors: true))
        XCTAssertTrue(verified.ok, verified.out)
    }

    func testFailedZipRemovesItsPartialIPA() throws {
        let f = try makeFixture(entitlements: false)
        let stage = ShellInstall.exportStage(root: f.root), ipa = ShellInstall.ipaPath(root: f.root)
        var i = installer(f)
        i.log = { line in
            if line.contains("/usr/bin/ditto -c -k ") {
                try? self.fm.removeItem(atPath: stage + "/Payload")
                try? self.write(ipa, "partial")
            }
        }
        let outcome = i.export(framework: f.framework, titleID: titleID, name: "Test Game")
        XCTAssertFalse(outcome.ok)
        XCTAssertFalse(fm.fileExists(atPath: ipa))
        XCTAssertFalse(fm.fileExists(atPath: stage))
    }

    func testLargeShaderLibraryLeavesAllIPAEntriesVisibleToZIP32Readers() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NX2APPLE_LARGE_IPA_TEST"] == "1", "Opt in to creating 65,536 shader files")
        let f = try makeFixture(entitlements: false)
        let chain = ShellInstall.exportAppPath(root: f.root) + "/Frameworks/DmGame\(titleID).framework/msl/b-test"
        try fm.createDirectory(atPath: chain, withIntermediateDirectories: true)
        for key in 0...Int(UInt16.max) {
            guard fm.createFile(atPath: chain + "/\(key).json", contents: Data()) else { throw CocoaError(.fileWriteUnknown) }
        }
        let outcome = installer(f).export(framework: f.framework, titleID: titleID, name: "Test Game")
        XCTAssertTrue(outcome.ok, outcome.message)
        let names = try entries(ofZip: outcome.ipaPath)
        XCTAssertEqual(names.count, 8)   // Payload/, app/, Frameworks/, framework/, two executables, Info.plist, one shader archive
        XCTAssertTrue(names.contains("Payload/DmShell.app/Info.plist"))
        XCTAssertEqual(names.filter { $0.hasSuffix(".aar") }.count, 1)
        // The count a ZIP32 reader actually sees in ditto's end-of-central-directory record.
        let end = try Data(contentsOf: URL(fileURLWithPath: outcome.ipaPath), options: .mappedIfSafe).suffix(22)
        XCTAssertEqual(Array(end.prefix(4)), [0x50, 0x4b, 0x05, 0x06])
        XCTAssertEqual(Array(end.dropFirst(10).prefix(2)), [8, 0])
    }

    func testAnExportReplacesTheIPAOfTheLastOne() throws {
        let f = try makeFixture()
        try write(ShellInstall.ipaPath(root: f.root), "old")
        let outcome = installer(f).export(framework: f.framework, titleID: titleID, name: "Test Game")
        XCTAssertTrue(outcome.ok, outcome.message)
        XCTAssertFalse(try entries(ofZip: outcome.ipaPath).isEmpty)
    }

    func testAFailingBuildReachesThePlayerAndLeavesNoIPA() throws {
        let f = try makeFixture()
        try write(state + "/xcode-fails", "")
        let outcome = installer(f).export(framework: f.framework, titleID: titleID, name: "Test Game")
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.message, String(format: L10n.string("shell.exportFailed", .en), "error: Build input file cannot be found: DmShell.m"))
        XCTAssertFalse(fm.fileExists(atPath: ShellInstall.ipaPath(root: f.root)))
    }

    func testAnAppWithoutEntitlementsFileStillExports() throws {
        let f = try makeFixture(entitlements: false)
        var logged = ""
        var i = installer(f)
        i.log = { logged += $0 }
        let outcome = i.export(framework: f.framework, titleID: titleID, name: "Test Game")
        XCTAssertTrue(outcome.ok, outcome.message)
        XCTAssertTrue(logged.contains("no entitlements file"), logged)
    }

    func testAMissingFrameworkStopsBeforeAnyTool() throws {
        let f = try makeFixture()
        let outcome = installer(f).export(framework: path("nowhere.framework"), titleID: titleID, name: "Test Game")
        XCTAssertFalse(outcome.ok)
        XCTAssertTrue(calls.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: state + "/shell-env.txt"))
    }

    /// #491: the build steps were green and the Builds page ended in "The game's framework was not found: <path>", cut off.
    func testAMissingFrameworkNamesTheGameAndKeepsThePathInTheLogOnly() throws {
        let f = try makeFixture()
        let missing = path("work/shell-framework/DmGame\(titleID).framework.gone")
        var logged = ""
        var i = installer(f)
        i.log = { logged += $0 }
        let outcome = i.export(framework: missing, titleID: titleID, name: "Test Game")
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.message, String(format: L10n.string("shell.noFramework", .en), "Test Game", "shell-framework"))
        XCTAssertTrue(outcome.message.contains("Test Game"), outcome.message)
        XCTAssertFalse(outcome.message.contains("/"), outcome.message)
        XCTAssertTrue(outcome.message.contains("open an issue"), outcome.message)
        for lang in Lang.all {
            XCTAssertFalse(L10n.string("shell.noFramework", lang).contains(";"), lang.code)
            XCTAssertTrue(L10n.string("shell.noFramework", lang).contains("%2$@"), lang.code)
        }
        XCTAssertTrue(logged.contains(missing), logged)
        // the install path says the same
        let installed = i.install(framework: missing, titleID: titleID, name: "Test Game", archive: "")
        XCTAssertEqual(installed.message, outcome.message)
    }

    // ---- a framework that a cut-off delete or copy left incomplete ----

    /// v1.0.2-rc1: the launcher was quit while the stale prompt deleted Breath of the Wild's framework (a minute for its shader files).
    /// shell.json still named the half framework, and the next build of Hades failed at "Prepare the shared app" with only its path.
    func testAnotherGamesIncompleteFrameworkIsLeftOutNamedAndNotShipped() throws {
        let f = try makeFixture()
        let otherID = "01007EF00011E000"
        let half = ShellInstall.mirroredFramework(root: f.root, titleID: otherID)
        try write(half + "/Info.plist", "plist")
        try write(half + "/msl/b-e65a4ebd3322/0000.metallib", "shader")
        var library = ShellLibrary()
        library.add(.init(titleID: otherID, name: "Zelda Breath of the Wild", framework: half))
        try library.save(root: f.root)
        var logged = ""
        var i = installer(f)
        i.log = { logged += $0 }
        i.banners = URL(fileURLWithPath: path("banners"))
        let outcome = i.export(framework: f.framework, titleID: titleID, name: "Hades")
        XCTAssertTrue(outcome.ok, outcome.message)
        let env = try String(contentsOfFile: state + "/shell-env.txt", encoding: .utf8)
        XCTAssertFalse(env.contains(otherID), "the half framework does not go into the app: " + env)
        XCTAssertEqual(ShellLibrary.load(root: f.root).games.map(\.titleID), [titleID])
        let note = String(format: L10n.string("shell.gameLeftOut", .en), "Zelda Breath of the Wild", "game.manifest.json")
        XCTAssertTrue(outcome.message.hasSuffix(note), outcome.message)
        XCTAssertTrue(logged.contains(note), logged)
        XCTAssertFalse(fm.fileExists(atPath: half), "the half mirror is taken away")
    }

    /// Build A (Breath of the Wild) is stopped while the build script copies its framework, then build B (Hades) runs. A's framework
    /// in its build folder is half written, and a library entry from before the mirror still points there. B's shared app leaves A out,
    /// does not mirror the half framework and does not delete it either: the build folder belongs to A's next build.
    func testAStoppedBuildsHalfFrameworkInItsBuildFolderIsLeftOutOfTheNextGamesSharedApp() throws {
        let f = try makeFixture()
        let otherID = "01007EF00011E000"
        let half = path("botw/01007EF00011E000_build/shell-framework/DmGame\(otherID).framework")
        try write(half + "/Info.plist", "plist")
        try write(half + "/pso/archive.tsv", "pso")
        var library = ShellLibrary()
        library.add(.init(titleID: otherID, name: "Zelda Breath of the Wild", framework: half))
        try library.save(root: f.root)
        var i = installer(f)
        i.banners = URL(fileURLWithPath: path("banners"))
        let outcome = i.export(framework: f.framework, titleID: titleID, name: "Hades")
        XCTAssertTrue(outcome.ok, outcome.message)
        let env = try String(contentsOfFile: state + "/shell-env.txt", encoding: .utf8)
        XCTAssertFalse(env.contains(otherID), env)
        XCTAssertEqual(ShellLibrary.load(root: f.root).games.map(\.titleID), [titleID])
        XCTAssertTrue(outcome.message.contains(String(format: L10n.string("shell.gameLeftOut", .en), "Zelda Breath of the Wild", "game.manifest.json")), outcome.message)
        XCTAssertFalse(fm.fileExists(atPath: ShellInstall.mirroredFramework(root: f.root, titleID: otherID)), "the half framework is not mirrored")
        XCTAssertTrue(fm.fileExists(atPath: half + "/Info.plist"), "the build folder is left to A's next build")
    }

    func testTheBuiltGamesOwnIncompleteFrameworkStopsWithItsNameAndTheMissingFile() throws {
        let f = try makeFixture()
        try fm.removeItem(atPath: f.framework + "/DmGame\(titleID)")
        var stages: [ShellStage] = []
        var i = installer(f)
        i.stage = { stages.append($0) }
        i.lang = .de
        let outcome = i.export(framework: f.framework, titleID: titleID, name: "Hades")
        XCTAssertFalse(outcome.ok)
        let why = String(format: L10n.string("shell.frameworkIncomplete", .de), "Hades", "DmGame\(titleID)")
        XCTAssertEqual(outcome.message, String(format: L10n.string("shell.projectFailed", .de), why))
        XCTAssertEqual(stages.last?.id, ShellInstaller.projectStageID)
        XCTAssertEqual(stages.last?.state, .failed)
        XCTAssertEqual(stages.last?.detail, why)
        XCTAssertFalse(fm.fileExists(atPath: state + "/shell-env.txt"), "build_shell.sh never runs")
    }

    func testTheCheckNamesTheManifestThenTheExecutableTheManifestNames() throws {
        let fw = path("check/DmGame\(titleID).framework")
        try fm.createDirectory(atPath: fw, withIntermediateDirectories: true)
        XCTAssertEqual(ShellInstall.missingFile(inFramework: fw, titleID: titleID), "game.manifest.json")
        try write(fw + "/game.manifest.json", "not json")
        XCTAssertEqual(ShellInstall.missingFile(inFramework: fw, titleID: titleID), "game.manifest.json")
        try write(fw + "/game.manifest.json", #"{"framework_executable": "Other"}"#)
        XCTAssertEqual(ShellInstall.missingFile(inFramework: fw, titleID: titleID), "Other")
        try write(fw + "/Other", "executable")
        XCTAssertNil(ShellInstall.missingFile(inFramework: fw, titleID: titleID))
        try write(fw + "/game.manifest.json", "{}")
        XCTAssertEqual(ShellInstall.missingFile(inFramework: fw, titleID: titleID), "DmGame\(titleID)")
    }

    func testTheNewTextsNameGameAndFileInEveryLanguage() {
        for lang in Lang.all {
            for key in ["shell.frameworkIncomplete", "shell.gameLeftOut"] {
                let text = L10n.string(key, lang)
                XCTAssertTrue(text.contains("%1$@") && text.contains("%2$@"), "\(key) in \(lang)")
                XCTAssertFalse(text.contains(";") || text.contains("；") || text.contains("—"), "\(key) in \(lang)")
            }
        }
    }

    // ---- step 3: the game data to the device ----

    private func makeArchive() throws -> String {
        let archive = path("out/games", titleID)
        try write(archive + "/romfs.img", "0123456789")
        try write(archive + "/aoc/1.img", "abcd")
        return archive
    }

    /// The apps the stand-in device lists (`devicectl device info apps`).
    private func listApps(_ apps: [(bundle: String, name: String)]) throws {
        let list = apps.map { ["bundleIdentifier": $0.bundle, "name": $0.name] }
        try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success"], "result": ["apps": list]])
            .write(to: URL(fileURLWithPath: state + "/apps.json"))
    }

    private func sender(_ f: Fixture) -> ShellInstaller {
        var i = installer(f)
        i.device = "DEV-1"
        i.deviceName = "Z"
        return i
    }

    func testTheShellAppIsFoundByItsBundleIDPrefix() {
        let apps = [InstalledApp(bundle: "com.apple.mobilesafari", name: "Safari"),
                    InstalledApp(bundle: "org.nxnative.shell.ABC123", name: "NX2Apple"),
                    InstalledApp(bundle: "org.nxnative.0100535012974000", name: "Odyssey"),
                    InstalledApp(bundle: "org.nxnative.shell", name: "NX2Apple")]
        XCTAssertEqual(ShellInstall.shellApps(in: apps).map(\.bundle), ["org.nxnative.shell", "org.nxnative.shell.ABC123"])
        XCTAssertEqual(ShellInstall.shellApps(in: Array(apps.prefix(1))), [])
    }

    func testOneAppIsUsedWithoutAskingAndTheCopyGoesIntoItsContainer() throws {
        let f = try makeFixture()
        let archive = try makeArchive()
        try listApps([("com.apple.mobilesafari", "Safari"), ("org.nxnative.shell.ABC123", "NX2Apple")])
        var progress: [(Int64, Int64)] = []
        var i = sender(f)
        i.copyProgress = { progress.append(($0, $1)) }
        let outcome = i.sendData(titleID: titleID, archive: archive)
        XCTAssertTrue(outcome.ok, outcome.message)
        XCTAssertEqual(outcome.message, L10n.string("shell.sendDone", .en))
        XCTAssertEqual(outcome.appName, "NX2Apple")
        XCTAssertEqual(outcome.bundleID, "org.nxnative.shell.ABC123")
        let copies = calls.filter { $0.hasPrefix("devicectl device copy to") }
        XCTAssertEqual(copies.count, 2)
        for copy in copies {
            XCTAssertTrue(copy.contains("--device DEV-1 ") && copy.contains("--domain-type appDataContainer --domain-identifier org.nxnative.shell.ABC123"), copy)
            XCTAssertTrue(copy.contains("--destination Documents/games/\(titleID)/"), copy)
        }
        XCTAssertEqual(progress.last?.0, 14)
        XCTAssertEqual(progress.last?.1, 14)
        XCTAssertFalse(calls.contains { $0.hasPrefix("xcodebuild") }, "nothing is built or signed")
    }

    func testSendingAnUnchangedImageKeepsTheSendCompletionMessage() throws {
        let f = try makeFixture()
        let archive = try makeArchive()
        let bundle = "org.nxnative.shell"
        try write(f.repo + "/" + RepoLayout.romfsImageTool, "print('DMROMFSID1 same-image')")
        var i = sender(f)
        i.defaults = testDefaults
        XCTAssertEqual(i.sendData(titleID: titleID, archive: archive, bundleID: bundle).copied, 2)
        let listing = #"{"result":{"files":[{"relativePath":"romfs.img","metadata":{"size":10}},{"relativePath":"aoc/1.img","metadata":{"size":4}}]}}"#
        try write(state + "/files.json", listing)
        i.decideCopy = { _ in XCTFail("the matching image needs no copy"); return .skip }
        let outcome = i.sendData(titleID: titleID, archive: archive, bundleID: bundle)
        XCTAssertTrue(outcome.ok, outcome.message)
        XCTAssertEqual(outcome.copied, 0)
        XCTAssertEqual(outcome.message, L10n.string("shell.sendDone", .en))
    }

    func testSeveralAppsAreAskedAboutAndNoneSaysToInstallFirst() throws {
        let f = try makeFixture()
        let archive = try makeArchive()
        try listApps([("org.nxnative.shell", "NX2Apple"), ("org.nxnative.shell.ABC123", "NX2Apple")])
        let several = sender(f).sendData(titleID: titleID, archive: archive)
        XCTAssertFalse(several.ok)
        XCTAssertEqual(several.apps.map(\.bundle), ["org.nxnative.shell", "org.nxnative.shell.ABC123"])
        XCTAssertTrue(calls.filter { $0.hasPrefix("devicectl device copy") }.isEmpty, "nothing is copied before the player chooses")
        // the chosen one
        let chosen = sender(f).sendData(titleID: titleID, archive: archive, bundleID: "org.nxnative.shell.ABC123")
        XCTAssertTrue(chosen.ok, chosen.message)
        // none
        try listApps([("com.apple.mobilesafari", "Safari")])
        let none = sender(f).sendData(titleID: titleID, archive: archive)
        XCTAssertFalse(none.ok)
        XCTAssertEqual(none.dataFailure, .appNotFound)
        XCTAssertEqual(none.message, L10n.string("shell.sendNoApp", .en))
    }

    func testARefusalKeepsDevicectlsWordsForTheDetails() throws {
        let f = try makeFixture()
        let archive = try makeArchive()
        try listApps([("org.nxnative.shell", "NX2Apple")])
        try write(state + "/refuse", "")
        let outcome = sender(f).sendData(titleID: titleID, archive: archive)
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.dataFailure, .refused)
        XCTAssertEqual(outcome.message, L10n.string("shell.sendRefused", .en))
        XCTAssertTrue(outcome.detail.contains("get-task-allow"), outcome.detail)
        XCTAssertNil(outcome.failure, "the install's Retry card does not fit")
    }

    /// #491: the device listed the app, so a copy that fails is a refusal whatever devicectl says, even words that sound like a missing app.
    /// Before, such words said "Install the IPA first" to a player whose app was installed, and the Finder way was not offered.
    func testACopyIntoAListedAppThatFailsIsAlwaysARefusal() throws {
        let f = try makeFixture()
        let archive = try makeArchive()
        try listApps([("org.nxnative.shell", "NX2Apple")])
        for words in ["ERROR: Could not find the app's data container. (com.apple.dt.CoreDeviceError error 3)",
                      "ERROR: The application is not installed on the device.", "ERROR: Operation not permitted (NSPOSIXErrorDomain error 1)"] {
            try write(state + "/refuse", words)
            let outcome = sender(f).sendData(titleID: titleID, archive: archive)
            XCTAssertEqual(outcome.dataFailure, .refused, words)
            XCTAssertEqual(outcome.detail, words)
            XCTAssertEqual(DataSend.after(outcome, notConnected: "x"), .refused(detail: words))
        }
    }

    /// An app list the device does not give is said in plain words, with the device's name, not as devicectl's raw line.
    func testAnUnreadableAppListIsSaidInPlainWords() throws {
        let f = try makeFixture()
        let archive = try makeArchive()
        try write(state + "/apps-locked", "")
        let outcome = sender(f).sendData(titleID: titleID, archive: archive)
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.dataFailure, .noAppList)
        XCTAssertEqual(outcome.message, String(format: L10n.string("shell.sendListFailed", .en), "Z"))
        XCTAssertTrue(outcome.detail.contains("locked"), outcome.detail)
        XCTAssertEqual(DataSend.after(outcome, notConnected: "x"), .failed(outcome.message))
        XCTAssertFalse(DataSend.after(outcome, notConnected: "x").offersFinder, "a locked device is not a case for Finder")
    }

    /// The mapping from the end of a send to what step 3 shows. Only a refusal and an app the device does not list offer the Finder way.
    func testTheEndOfASendMapsToItsStateAndOnlyFailuresOfTheCopyOfferFinder() {
        var sent = ShellInstaller.Outcome(ok: true, message: "")
        sent.appName = "App"
        XCTAssertEqual(DataSend.after(sent, notConnected: "off"), .sent(app: "App"))
        let skipped = ShellInstaller.Outcome(ok: true, message: "", copySkipped: true)
        XCTAssertEqual(DataSend.after(skipped, notConnected: "off"), .failed("off"))
        var several = ShellInstaller.Outcome(ok: false, message: "")
        several.apps = [InstalledApp(bundle: "org.nxnative.shell", name: "A"), InstalledApp(bundle: "org.nxnative.shell.T", name: "B")]
        XCTAssertEqual(DataSend.after(several, notConnected: "off"), .chooseApp(several.apps))
        var none = ShellInstaller.Outcome(ok: false, message: "")
        none.dataFailure = .appNotFound
        XCTAssertEqual(DataSend.after(none, notConnected: "off"), .appNotFound)
        var refused = ShellInstaller.Outcome(ok: false, message: "")
        refused.dataFailure = .refused; refused.detail = "ERROR: no"
        XCTAssertEqual(DataSend.after(refused, notConnected: "off"), .refused(detail: "ERROR: no"))
        let space = ShellInstaller.Outcome(ok: false, message: "No space")
        XCTAssertEqual(DataSend.after(space, notConnected: "off"), .failed("No space"))

        let offers: [DataSend] = [.appNotFound, .refused(detail: "")]
        let others: [DataSend] = [.idle, .sending(done: 0, total: 1, note: ""), .sent(app: ""), .chooseApp([]), .failed("x"),
                                  .copying(done: 0, total: 1), .copied(folder: "/f")]
        XCTAssertTrue(offers.allSatisfy(\.offersFinder))
        XCTAssertFalse(others.contains(where: \.offersFinder), "never a second button while the first way works")
    }

    /// What Finder shows selected: the game's own folder (romfs.img and its add-on content), named by its title ID. One game's own IPA
    /// holds its data, so it has nothing to drag.
    func testFinderShowsTheGamesFolderForTheSharedAppAndNothingForOneGame() {
        let archive = path("out/games", titleID)
        XCTAssertEqual(BuildStore.finderItem(archive: archive, oneGame: false), archive)
        XCTAssertEqual((BuildStore.finderItem(archive: archive, oneGame: false)! as NSString).lastPathComponent, titleID)
        XCTAssertNil(BuildStore.finderItem(archive: archive, oneGame: true))
        XCTAssertNil(BuildStore.finderItem(archive: "", oneGame: false), "nothing packed yet")
    }

    /// Copy with Finder selects the folder in Finder and opens the three steps. A new send closes them again. Before a failure it does nothing.
    func testCopyWithFinderRevealsTheFolderAndOpensTheSteps() throws {
        let stores = LauncherStores(defaults: testDefaults); let model = stores.build
        var revealed: [URL] = []
        model.revealItem = { revealed.append($0) }
        model.archivePath = path("out/games", titleID)
        model.copyWithFinder(oneGame: false)
        XCTAssertTrue(revealed.isEmpty, "only after the copy to the device did not work")
        XCTAssertFalse(model.finderShown)
        model.send = .refused(detail: "ERROR: no")
        model.copyWithFinder(oneGame: false)
        XCTAssertEqual(revealed.map(\.path), [path("out/games", titleID)])
        XCTAssertTrue(model.finderShown)
        model.send = .sending(done: 0, total: 0, note: "")
        XCTAssertFalse(model.finderShown, "a new send closes the steps")
        model.send = .appNotFound
        model.copyWithFinder(oneGame: true)
        XCTAssertEqual(revealed.count, 1, "one game's own IPA has nothing to drag")
        XCTAssertFalse(model.finderShown)
    }

    /// The Finder way's texts: every required language, the same number of %@ as English, and step 3 names the shell's own button.
    func testTheFinderWayTextsFitEveryLanguage() {
        let keys = ["shell.sendFinder", "shell.sendFinderStep1", "shell.sendFinderStep2", "shell.sendFinderStep3", "shell.sendListFailed",
                    "shell.sendRefused", "shell.sendNoApp"]
        func placeholders(_ text: String) -> Int { text.components(separatedBy: "%@").count - 1 }
        for key in keys {
            for lang in Lang.all {
                XCTAssertEqual(placeholders(L10n.string(key, lang)), placeholders(L10n.string(key, .en)), "\(key) in \(lang.code)")
            }
        }
        XCTAssertEqual(placeholders(L10n.string("shell.sendFinderStep3", .en)), 2)
        XCTAssertNotEqual(L10n.string("ios.ui.chooseGameData", .en), "ios.ui.chooseGameData", "step 3 names a button the shell has")
    }

    func testTheSendButtonsNeedTheIPAAndTheirPlace() throws {
        let stores = LauncherStores(defaults: testDefaults); let model = stores.build
        stores.deviceStore.installDevice = "DEV-1"
        model.archivePath = path("out/games", titleID)
        XCTAssertFalse(model.canSendGameData, "step 3 waits for step 1")
        model.exportedIPAPath = path("export/NX2Apple.ipa")
        XCTAssertTrue(model.canSendToDevice)
        XCTAssertEqual(model.packedTitleID, titleID)
        stores.deviceStore.installDevice = ""
        XCTAssertFalse(model.canSendToDevice)
        XCTAssertFalse(model.canCopyToDrive, "no folder chosen")
        model.running = true
        XCTAssertFalse(model.canSendGameData)
    }

    @MainActor func testTheStoreSendsToTheDeviceItFoundTheAppOn() throws {
        let f = try makeFixture()
        let archive = try makeArchive()
        try listApps([("org.nxnative.shell.ABC123", "NX2Apple")])
        try write(state + "/devices-ok", "")
        testDefaults.set(f.root, forKey: "shellRoot")
        let stores = LauncherStores(xcrun: f.xcrun, defaults: testDefaults); let model = stores.build
        stores.repo.path = f.repo
        stores.dependencies.pythonPath = "/usr/bin/python3"
        stores.deviceStore.installDevice = "DEV-1"
        model.target = "ios"
        model.archivePath = archive
        model.exportedIPAPath = path("export/NX2Apple.ipa")
        let sent = expectation(description: "Sent")
        let token = model.$send.sink { if case .sent = $0 { sent.fulfill() } }
        model.sendGameData()
        wait(for: [sent], timeout: 30)
        withExtendedLifetime(token) {}
        XCTAssertFalse(model.running)
        XCTAssertEqual(calls.filter { $0.hasPrefix("devicectl device copy to") }.count, 2)
        // the app is gone: the next step is named, nothing else
        try listApps([])
        let missing = expectation(description: "No app")
        let again = model.$send.sink { if $0 == .appNotFound { missing.fulfill() } }
        model.sendGameData()
        wait(for: [missing], timeout: 30)
        withExtendedLifetime(again) {}
    }

    // ---- step 3: the game data to a drive or folder ----

    func testDataResendIgnoresHiddenShaderCachesAndPreservesTheDestinationsOtherFiles() throws {
        let archive = try makeArchive(), destination = path("drive", titleID)
        let cache = ".shader-resources/msl-" + UUID().uuidString + "/b-3f9a2c/example.metallib"
        try write(archive + "/" + cache, "not transfer data")
        try write(destination + "/" + cache, "prepared shaders")
        try write(destination + "/save/progress.sav", "player save")
        try write(destination + "/romfs.img", "short")
        try write(destination + "/aoc/1.img", "abcd")
        let local = ShellInstall.localFiles(in: archive)
        XCTAssertEqual(local, ["romfs.img": 10, "aoc/1.img": 4])

        // A device listing may include the hidden cache. Only differing local game data is sent.
        let listing: [[String: Any]] = [
            ["relativePath": "romfs.img", "metadata": ["size": 5]],
            ["relativePath": "aoc/1.img", "metadata": ["size": 4]],
            ["relativePath": cache, "metadata": ["size": 16]],
            ["relativePath": "save/progress.sav", "metadata": ["size": 11]]
        ]
        let device = ShellInstall.parseListing(try JSONSerialization.data(withJSONObject: ["result": ["files": listing]]))
        XCTAssertEqual(ShellInstall.filesToCopy(local: local, device: device), ["romfs.img"])
        let command = ShellInstall.copyCommand(xcrun: "/xcrun", device: "fixture", bundleID: "org.nxnative.shell",
                                               titleID: titleID, source: archive + "/romfs.img", relativePath: "romfs.img")
        XCTAssertFalse(command.contains("--remove-existing-content"))

        // Exercise the real folder-copy path with the same transfer list, without a device or signing.
        var progress: [(Int64, Int64)] = []
        try DriveCopy.copy(archive: archive, files: local, to: destination) { progress.append(($0, $1)) }
        XCTAssertEqual(progress.last?.1, 10)
        XCTAssertEqual(try String(contentsOfFile: destination + "/romfs.img"), "0123456789")
        XCTAssertEqual(try String(contentsOfFile: destination + "/" + cache), "prepared shaders")
        XCTAssertEqual(try String(contentsOfFile: destination + "/save/progress.sav"), "player save")
    }

    func testTheDriveGetsTheSameFilesAsTheDeviceUnderTheTitleIDFolder() throws {
        let archive = try makeArchive()
        try write(archive + "/.packstamp", "stamp")   // a dot file is not game data
        let folder = path("drive")
        let destination = DriveCopy.destination(folder: folder, titleID: titleID)
        XCTAssertEqual(destination, folder + "/" + titleID)
        var seen: [(Int64, Int64)] = []
        try DriveCopy.copy(archive: archive, files: ShellInstall.localFiles(in: archive), to: destination, chunk: 3) { seen.append(($0, $1)) }
        // what the shell scans for: <folder>/<title ID>/romfs.img of the size the image has, and the aoc images beside it
        XCTAssertEqual(try String(contentsOfFile: destination + "/romfs.img"), "0123456789")
        XCTAssertEqual(try String(contentsOfFile: destination + "/aoc/1.img"), "abcd")
        XCTAssertEqual(ShellInstall.localFiles(in: destination), ShellInstall.localFiles(in: archive))
        XCTAssertFalse(fm.fileExists(atPath: destination + "/.packstamp"))
        XCTAssertFalse(ShellInstall.localFiles(in: destination).keys.contains { $0.hasSuffix(".partial") })
        XCTAssertEqual(seen.first?.0, 0)
        XCTAssertEqual(seen.last?.0, 14)
        XCTAssertEqual(seen.last?.1, 14)
        // a second run leaves finished files alone and finishes a cut-off one
        try "01234".write(toFile: destination + "/romfs.img", atomically: true, encoding: .utf8)
        var second: [(Int64, Int64)] = []
        try DriveCopy.copy(archive: archive, files: ShellInstall.localFiles(in: archive), to: destination) { second.append(($0, $1)) }
        XCTAssertEqual(second.last?.1, 10, "only romfs.img was short")
        XCTAssertEqual(try String(contentsOfFile: destination + "/romfs.img"), "0123456789")
    }

    func testTheDriveCopyStopsWhenCancelledAndLeavesNoCutOffImage() throws {
        let archive = try makeArchive()
        let destination = path("drive", titleID)
        var chunks = 0
        XCTAssertThrowsError(try DriveCopy.copy(archive: archive, files: ShellInstall.localFiles(in: archive), to: destination, chunk: 2,
                                                progress: { _, _ in }, cancelled: { chunks += 1; return chunks > 3 })) {
            XCTAssertEqual($0 as? DriveCopy.CopyError, .cancelled)
        }
        XCTAssertFalse(fm.fileExists(atPath: destination + "/romfs.img"))
        XCTAssertFalse(fm.fileExists(atPath: destination + "/aoc/1.img"))
        XCTAssertFalse(ShellInstall.localFiles(in: destination).keys.contains { $0.hasSuffix(".partial") })
    }

    func testTheDriveChecksReadOnlyFAT32AndFreeSpaceWithInjectedValues() {
        let small = ["romfs.img": Int64(2_000_000_000)]
        let big = ["romfs.img": Int64(5_000_000_000), "aoc/1.img": 10]
        let roomy = DriveCopy.Volume(freeBytes: 100_000_000_000, fileSystem: "exfat", readOnly: false)
        XCTAssertNil(DriveCopy.problem(files: big, volume: roomy))
        XCTAssertNil(DriveCopy.problem(files: big, volume: DriveCopy.Volume(freeBytes: 100_000_000_000, fileSystem: "apfs", readOnly: false)))
        XCTAssertEqual(DriveCopy.problem(files: big, volume: DriveCopy.Volume(freeBytes: 100_000_000_000, fileSystem: "msdos", readOnly: false)),
                       .fat32(largest: 5_000_000_000))
        XCTAssertNil(DriveCopy.problem(files: small, volume: DriveCopy.Volume(freeBytes: 100_000_000_000, fileSystem: "msdos", readOnly: false)),
                     "FAT32 holds files under 4 GB")
        XCTAssertEqual(DriveCopy.problem(files: small, volume: DriveCopy.Volume(freeBytes: 100, fileSystem: "exfat", readOnly: true)), .readOnly)
        XCTAssertEqual(DriveCopy.problem(files: big, volume: DriveCopy.Volume(freeBytes: 1_000_000_000, fileSystem: "exfat", readOnly: false)),
                       .noSpace(needed: 5_000_000_010, free: 1_000_000_000))
        // what the drive holds already needs no room again
        XCTAssertNil(DriveCopy.problem(files: big, have: big, volume: DriveCopy.Volume(freeBytes: 0, fileSystem: "exfat", readOnly: false)))
        XCTAssertEqual(DriveCopy.fileSystemName("msdos"), "FAT32")
        XCTAssertEqual(DriveCopy.fileSystemName("exfat"), "exFAT")
        XCTAssertEqual(DriveCopy.fileSystemName("apfs"), "APFS")
    }

    func testTheRealVolumeOfATemporaryFolderAnswers() {
        let volume = DriveCopy.volume(at: path("not", "made", "yet"))   // the nearest folder above it answers
        XCTAssertNotNil(volume)
        XCTAssertEqual(volume?.readOnly, false)
        XCTAssertGreaterThan(volume?.freeBytes ?? 0, 0)
    }

    @MainActor func testTheStoreCopiesToTheChosenFolderAndRefusesAFAT32Drive() throws {
        let archive = try makeArchive()
        let stores = LauncherStores(defaults: testDefaults); let model = stores.build
        model.archivePath = archive
        model.exportedIPAPath = path("export/NX2Apple.ipa")
        let folder = path("drive")
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        model.chooseFolder = { folder }
        model.chooseDriveFolder()
        XCTAssertEqual(stores.deviceStore.driveFolder, folder)
        XCTAssertEqual(model.drive?.needed, 14)
        XCTAssertNil(model.drive?.problem)
        XCTAssertTrue(model.canCopyToDrive)
        let copied = expectation(description: "Copied")
        let token = model.$send.sink { if case .copied = $0 { copied.fulfill() } }
        model.copyToDrive()
        wait(for: [copied], timeout: 30)
        withExtendedLifetime(token) {}
        XCTAssertEqual(try String(contentsOfFile: folder + "/" + titleID + "/romfs.img"), "0123456789")
        XCTAssertFalse(model.running)
        // a FAT32 drive keeps the button inert
        model.drive = DriveState(volume: DriveCopy.Volume(freeBytes: 1 << 40, fileSystem: "msdos", readOnly: false), needed: 5_000_000_000,
                                 problem: .fat32(largest: 5_000_000_000))
        XCTAssertFalse(model.canCopyToDrive)
    }

    func testEveryLanguageHasTheExportTexts() {
        let keys = ["shell.exportBuildStage", "shell.exportDone", "shell.exportFailed", "shell.exportPackStage", "shell.modeTitle", "shell.modeInstall",
                    "shell.modeExport", "shell.step1Title", "shell.step1Sub", "shell.step1Button", "shell.step1Done", "shell.showInFinder", "shell.step2Title",
                    "shell.step2Sub", "shell.step3Title", "shell.step3Sub", "shell.whereDevice", "shell.whereDrive", "shell.sendButton", "shell.sendStage",
                    "shell.sendProgress", "shell.sendDone", "shell.sendNoApp", "shell.sendSeveral", "shell.sendRefused", "shell.sendFinder",
                    "shell.sendFinderStep1", "shell.sendFinderStep2", "shell.sendFinderStep3", "shell.sendListFailed", "shell.sendDetails", "shell.driveNone", "shell.driveChoose", "shell.driveCopy", "shell.driveNote", "shell.driveFat32",
                    "shell.driveReadOnly", "shell.driveNoSpace", "shell.driveProgress", "shell.driveDone", "shell.driveFailed"]
        // The five languages the launcher ships with must have every text, translated. Any other language file (it, for one) may leave a key out:
        // that key then shows the English text, and nothing here asks for it.
        let required = ["zh", "en", "sv", "de", "fr"]
        XCTAssertTrue(required.allSatisfy { code in Lang.all.contains { $0.code == code } }, "all five required languages exist")
        for key in keys {
            for lang in Lang.all {
                let isRequired = required.contains(lang.code)
                let text = L10n.string(key, lang)
                XCTAssertNotEqual(text, key, "\(key) in \(lang.code)")
                if isRequired { XCTAssertNotNil(L10n.catalogs[lang.code]?[key], "\(key) is missing in \(lang.code)") }
                XCTAssertFalse(text.contains(";") || text.contains("；"), "\(key) in \(lang.code)")
                XCTAssertFalse(text.contains("NX2Apple"), "\(key) in \(lang.code): no product name in a screen")
                if isRequired && lang != .en && !key.hasPrefix("shell.export") { XCTAssertNotEqual(text, L10n.string(key, .en), "\(key) in \(lang.code) is English") }
            }
        }
        // a language file without these keys (no catalog at all here) shows the English text, never the key
        for key in keys { XCTAssertEqual(L10n.string(key, Lang("xx")), L10n.string(key, .en), key) }
        // the arguments the code passes
        XCTAssertEqual(L10n.string("shell.step1Done", .en).components(separatedBy: "%@").count, 2)
        for lang in Lang.all {
            XCTAssertEqual(L10n.string("shell.driveNote", lang).components(separatedBy: "%@").count, 5, lang.code)
            XCTAssertEqual(L10n.string("shell.driveDone", lang).components(separatedBy: "%@").count, 3, lang.code)
            XCTAssertEqual(L10n.string("shell.sendProgress", lang).components(separatedBy: "%@").count, 4, lang.code)
        }
        XCTAssertTrue(L10n.string("ios.ui.gameData", .en) == "Game data", "the drive note names the shell's own row")
        XCTAssertTrue(L10n.string("shell.driveNote", .en).contains("has to stay connected"))
    }

    // ---- the choice in the build ----

    /// An iPhone build with the export chosen and no device and no team runs the script without `--team-id`, then ends with the IPA
    /// instead of the "needs a device and a signing team" stop.
    @MainActor func testBuildWithTheExportChoiceNeedsNoDeviceAndNoTeam() throws {
        let f = try makeFixture()
        testDefaults.set(f.root, forKey: "shellRoot")
        let stores = LauncherStores(xcrun: f.xcrun, defaults: testDefaults); let model = stores.build
        stores.repo.path = f.repo
        model.target = "ios"
        model.bcOnCPU = true
        model.outDir = path("out")
        stores.dependencies.pythonPath = "/usr/bin/python3"
        stores.dependencies.dotnetPath = "/usr/bin/true"
        stores.dependencies.checked = true
        stores.dependencies.deps = [Dep(id: "test", name: "test", hint: "", present: true, installCmd: [])]
        stores.deviceStore.installDevice = ""
        stores.deviceStore.signingTeam = ""
        stores.deviceStore.exportIPA = true
        XCTAssertTrue(model.exportsShell)
        XCTAssertFalse(model.installsDirectly)
        try write(f.repo + "/dm/tools/nx_extract/Program.cs", "")
        for tool in RepoLayout.requiredTools.filter({ $0 != RepoLayout.buildScript }) { try write(f.repo + "/" + tool, "") }
        try write(f.repo + "/dm/tools/romfs_image.py", "import sys\nopen(sys.argv[3], 'wb').write(b'image')\n")
        try write(f.repo + "/scripts/build_ipa_from_nsp.py", """
        import sys, json, pathlib
        pathlib.Path('\(state)/build-env.txt').write_text(pathlib.Path(sys.argv[sys.argv.index('--env-file') + 1]).read_text())
        open('\(state)/script.txt', 'w').write(' '.join(sys.argv[1:]))
        work = pathlib.Path(sys.argv[sys.argv.index('--work-dir') + 1])
        fw = pathlib.Path(sys.argv[sys.argv.index('--shell-framework') + 1]) / 'DmGame\(titleID).framework'
        fw.mkdir(parents=True); (fw / 'game.manifest.json').write_text('{}'); (fw / 'DmGame\(titleID)').write_text('executable')
        (work / 'extract/v0/RomFS').mkdir(parents=True); (work / 'extract/v0/RomFS/data.bin').write_bytes(b'game')
        print(json.dumps(dict(ev='stage', k=1, n=1, name='framework')), flush=True)
        print(json.dumps(dict(ev='stage_end', k=1, name='framework', ok=True, summary='', elapsed=1)), flush=True)
        """)
        let base = temporary.appendingPathComponent("Test [\(titleID)].nsp"), keys = temporary.appendingPathComponent("prod.keys")
        try Data([0]).write(to: base); try Data().write(to: keys)
        model.slots[0].paths = [base.path]; model.slots[3].paths = [keys.path]

        let finished = expectation(description: "Exported")
        let token = model.$done.filter { $0 }.prefix(1).sink { _ in finished.fulfill() }
        model.startBuild()
        wait(for: [finished], timeout: 30)
        withExtendedLifetime(token) {}

        let script = try String(contentsOfFile: state + "/script.txt")
        XCTAssertEqual(try String(contentsOfFile: state + "/build-env.txt"), "DM_PROF_TEX_BC_CPU=1\n")
        XCTAssertTrue(script.contains("--shell-framework \(temporary.path)/out/\(titleID)_build/shell-framework"), script)
        XCTAssertFalse(script.contains("--team-id"), script)
        XCTAssertEqual(model.exportedIPAPath, ShellInstall.ipaPath(root: f.root))
        XCTAssertTrue(fm.fileExists(atPath: model.exportedIPAPath))
        XCTAssertEqual(model.installedOn, "")
        XCTAssertFalse(model.running)
        XCTAssertNotEqual(model.doneNote, model.t("shell.needsDevice"))
        XCTAssertEqual(model.doneNote, String(format: model.t("shell.exportDone"), model.exportedIPAPath))
        XCTAssertFalse(calls.contains { $0.hasPrefix("devicectl") })
        XCTAssertTrue(fm.fileExists(atPath: model.archivePath + "/romfs.img"), "the game data is packed beside the IPA, not in it")
        XCTAssertFalse(try entries(ofZip: model.exportedIPAPath).contains { $0.hasSuffix("romfs.img") })
    }

    /// One game's own IPA (#540): the script runs without `--shell-framework`, packs the game data into the IPA it names, and the
    /// build ends with that IPA. No shared app, no archive, no shell.json, no stale prompt.
    @MainActor func testOneGameExportBuildsTheGamesOwnIPAWithItsDataInside() throws {
        let f = try makeFixture()
        testDefaults.set(f.root, forKey: "shellRoot")
        let stores = LauncherStores(xcrun: f.xcrun, defaults: testDefaults); let model = stores.build
        stores.repo.path = f.repo
        model.target = "ios"
        model.outDir = path("out")
        stores.dependencies.pythonPath = "/usr/bin/python3"
        stores.dependencies.dotnetPath = "/usr/bin/true"
        stores.dependencies.checked = true
        stores.dependencies.deps = [Dep(id: "test", name: "test", hint: "", present: true, installCmd: [])]
        stores.deviceStore.installDevice = ""
        stores.deviceStore.signingTeam = ""
        stores.deviceStore.exportIPA = true
        stores.deviceStore.exportOneGame = true
        XCTAssertTrue(model.exportsOneGame)
        try write(f.repo + "/dm/tools/nx_extract/Program.cs", "")
        for tool in RepoLayout.requiredTools.filter({ $0 != RepoLayout.buildScript }) { try write(f.repo + "/" + tool, "") }
        try write(f.repo + "/scripts/build_ipa_from_nsp.py", """
        import sys, os, json, pathlib
        open('\(state)/script.txt', 'w').write(' '.join(sys.argv[1:]))
        open('\(state)/full-romfs.txt', 'w').write(os.environ.get('DM_FULL_ROMFS', ''))
        ipa = pathlib.Path(sys.argv[sys.argv.index('-o') + 1]); ipa.parent.mkdir(parents=True, exist_ok=True); ipa.write_bytes(b'ipa')
        print(json.dumps(dict(ev='stage', k=1, n=1, name='ipa')), flush=True)
        print(json.dumps(dict(ev='stage_end', k=1, name='ipa', ok=True, summary='', elapsed=1)), flush=True)
        """)
        let base = temporary.appendingPathComponent("Test [\(titleID)].nsp"), keys = temporary.appendingPathComponent("prod.keys")
        try Data([0]).write(to: base); try Data().write(to: keys)
        model.slots[0].paths = [base.path]; model.slots[3].paths = [keys.path]

        let finished = expectation(description: "Exported")
        let token = model.$done.filter { $0 }.prefix(1).sink { _ in finished.fulfill() }
        model.startBuild()
        wait(for: [finished], timeout: 30)
        withExtendedLifetime(token) {}

        let script = try String(contentsOfFile: state + "/script.txt")
        let ipa = path("out", "\(titleID).ipa")
        XCTAssertTrue(script.contains("--platform ios --romfs bundle -o " + ipa), script)
        XCTAssertFalse(script.contains("--shell-framework") || script.contains("--team-id"), script)
        XCTAssertEqual(try String(contentsOfFile: state + "/full-romfs.txt"), "1", "the fork's build_ipa.sh packs the game data only with DM_FULL_ROMFS=1")
        XCTAssertEqual(model.exportedIPAPath, ipa)
        XCTAssertEqual(model.doneNote, String(format: model.t("shell.exportDone"), ipa))
        XCTAssertFalse(model.running)
        XCTAssertTrue(model.staleFrameworks.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: ShellLibrary.stateFile(root: f.root)), "the shared app is not touched")
        XCTAssertTrue(calls.isEmpty, "no xcodebuild for a shared app and no device")
        XCTAssertEqual(model.archivePath, "", "the game data is inside the IPA, nothing is packed beside it")
    }

    func testOneGameChoiceIsOffAtFirstSavedAndOnlyCountsForAnExport() throws {
        testDefaults.removeObject(forKey: DeviceStore.oneGameKey)
        let stores = LauncherStores(defaults: testDefaults); let model = stores.build
        XCTAssertFalse(stores.deviceStore.exportOneGame, "the shared app stays the default")
        model.target = "ios"
        stores.deviceStore.exportOneGame = true
        XCTAssertTrue(testDefaults.bool(forKey: DeviceStore.oneGameKey))
        stores.deviceStore.exportIPA = false
        XCTAssertFalse(model.exportsOneGame, "installing on a device is always the shared app")
        stores.deviceStore.exportIPA = true
        XCTAssertTrue(model.exportsOneGame)
        model.target = BuildTarget.mac
        XCTAssertFalse(model.exportsOneGame)
        XCTAssertEqual(OneGameIPA.arguments(ipa: "/O/0100.ipa"), ["--platform", "ios", "--romfs", "bundle", "-o", "/O/0100.ipa"])
        XCTAssertEqual(OneGameIPA.path(folder: "/O", titleID: "0100"), "/O/0100.ipa")
    }

    /// The choice is saved and a build without it still asks for a device and a team.
    @MainActor func testTheChoiceIsSavedAndWithoutItTheDeviceIsStillNeeded() throws {
        let stores = LauncherStores(defaults: testDefaults); let model = stores.build
        stores.repo.path = temporary.path
        try write(temporary.path + "/dm/tools/nx_extract/Program.cs", "")
        model.target = "ios"
        stores.deviceStore.installDevice = ""
        stores.deviceStore.exportIPA = true
        XCTAssertTrue(testDefaults.bool(forKey: DeviceStore.exportKey))
        stores.deviceStore.exportIPA = false
        XCTAssertFalse(testDefaults.bool(forKey: DeviceStore.exportKey))
        XCTAssertFalse(model.exportsShell)
        model.startBuild()
        XCTAssertEqual(model.doneNote, model.t("shell.needsDevice"))
        // the Mac app is never an export
        stores.deviceStore.exportIPA = true
        model.target = BuildTarget.mac
        XCTAssertFalse(model.exportsShell)
    }
}
