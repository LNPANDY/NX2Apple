import XCTest
import Combine
@testable import NX2Apple
@testable import NXCore
import NXModel
@testable import NXLauncher

/// Route C: one app on the device for several games. The commands and parsers are checked as pure functions, and the whole path
/// after the build runs headless against a stand-in `xcrun` that models devicectl on a folder (a fake device container): an install
/// keeps the container, a copy to a file creates the parents, and `--remove-existing-content true` wipes the destination's siblings,
/// as it does on a real device. No test reaches a device or a real game.
@MainActor final class ShellInstallTests: IsolatedDefaultsTestCase {
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

    /// #427: the default no longer depends on the output folder, and what is saved stays.
    func testShellRootDefaultsToApplicationSupportAndIsKept() throws {
        let defaults = TestDefaults.make("nspb-shell")
        let home = temporary.path + "/home"
        XCTAssertEqual(ShellLibrary.resolveRoot(defaults: defaults, parent: "/Volumes/A", home: home),
                       home + "/Library/Application Support/NX2Apple/shell")
        XCTAssertEqual(ShellLibrary.resolveRoot(defaults: defaults, parent: "/Volumes/B", home: home),
                       home + "/Library/Application Support/NX2Apple/shell")
        XCTAssertEqual(defaults.string(forKey: "shellRoot"), home + "/Library/Application Support/NX2Apple/shell")
        // a root the player chose themselves is not touched
        defaults.set("/Volumes/Games/Cache/shell", forKey: "shellRoot")
        XCTAssertEqual(ShellLibrary.resolveRoot(defaults: defaults, parent: "/Volumes/B", home: home), "/Volumes/Games/Cache/shell")
    }

    /// #492: the Settings page reads the path before a game is chosen; the empty parent put the shell at the root of the
    /// read-only system volume, where the write failed after the whole build.
    func testAnEmptyOrRootParentNeverSavesTheShellAtTheVolumeRoot() {
        let defaults = TestDefaults.make("nspb-shell")
        let home = "/Users/tester"
        let root = "/Users/tester/Library/Application Support/NX2Apple/shell"
        for parent in ["", "/", "relative/games"] {
            XCTAssertEqual(ShellLibrary.resolveRoot(defaults: defaults, parent: parent, home: home), root)
            XCTAssertEqual(defaults.string(forKey: "shellRoot"), root)
            defaults.removeObject(forKey: "shellRoot")
        }
    }

    func testASavedRootAtTheVolumeRootIsRepaired() {
        let defaults = TestDefaults.make("nspb-shell")
        defaults.set("/NX2Apple-shell", forKey: "shellRoot")
        XCTAssertEqual(ShellLibrary.resolveRoot(defaults: defaults, parent: "/Users/tester/games", home: "/Users/tester"),
                       "/Users/tester/Library/Application Support/NX2Apple/shell")
        XCTAssertEqual(defaults.string(forKey: "shellRoot"), "/Users/tester/Library/Application Support/NX2Apple/shell")   // the bad value is replaced
    }

    func testThePreviewDoesNotSaveARoot() {
        let defaults = TestDefaults.make("nspb-shell")
        XCTAssertEqual(ShellLibrary.previewRoot(defaults: defaults, parent: "/Volumes/A", home: "/Users/tester"),
                       "/Users/tester/Library/Application Support/NX2Apple/shell")
        XCTAssertNil(defaults.string(forKey: "shellRoot"))
        defaults.set("/Volumes/A/NX2Apple-shell", forKey: "shellRoot")
        XCTAssertEqual(ShellLibrary.previewRoot(defaults: defaults, parent: "/Volumes/B"), "/Volumes/A/NX2Apple-shell")   // an old root shows until it moves
    }

    func testRootNeedsAWritableParent() throws {
        let parent = NSTemporaryDirectory() + "nspb-shell-parent-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: parent) }
        XCTAssertTrue(ShellInstall.canWriteRoot(parent + "/NX2Apple-shell"))
        XCTAssertFalse(ShellInstall.canWriteRoot(NSTemporaryDirectory() + "nspb-missing-" + UUID().uuidString + "/NX2Apple-shell"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent) }
        XCTAssertFalse(ShellInstall.canWriteRoot(parent + "/NX2Apple-shell"))
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
        let store = try makeTree(["engine/id/dm/gfx/nvn/dmsh_chain.h"]) + "/engine/id"
        let bundle = try makeTree(["frontend-ios/Package.swift", "frontend-ios/AppIcon.icon/icon.json", "frontend-ios/Shell/build_shell.sh"])
        let package = try XCTUnwrap(ShellInstall.shellPackage(resources: bundle, repo: store))
        let env = ShellInstall.projectEnvironment(root: "/R", frameworks: [], bundleID: "b", team: "T", python: "/py", path: "/p",
                                                  home: "/h", user: "u", package: package, engine: store)
        let path = try XCTUnwrap(env["DM_SHELL_PACKAGE"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/Package.swift"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/AppIcon.icon"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/Shell/build_shell.sh"))
        XCTAssertEqual(env["DM_ENGINE_DIR"], store)
        XCTAssertFalse(path.hasPrefix(store))
        XCTAssertNil(ShellInstall.projectEnvironment(root: "/R", frameworks: [], bundleID: "b", team: "T", python: "/py", path: "/p",
                                                     home: "/h", user: "u")["DM_SHELL_PACKAGE"])
    }

    /// #515: a file name without a title ID gives a build key the build never names its framework after. The handoff takes the
    /// framework the build wrote, and its title ID, not the key.
    func testBuiltFrameworkIsTheOneTheBuildWrote() throws {
        let name = "The_Legend_of_Zelda_Breath_of_the_Wild-7603d90e"
        let key = TitleID.buildKey("/in/" + name + ".nsp")
        XCTAssertFalse(key.hasPrefix("01"))
        let work = try makeTree(["shell-framework/DmGame01007EF00011E000.framework/game.manifest.json", "shell-framework/notes.txt"])
        let fw = try XCTUnwrap(ShellInstall.builtFramework(workDir: work))
        XCTAssertEqual(fw, work + "/shell-framework/DmGame01007EF00011E000.framework")
        XCTAssertNotEqual(fw, ShellInstall.frameworkPath(workDir: work, titleID: key))
        XCTAssertEqual(ShellInstall.titleID(ofFramework: fw), "01007EF00011E000")

        // An older build's framework beside it: the newest one is the build's
        let old = work + "/shell-framework/DmGame0100000000010000.framework"
        try FileManager.default.createDirectory(atPath: old, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old)
        XCTAssertEqual(ShellInstall.builtFramework(workDir: work), fw)

        XCTAssertNil(ShellInstall.builtFramework(workDir: try makeTree(["shell-framework/notes.txt"])))
        XCTAssertNil(ShellInstall.builtFramework(workDir: try makeTree([])))
    }

    func testCommandsAreExact() {
        let root = "/R/NX2Apple-shell"
        XCTAssertEqual(ShellInstall.buildArguments(workDir: "/W", team: "T"), ["--shell-framework", "/W/shell-framework", "--team-id", "T"])
        XCTAssertEqual(ShellInstall.frameworkPath(workDir: "/W", titleID: "01"), "/W/shell-framework/DmGame01.framework")
        XCTAssertEqual(ShellInstall.projectCommand(package: "/pkg/frontend-ios"), ["/bin/bash", "/pkg/frontend-ios/Shell/build_shell.sh", "--prepare-xcode"])
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
        for command in [build, list, copy, ShellInstall.projectCommand(package: "/p"), ShellInstall.installCommand(xcrun: "/x", device: "D", app: "/a")] {
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
                    "shell.copyWifiMinute", "shell.copyNotConnected", "shell.copyWaiting", "shell.copyTitle",
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

    /// xcodebuild and devicectl as one script. `state/taken` makes the plain bundle ID "registered to another team", `state/noprofile`
    /// makes the bundle ID it holds have no profile.
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
            pbx = val('-project') + '/project.pbxproj'
            if os.path.exists(pbx):
                import re
                pdir = os.path.dirname(val('-project'))
                for m in re.finditer(r'(?:path|relativePath) = "([^"]+)";', open(pbx).read()):
                    pkg = m.group(1) if os.path.isabs(m.group(1)) else os.path.normpath(os.path.join(pdir, m.group(1)))
                    if not os.path.isfile(pkg + '/Package.swift'):
                        print('xcodebuild: error: Could not resolve package dependencies:', flush=True)
                        sys.exit(74)
            if os.path.exists(STATE + '/xcodebuild-error'):
                sys.stderr.write(open(STATE + '/xcodebuild-error').read())
                sys.exit(70)
            bundle = [x.split('=', 1)[1] for x in a if x.startswith('PRODUCT_BUNDLE_IDENTIFIER=')][0]
            if os.path.exists(STATE + '/taken') and bundle == 'org.nxnative.shell':
                print('error: The app identifier "' + bundle + '" cannot be registered to your development team because it is not available. Change your bundle identifier to a unique string to try again.', flush=True)
                sys.exit(65)
            if os.path.exists(STATE + '/noprofile') and bundle == open(STATE + '/noprofile').read().strip():
                print('error: No profiles for \\'' + bundle + '\\' were found: Xcode couldn\\'t find any iOS App Development provisioning profiles matching \\'' + bundle + '\\'.', flush=True)
                sys.exit(65)
            if os.path.exists(STATE + '/nomemory') and not os.path.exists(os.path.dirname(val('-project')) + '/entitlements-empty'):
                print('error: Provisioning profile iOS Team Provisioning Profile: ' + bundle + ' doesn\\'t include the Increased Memory Limit capability.', flush=True)
                sys.exit(65)
            if os.path.exists(STATE + '/fail-xcodebuild'):
                print('error: Communication with Apple failed: Your device is offline.', flush=True)
                sys.exit(65)
            app = val('-derivedDataPath') + '/Build/Products/Release-iphoneos/DmShell.app'
            fwlist = os.path.dirname(val('-project')) + '/frameworks.txt'
            if os.path.exists(fwlist):
                for line in open(fwlist).read().splitlines():
                    if not line.strip(): continue
                    fw = line.split('\t')[1] if '\t' in line else line.strip()
                    if not os.path.isdir(fw):
                        print('error: ' + fw + ': No such file or directory (in target \\'DmShell\\' from project \\'DmShell\\')', flush=True)
                        sys.exit(65)
                    os.makedirs(app + '/Frameworks/' + os.path.basename(fw), exist_ok=True)
            os.makedirs(app, exist_ok=True)
            open(app + '/bundle.txt', 'w').write(bundle)
            if os.path.exists(STATE + '/new-profile'):
                shutil.copyfile(STATE + '/new-profile', app + '/embedded.mobileprovision')
                os.makedirs(app + '/_CodeSignature', exist_ok=True)
                open(app + '/_CodeSignature/CodeResources', 'w').write('new-sig')
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
            if os.path.exists(STATE + '/fail-install'):
                print('ERROR: The device was disconnected during installation.', flush=True)
                sys.exit(1)
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
        try write(repo + "/frontend-ios/Shell/build_shell.sh", """
        #!/bin/bash
        [ "$1" = "--prepare-xcode" ] || { echo "FAIL: no --prepare-xcode"; exit 1; }
        if [ -f "\(state)/refuse" ]; then
          echo "[RED] games of different profiles in one shell: A (x), B (y)"
          echo "[12:00:01] FAIL: the frameworks in DM_SHELL_FRAMEWORKS (above)"
          exit 1
        fi
        mkdir -p "$SHELL_DIR/DmShell.xcodeproj"
        : > "$SHELL_DIR/frameworks.txt"
        while IFS= read -r fw; do
          [ -n "$fw" ] || continue
          [ -d "$fw" ] || { echo "[RED] $fw: no readable game.manifest.json"; exit 1; }
          [ -f "$fw/refuse-me" ] && { echo "[RED] $fw: built without a host in the framework (loader 'FR')"; exit 1; }
          tid=$(basename "$fw" .framework); tid=${tid#DmGame}
          printf '%s\t%s\t%s\n' "$tid" "$fw" "$tid" >> "$SHELL_DIR/frameworks.txt"
        done <<< "$DM_SHELL_FRAMEWORKS"
        cat > "$SHELL_DIR/DmShell.xcodeproj/project.pbxproj" <<EOF
        F96F /* frontend-ios */ = {isa = PBXFileReference; name = "frontend-ios"; path = "$DM_SHELL_PACKAGE"; sourceTree = SOURCE_ROOT; };
        376B /* XCLocalSwiftPackageReference */ = {isa = XCLocalSwiftPackageReference; relativePath = "$DM_SHELL_PACKAGE"; };
        EOF
        env | sort > "\(state)/shell-env.txt"
        if [ "${DM_ENTITLEMENTS+set}" = set ] && [ -z "$DM_ENTITLEMENTS" ]; then touch "$SHELL_DIR/entitlements-empty"; else rm -f "$SHELL_DIR/entitlements-empty"; fi
        """)
        try write(repo + "/frontend-ios/Package.swift", "// swift-tools-version: 5.9\n")
        try fm.createDirectory(atPath: repo + "/frontend-ios/Shell/App", withIntermediateDirectories: true)
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
        try write(framework + "/DmGame\(titleID)", "executable")
        let archive = path("out/games", titleID)
        try write(archive + "/romfs.img", "0123456789")
        try write(archive + "/aoc/1.img", "abcd")
        try write(archive + "/.packstamp", "stamp")
        let made = Fixture(xcrun: try makeXcrun(), repo: try makeRepo(), framework: framework, archive: archive, root: path("shell-root"))
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
        i.defaults = testDefaults
        i.pollInterval = 0.02
        i.resources = nil
        return i
    }

    private func install(_ i: ShellInstaller, _ f: Fixture) -> ShellInstaller.Outcome {
        i.install(framework: f.framework, titleID: titleID, name: "Test Game", archive: f.archive)
    }

    private func run(_ f: Fixture, _ extra: [String] = []) -> (status: Int32, output: String) {
        var output = ""
        let defaults = TestDefaults.make("nspb-shell")
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
        try write(other + "/game.manifest.json", #"{"name": "other"}"#)
        try write(other + "/DmGame\(otherID)", "executable")
        var library = ShellLibrary()
        library.add(.init(titleID: otherID, name: "Other", framework: other))   // what an install before the mirror wrote
        try library.save(root: f.root)
        let r = run(f)
        XCTAssertEqual(r.status, 0, r.output)
        let saved = ShellLibrary.load(root: f.root)
        XCTAssertEqual(Set(saved.games.map(\.framework)), [mirrored(f.root), mirrored(f.root, otherID)])
        XCTAssertEqual(try String(contentsOfFile: mirrored(f.root, otherID) + "/game.manifest.json"), #"{"name": "other"}"#)
    }

    func testGameWithoutBuildFolderPlaysFromItsMirrorAndOneWithNeitherIsDropped() throws {
        let f = try makeFixture()
        let keptID = "0100BBBB00000000", lostID = "0100CCCC00000000"
        try write(mirrored(f.root, keptID) + "/game.manifest.json", #"{"name": "kept"}"#)
        try write(mirrored(f.root, keptID) + "/DmGame\(keptID)", "executable")
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

    private func fixtureWithRomFSTool() throws -> Fixture {
        let f = try makeFixture()
        let tool = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("engine/" + RepoLayout.romfsImageTool)
        let tools = f.repo + "/dm/tools"
        try fm.createDirectory(atPath: tools, withIntermediateDirectories: true)
        try fm.copyItem(atPath: tool.path, toPath: tools + "/romfs_image.py")

        return f
    }

    /// One byte of payload and a 24-byte index. Either byte can change independently at the same total size.
    private func romfsImage(payload: UInt8 = 0, index: UInt8 = 0) -> Data {
        var header = Data("DMROMFS1".utf8)
        for word: UInt8 in [33, 24, 1] {
            header.append(word)
            header.append(Data(repeating: 0, count: 7))
        }
        return header + Data([payload, index]) + Data(repeating: 0, count: 23)
    }

    func testSameSizeGameUpdateNeedsAnotherCopyUntilItSucceeds() throws {
        let f = try fixtureWithRomFSTool()
        let image = f.archive + "/romfs.img"
        let deviceImage = container + "/org.nxnative.shell/Documents/games/\(titleID)/romfs.img"
        let first = romfsImage(), update = romfsImage(index: 1)
        try first.write(to: URL(fileURLWithPath: image))
        var i = installer(f)
        XCTAssertTrue(install(i, f).ok)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: deviceImage)), first)

        try update.write(to: URL(fileURLWithPath: image))
        var plans: [ShellCopyPlan] = []
        var log = ""
        i.log = { log += $0 }
        i.decideCopy = { plans.append($0); return .skip }
        XCTAssertTrue(i.installData(titleID: titleID, archive: f.archive).copySkipped)
        XCTAssertEqual(plans.map(\.bytes), [Int64(update.count)])
        XCTAssertEqual(plans.first?.versionNote, "The game data has changed since the last copy.")
        XCTAssertTrue(log.contains("The game data has changed since the last copy."), log)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: deviceImage)), first)
        i.decideCopy = { _ in .copy }
        try write(state + "/fail-on", "romfs.img")
        XCTAssertEqual(i.installData(titleID: titleID, archive: f.archive).failure, .shellDataIncomplete)
        try fm.removeItem(atPath: state + "/fail-on")
        XCTAssertEqual(i.installData(titleID: titleID, archive: f.archive).copied, 1)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: deviceImage)), update)
        i.decideCopy = { _ in XCTFail("an unchanged copy needs no prompt"); return .skip }
        let current = i.installData(titleID: titleID, archive: f.archive)
        XCTAssertEqual(current.copied, 0)
        XCTAssertEqual(current.message, "Z already has this version of the game data.")
    }

    func testNewGameVersionWithUnchangedIndexAndReinstalledContainerBothNeedTheImage() throws {
        let f = try fixtureWithRomFSTool()
        let image = URL(fileURLWithPath: f.archive + "/romfs.img")
        let manifest = f.framework + "/game.manifest.json"
        try romfsImage().write(to: image)
        try write(manifest, #"{"display_version":"1.0","package_version":"v0"}"#)
        var i = installer(f)
        XCTAssertEqual(install(i, f).copied, 2)
        let update = romfsImage(payload: 9)
        try update.write(to: image)
        try write(manifest, #"{"display_version":"1.1","package_version":"v65536"}"#)
        XCTAssertEqual(install(i, f).copied, 1)
        let docs = container + "/org.nxnative.shell/Documents"
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: docs + "/games/\(titleID)/romfs.img")), update)

        // A different paired device has its own copy history, even if its directory listing looks identical.
        i.decideCopy = { plan in XCTAssertNil(plan.versionNote); return .copy }
        i.device = "00008150-BBBB"
        try writeDevices(state + "/devices-default.json", [(i.device, "wired")])
        XCTAssertEqual(i.installData(titleID: titleID, archive: f.archive).copied, 1)
        try fm.removeItem(atPath: docs)
        XCTAssertEqual(i.installData(titleID: titleID, archive: f.archive).copied, 2)
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

    func testARefusedProjectLeavesShellJsonAsItWas() throws {
        let f = try makeFixture()
        let i = installer(f)
        XCTAssertTrue(install(i, f).ok)
        let before = try Data(contentsOf: URL(fileURLWithPath: ShellLibrary.stateFile(root: f.root)))
        // A second game whose framework build_shell.sh rejects (an older build without a host in the framework, #392 follow-up)
        let other = "0100AAAA00000000"
        let framework = path("work2/shell-framework/DmGame\(other).framework")
        try write(framework + "/game.manifest.json", "{}")
        try write(framework + "/DmGame\(other)", "executable")
        try write(state + "/refuse", "")
        let r = i.install(framework: framework, titleID: other, name: "Other", archive: f.archive)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: ShellLibrary.stateFile(root: f.root))), before)
        XCTAssertEqual(ShellLibrary.load(root: f.root).games.map(\.titleID), [titleID])
        try fm.removeItem(atPath: state + "/refuse")
        XCTAssertTrue(install(i, f).ok, "the next install of the first game is not blocked by the refused one")
    }

    func testARefusedReplacementKeepsTheMirrorThatWorked() throws {
        let f = try makeFixture()
        let i = installer(f)
        XCTAssertTrue(install(i, f).ok)
        let before = try Data(contentsOf: URL(fileURLWithPath: ShellLibrary.stateFile(root: f.root)))
        // The game is rebuilt into a framework build_shell.sh rejects (an older build without a host in the framework)
        try write(f.framework + "/refuse-me", "")
        XCTAssertFalse(install(i, f).ok)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: ShellLibrary.stateFile(root: f.root))), before)
        XCTAssertTrue(fm.fileExists(atPath: mirrored(f.root) + "/DmGame\(titleID)"))
        XCTAssertFalse(fm.fileExists(atPath: mirrored(f.root) + "/refuse-me"), "the mirror is the framework that worked")
        // Another game installs afterwards, with the first one's framework that worked
        let other = "0100AAAA00000000"
        let framework = path("work2/shell-framework/DmGame\(other).framework")
        try write(framework + "/game.manifest.json", "{}")
        try write(framework + "/DmGame\(other)", "executable")
        let r = i.install(framework: framework, titleID: other, name: "Other", archive: f.archive)
        XCTAssertTrue(r.ok, r.message)
        XCTAssertEqual(ShellLibrary.load(root: f.root).games.map(\.titleID), [titleID, other])
    }

    func testATeamChangeRetriesUnderTheNewTeamsVariant() throws {
        let f = try makeFixture()
        try write(state + "/taken", "")
        // Team A installed first and stored its own variant
        var a = installer(f)
        a.team = "AAAAAAAAAA"
        let variantA = ShellLibrary.teamVariant(team: a.team)
        XCTAssertTrue(install(a, f).ok)
        XCTAssertEqual(ShellLibrary.load(root: f.root).bundleID, variantA)
        // Team B is selected now: Xcode only says it has no profile for team A's variant
        try write(state + "/noprofile", variantA)
        let variantB = ShellLibrary.teamVariant(team: team)
        let r = install(installer(f), f)
        XCTAssertTrue(r.ok, r.message)
        XCTAssertEqual(r.bundleID, variantB)
        XCTAssertEqual(ShellLibrary.load(root: f.root).bundleID, variantB)
        let builds = calls.filter { $0.hasPrefix("xcodebuild") }
        XCTAssertTrue(builds[builds.count - 2].contains("PRODUCT_BUNDLE_IDENTIFIER=\(variantA) build"))
        XCTAssertTrue(builds[builds.count - 1].contains("PRODUCT_BUNDLE_IDENTIFIER=\(variantB) build"))
    }

    func testTheRetryRuleIsApartFromTheCardRule() {
        let a = "org.nxnative.shell.AAAAAAAAAA", b = "org.nxnative.shell.BBBBBBBBBB"
        let noProfileA = "error: No profiles for '\(a)' were found"
        XCTAssertTrue(ShellInstall.retryUnderTeamVariant(noProfileA, attempted: a, variant: b), "a team change still retries")
        XCTAssertFalse(BuildFailureClassifier.signingTeamTaken(noProfileA), "but is not carded as registered to another team")
        XCTAssertFalse(ShellInstall.retryUnderTeamVariant("error: No profiles for '\(b)' were found", attempted: b, variant: b))
        XCTAssertTrue(ShellInstall.retryUnderTeamVariant("error: No profiles for 'org.nxnative.shell' were found",
                                                         attempted: "org.nxnative.shell", variant: b))
        XCTAssertTrue(ShellInstall.retryUnderTeamVariant("cannot be registered to your development team", attempted: a, variant: b))
        XCTAssertFalse(ShellInstall.retryUnderTeamVariant("error: something else", attempted: a, variant: b))
    }

    func testARefusedFirstProjectLeavesNoShellJson() throws {
        let f = try makeFixture()
        try write(state + "/refuse", "")
        XCTAssertFalse(install(installer(f), f).ok)
        XCTAssertFalse(fm.fileExists(atPath: ShellLibrary.stateFile(root: f.root)))
    }

    func testTeamVariantSignedWithoutTheMemoryCapabilityIsStored() throws {
        let f = try makeFixture()
        try write(state + "/taken", "")
        try write(state + "/nomemory", "")
        let variant = ShellLibrary.teamVariant(team: team)
        let r = install(installer(f), f)
        XCTAssertTrue(r.ok, r.message)
        XCTAssertTrue(r.noMemoryCapability)
        XCTAssertEqual(r.bundleID, variant)
        XCTAssertEqual(ShellLibrary.load(root: f.root).bundleID, variant)
        let builds = calls.filter { $0.hasPrefix("xcodebuild") }
        XCTAssertEqual(builds.count, 3)   // the plain identifier, the variant with the request, the variant without it
        XCTAssertTrue(builds[2].contains("PRODUCT_BUNDLE_IDENTIFIER=\(variant) build"))
        XCTAssertTrue(install(installer(f), f).ok)
        XCTAssertTrue(calls.filter { $0.hasPrefix("xcodebuild") }[3].contains("PRODUCT_BUNDLE_IDENTIFIER=\(variant) build"),
                      "the next install starts with the stored variant")
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
        XCTAssertEqual(ShellCLI.run(["--install-shell", "--framework", "/x"], defaults: TestDefaults.make("nspb-shell")) { output += $0 }, 1)
        XCTAssertTrue(output.hasPrefix("usage: NSPortBuilder --install-shell"))
        let f = try makeFixture()
        output = ""
        XCTAssertEqual(ShellCLI.run(f.args(extra: ["--framework", path("missing.framework")]),
                                    defaults: TestDefaults.make("nspb-shell")) { output += $0 }, 1)
        XCTAssertTrue(output.contains("its framework is not in the"), output)
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

    func testUnavailableDestinationShowsLocalizedRecoveryStepsAndKeepsTheLog() throws {
        let f = try makeFixture()
        let error = "xcodebuild: error: Unable to find a destination matching the provided destination specifier:"
        let diagnostic = """
        \(error)
            { id:\(device) }

        Destinations incompatible with the "DmShell" scheme:
            { platform:macOS, arch:arm64e, id:MAC, name:My Mac, error:My Mac’s macOS platform doesn’t match DmShell.app’s supported platforms. }
        """
        try write(state + "/xcodebuild-error", diagnostic)
        testDefaults.set(f.root, forKey: "shellRoot")
        let messages: [(Lang, String, String)] = [
            (.en, "Selected iPhone or iPad unavailable",
             "Xcode cannot use the selected iPhone or iPad. Connect and unlock it, check Xcode’s Devices and Simulators, then select it again under Install on."),
            (.zh, "所选 iPhone 或 iPad 不可用",
             "Xcode 无法使用所选 iPhone 或 iPad。请连接并解锁设备，在 Xcode 的“设备与模拟器”中检查它，然后在“安装到”中重新选择。"),
            (Lang("de"), "Ausgewähltes Gerät nicht verfügbar",
             "Xcode kann das ausgewählte iPhone oder iPad nicht verwenden. Verbinde und entsperre es, prüfe es in Xcodes „Devices and Simulators“ und wähle es unter „Installieren auf“ erneut aus.")
        ]
        for (lang, summary, message) in messages {
            let stores = try makeModel(f)
            let model = stores.build
            stores.localizer.lang = lang
            stores.deviceStore.readTeams = { [SigningTeam(id: "TEAM123456", identity: "")] }

            let stopped = expectation(description: "The sign step failed")
            let token = model.$running.dropFirst().filter { !$0 }.prefix(1).sink { _ in stopped.fulfill() }
            model.installShell(framework: f.framework, titleID: titleID, name: "Test Game", archive: f.archive)
            wait(for: [stopped], timeout: 30)
            withExtendedLifetime(token) {}

            XCTAssertEqual(model.doneNote, message, lang.code)
            XCTAssertEqual(model.stages.first(where: { $0.id == ShellInstaller.signStageID })?.detail, summary, lang.code)
            XCTAssertTrue(model.log.text.contains(diagnostic), "The full Xcode diagnostic remains available in the build log")
        }
    }

    func testOtherXcodeFailuresStillShowTheLastError() throws {
        let f = try makeFixture()
        try write(state + "/xcodebuild-error", """
        /fixture/Shell.swift:4:12: error: cannot find 'ShellConfig' in scope
        /fixture/Shell.swift:8:12: error: cannot find 'startShell' in scope
        ** BUILD FAILED **
        """)
        let result = install(installer(f), f)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.message, "Signing failed: /fixture/Shell.swift:8:12: error: cannot find 'startShell' in scope")
    }

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
        XCTAssertNil(plans.first?.versionNote)
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
        XCTAssertEqual(ShellCLI.run(f.args(), defaults: TestDefaults.make("nspb-shell")) { output += $0 }, 1)
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

    // ---- a file larger than one part (#899) ----

    func testPartNamesSizesAndWhatToSend() throws {
        XCTAssertEqual(ShellDataParts.partSize, 512 << 20)
        XCTAssertEqual(ShellDataParts.name(of: "romfs.img", index: 3, count: 9), "romfs.img.nxpart.0003.0009")
        XCTAssertEqual(ShellDataParts.name(of: "aoc/1.img", index: 0, count: 2), "aoc/1.img.nxpart.0000.0002")
        XCTAssertTrue(ShellDataParts.isPart("romfs.img.nxpart.0000.0002", of: "romfs.img"))
        XCTAssertFalse(ShellDataParts.isPart("romfs.img", of: "romfs.img"))
        XCTAssertEqual(ShellDataParts.count(size: 10, partSize: 4), 3)
        XCTAssertEqual(ShellDataParts.count(size: 8, partSize: 4), 2)
        XCTAssertEqual(ShellDataParts.count(size: 0, partSize: 4), 1)
        XCTAssertEqual(ShellDataParts.range(index: 2, size: 10, partSize: 4).offset, 8)
        XCTAssertEqual(ShellDataParts.range(index: 2, size: 10, partSize: 4).length, 2)
        // 8 GB of memory: up to 2 GB whole, never less than one part
        XCTAssertEqual(ShellDataParts.singleCopyLimit(physicalMemory: 8 << 30), 2 << 30)
        XCTAssertEqual(ShellDataParts.singleCopyLimit(physicalMemory: 1 << 30), ShellDataParts.partSize)

        let local: [String: Int64] = ["romfs.img": 10, "aoc/1.img": 4]
        XCTAssertEqual(ShellDataParts.toCopy(local: local, device: [:], splitAbove: 4, partSize: 4),
                       [.whole("aoc/1.img"), .part("romfs.img", index: 0, count: 3), .part("romfs.img", index: 1, count: 3),
                        .part("romfs.img", index: 2, count: 3)])
        // parts on the device with their size are not sent again, a short one is
        XCTAssertEqual(ShellDataParts.toCopy(local: local, device: ["aoc/1.img": 4, "romfs.img.nxpart.0000.0003": 4, "romfs.img.nxpart.0001.0003": 3],
                                             splitAbove: 4, partSize: 4),
                       [.part("romfs.img", index: 1, count: 3), .part("romfs.img", index: 2, count: 3)])
        // the whole file on the device needs nothing, parts or not
        XCTAssertEqual(ShellDataParts.toCopy(local: local, device: ["aoc/1.img": 4, "romfs.img": 10], splitAbove: 4, partSize: 4), [])
        XCTAssertEqual(ShellDataParts.toCopy(local: local, device: [:], splitAbove: 10, partSize: 4), [.whole("aoc/1.img"), .whole("romfs.img")])
        XCTAssertEqual(ShellDataParts.bytes(of: .part("romfs.img", index: 2, count: 3), local: local, partSize: 4), 2)

        XCTAssertTrue(ShellDataParts.joinsParts(features: "data-parts 1\n"))
        XCTAssertFalse(ShellDataParts.joinsParts(features: "data-parts 10\n"))
        XCTAssertFalse(ShellDataParts.joinsParts(features: nil))
    }

    func testWritePartCutsTheRightBytes() throws {
        let source = path("big.bin"), out = path("part.bin")
        let bytes = Data((0..<250).map { UInt8($0) })
        try bytes.write(to: URL(fileURLWithPath: source))
        try ShellDataParts.writePart(source: source, index: 1, size: Int64(bytes.count), partSize: 100, to: out)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: out)), bytes[100..<200])
        try ShellDataParts.writePart(source: source, index: 2, size: Int64(bytes.count), partSize: 100, to: out)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: out)), bytes[200..<250])
    }

    /// What the shared app does at its start (frontend-ios `DataParts`), for the fake device: the parts in order, then removed.
    private func joinOnDevice(_ folder: String, file: String) throws {
        let names = try fm.contentsOfDirectory(atPath: folder).filter { ShellDataParts.isPart($0, of: file) }.sorted()
        var whole = Data()
        for name in names { whole += try Data(contentsOf: URL(fileURLWithPath: folder + "/" + name)); try fm.removeItem(atPath: folder + "/" + name) }
        try whole.write(to: URL(fileURLWithPath: folder + "/" + file))
    }

    func testALargeFileGoesInPartsAndAStoppedSendResumes() throws {
        let f = try makeFixture()
        let games = container + "/org.nxnative.shell/Documents/games/\(titleID)"
        var i = installer(f)
        i.partSize = 4
        var log = ""
        i.log = { log += $0 }
        try write(state + "/fail-on", "romfs.img.nxpart.0001.0003")   // the device locks during the second part
        var r = install(i, f)
        XCTAssertEqual(r.failure, .shellDataIncomplete)
        XCTAssertTrue(log.contains("The large files go over in 3 parts. The shared app joins them when it next opens."), log)
        XCTAssertEqual(try String(contentsOfFile: games + "/romfs.img.nxpart.0000.0003"), "0123")
        XCTAssertFalse(fm.fileExists(atPath: games + "/romfs.img"), "the whole file never goes over")
        XCTAssertEqual(try String(contentsOfFile: games + "/aoc/1.img"), "abcd", "a file of one part goes whole")

        try fm.removeItem(atPath: state + "/fail-on")
        let before = copies().count
        r = i.installData(titleID: titleID, archive: f.archive)
        XCTAssertTrue(r.ok, r.message)
        XCTAssertEqual(copies().count - before, 2, "the short second part and the third, not the first")
        XCTAssertEqual(r.copied, 2)
        XCTAssertEqual(try String(contentsOfFile: games + "/romfs.img.nxpart.0001.0003"), "4567")
        XCTAssertEqual(try String(contentsOfFile: games + "/romfs.img.nxpart.0002.0003"), "89")

        // before the app has joined them, the parts count as the data
        XCTAssertEqual(i.installData(titleID: titleID, archive: f.archive).copied, 0)
        // and after
        try joinOnDevice(games, file: "romfs.img")
        XCTAssertEqual(try String(contentsOfFile: games + "/romfs.img"), "0123456789")
        let after = i.installData(titleID: titleID, archive: f.archive)
        XCTAssertEqual(after.copied, 0)
        XCTAssertEqual(after.message, "Installed on Z, the game data was already on the device")
    }

    func testSendingToAnAppThatMayNotJoinPartsSplitsOnlyWhatCannotGoWhole() throws {
        let f = try makeFixture()
        let docs = container + "/org.nxnative.shell/Documents"
        let games = docs + "/games/\(titleID)"
        try fm.createDirectory(atPath: docs, withIntermediateDirectories: true)
        var i = installer(f)
        i.partSize = 4
        i.singleCopyLimit = 100
        // an app that never said it joins parts: the 10-byte image fits one copy, so it goes whole
        XCTAssertEqual(i.copyGameData(titleID: titleID, archive: f.archive, app: "", bundleID: "org.nxnative.shell",
                                      outcome: .init(ok: true, message: "")).copied, 2)
        XCTAssertEqual(try String(contentsOfFile: games + "/romfs.img"), "0123456789")
        XCTAssertTrue(calls.contains { $0.contains("--source Documents/shell-features.txt") })

        // too large for one copy: parts all the same
        try fm.removeItem(atPath: games)
        i.singleCopyLimit = 4
        XCTAssertEqual(i.copyGameData(titleID: titleID, archive: f.archive, app: "", bundleID: "org.nxnative.shell",
                                      outcome: .init(ok: true, message: "")).copied, 4)
        XCTAssertTrue(fm.fileExists(atPath: games + "/romfs.img.nxpart.0002.0003"))

        // an app that says it joins parts gets them for any file larger than one part
        try fm.removeItem(atPath: games)
        i.singleCopyLimit = 100
        try write(docs + "/shell-features.txt", "data-parts 1\n")
        XCTAssertEqual(i.copyGameData(titleID: titleID, archive: f.archive, app: "", bundleID: "org.nxnative.shell",
                                      outcome: .init(ok: true, message: "")).copied, 4)
        XCTAssertFalse(fm.fileExists(atPath: games + "/romfs.img"))
    }

    func testPartsOfAnotherImageAreSentAgain() throws {
        let f = try fixtureWithRomFSTool()
        let image = URL(fileURLWithPath: f.archive + "/romfs.img")
        let games = container + "/org.nxnative.shell/Documents/games/\(titleID)"
        try romfsImage().write(to: image)   // 58 bytes: 4 parts of 16
        var i = installer(f)
        i.partSize = 16
        try write(state + "/fail-on", "romfs.img.nxpart.0003.0004")
        XCTAssertEqual(install(i, f).failure, .shellDataIncomplete)
        try fm.removeItem(atPath: state + "/fail-on")

        // the same image: the three parts that went over stay
        var before = copies().count
        XCTAssertTrue(i.installData(titleID: titleID, archive: f.archive).ok)
        XCTAssertEqual(copies().count - before, 1)

        // another image of the same size: every part goes again
        let update = romfsImage(index: 1)
        try update.write(to: image)
        before = copies().count
        XCTAssertTrue(i.installData(titleID: titleID, archive: f.archive).ok)
        XCTAssertEqual(copies().count - before, 4)
        try joinOnDevice(games, file: "romfs.img")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: games + "/romfs.img")), update)
        XCTAssertEqual(i.installData(titleID: titleID, archive: f.archive).message, "Z already has this version of the game data.")
    }

    // ---- through the model: the build with the third target, and the re-sign ----

    @MainActor func testBuildWithTheShellTargetInstallsAndResignsTheSharedApp() throws {
        let f = try fixtureWithRomFSTool()
        testDefaults.set(f.root, forKey: "shellRoot")
        let modelStores = LauncherStores(xcrun: f.xcrun, defaults: testDefaults); let model = modelStores.build
        modelStores.repo.path = f.repo
        model.target = "ios"
        model.home = path("home")
        model.outDir = path("out")
        modelStores.dependencies.pythonPath = "/usr/bin/python3"
        modelStores.dependencies.dotnetPath = "/usr/bin/true"
        modelStores.dependencies.checked = true
        modelStores.dependencies.deps = [Dep(id: "test", name: "test", hint: "", present: true, installCmd: [])]
        modelStores.deviceStore.installDevice = device
        modelStores.deviceStore.signingTeam = team
        try write(f.repo + "/dm/tools/nx_extract/Program.cs", "")
        try write(f.repo + "/scripts/build_ipa_from_nsp.py", """
        import sys, json, pathlib
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
        try fm.removeItem(atPath: f.archive)   // the build's own archive step makes it

        let finished = expectation(description: "Installed")
        let token = model.$done.filter { $0 }.prefix(1).sink { _ in finished.fulfill() }
        let asked = modelStores.deviceStore.$shellCopy.compactMap { $0 }.prefix(1).sink { _ in modelStores.deviceStore.answerCopy(.copy) }
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

        // the re-sign after seven days: same project, same identifier, same app, even if the project was generated from an
        // unmounted Gatekeeper AppTranslocation path or a moved launcher bundle
        let pbxPath = f.root + "/project/DmShell.xcodeproj/project.pbxproj"
        XCTAssertFalse((try String(contentsOfFile: pbxPath, encoding: .utf8)).contains(f.repo))
        let translocated = "/private/var/folders/xx/T/AppTranslocation/2CFF0344-0DA8/d/NX2Apple.app/Contents/Resources/frontend-ios"
        try write(pbxPath, """
        F96F /* frontend-ios */ = {isa = PBXFileReference; name = "frontend-ios"; path = "../../../../../../../\(translocated.dropFirst())"; sourceTree = SOURCE_ROOT; };
        376B /* XCLocalSwiftPackageReference */ = {isa = XCLocalSwiftPackageReference; relativePath = "\(translocated)"; };
        """)
        let pkgLink = f.root + "/project/frontend-ios", shellLink = f.root + "/project/Shell"
        try? fm.removeItem(atPath: pkgLink); try? fm.removeItem(atPath: shellLink)
        try fm.createSymbolicLink(atPath: pkgLink, withDestinationPath: translocated)
        try fm.createSymbolicLink(atPath: shellLink, withDestinationPath: "/private/var/folders/xx/T/AppTranslocation/2CFF0344-0DA8/Shell")
        try write(container + "/org.nxnative.shell/Documents/save/slot1.bin", "my save")
        model.home = path("home")
        let cachedProfiles = model.home + "/Library/Developer/Xcode/UserData/Provisioning Profiles"
        try fm.createDirectory(atPath: cachedProfiles, withIntermediateDirectories: true)
        let staleExpiry = Date(timeIntervalSince1970: 1_900_000_000)
        let freshExpiry = Date(timeIntervalSince1970: 1_900_604_800)
        let staleProfile = try PropertyListSerialization.data(
            fromPropertyList: [
                "UUID": "STALE-UUID",
                "Name": "iOS Team Provisioning Profile: org.nxnative.shell",
                "TeamIdentifier": [team],
                "Entitlements": ["application-identifier": "\(team).org.nxnative.shell"],
                "ExpirationDate": staleExpiry
            ],
            format: .xml,
            options: 0
        )
        let freshProfile = try PropertyListSerialization.data(
            fromPropertyList: [
                "UUID": "FRESH-UUID",
                "Name": "iOS Team Provisioning Profile: org.nxnative.shell",
                "TeamIdentifier": [team],
                "Entitlements": ["application-identifier": "\(team).org.nxnative.shell"],
                "ExpirationDate": freshExpiry
            ],
            format: .xml,
            options: 0
        )
        let appPath = model.installedAppPath
        try staleProfile.write(to: URL(fileURLWithPath: cachedProfiles + "/STALE-UUID.mobileprovision"))
        try staleProfile.write(to: URL(fileURLWithPath: appPath + "/embedded.mobileprovision"))
        try fm.createDirectory(atPath: appPath + "/_CodeSignature", withIntermediateDirectories: true)
        try write(appPath + "/_CodeSignature/CodeResources", "old-sig")

        // 1. If xcodebuild itself fails, staged profiles and _CodeSignature roll back intact.
        try write(state + "/fail-xcodebuild", "")
        let failedSign = expectation(description: "Failed xcodebuild")
        model.resignOnDevice(app: appPath, device: device) { failedSign.fulfill() }
        wait(for: [failedSign], timeout: 30)
        try fm.removeItem(atPath: state + "/fail-xcodebuild")
        XCTAssertTrue(fm.fileExists(atPath: cachedProfiles + "/STALE-UUID.mobileprovision"))
        XCTAssertEqual(AppSignature.expiration(ofApp: appPath), staleExpiry)
        XCTAssertEqual(try String(contentsOfFile: appPath + "/_CodeSignature/CodeResources"), "old-sig")

        // 2. Once xcodebuild succeeds and embeds a new 7-day profile + signature, a later devicectl install failure
        // keeps the newly signed DmShell.app intact rather than rolling the old profile back over the newly signed binary.
        try freshProfile.write(to: URL(fileURLWithPath: state + "/new-profile"))
        try write(state + "/fail-install", "")
        let failedInstall = expectation(description: "Failed devicectl install after xcodebuild succeeded")
        model.resignOnDevice(app: appPath, device: device) { failedInstall.fulfill() }
        wait(for: [failedInstall], timeout: 30)
        try fm.removeItem(atPath: state + "/fail-install")
        XCTAssertFalse(fm.fileExists(atPath: cachedProfiles + "/STALE-UUID.mobileprovision"),
                       "stale cached profile is committed as soon as xcodebuild writes the new signature")
        XCTAssertEqual(AppSignature.expiration(ofApp: appPath), freshExpiry,
                       "DmShell.app keeps its newly signed 7-day profile when only devicectl install fails")
        XCTAssertEqual(try String(contentsOfFile: appPath + "/_CodeSignature/CodeResources"), "new-sig")

        // 3. Full re-sign + install succeeds.
        try staleProfile.write(to: URL(fileURLWithPath: cachedProfiles + "/STALE-UUID.mobileprovision"))
        let before = calls.count
        let resigned = expectation(description: "Re-signed")
        model.resignOnDevice(app: appPath, device: device) { resigned.fulfill() }
        wait(for: [resigned], timeout: 30)
        try? fm.removeItem(atPath: state + "/new-profile")
        XCTAssertFalse(fm.fileExists(atPath: cachedProfiles + "/STALE-UUID.mobileprovision"),
                       "stale cached profile must be cleared so Xcode requests a fresh 7-day profile")
        XCTAssertEqual(AppSignature.expiration(ofApp: appPath), freshExpiry)
        let log = Array(calls.dropFirst(before))
        let build = try XCTUnwrap(log.first { $0.hasPrefix("xcodebuild") })
        XCTAssertTrue(build.contains("-project \(f.root)/project/DmShell.xcodeproj -scheme DmShell"), build)
        XCTAssertTrue(build.contains("PRODUCT_BUNDLE_IDENTIFIER=org.nxnative.shell build"), build)
        XCTAssertEqual(log.filter { $0.hasPrefix("devicectl device install app") }.count, 1)
        XCTAssertTrue(log.allSatisfy { !$0.contains("--remove-existing-content") })
        XCTAssertEqual(try String(contentsOfFile: container + "/org.nxnative.shell/Documents/save/slot1.bin"), "my save")
        XCTAssertEqual(model.doneNote, String(format: model.t("dev.resigned"), "iPhone"))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: pkgLink), f.repo + "/frontend-ios")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: shellLink), f.repo + "/frontend-ios/Shell/App")
        let repairedPbx = try String(contentsOfFile: pbxPath, encoding: .utf8)
        XCTAssertFalse(repairedPbx.contains("AppTranslocation"), repairedPbx)
        XCTAssertTrue(repairedPbx.contains(#"relativePath = "frontend-ios";"#), repairedPbx)

        // When repo moves to another checkout, Shell resolves under <checkout>/frontend-ios/Shell/App and legacy dangling links are removed
        let checkout = path("moved-checkout")
        try write(checkout + "/tools/engine.py", "")
        try write(checkout + "/.upstream-ref", "deadbeef\n")
        try write(checkout + "/frontend-ios/Package.swift", "// swift-tools-version: 5.9\n")
        try fm.createDirectory(atPath: checkout + "/frontend-ios/Shell/App", withIntermediateDirectories: true)
        for item in ["Sources", "Shell", "tools"] {
            let link = f.root + "/project/" + item
            try? fm.removeItem(atPath: link)
            try fm.createSymbolicLink(atPath: link, withDestinationPath: "/missing/" + item)
        }
        try? fm.removeItem(atPath: pkgLink)
        try fm.createSymbolicLink(atPath: pkgLink, withDestinationPath: "/missing/frontend-ios")
        ShellInstall.refreshProjectLinks(root: f.root, resources: nil, repo: checkout)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: pkgLink), checkout + "/frontend-ios")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: f.root + "/project/Shell"), checkout + "/frontend-ios/Shell/App")
        for item in ["Sources", "tools"] {
            XCTAssertNil(try? fm.attributesOfItem(atPath: f.root + "/project/" + item))
        }
    }

    @MainActor private func makeModel(_ f: Fixture) throws -> LauncherStores {
        let modelStores = LauncherStores(xcrun: f.xcrun, defaults: testDefaults); let model = modelStores.build
        modelStores.repo.path = f.repo
        model.target = "ios"
        model.home = path("home")
        model.outDir = path("out")
        modelStores.dependencies.pythonPath = "/usr/bin/python3"
        modelStores.dependencies.dotnetPath = "/usr/bin/true"
        modelStores.dependencies.checked = true
        modelStores.dependencies.deps = [Dep(id: "test", name: "test", hint: "", present: true, installCmd: [])]
        modelStores.deviceStore.installDevice = device
        modelStores.deviceStore.signingTeam = team
        try write(f.repo + "/dm/tools/nx_extract/Program.cs", "")
        for tool in RepoLayout.requiredTools.filter({ $0 != RepoLayout.buildScript }) { try write(f.repo + "/" + tool, "") }
        try write(f.repo + "/scripts/build_ipa_from_nsp.py", "open('\(state)/script.txt', 'w').write('ran')\n")
        let base = temporary.appendingPathComponent("Test [\(titleID)].nsp"), keys = temporary.appendingPathComponent("prod.keys")
        try Data([0]).write(to: base); try Data().write(to: keys)
        model.slots[0].paths = [base.path]; model.slots[3].paths = [keys.path]
        return modelStores
    }

    /// An unknown device stops the build before the script runs: no hour of building for a device that cannot be installed on.
    @MainActor func testUnknownDeviceStopsTheBuildBeforeTheScriptRuns() throws {
        let f = try makeFixture()
        try writeDevices(state + "/devices-default.json", [("00008150-OTHER", "wired")])
        let modelStores = try makeModel(f)
        let model = modelStores.build
        model.startBuild()
        let stopped = expectation(description: "Checked")
        let token = model.$running.dropFirst().filter { !$0 }.prefix(1).sink { _ in stopped.fulfill() }
        wait(for: [stopped], timeout: 20)
        withExtendedLifetime(token) {}
        XCTAssertEqual(model.failure?.kind, .devicePairing)
        XCTAssertEqual(model.doneNote, String(format: model.t("shell.notPaired"), modelStores.deviceStore.deviceName(modelStores.deviceStore.installDevice)), "the pairing steps, in the app's language")
        XCTAssertFalse(fm.fileExists(atPath: state + "/script.txt"), "the build script did not start")
    }

    /// The copy card's answer and the failure row: a copy that fails midway says the data is incomplete, and Retry runs only the data step.
    @MainActor func testFailedCopyShowsTheIncompleteRowAndRetryFinishesIt() throws {
        let f = try makeFixture()
        testDefaults.set(f.root, forKey: "shellRoot")
        let modelStores = try makeModel(f)
        let model = modelStores.build
        try write(state + "/fail-on", "romfs.img")
        var plans: [ShellCopyPlan] = []
        let asked = modelStores.deviceStore.$shellCopy.compactMap { $0 }.sink { plans.append($0); modelStores.deviceStore.answerCopy(.copy) }
        func finish(_ start: () -> Void) {
            let ended = expectation(description: "Ended")
            let token = model.$running.dropFirst().filter { !$0 }.prefix(1).sink { _ in ended.fulfill() }
            start()
            wait(for: [ended], timeout: 30)
            withExtendedLifetime(token) {}
        }
        finish { model.installShell(framework: f.framework, titleID: titleID, name: "Test Game", archive: f.archive) }
        XCTAssertEqual(model.failure?.kind, .shellDataIncomplete)
        // The sentence before the tool's error, in every language: it used to split the English template on ": ", which
        // never matches a full-width colon (a Chinese macOS ran this test red on main).
        let marker = "\u{1}"
        let prefix = String(format: model.t("shell.copyIncomplete"), modelStores.deviceStore.deviceName(modelStores.deviceStore.installDevice), marker)
            .components(separatedBy: marker).first ?? "-"
        XCTAssertTrue(model.doneNote.hasPrefix(prefix), model.doneNote)
        XCTAssertFalse(model.done)
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans.first?.connection, .wired)

        // A failed automatic install offers the export's Finder recovery too (#899).
        // Use that install's folder, even if the selected build archive has since changed.
        var revealed: [URL] = []
        model.revealItem = { revealed.append($0) }
        model.archivePath = temporary.appendingPathComponent("another-game").path
        let beforeFinder = calls
        model.copyWithFinder(oneGame: false)
        XCTAssertEqual(revealed.map(\.path), [f.archive])
        XCTAssertTrue(model.finderShown)
        XCTAssertEqual(calls, beforeFinder, "Finder recovery does not start another copy or build")
        XCTAssertFalse(model.done, "showing the manual instructions does not claim a successful transfer")
        XCTAssertEqual(model.failure?.kind, .shellDataIncomplete)
        model.running = true
        model.copyWithFinder(oneGame: false)
        model.running = false
        model.copyWithFinder(oneGame: true)
        XCTAssertEqual(revealed.count, 1, "no recovery during a transfer or for a single-game IPA")

        try fm.removeItem(atPath: state + "/fail-on")
        let signs = calls.filter { $0.hasPrefix("xcodebuild") }.count
        finish { model.fixBuildFailure(.shellDataIncomplete) }
        withExtendedLifetime(asked) {}
        XCTAssertNil(model.failure)
        XCTAssertFalse(model.finderShown, "retrying the install clears the previous manual instructions")
        model.copyWithFinder(oneGame: false)
        XCTAssertEqual(revealed.count, 1, "a successful install does not offer the failure fallback")
        XCTAssertTrue(model.done, model.doneNote)
        XCTAssertTrue(model.buildingGame, "retrying the data copy keeps buildingGame true so BuildRecorder and BuildNotifications record the completed iOS build")
        XCTAssertEqual(model.installedOn, device)
        XCTAssertEqual(calls.filter { $0.hasPrefix("xcodebuild") }.count, signs)
        XCTAssertEqual(try String(contentsOfFile: container + "/org.nxnative.shell/Documents/games/\(titleID)/romfs.img"), "0123456789")
    }

    @MainActor func testShellTargetWithoutDeviceStopsBeforeBuilding() throws {
        let modelStores = LauncherStores(defaults: testDefaults); let model = modelStores.build
        modelStores.repo.path = temporary.path
        try write(temporary.path + "/dm/tools/nx_extract/Program.cs", "")
        model.target = "ios"
        modelStores.deviceStore.installDevice = ""
        // "Export the IPA" is read from the shared preferences of the test process, so a value left there (a killed run, a run in
        // another worktree at the same time) skipped the device check and the test saw the stale-tools note instead.
        modelStores.deviceStore.exportIPA = false
        model.startBuild()
        XCTAssertFalse(model.running)
        XCTAssertEqual(model.doneNote, model.t("shell.needsDevice"))
    }

    @MainActor func testResignAfterDeletingAGameRegeneratesTheProjectAndPrunesEmbeddedFrameworks() throws {
        let f = try makeFixture()
        let secondID = "0100000000010000"
        let secondFramework = path("work2/shell-framework/DmGame\(secondID).framework")
        try write(secondFramework + "/game.manifest.json", "{}")
        try write(secondFramework + "/DmGame\(secondID)", "executable")
        let secondArchive = path("out/games", secondID)
        try write(secondArchive + "/romfs.img", "second")

        var first = installer(f)
        first.decideCopy = { _ in .skip }
        XCTAssertTrue(install(first, f).ok)
        var second = installer(f)
        second.decideCopy = { _ in .skip }
        XCTAssertTrue(second.install(framework: secondFramework, titleID: secondID, name: "Second Game", archive: secondArchive).ok)

        let embedded = f.root + "/derived-data/Build/Products/Release-iphoneos/DmShell.app/Frameworks"
        XCTAssertTrue(fm.fileExists(atPath: embedded + "/DmGame\(titleID).framework"))
        XCTAssertTrue(fm.fileExists(atPath: embedded + "/DmGame\(secondID).framework"))
        XCTAssertEqual(ShellLibrary.load(root: f.root).games.map(\.titleID), [titleID, secondID])

        // Delete the second game through GameDeletion (removes its mirrored framework and drops it from shell.json,
        // while DmShell.xcodeproj / frameworks.txt still lists both games).
        var secondGame = LibraryGame(titleID: secondID, name: "Second Game", archivePath: secondArchive)
        secondGame.iosAppPath = ShellInstall.appPath(root: f.root)
        secondGame.outputDirectory = path("out")
        let deletion = GameDeletion.plan(for: secondGame, shellRoot: f.root, home: path("home"), support: URL(fileURLWithPath: path("support")))
        XCTAssertEqual(deletion.run(saves: false, trash: { try self.fm.removeItem(at: $0) }), [])
        XCTAssertFalse(fm.fileExists(atPath: ShellInstall.mirroredFramework(root: f.root, titleID: secondID)))
        XCTAssertEqual(ShellLibrary.load(root: f.root).games.map(\.titleID), [titleID])

        testDefaults.set(f.root, forKey: "shellRoot")
        let modelStores = try makeModel(f)
        let model = modelStores.build
        model.target = BuildTarget.mac
        XCTAssertEqual(model.runningTarget, BuildTarget.mac)
        var observedRunningTarget = ""
        var observedBuildingGame = true
        let runningProbe = model.$running.filter { $0 }.prefix(1).sink { _ in
            observedRunningTarget = model.runningTarget
            observedBuildingGame = model.buildingGame
        }
        let resigned = expectation(description: "Re-signed after deletion")
        model.resignOnDevice(app: ShellInstall.appPath(root: f.root), device: device) { resigned.fulfill() }
        wait(for: [resigned], timeout: 30)
        withExtendedLifetime(runningProbe) {}

        XCTAssertEqual(observedRunningTarget, BuildTarget.ios, "re-signing while the Build form sits on mac-app still reports an iPhone activity")
        XCTAssertFalse(observedBuildingGame, "re-signing does not mark the Build form's game as a running game build")
        XCTAssertEqual(model.target, BuildTarget.mac, "re-signing leaves the Build form's target choice untouched")
        XCTAssertEqual(model.runningTarget, BuildTarget.mac, "once the standalone re-sign ends, runningTarget returns to the Build form's target so OutcomeCard is not polluted")
        XCTAssertEqual(model.doneNote, String(format: model.t("dev.resigned"), "iPhone"))
        XCTAssertTrue(fm.fileExists(atPath: embedded + "/DmGame\(titleID).framework"))
        XCTAssertFalse(fm.fileExists(atPath: embedded + "/DmGame\(secondID).framework"),
                       "the deleted game's framework must be pruned from the built DmShell.app")
        let fwlist = try String(contentsOfFile: f.root + "/project/frameworks.txt", encoding: .utf8)
        XCTAssertTrue(fwlist.contains("DmGame\(titleID).framework"), fwlist)
        XCTAssertFalse(fwlist.contains("DmGame\(secondID).framework"), fwlist)

        // When all games' frameworks are gone on disk, re-signing reports the missing project instead of failing in xcodebuild.
        try fm.removeItem(atPath: ShellInstall.mirroredFramework(root: f.root, titleID: titleID))
        let empty = expectation(description: "No games left")
        model.resignOnDevice(app: ShellInstall.appPath(root: f.root), device: device) { empty.fulfill() }
        wait(for: [empty], timeout: 10)
        XCTAssertEqual(model.doneNote, String(format: model.t("dev.resignNoProject"), model.shortPath(f.root + "/project/DmShell.xcodeproj")))
    }

    @MainActor func testInstallShellForwardsCompileSignInstallAndWeightedTransferProgressToBuildStoreStages() throws {
        let f = try makeFixture()
        try write(f.archive + "/romfs.img", String(repeating: "a", count: 60))
        try write(f.archive + "/aoc/1.img", String(repeating: "b", count: 40))

        let customXcrun = path("xcrun-progress")
        let baseXcrun = try String(contentsOfFile: f.xcrun, encoding: .utf8)
        let patchedXcrun = baseXcrun
            .replacingOccurrences(
                of: "print('CodeSign ' + app, flush=True)",
                with: "print('CompileC /tmp/ShellMain.o /tmp/ShellMain.m', flush=True), print('CodeSign ' + app, flush=True)"
            )
            .replacingOccurrences(
                of: "print('60%', flush=True)",
                with: "sys.stdout.write('20%\\r50%\\n') or sys.stdout.flush()"
            )
        try patchedXcrun.write(toFile: customXcrun, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: customXcrun)

        var custom = f
        custom.xcrun = customXcrun
        testDefaults.set(custom.root, forKey: "shellRoot")
        let stores = try makeModel(custom)
        let model = stores.build
        let asked = stores.deviceStore.$shellCopy.compactMap { $0 }.sink { _ in
            stores.deviceStore.answerCopy(.copy)
        }

        var signDetails: [String] = []
        var installSnapshots: [(String, Double?)] = []
        var copySnapshots: [(String, Double?)] = []
        let sub = model.$stages.sink { stages in
            if let sign = stages.first(where: { $0.id == ShellInstaller.signStageID && $0.state == .running }), !sign.detail.isEmpty {
                signDetails.append(sign.detail)
            }
            if let inst = stages.first(where: { $0.id == ShellInstaller.installStageID && $0.state == .running }), !inst.detail.isEmpty {
                installSnapshots.append((inst.detail, inst.percent))
            }
            if let copy = stages.first(where: { $0.id == ShellInstaller.copyStageID && $0.state == .running }), !copy.detail.isEmpty {
                copySnapshots.append((copy.detail, copy.percent))
            }
        }

        let finished = expectation(description: "installShell finished")
        let doneSub = model.$running.dropFirst().filter { !$0 }.prefix(1).sink { _ in finished.fulfill() }
        model.installShell(framework: custom.framework, titleID: titleID, name: "Test Game", archive: custom.archive)
        wait(for: [finished], timeout: 30)
        withExtendedLifetime(asked) {}
        withExtendedLifetime(sub) {}
        withExtendedLifetime(doneSub) {}

        XCTAssertTrue(model.done, model.doneNote)
        XCTAssertTrue(signDetails.contains("compiling"), "expected compiling detail in \(signDetails)")
        XCTAssertTrue(signDetails.contains("signing"), "expected signing detail in \(signDetails)")
        XCTAssertTrue(installSnapshots.contains { $0.0 == "installing" && $0.1 == 45 }, "expected 45% install progress in \(installSnapshots)")
        // localFiles orders aoc/1.img (40 B) before romfs.img (60 B): 20% and 50% of 40 B = 8% and 20%, then 40 + 20%/50% of 60 B = 52% and 70%.
        XCTAssertTrue(copySnapshots.contains { $0.0 == "1/2" && $0.1 == 8 }, "expected weighted 8% on first file in \(copySnapshots)")
        XCTAssertTrue(copySnapshots.contains { $0.0 == "1/2" && $0.1 == 20 }, "expected weighted 20% on first file in \(copySnapshots)")
        XCTAssertTrue(copySnapshots.contains { $0.0 == "2/2" && $0.1 == 52 }, "expected weighted 52% on second file in \(copySnapshots)")
        XCTAssertTrue(copySnapshots.contains { $0.0 == "2/2" && $0.1 == 70 }, "expected weighted 70% on second file in \(copySnapshots)")

        var partStages: [ShellStage] = []
        var partBytes: [(Int64, Int64)] = []
        let partArchive = path("out/part-games", titleID)
        try write(partArchive + "/romfs.img", String(repeating: "z", count: 25))
        var chunked = installer(custom)
        chunked.partSize = 10
        chunked.stage = { partStages.append($0) }
        chunked.copyProgress = { partBytes.append(($0, $1)) }
        let partOutcome = chunked.installData(titleID: titleID, archive: partArchive)
        XCTAssertTrue(partOutcome.ok, partOutcome.message)
        let runningParts = partStages.filter { $0.id == ShellInstaller.copyStageID && $0.state == .running && $0.percent != nil }
        let percents = runningParts.compactMap(\.percent)
        XCTAssertFalse(percents.isEmpty)
        for pair in zip(percents, percents.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0, pair.1, "part percentages must never regress across chunks: \(percents)")
        }
        XCTAssertTrue(runningParts.contains { $0.detail == "1/3" && $0.percent == 20 }, "\(runningParts)")
        XCTAssertTrue(runningParts.contains { $0.detail == "2/3" && $0.percent == 60 }, "\(runningParts)")
        XCTAssertTrue(runningParts.contains { $0.detail == "3/3" && $0.percent == 90 }, "\(runningParts)")
        XCTAssertEqual(partBytes.last?.0, 25)
    }

    func testAppIDLimit9120DoesNotRetryTeamVariantAndReportsAppIDLimit() throws {
        let f = try makeFixture()
        try write(state + "/xcodebuild-error", """
        /tmp/shell/project/DmShell.xcodeproj: error: Failed to register bundle identifier: The app identifier "org.nxnative.shell" cannot be registered to your development team because it is not available. (9120) (in target 'DmShell' from project 'DmShell')
        /tmp/shell/project/DmShell.xcodeproj: error: No profiles for 'org.nxnative.shell' were found: Xcode couldn't find any iOS App Development provisioning profiles matching 'org.nxnative.shell'. (in target 'DmShell' from project 'DmShell')

        """)
        let outcome = install(installer(f), f)
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.step, .sign)
        XCTAssertEqual(outcome.failure, .appIDLimit)
        XCTAssertTrue(outcome.message.contains("9120"), outcome.message)
        let builds = try String(contentsOfFile: state + "/calls.txt", encoding: .utf8).split(separator: "\n").filter { $0.hasPrefix("xcodebuild") }
        XCTAssertEqual(builds.count, 1, "must not retry under org.nxnative.shell.<team> when 9120 is reached: \(builds)")
    }
}
