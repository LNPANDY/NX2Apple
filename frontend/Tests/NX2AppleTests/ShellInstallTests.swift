import XCTest
import Combine
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

/// Route C: one app on the device for several games. The commands and parsers are checked as pure functions, and the whole path
/// after the build runs headless against a stand-in `xcrun` that models devicectl on a folder (a fake device container): an install
/// keeps the container, a copy to a file creates the parents, and `--remove-existing-content true` wipes the destination's siblings,
/// as it does on a real device. No test reaches a device or a real game.
final class ShellInstallTests: XCTestCase {
    private var temporary: URL!
    private let fm = FileManager.default
    private let titleID = "0100535012974000"
    private let device = "00008150-AAAA"
    private let team = "TEAM123456"

    override func setUpWithError() throws {
        temporary = fm.temporaryDirectory.appendingPathComponent("nspb-shell-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try fm.removeItem(at: temporary) }

    private func path(_ parts: String...) -> String { parts.reduce(temporary.path) { $0 + "/" + $1 } }
    private func write(_ file: String, _ text: String) throws {
        try fm.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: file, atomically: true, encoding: .utf8)
    }

    // ---- the state file ----

    func testLibraryCreateAddReplaceDropAndKeepBundleID() throws {
        let root = path("shell")
        XCTAssertEqual(ShellLibrary.load(root: root), ShellLibrary())   // no file yet
        var library = ShellLibrary.load(root: root)
        XCTAssertEqual(library.bundleID, "org.nxnative.shell")
        let one = path("one.framework"), two = path("two.framework"), gone = path("gone.framework")
        for f in [one, two] { try fm.createDirectory(atPath: f, withIntermediateDirectories: true) }
        library.team = team
        library.add(.init(titleID: "A", name: "One", framework: one))
        library.add(.init(titleID: "B", name: "Two", framework: two))
        library.add(.init(titleID: "C", name: "Gone", framework: gone))
        library.bundleID = "org.nxnative.shell." + team
        try library.save(root: root)
        XCTAssertEqual(ShellLibrary.load(root: root), library)

        var again = ShellLibrary.load(root: root)
        again.add(.init(titleID: "A", name: "One again", framework: two))   // the same title ID replaces
        XCTAssertEqual(again.games.count, 3)
        XCTAssertEqual(again.games.first?.name, "One again")
        again.dropMissing()
        XCTAssertEqual(again.games.map(\.titleID), ["A", "B"])
        try again.save(root: root)
        XCTAssertEqual(ShellLibrary.load(root: root).bundleID, "org.nxnative.shell." + team)   // the bundle ID stays
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: root + "/shell.json"))) as? [String: Any]
        XCTAssertEqual(Set(json?.keys.map { $0 } ?? []), ["bundleID", "team", "games"])
    }

    func testShellRootIsDerivedOnceAndKept() throws {
        let defaults = UserDefaults(suiteName: "nspb-shell-" + UUID().uuidString)!
        XCTAssertEqual(ShellLibrary.resolveRoot(defaults: defaults, parent: "/Volumes/A"), "/Volumes/A/NX2Apple-shell")
        XCTAssertEqual(ShellLibrary.resolveRoot(defaults: defaults, parent: "/Volumes/B"), "/Volumes/A/NX2Apple-shell")
    }

    // ---- the commands ----

    // ---- the iOS shell package (DM_SHELL_PACKAGE) ----

    private func makeTree(_ files: [String]) throws -> String {
        let dir = NSTemporaryDirectory() + "shellpkg-" + UUID().uuidString
        for f in files {
            try FileManager.default.createDirectory(atPath: (dir + "/" + f as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: dir + "/" + f, contents: Data())
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir
    }

    func testShellPackagePrefersTheBundleThenTheCheckout() throws {
        let bundle = try makeTree(["frontend-ios/Package.swift"])
        let checkout = try makeTree(["frontend-ios/Package.swift"])
        XCTAssertEqual(ShellInstall.shellPackage(resources: bundle, repo: checkout), bundle + "/frontend-ios")
        XCTAssertEqual(ShellInstall.shellPackage(resources: nil, repo: checkout), checkout + "/frontend-ios")
        let bare = try makeTree([])
        XCTAssertEqual(ShellInstall.shellPackage(resources: bare, repo: checkout), checkout + "/frontend-ios")
        XCTAssertNil(ShellInstall.shellPackage(resources: bare, repo: bare))
        XCTAssertNil(ShellInstall.shellPackage(resources: nil, repo: ""))
    }

    /// The failure of the report: the repo is an engine in the store (no frontend-ios in it), the release app carries the package.
    func testStoreEngineGetsTheBundledPackage() throws {
        let store = try makeTree(["engine/id/dm/ios/tools/build_shell.sh"]) + "/engine/id"
        let bundle = try makeTree(["frontend-ios/Package.swift", "frontend-ios/AppIcon.icon/icon.json"])
        let package = try XCTUnwrap(ShellInstall.shellPackage(resources: bundle, repo: store))
        let env = ShellInstall.projectEnvironment(root: "/R", frameworks: [], bundleID: "b", team: "T", python: "/py", path: "/p",
                                                  home: "/h", user: "u", package: package)
        let path = try XCTUnwrap(env["DM_SHELL_PACKAGE"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/Package.swift"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/AppIcon.icon"))
        XCTAssertFalse(path.hasPrefix(store))
        XCTAssertNil(ShellInstall.projectEnvironment(root: "/R", frameworks: [], bundleID: "b", team: "T", python: "/py", path: "/p",
                                                     home: "/h", user: "u")["DM_SHELL_PACKAGE"])
    }

    func testCommandsAreExact() {
        let root = "/R/NX2Apple-shell"
        XCTAssertEqual(ShellInstall.buildArguments(workDir: "/W", team: "T"), ["--shell-framework", "/W/shell-framework", "--team-id", "T"])
        XCTAssertEqual(ShellInstall.frameworkPath(workDir: "/W", titleID: "01"), "/W/shell-framework/DmGame01.framework")
        XCTAssertEqual(ShellInstall.projectCommand(repo: "/repo"), ["/bin/bash", "/repo/dm/ios/tools/build_shell.sh", "--prepare-xcode"])
        let env = ShellInstall.projectEnvironment(root: root, frameworks: ["/f/a", "/f/b"], bundleID: "org.nxnative.shell", team: "T",
                                                  python: "/py", path: "/opt/homebrew/bin:/usr/bin", home: "/h", user: "u")
        XCTAssertEqual(env, ["SHELL_DIR": root + "/project", "DM_SHELL_FRAMEWORKS": "/f/a\n/f/b", "DM_BUNDLE_ID": "org.nxnative.shell",
                             "DM_TEAM_ID": "T", "DM_XCODE_DERIVED_DATA": root + "/derived-data", "FONT_PY": "/py",
                             "PATH": "/opt/homebrew/bin:/usr/bin", "HOME": "/h", "USER": "u", "LANG": "en_US.UTF-8"])
        let build = ["/x", "xcodebuild", "-project", root + "/project/DmShell.xcodeproj", "-scheme", "DmShell", "-configuration", "Release",
                     "-destination", "id=D", "-derivedDataPath", root + "/derived-data", "-allowProvisioningUpdates", "DEVELOPMENT_TEAM=T"]
        XCTAssertEqual(ShellInstall.buildCommand(xcrun: "/x", root: root, device: "D", team: "T", bundleID: "org.nxnative.shell"),
                       build + ["PRODUCT_BUNDLE_IDENTIFIER=org.nxnative.shell", "build"])
        XCTAssertEqual(ShellInstall.buildCommand(xcrun: "/x", root: root, device: "D", team: "T", bundleID: ShellLibrary.teamVariant(team: "T")),
                       build + ["PRODUCT_BUNDLE_IDENTIFIER=org.nxnative.shell.T", "build"])
        XCTAssertEqual(ShellInstall.installCommand(xcrun: "/x", device: "D", app: ShellInstall.appPath(root: root)),
                       ["/x", "devicectl", "device", "install", "app", "--device", "D",
                        root + "/derived-data/Build/Products/Release-iphoneos/DmShell.app"])
        let list = ShellInstall.listCommand(xcrun: "/x", device: "D", bundleID: "b", titleID: "01", json: "/t.json")
        XCTAssertEqual(list, ["/x", "devicectl", "device", "info", "files", "--device", "D", "--domain-type", "appDataContainer",
                              "--domain-identifier", "b", "--subdirectory", "Documents/games/01", "--json-output", "/t.json"])
        let copy = ShellInstall.copyCommand(xcrun: "/x", device: "D", bundleID: "b", titleID: "01", source: "/a/aoc/1.img", relativePath: "aoc/1.img")
        XCTAssertEqual(copy, ["/x", "devicectl", "device", "copy", "to", "--device", "D", "--source", "/a/aoc/1.img",
                              "--destination", "Documents/games/01/aoc/1.img", "--domain-type", "appDataContainer", "--domain-identifier", "b"])
        for command in [build, list, copy, ShellInstall.projectCommand(repo: "/r"), ShellInstall.installCommand(xcrun: "/x", device: "D", app: "/a")] {
            XCTAssertFalse(command.contains("--remove-existing-content"))
        }
    }

    func testShellAppPathsForAResign() {
        let app = "/Volumes/NX/NX2Apple-shell/derived-data/Build/Products/Release-iphoneos/DmShell.app"
        let paths = ShellInstall.paths(ofApp: app)
        XCTAssertEqual(paths?.root, "/Volumes/NX/NX2Apple-shell")
        XCTAssertEqual(paths?.project, "/Volumes/NX/NX2Apple-shell/project/DmShell.xcodeproj")
        XCTAssertEqual(paths?.derived, "/Volumes/NX/NX2Apple-shell/derived-data")
        XCTAssertNil(ShellInstall.paths(ofApp: "/x/0100_build/xcode-derived-data/Build/Products/Release-iphoneos/DmIOS.app"))
    }

    // ---- the listing ----

    func testListingParserOnTheRealShapeAndOnTheErrorJSON() {
        let listing = """
        {"info": {"outcome": "success"}, "result": {"files": [
          {"name": "aoc", "relativePath": "aoc", "metadata": {"size": 96}, "resources": {"isDirectory": true}},
          {"name": "aoc/1.img", "relativePath": "aoc/1.img", "metadata": {"size": 4}, "resources": {"isDirectory": false}},
          {"name": "romfs.img", "relativePath": "romfs.img", "metadata": {"size": 10000000000}, "resources": {"isDirectory": false}}]}}
        """
        XCTAssertEqual(ShellInstall.parseListing(Data(listing.utf8)), ["aoc/1.img": 4, "romfs.img": 10_000_000_000])
        let failed = #"{"error": {"code": 6, "domain": "NSCocoaErrorDomain"}, "info": {"outcome": "failed"}}"#
        XCTAssertEqual(ShellInstall.parseListing(Data(failed.utf8)), [:])
        XCTAssertEqual(ShellInstall.parseListing(nil), [:])
        XCTAssertEqual(ShellInstall.parseListing(Data("not json".utf8)), [:])
    }

    func testBannerGoesIntoTheFrameworkAndTheCacheStaysUntouched() throws {
        let cache = path("artwork"), fw = path("DmGame\(titleID).framework"), picked = path("mine.png")
        try write(cache + "/\(titleID).jpg", "jpeg")
        try fm.createDirectory(atPath: fw, withIntermediateDirectories: true)
        let banners = URL(fileURLWithPath: cache)
        XCTAssertEqual(ShellInstall.placeBanner(titleID: titleID, framework: fw, banners: banners, picked: nil), cache + "/\(titleID).jpg")
        XCTAssertEqual(try String(contentsOfFile: fw + "/banner.jpg", encoding: .utf8), "jpeg")
        XCTAssertTrue(fm.fileExists(atPath: cache + "/\(titleID).jpg"), "the cache is only read")
        try write(picked, "png")
        XCTAssertEqual(ShellInstall.placeBanner(titleID: titleID, framework: fw, banners: banners, picked: picked), picked, "the player's own picture wins")
        XCTAssertTrue(fm.fileExists(atPath: fw + "/banner.png"))
        XCTAssertFalse(fm.fileExists(atPath: fw + "/banner.jpg"), "one banner, the older one goes")
        XCTAssertNil(ShellInstall.placeBanner(titleID: "0100000000000000", framework: fw, banners: banners, picked: nil))
        XCTAssertFalse(fm.fileExists(atPath: fw + "/banner.png"), "no picture: the library falls back to the icon")
    }

    func testDiffByPathAndSizeSkippingDotFiles() throws {
        let archive = path("games", titleID)
        try write(archive + "/romfs.img", "0123456789")
        try write(archive + "/aoc/1.img", "abcd")
        try write(archive + "/.packstamp", "stamp")
        let local = ShellInstall.localFiles(in: archive)
        XCTAssertEqual(local, ["romfs.img": 10, "aoc/1.img": 4])
        XCTAssertEqual(ShellInstall.filesToCopy(local: local, device: [:]), ["aoc/1.img", "romfs.img"])
        XCTAssertEqual(ShellInstall.filesToCopy(local: local, device: ["romfs.img": 10, "aoc/1.img": 4, "extra.bin": 1]), [])
        XCTAssertEqual(ShellInstall.filesToCopy(local: local, device: ["romfs.img": 10, "aoc/1.img": 5]), ["aoc/1.img"])
    }

    func testScriptFailurePrefersTheRedLine() {
        let out = "[12:00:00] checking\n[RED] games of different profiles in one shell: A (x), B (y)\n[12:00:01] FAIL: the frameworks in DM_SHELL_FRAMEWORKS (above)\n"
        XCTAssertEqual(ShellInstall.scriptFailure(out), "games of different profiles in one shell: A (x), B (y)")
        XCTAssertEqual(ShellInstall.scriptFailure("[12:00:01] FAIL: mkdir x\n"), "mkdir x")
        XCTAssertEqual(ShellInstall.scriptFailure("boom\n"), "boom")
    }

    func testEveryLanguageHasTheShellTexts() {
        for key in ["build.iosNote", "shell.projectStage", "shell.projectFailed", "shell.checkStage", "shell.dataAlready",
                    "shell.noFramework", "shell.needsDevice", "shell.copySize", "shell.copyWired", "shell.copyWifi", "shell.copyWifiOne",
                    "shell.copyWifiMinute", "shell.copyNotConnected", "shell.copyWaiting", "shell.copyTitle", "shell.copyContinue",
                    "shell.copyWaitCable", "shell.copySkip", "shell.copyStopWaiting", "shell.retry", "shell.notPaired",
                    "shell.copyIncomplete", "fail.devicePairing.what", "fail.devicePairing.next", "fail.shellDataIncomplete.what",
                    "fail.shellDataIncomplete.next"] {
            let both = L10n.table[key]
            XCTAssertNotNil(both, key)
            XCTAssertNotNil(L10n.sv[key], key)
            for text in [both?.zh, both?.en, L10n.sv[key]].compactMap({ $0 }) {
                XCTAssertFalse(text.contains(";") || text.contains("；"), key)
            }
        }
        XCTAssertEqual(L10n.string("build.iosNote", .en), "One app on your iPhone or iPad for all your games.")
    }

    // ---- the stand-ins ----

    /// A fake device: `container/<bundle ID>/...` is the app data container of each app.
    private var container: String { path("device") }
    private var state: String { path("state") }

    /// xcodebuild and devicectl as one script. `state/taken` makes the plain bundle ID "registered to another team".
    private func makeXcrun() throws -> String {
        try fm.createDirectory(atPath: state, withIntermediateDirectories: true)
        let xcrun = path("xcrun")
        try """
        #!/usr/bin/python3
        import sys, os, json, shutil
        a = sys.argv[1:]
        CONT, STATE = '\(container)', '\(state)'
        open(STATE + '/calls.txt', 'a').write(' '.join(a) + '\\n')
        def val(flag): return a[a.index(flag) + 1] if flag in a else None
        if a[0] == 'xcodebuild':
            bundle = [x.split('=', 1)[1] for x in a if x.startswith('PRODUCT_BUNDLE_IDENTIFIER=')][0]
            if os.path.exists(STATE + '/taken') and bundle == 'org.nxnative.shell':
                print('error: The app identifier "' + bundle + '" cannot be registered to your development team because it is not available. Change your bundle identifier to a unique string to try again.', flush=True)
                sys.exit(65)
            if os.path.exists(STATE + '/nomemory') and not os.path.exists(os.path.dirname(val('-project')) + '/entitlements-empty'):
                print('error: Provisioning profile iOS Team Provisioning Profile: ' + bundle + ' doesn\\'t include the Increased Memory Limit capability.', flush=True)
                sys.exit(65)
            app = val('-derivedDataPath') + '/Build/Products/Release-iphoneos/DmShell.app'
            os.makedirs(app, exist_ok=True)
            open(app + '/bundle.txt', 'w').write(bundle)
            print('CodeSign ' + app, flush=True)
        elif a[:3] == ['devicectl', 'list', 'devices']:
            n = (int(open(STATE + '/list-count').read()) if os.path.exists(STATE + '/list-count') else 0) + 1
            open(STATE + '/list-count', 'w').write(str(n))
            after = int(open(STATE + '/switch-after').read()) if os.path.exists(STATE + '/switch-after') else None
            src = STATE + ('/devices-wired.json' if after is not None and n > after else '/devices.json')
            if not os.path.exists(src): src = STATE + '/devices-default.json'
            shutil.copyfile(src, val('--json-output'))
        elif a[:4] == ['devicectl', 'device', 'copy', 'from']:
            src = CONT + '/' + val('--domain-identifier') + '/' + val('--source')
            if not os.path.exists(src):
                print('ERROR: The file couldn\\'t be opened because there is no such file. (NSCocoaErrorDomain error 260)', flush=True)
                sys.exit(1)
            shutil.copyfile(src, val('--destination'))
        elif a[:3] == ['devicectl', 'device', 'install']:
            app = a[-1]
            bundle = open(app + '/bundle.txt').read()
            os.makedirs(CONT + '/' + bundle + '/Documents', exist_ok=True)   # an existing container is kept as it is
            print('45%', flush=True); print('App installed', flush=True)
        elif a[:4] == ['devicectl', 'device', 'copy', 'to']:
            dest = CONT + '/' + val('--domain-identifier') + '/' + val('--destination')
            src = val('--source')
            if val('--remove-existing-content') == 'true':   # a real device deletes the destination's siblings too
                parent = os.path.dirname(dest)
                for e in (os.listdir(parent) if os.path.isdir(parent) else []):
                    p = parent + '/' + e
                    shutil.rmtree(p) if os.path.isdir(p) else os.remove(p)
            if os.path.exists(STATE + '/fail-on') and dest.endswith(open(STATE + '/fail-on').read().strip()):
                os.makedirs(os.path.dirname(dest), exist_ok=True)   # a locked device: half of the file is there, then the copy stops
                data = open(src, 'rb').read()
                open(dest, 'wb').write(data[:len(data) // 2])
                print('ERROR: The device is locked. (com.apple.dt.CoreDeviceError error 1)', flush=True)
                sys.exit(1)
            if os.path.isdir(src):
                os.makedirs(dest, exist_ok=True)
                shutil.copytree(src, dest, dirs_exist_ok=True)   # merged into the destination
            else:
                os.makedirs(os.path.dirname(dest), exist_ok=True)   # a file destination makes the parents and names the file
                shutil.copyfile(src, dest)
            print('60%', flush=True); print('Copied', flush=True)
        elif a[:4] == ['devicectl', 'device', 'info', 'files']:
            base = CONT + '/' + val('--domain-identifier') + '/' + val('--subdirectory')
            out = val('--json-output')
            if not os.path.isdir(base):
                json.dump({'error': {'code': 6}, 'info': {'outcome': 'failed'}}, open(out, 'w'))
                print('ERROR: The file couldn\\'t be opened because there is no such file. (NSCocoaErrorDomain error 260)', flush=True)
                sys.exit(1)
            files = []
            for root, dirs, names in os.walk(base):
                for n in dirs + names:
                    full = root + '/' + n; rel = os.path.relpath(full, base)
                    files.append({'name': rel, 'relativePath': rel, 'metadata': {'size': os.path.getsize(full)},
                                  'resources': {'isDirectory': os.path.isdir(full)}})
            json.dump({'info': {'outcome': 'success'}, 'result': {'files': files}}, open(out, 'w'))
        """.write(toFile: xcrun, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xcrun)
        return xcrun
    }

    /// A checkout with a stand-in build_shell.sh: it records its environment, makes the project folder, and refuses when asked to.
    private func makeRepo() throws -> String {
        let repo = path("repo")
        try write(repo + "/dm/ios/tools/build_shell.sh", """
        #!/bin/bash
        [ "$1" = "--prepare-xcode" ] || { echo "FAIL: no --prepare-xcode"; exit 1; }
        if [ -f "\(state)/refuse" ]; then
          echo "[RED] games of different profiles in one shell: A (x), B (y)"
          echo "[12:00:01] FAIL: the frameworks in DM_SHELL_FRAMEWORKS (above)"
          exit 1
        fi
        mkdir -p "$SHELL_DIR/DmShell.xcodeproj"
        env | sort > "\(state)/shell-env.txt"
        if [ "${DM_ENTITLEMENTS+set}" = set ] && [ -z "$DM_ENTITLEMENTS" ]; then touch "$SHELL_DIR/entitlements-empty"; else rm -f "$SHELL_DIR/entitlements-empty"; fi
        """)
        try write(repo + "/frontend-ios/Package.swift", "// swift-tools-version: 5.9\n")
        return repo
    }

    private struct Fixture {
        var xcrun: String, repo: String, framework: String, archive: String, root: String
        func args(name: String = "Test Game", extra: [String] = []) -> [String] {
            ["--install-shell", "--framework", framework, "--archive", archive, "--title-id", "0100535012974000", "--name", name,
             "--device", "00008150-AAAA", "--team", "TEAM123456", "--repo", repo, "--shell-root", root,
             "--python", "/usr/bin/python3", "--xcrun", xcrun] + extra
        }
    }

    private func makeFixture() throws -> Fixture {
        guard fm.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("System Python is required for the process fixture") }
        let framework = path("work/shell-framework/DmGame\(titleID).framework")
        try write(framework + "/game.manifest.json", "{}")
        let archive = path("out/games", titleID)
        try write(archive + "/romfs.img", "0123456789")
        try write(archive + "/aoc/1.img", "abcd")
        try write(archive + "/.packstamp", "stamp")
        let made = Fixture(xcrun: try makeXcrun(), repo: try makeRepo(), framework: framework, archive: archive, root: path("NX2Apple-shell"))
        try writeDevices(state + "/devices-default.json", [(device, "wired")])
        return made
    }

    /// `devicectl list devices` output in its real shape: transportType is "wired" (cable) or "localNetwork" (Wi-Fi), and absent
    /// for a device that is not connected.
    private func writeDevices(_ file: String, _ entries: [(udid: String, transport: String?)]) throws {
        let list: [[String: Any]] = entries.map { e in
            var connection: [String: Any] = ["pairingState": "paired", "tunnelState": e.transport == nil ? "unavailable" : "connected"]
            if let t = e.transport { connection["transportType"] = t }
            return ["hardwareProperties": ["udid": e.udid, "reality": "physical", "platform": "iOS", "marketingName": "iPhone 17 Pro"],
                    "deviceProperties": ["name": "Z", "osVersionNumber": "27.0"], "connectionProperties": connection]
        }
        try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success"], "result": ["devices": list]]).write(to: URL(fileURLWithPath: file))
    }

    private func installer(_ f: Fixture) -> ShellInstaller {
        var i = ShellInstaller(xcrun: f.xcrun, repo: f.repo, python: "/usr/bin/python3", root: f.root, device: device, team: team)
        i.deviceName = "Z"
        i.pollInterval = 0.02
        i.resources = nil
        return i
    }

    private func install(_ i: ShellInstaller, _ f: Fixture) -> ShellInstaller.Outcome {
        i.install(framework: f.framework, titleID: titleID, name: "Test Game", archive: f.archive)
    }

    private func run(_ f: Fixture, _ extra: [String] = []) -> (status: Int32, output: String) {
        var output = ""
        let defaults = UserDefaults(suiteName: "nspb-shell-" + UUID().uuidString)!
        let status = ShellCLI.run(f.args(extra: extra), defaults: defaults) { output += $0 }
        return (status, output)
    }

    private func mirrored(_ root: String, _ id: String? = nil) -> String { ShellInstall.mirroredFramework(root: root, titleID: id ?? titleID) }

    private var calls: [String] { ((try? String(contentsOfFile: state + "/calls.txt", encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    private func copies() -> [String] { calls.filter { $0.hasPrefix("devicectl device copy to") } }

    // ---- the mirror in the shell folder is the primary copy ----

    func testInstallMirrorsTheBuildAndShellJsonPointsAtTheMirror() throws {
        let f = try makeFixture()
        let r = run(f)
        XCTAssertEqual(r.status, 0, r.output)
        let mirror = mirrored(f.root)
        XCTAssertEqual(try String(contentsOfFile: mirror + "/game.manifest.json"), "{}")
        XCTAssertEqual(ShellLibrary.load(root: f.root).games.map(\.framework), [mirror])
        // a later write to the build folder does not reach the mirror
        try write(f.framework + "/game.manifest.json", "changed")
        XCTAssertEqual(try String(contentsOfFile: mirror + "/game.manifest.json"), "{}")
    }

    func testInstallMirrorsAGameBuiltBeforeTheMirrorExisted() throws {
        let f = try makeFixture()
        let otherID = "0100AAAA00000000"
        let other = path("work2/shell-framework/DmGame\(otherID).framework")
        try write(other + "/game.manifest.json", "other")
        var library = ShellLibrary()
        library.add(.init(titleID: otherID, name: "Other", framework: other))   // what an install before the mirror wrote
        try library.save(root: f.root)
        let r = run(f)
        XCTAssertEqual(r.status, 0, r.output)
        let saved = ShellLibrary.load(root: f.root)
        XCTAssertEqual(Set(saved.games.map(\.framework)), [mirrored(f.root), mirrored(f.root, otherID)])
        XCTAssertEqual(try String(contentsOfFile: mirrored(f.root, otherID) + "/game.manifest.json"), "other")
    }

    func testGameWithoutBuildFolderPlaysFromItsMirrorAndOneWithNeitherIsDropped() throws {
        let f = try makeFixture()
        let keptID = "0100BBBB00000000", lostID = "0100CCCC00000000"
        try write(mirrored(f.root, keptID) + "/game.manifest.json", "kept")
        var library = ShellLibrary()
        library.add(.init(titleID: keptID, name: "Kept", framework: path("gone/DmGame\(keptID).framework")))
        library.add(.init(titleID: lostID, name: "Lost", framework: path("gone/DmGame\(lostID).framework")))
        try library.save(root: f.root)
        let r = run(f)
        XCTAssertEqual(r.status, 0, r.output)
        XCTAssertEqual(Set(ShellLibrary.load(root: f.root).games.map(\.titleID)), [titleID, keptID])
        XCTAssertEqual(ShellLibrary.load(root: f.root).games.first { $0.titleID == keptID }?.framework, mirrored(f.root, keptID))
    }

    func testFailedMirrorIsLoggedAndTheGameKeepsItsBuildPath() throws {
        let f = try makeFixture()
        try write(f.root + "/frameworks", "a file where the mirror folder should be")
        let r = run(f)
        XCTAssertEqual(r.status, 0, r.output)
        XCTAssertTrue(r.output.contains("\(titleID)'s framework could not be mirrored"), r.output)
        XCTAssertEqual(ShellLibrary.load(root: f.root).games.map(\.framework), [f.framework])
    }

    func testTheFakeDeviceWipesSiblingsWithRemoveExistingContent() throws {
        let f = try makeFixture()
        try write(container + "/b/Documents/games/X/old.bin", "old")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: f.xcrun)
        p.arguments = ["devicectl", "device", "copy", "to", "--device", "D", "--source", f.archive + "/romfs.img", "--destination", "Documents/games/X/romfs.img",
                       "--domain-type", "appDataContainer", "--domain-identifier", "b", "--remove-existing-content", "true"]
        try p.run(); p.waitUntilExit()
        XCTAssertFalse(fm.fileExists(atPath: container + "/b/Documents/games/X/old.bin"))
        XCTAssertTrue(fm.fileExists(atPath: container + "/b/Documents/games/X/romfs.img"))
    }

    // ---- the headless install, end to end ----

    func testHeadlessInstallCopiesOnlyWhatTheDeviceLacksAndKeepsTheSave() throws {
        let f = try makeFixture()
        let bundle = "org.nxnative.shell"
        let save = container + "/\(bundle)/Documents/save/slot1.bin"
        try write(save, "my save")   // the app is on the device already, with a save

        // first run: the game's folder does not exist on the device (error JSON), so both files go
        var r = run(f)
        XCTAssertEqual(r.status, 0, r.output)
        XCTAssertTrue(r.output.contains("OK: Installed on"), r.output)
        let games = container + "/\(bundle)/Documents/games/\(titleID)"
        XCTAssertEqual(try String(contentsOfFile: games + "/romfs.img"), "0123456789")
        XCTAssertEqual(try String(contentsOfFile: games + "/aoc/1.img"), "abcd")
        XCTAssertFalse(fm.fileExists(atPath: games + "/.packstamp"))
        XCTAssertEqual(copies().count, 2)
        XCTAssertEqual(try String(contentsOfFile: save), "my save")
        let env = try String(contentsOfFile: state + "/shell-env.txt")
        for line in ["DM_BUNDLE_ID=org.nxnative.shell", "DM_SHELL_FRAMEWORKS=\(mirrored(f.root))", "DM_TEAM_ID=TEAM123456",
                     "SHELL_DIR=\(f.root)/project", "DM_XCODE_DERIVED_DATA=\(f.root)/derived-data", "FONT_PY=/usr/bin/python3", "DM_SHELL_PACKAGE=\(f.repo)/frontend-ios"] {
            XCTAssertTrue(env.contains(line), line)
        }
        let library = ShellLibrary.load(root: f.root)
        XCTAssertEqual(library.games, [.init(titleID: titleID, name: "Test Game", framework: mirrored(f.root))])
        XCTAssertEqual(library.team, team)

        // second run, same data: nothing is copied
        r = run(f)
        XCTAssertEqual(r.status, 0, r.output)
        XCTAssertEqual(copies().count, 2)
        XCTAssertTrue(r.output.contains("the game data was already on the device"), r.output)
        XCTAssertEqual(try String(contentsOfFile: save), "my save")

        // a file with another size: only that one is copied
        try write(f.archive + "/aoc/1.img", "abcdef")
        r = run(f)
        XCTAssertEqual(r.status, 0, r.output)
        XCTAssertEqual(copies().count, 3)
        XCTAssertTrue(copies().last?.contains("--destination Documents/games/\(titleID)/aoc/1.img") ?? false)
        XCTAssertEqual(try String(contentsOfFile: games + "/aoc/1.img"), "abcdef")
        XCTAssertEqual(try String(contentsOfFile: games + "/romfs.img"), "0123456789")
        XCTAssertEqual(try String(contentsOfFile: save), "my save")

        XCTAssertFalse(calls.contains { $0.contains("--remove-existing-content") })
        XCTAssertEqual(calls.filter { $0.hasPrefix("devicectl device install app") }.count, 3)
    }

    func testTeamVariantRetryStoresTheBundleIDAndTheNextRunUsesIt() throws {
        let f = try makeFixture()
        try write(state + "/taken", "")
        let variant = "org.nxnative.shell." + team
        let save = container + "/\(variant)/Documents/save/slot1.bin"
        try write(save, "my save")

        var r = run(f)
        XCTAssertEqual(r.status, 0, r.output)
        XCTAssertEqual(ShellLibrary.load(root: f.root).bundleID, variant)
        var builds = calls.filter { $0.hasPrefix("xcodebuild") }
        XCTAssertEqual(builds.count, 2)
        XCTAssertTrue(builds[0].contains("PRODUCT_BUNDLE_IDENTIFIER=org.nxnative.shell build"))
        XCTAssertTrue(builds[1].contains("PRODUCT_BUNDLE_IDENTIFIER=\(variant) build"))
        XCTAssertEqual(try String(contentsOfFile: container + "/\(variant)/Documents/games/\(titleID)/romfs.img"), "0123456789")

        r = run(f)   // the plain identifier is not tried again
        XCTAssertEqual(r.status, 0, r.output)
        builds = calls.filter { $0.hasPrefix("xcodebuild") }
        XCTAssertEqual(builds.count, 3)
        XCTAssertTrue(builds[2].contains("PRODUCT_BUNDLE_IDENTIFIER=\(variant) build"))
        XCTAssertEqual(copies().count, 2)
        XCTAssertEqual(try String(contentsOfFile: save), "my save")
        XCTAssertFalse(calls.contains { $0.contains("--remove-existing-content") })
    }

    func testAFailingProjectScriptReachesThePlayer() throws {
        let f = try makeFixture()
        try write(state + "/refuse", "")
        let r = run(f)
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.output.contains("FAIL: The shared app could not be prepared: games of different profiles in one shell: A (x), B (y)"), r.output)
        XCTAssertFalse(calls.contains { $0.hasPrefix("xcodebuild") || $0.hasPrefix("devicectl device") })   // nothing was signed or installed
    }

    func testMissingShellPackageStopsBeforeTheScript() throws {
        let f = try makeFixture()
        try fm.removeItem(atPath: f.repo + "/frontend-ios")
        let r = run(f)
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.output.contains("FAIL: The shared app could not be prepared: no frontend-ios Swift package"), r.output)
        XCTAssertFalse(fm.fileExists(atPath: state + "/shell-env.txt"), "build_shell.sh must not run")
    }

    func testCLIChecksItsArguments() throws {
        var output = ""
        XCTAssertEqual(ShellCLI.run(["--install-shell", "--framework", "/x"], defaults: UserDefaults(suiteName: "nspb-shell-" + UUID().uuidString)!) { output += $0 }, 1)
        XCTAssertTrue(output.hasPrefix("usage: NSPortBuilder --install-shell"))
        let f = try makeFixture()
        output = ""
        XCTAssertEqual(ShellCLI.run(f.args(extra: ["--framework", path("missing.framework")]),
                                    defaults: UserDefaults(suiteName: "nspb-shell-" + UUID().uuidString)!) { output += $0 }, 1)
        XCTAssertTrue(output.contains("framework was not found"), output)
    }

    // ---- the lead's three: memory capability, free space, the shell's log ----

    func testMemoryCapabilityFreeSpaceAndLogCommand() {
        XCTAssertTrue(ShellInstall.memoryCapabilityMissing("error: Provisioning profile \"x\" doesn't include the Increased Memory Limit capability."))
        XCTAssertTrue(ShellInstall.memoryCapabilityMissing("doesn't include the com.apple.developer.kernel.increased-memory-limit entitlement"))
        XCTAssertFalse(ShellInstall.memoryCapabilityMissing("error: No profiles for 'org.nxnative.shell' were found"))
        XCTAssertEqual(ShellInstall.shellLogCommand(xcrun: "/x", device: "D", bundleID: "b", destination: "/t.txt"),
                       ["/x", "devicectl", "device", "copy", "from", "--device", "D", "--domain-type", "appDataContainer",
                        "--domain-identifier", "b", "--source", "Documents/shell-log.txt", "--destination", "/t.txt"])
        XCTAssertEqual(ShellInstall.freeSpace(inShellLog: "shell: start\nshell: free space 123 bytes\nshell: free space 4567 bytes\nother\n"), 4567)
        XCTAssertNil(ShellInstall.freeSpace(inShellLog: "shell: start\n"))
        XCTAssertNil(ShellInstall.freeSpace(inShellLog: nil))
        XCTAssertNil(ShellInstall.freeSpace(inShellLog: "shell: free space -1 bytes\n"))
        XCTAssertEqual(ShellInstall.freeSpaceMargin, 2_000_000_000)
    }

    func testNoSpaceRefusesTheCopyAndALaterRunWithRoomCopies() throws {
        let f = try makeFixture()
        let log = container + "/org.nxnative.shell/Documents/shell-log.txt"
        try write(log, "shell: free space 9999999999 bytes\nshell: free space 5 bytes\n")   // the last line counts
        var r = install(installer(f), f)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.hasPrefix("Not enough space on Z"), r.message)
        XCTAssertNil(r.failure)
        XCTAssertTrue(copies().isEmpty)
        try write(log, "shell: free space 100000000000 bytes\n")
        r = install(installer(f), f)
        XCTAssertTrue(r.ok, r.message)
        XCTAssertEqual(copies().count, 2)
    }

    func testMissingMemoryCapabilityFallsBackToASecondSignWithoutEntitlements() throws {
        let f = try makeFixture()
        try write(state + "/nomemory", "")
        let r = install(installer(f), f)
        XCTAssertTrue(r.ok, r.message)
        XCTAssertTrue(r.noMemoryCapability)
        XCTAssertEqual(calls.filter { $0.hasPrefix("xcodebuild") }.count, 2)
        XCTAssertTrue(try String(contentsOfFile: state + "/shell-env.txt").contains("DM_ENTITLEMENTS=\n"))
        XCTAssertEqual(copies().count, 2)
        try fm.removeItem(atPath: state + "/nomemory")
        XCTAssertFalse(install(installer(f), f).noMemoryCapability)   // a team that can carry it signs with it
    }

    // ---- the connection ----

    func testConnectionFromTheRealDeviceList() throws {
        let real = """
        {"info": {"outcome": "success"}, "result": {"devices": [
         {"hardwareProperties": {"udid": "CABLE", "reality": "physical", "platform": "iOS"}, "deviceProperties": {"name": "A"},
          "connectionProperties": {"pairingState": "paired", "transportType": "wired", "tunnelState": "connected"}},
         {"hardwareProperties": {"udid": "WIFI", "reality": "physical", "platform": "iOS"}, "deviceProperties": {"name": "B"},
          "connectionProperties": {"pairingState": "paired", "transportType": "localNetwork", "tunnelState": "connected"}},
         {"hardwareProperties": {"udid": "AWAY", "reality": "physical", "platform": "iOS"}, "deviceProperties": {"name": "C"},
          "connectionProperties": {"pairingState": "paired", "tunnelState": "unavailable"}},
         {"hardwareProperties": {"udid": "NEW", "reality": "physical", "platform": "iOS"}, "deviceProperties": {"name": "D"},
          "connectionProperties": {"pairingState": "unpaired", "tunnelState": "unavailable"}}]}}
        """
        let devices = DeviceTools.parseDevices(Data(real.utf8))
        XCTAssertEqual(devices.first { $0.id == "CABLE" }?.transport, "wired")
        XCTAssertEqual(devices.first { $0.id == "AWAY" }?.transport, "")
        XCTAssertEqual(ShellInstall.connection(of: "CABLE", in: devices), .wired)
        XCTAssertEqual(ShellInstall.connection(of: "WIFI", in: devices), .network)
        XCTAssertEqual(ShellInstall.connection(of: "AWAY", in: devices), .notConnected)
        XCTAssertEqual(ShellInstall.connection(of: "NEW", in: devices), .notPaired)      // listed unpaired
        XCTAssertEqual(ShellInstall.connection(of: "NOPE", in: devices), .notPaired)     // not listed at all
        XCTAssertEqual(ShellInstall.wifiEstimate(bytes: 15_000_000_000).low, 10)
        XCTAssertEqual(ShellInstall.wifiEstimate(bytes: 15_000_000_000).high, 15)
        XCTAssertEqual(ShellInstall.wifiEstimate(bytes: 5).low, 1)
    }

    func testOverACableTheNoteSaysToKeepTheDeviceUnlockedAndTheCopyStarts() throws {
        let f = try makeFixture()
        var plans: [ShellCopyPlan] = []
        var i = installer(f)
        i.decideCopy = { plans.append($0); return .copy }
        var lines = ""
        i.log = { lines += $0 }
        let r = install(i, f)
        XCTAssertTrue(r.ok, r.message)
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans.first?.connection, .wired)
        XCTAssertEqual(plans.first?.connectionText, "Keep Z unlocked until the copy finishes.")
        XCTAssertEqual(plans.first?.files, 2)
        XCTAssertEqual(plans.first?.canWaitForCable, false)
        XCTAssertTrue(lines.contains("Keep Z unlocked"), "the terminal prints the same note")
        XCTAssertEqual(copies().count, 2)
    }

    func testOverWiFiTheHintHasTheEstimateAndNotNowCopiesNothing() throws {
        let f = try makeFixture()
        try writeDevices(state + "/devices.json", [(device, "localNetwork")])
        var plans: [ShellCopyPlan] = []
        var i = installer(f)
        i.decideCopy = { plans.append($0); return .skip }
        let r = install(i, f)
        XCTAssertTrue(r.ok && r.copySkipped, r.message)
        XCTAssertEqual(plans.first?.connection, .network)
        XCTAssertEqual(plans.first?.canWaitForCable, true)
        XCTAssertTrue(plans.first?.connectionText.hasPrefix("Connected over Wi-Fi: copying 1 KB takes about a minute") ?? false, plans.first?.connectionText ?? "")
        XCTAssertTrue(plans.first?.connectionText.hasSuffix("A cable is faster.") ?? false)
        XCTAssertTrue(copies().isEmpty)
    }

    func testWaitForACableStartsTheCopyWhenTheDeviceShowsUpWired() throws {
        let f = try makeFixture()
        try writeDevices(state + "/devices.json", [(device, "localNetwork")])
        try writeDevices(state + "/devices-wired.json", [(device, "wired")])
        try write(state + "/switch-after", "3")   // the precheck, the plan and the first poll still see Wi-Fi
        var i = installer(f)
        var waits: [Bool] = []
        i.decideCopy = { _ in .waitForCable }
        i.waiting = { waits.append($0) }
        let r = install(i, f)
        XCTAssertTrue(r.ok && !r.copySkipped, r.message)
        XCTAssertEqual(waits, [true, false])
        XCTAssertEqual(copies().count, 2)
        XCTAssertEqual(try String(contentsOfFile: container + "/org.nxnative.shell/Documents/games/\(titleID)/romfs.img"), "0123456789")
    }

    func testCancellingTheWaitCopiesNothing() throws {
        let f = try makeFixture()
        try writeDevices(state + "/devices.json", [(device, "localNetwork")])   // never wired
        var i = installer(f)
        var waits: [Bool] = [], polls = 0
        i.decideCopy = { _ in .waitForCable }
        i.waiting = { waits.append($0) }
        i.waitCancelled = { polls += 1; return polls > 3 }
        let r = install(i, f)
        XCTAssertTrue(r.ok && r.copySkipped, r.message)
        XCTAssertEqual(waits, [true, false])
        XCTAssertTrue(copies().isEmpty)
    }

    func testAnUnknownDeviceGetsThePairingStepsBeforeAnythingIsBuilt() throws {
        let f = try makeFixture()
        try writeDevices(state + "/devices-default.json", [("00008150-OTHER", "wired")])
        let r = install(installer(f), f)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.failure, .devicePairing)
        XCTAssertTrue(r.message.contains("Connect it with a cable, tap Trust on the device and enter its passcode"), r.message)
        XCTAssertFalse(fm.fileExists(atPath: state + "/shell-env.txt"), "build_shell.sh did not run")
        XCTAssertFalse(calls.contains { $0.hasPrefix("xcodebuild") || $0.hasPrefix("devicectl device") })
        var output = ""
        XCTAssertEqual(ShellCLI.run(f.args(), defaults: UserDefaults(suiteName: "nspb-shell-" + UUID().uuidString)!) { output += $0 }, 1)
        XCTAssertTrue(output.contains("FAIL: ") && output.contains("tap Trust"), output)
    }

    // ---- a copy that fails midway ----

    func testAFailedCopyIsIncompleteAndRetryCopiesOnlyWhatIsMissingOrShort() throws {
        let f = try makeFixture()
        let games = container + "/org.nxnative.shell/Documents/games/\(titleID)"
        try write(state + "/fail-on", "romfs.img")
        var r = install(installer(f), f)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.failure, .shellDataIncomplete)
        XCTAssertTrue(r.message.contains("The game data on Z is incomplete: ERROR: The device is locked."), r.message)
        XCTAssertTrue(r.message.hasSuffix("Retry finishes it."), r.message)
        XCTAssertEqual(try String(contentsOfFile: games + "/aoc/1.img"), "abcd")
        XCTAssertEqual(try String(contentsOfFile: games + "/romfs.img"), "01234")   // a short file on the device
        let signs = calls.filter { $0.hasPrefix("xcodebuild") }.count, installs = calls.filter { $0.hasPrefix("devicectl device install") }.count

        try fm.removeItem(atPath: state + "/fail-on")
        let before = copies().count
        r = installer(f).installData(titleID: titleID, archive: f.archive)
        XCTAssertTrue(r.ok, r.message)
        XCTAssertEqual(copies().count - before, 1, "only the short romfs.img")
        XCTAssertTrue(copies().last?.contains("Documents/games/\(titleID)/romfs.img") ?? false)
        XCTAssertEqual(try String(contentsOfFile: games + "/romfs.img"), "0123456789")
        XCTAssertEqual(calls.filter { $0.hasPrefix("xcodebuild") }.count, signs, "Retry does not sign again")
        XCTAssertEqual(calls.filter { $0.hasPrefix("devicectl device install") }.count, installs, "or install again")

        try write(games + "/aoc/1.img", "ab")   // a file that is short on the device is copied again
        let again = copies().count
        r = installer(f).installData(titleID: titleID, archive: f.archive)
        XCTAssertTrue(r.ok, r.message)
        XCTAssertEqual(copies().count - again, 1)
        XCTAssertTrue(copies().last?.contains("aoc/1.img") ?? false)
        XCTAssertEqual(installer(f).installData(titleID: titleID, archive: f.archive).message, "Installed on Z, the game data was already on the device")
    }

    // ---- through the model: the build with the third target, and the re-sign ----

    @MainActor func testBuildWithTheShellTargetInstallsAndResignsTheSharedApp() throws {
        let f = try makeFixture()
        let keysSaved = ["repoPath", "buildTarget", "buildOutputDirectory", "installDevice", "signingTeam", "shellRoot"].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { for (key, value) in keysSaved { UserDefaults.standard.set(value, forKey: key) } }
        UserDefaults.standard.set(f.root, forKey: "shellRoot")
        let model = BuildModel()
        model.repoPath = f.repo
        model.target = "ios"
        model.outDir = path("out")
        model.pythonPath = "/usr/bin/python3"
        model.dotnetPath = "/usr/bin/true"
        model.depsChecked = true
        model.deps = [Dep(id: "test", name: "test", hint: "", present: true, installCmd: [])]
        model.installDevice = device
        model.signingTeam = team
        model.xcrunPath = f.xcrun
        try write(f.repo + "/dm/tools/nx_extract/Program.cs", "")
        for tool in BuildModel.requiredTools.filter({ $0 != BuildModel.buildScript }) { try write(f.repo + "/" + tool, "") }
        // the packer stand-in writes the image from the extracted RomFS
        try write(f.repo + "/dm/tools/romfs_image.py", "import sys\nopen(sys.argv[3], 'wb').write(b'image')\n")
        try write(f.repo + "/scripts/build_ipa_from_nsp.py", """
        import sys, json, pathlib
        open('\(state)/script.txt', 'w').write(' '.join(sys.argv[1:]))
        work = pathlib.Path(sys.argv[sys.argv.index('--work-dir') + 1])
        fw = pathlib.Path(sys.argv[sys.argv.index('--shell-framework') + 1]) / 'DmGame\(titleID).framework'
        fw.mkdir(parents=True); (fw / 'game.manifest.json').write_text('{}')
        (work / 'extract/v0/RomFS').mkdir(parents=True); (work / 'extract/v0/RomFS/data.bin').write_bytes(b'game')
        print(json.dumps(dict(ev='stage', k=1, n=1, name='framework')), flush=True)
        print(json.dumps(dict(ev='stage_end', k=1, name='framework', ok=True, summary='', elapsed=1)), flush=True)
        """)
        let base = temporary.appendingPathComponent("Test [\(titleID)].nsp"), keys = temporary.appendingPathComponent("prod.keys")
        try Data([0]).write(to: base); try Data().write(to: keys)
        model.slots[0].paths = [base.path]; model.slots[3].paths = [keys.path]
        try fm.removeItem(atPath: f.archive)   // the build's own archive step makes it

        let finished = expectation(description: "Installed")
        let token = model.$done.filter { $0 }.prefix(1).sink { _ in finished.fulfill() }
        let asked = model.$shellCopy.compactMap { $0 }.prefix(1).sink { _ in model.answerShellCopy(.copy) }
        model.startBuild()
        wait(for: [finished], timeout: 30)
        withExtendedLifetime(token) {}; withExtendedLifetime(asked) {}

        let script = try String(contentsOfFile: state + "/script.txt")
        XCTAssertTrue(script.contains("--shell-framework \(temporary.path)/out/\(titleID)_build/shell-framework --team-id \(team)"), script)
        XCTAssertFalse(script.contains("--prepare-xcode"))
        XCTAssertEqual(model.installedOn, device)
        XCTAssertEqual(model.installedAppPath, f.root + "/derived-data/Build/Products/Release-iphoneos/DmShell.app")
        XCTAssertFalse(model.running)
        let games = container + "/org.nxnative.shell/Documents/games/\(titleID)"
        XCTAssertTrue(fm.fileExists(atPath: games + "/romfs.img"))
        XCTAssertEqual(ShellLibrary.load(root: f.root).games.map(\.titleID), [titleID])

        // the re-sign after seven days: same project, same identifier, same app
        try write(container + "/org.nxnative.shell/Documents/save/slot1.bin", "my save")
        let before = calls.count
        let resigned = expectation(description: "Re-signed")
        model.resignOnDevice(app: model.installedAppPath, device: device) { resigned.fulfill() }
        wait(for: [resigned], timeout: 30)
        let log = Array(calls.dropFirst(before))
        let build = try XCTUnwrap(log.first { $0.hasPrefix("xcodebuild") })
        XCTAssertTrue(build.contains("-project \(f.root)/project/DmShell.xcodeproj -scheme DmShell"), build)
        XCTAssertTrue(build.contains("PRODUCT_BUNDLE_IDENTIFIER=org.nxnative.shell build"), build)
        XCTAssertEqual(log.filter { $0.hasPrefix("devicectl device install app") }.count, 1)
        XCTAssertTrue(log.allSatisfy { !$0.contains("--remove-existing-content") })
        XCTAssertEqual(try String(contentsOfFile: container + "/org.nxnative.shell/Documents/save/slot1.bin"), "my save")
        XCTAssertEqual(model.doneNote, String(format: model.t("dev.resigned"), "iPhone"))
    }

    @MainActor private func makeModel(_ f: Fixture) throws -> BuildModel {
        let model = BuildModel()
        model.repoPath = f.repo
        model.target = "ios"
        model.outDir = path("out")
        model.pythonPath = "/usr/bin/python3"
        model.dotnetPath = "/usr/bin/true"
        model.depsChecked = true
        model.deps = [Dep(id: "test", name: "test", hint: "", present: true, installCmd: [])]
        model.installDevice = device
        model.signingTeam = team
        model.xcrunPath = f.xcrun
        try write(f.repo + "/dm/tools/nx_extract/Program.cs", "")
        for tool in BuildModel.requiredTools.filter({ $0 != BuildModel.buildScript }) { try write(f.repo + "/" + tool, "") }
        try write(f.repo + "/scripts/build_ipa_from_nsp.py", "open('\(state)/script.txt', 'w').write('ran')\n")
        let base = temporary.appendingPathComponent("Test [\(titleID)].nsp"), keys = temporary.appendingPathComponent("prod.keys")
        try Data([0]).write(to: base); try Data().write(to: keys)
        model.slots[0].paths = [base.path]; model.slots[3].paths = [keys.path]
        return model
    }

    /// An unknown device stops the build before the script runs: no hour of building for a device that cannot be installed on.
    @MainActor func testUnknownDeviceStopsTheBuildBeforeTheScriptRuns() throws {
        let f = try makeFixture()
        try writeDevices(state + "/devices-default.json", [("00008150-OTHER", "wired")])
        let saved = ["repoPath", "buildTarget", "buildOutputDirectory", "installDevice", "signingTeam"].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) } }
        let model = try makeModel(f)
        model.startBuild()
        let stopped = expectation(description: "Checked")
        let token = model.$running.dropFirst().filter { !$0 }.prefix(1).sink { _ in stopped.fulfill() }
        wait(for: [stopped], timeout: 20)
        withExtendedLifetime(token) {}
        XCTAssertEqual(model.failure?.kind, .devicePairing)
        XCTAssertEqual(model.doneNote, String(format: model.t("shell.notPaired"), model.deviceName(model.installDevice)), "the pairing steps, in the app's language")
        XCTAssertFalse(fm.fileExists(atPath: state + "/script.txt"), "the build script did not start")
    }

    /// The copy card's answer and the failure row: a copy that fails midway says the data is incomplete, and Retry runs only the data step.
    @MainActor func testFailedCopyShowsTheIncompleteRowAndRetryFinishesIt() throws {
        let f = try makeFixture()
        let saved = ["repoPath", "buildTarget", "buildOutputDirectory", "installDevice", "signingTeam", "shellRoot"].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) } }
        UserDefaults.standard.set(f.root, forKey: "shellRoot")
        let model = try makeModel(f)
        try write(state + "/fail-on", "romfs.img")
        var plans: [ShellCopyPlan] = []
        let asked = model.$shellCopy.compactMap { $0 }.sink { plans.append($0); model.answerShellCopy(.copy) }
        func finish(_ start: () -> Void) {
            let ended = expectation(description: "Ended")
            let token = model.$running.dropFirst().filter { !$0 }.prefix(1).sink { _ in ended.fulfill() }
            start()
            wait(for: [ended], timeout: 30)
            withExtendedLifetime(token) {}
        }
        finish { model.installShell(framework: f.framework, titleID: titleID, name: "Test Game", archive: f.archive) }
        XCTAssertEqual(model.failure?.kind, .shellDataIncomplete)
        XCTAssertTrue(model.doneNote.hasPrefix(String(format: model.t("shell.copyIncomplete"), model.deviceName(model.installDevice), "").components(separatedBy: ": ").first ?? "-"), model.doneNote)
        XCTAssertFalse(model.done)
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans.first?.connection, .wired)

        try fm.removeItem(atPath: state + "/fail-on")
        let signs = calls.filter { $0.hasPrefix("xcodebuild") }.count
        finish { model.fixBuildFailure(.shellDataIncomplete) }
        withExtendedLifetime(asked) {}
        XCTAssertNil(model.failure)
        XCTAssertTrue(model.done, model.doneNote)
        XCTAssertEqual(model.installedOn, device)
        XCTAssertEqual(calls.filter { $0.hasPrefix("xcodebuild") }.count, signs)
        XCTAssertEqual(try String(contentsOfFile: container + "/org.nxnative.shell/Documents/games/\(titleID)/romfs.img"), "0123456789")
    }

    @MainActor func testShellTargetWithoutDeviceStopsBeforeBuilding() throws {
        let saved = ["repoPath", "buildTarget", "installDevice", "signingTeam"].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) } }
        let model = BuildModel()
        model.repoPath = temporary.path
        try write(temporary.path + "/dm/tools/nx_extract/Program.cs", "")
        model.target = "ios"
        model.installDevice = ""
        model.startBuild()
        XCTAssertFalse(model.running)
        XCTAssertEqual(model.doneNote, model.t("shell.needsDevice"))
    }
}
