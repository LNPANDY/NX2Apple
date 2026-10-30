import XCTest
import SwiftUI
import Combine
@testable import NSPortBuilder

final class LibraryTests: XCTestCase {
    private var temporary: URL!
    private let titleID = "0100535012974000"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    /// Every test app carries this bundle ID, so a saved choice goes to a preferences domain of this run and never to a real game's.
    private var bundleID: String { "org.nxnative.frontendtests." + temporary.lastPathComponent }

    override func tearDownWithError() throws {
        let domain = bundleID as CFString
        for key in (CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]) ?? [] { CFPreferencesSetAppValue(key as CFString, nil, domain) }
        CFPreferencesAppSynchronize(domain)
        try FileManager.default.removeItem(at: temporary)
    }

    private func makeApp(_ titleID: String, name: String = "Hades") throws -> URL {
        let app = temporary.appendingPathComponent(name + ".app")
        let executables = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
        for name in ["nxnative", "dmhost"] {
            try FileManager.default.createSymbolicLink(at: executables.appendingPathComponent(name), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        }
        let info: [String: Any] = ["DMTitleID": titleID, "CFBundleDisplayName": name, "CFBundleExecutable": "nxnative", "CFBundleIdentifier": bundleID]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    func testReadyRequiresMatchingGameAndCompleteExecutables() throws {
        let app = try makeApp(titleID)
        var game = LibraryGame(titleID: titleID, name: "Hades", appPath: app.path)
        XCTAssertTrue(game.isReady)
        game.titleID = "01007EF00011E000"
        XCTAssertFalse(game.isReady)
        game.titleID = titleID
        try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/MacOS/dmhost"))
        XCTAssertFalse(game.isReady)
        XCTAssertThrowsError(try MacGameBundle.read(app))
    }

    func testRejectsUnrelatedApplicationsAndExecutableTraversal() throws {
        let app = try makeApp("not-a-title-id")
        XCTAssertThrowsError(try MacGameBundle.read(app))
        let info: [String: Any] = ["DMTitleID": titleID, "CFBundleExecutable": "../../../../usr/bin/true"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertThrowsError(try MacGameBundle.read(app))
    }

    func testCollectionPersistsPathsAndRemovalLeavesFilesAlone() throws {
        let app = try makeApp(titleID)
        let file = temporary.appendingPathComponent("state/library.json")
        let library = GameLibrary(file: file)
        let id = try library.addApp(app)
        let image = temporary.appendingPathComponent("my-picture.png")
        try Data("not game data".utf8).write(to: image)
        library.setArtwork(image.path, for: id)
        let restored = GameLibrary(file: file)
        XCTAssertEqual(restored.games.count, 1)
        XCTAssertEqual(restored.games.first?.artworkPath, image.path)
        XCTAssertEqual(restored.games.first?.appPath, app.path)
        XCTAssertTrue(restored.games[0].isReady)
        restored.remove(id)
        XCTAssertTrue(GameLibrary(file: file).games.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
    }

    func testSuccessfulBuildMustMatchTheLibraryEntry() throws {
        let app = try makeApp(titleID)
        let file = temporary.appendingPathComponent("library.json")
        let game = LibraryGame(titleID: titleID, name: "Hades")
        try JSONEncoder().encode([game]).write(to: file)
        let library = GameLibrary(file: file)
        library.recordCompletedApp(path: temporary.appendingPathComponent("missing.app").path, for: game.id)
        XCTAssertFalse(library.games[0].isReady)
        let wrongGame = try makeApp("01007EF00011E000", name: "Other")
        library.recordCompletedApp(path: wrongGame.path, for: game.id)
        XCTAssertFalse(library.games[0].isReady)
        library.recordCompletedApp(path: app.path, for: game.id)
        XCTAssertTrue(library.games[0].isReady)
        try FileManager.default.removeItem(at: app)
        XCTAssertFalse(library.games[0].isReady)
    }

    func testRebuildingSameGameKeepsOneEntryAndCustomArtwork() throws {
        let app = try makeApp(titleID)
        let library = GameLibrary(file: temporary.appendingPathComponent("library.json"))
        let first = try library.addApp(app)
        library.setArtwork("/some/external/artwork.jpg", for: first)
        XCTAssertEqual(try library.addApp(app), first)
        XCTAssertEqual(library.games.count, 1)
        XCTAssertEqual(library.games[0].artworkPath, "/some/external/artwork.jpg")
    }

    private func writeSettings(_ app: URL) throws {
        let dm = app.appendingPathComponent("Contents/Resources/dm")
        try FileManager.default.createDirectory(at: dm, withIntermediateDirectories: true)
        try Data("""
        {"game": "\(titleID)", "settings": [
         {"env": "DM_FPS_TARGET", "kind": "choice", "section": "Game", "label": "Frame rate", "note": "", "default": "30", "options": [["30", "30 fps"], ["60", "60 fps"]]},
         {"env": "DM_RENDER_SCALE", "kind": "range", "section": "Game", "label": "Render scale", "note": "", "default": "1.0", "min": 0.5, "max": 1.0, "step": 0.05},
         {"env": "DM_FPS_HOLD", "kind": "toggle", "section": "Performance", "label": "Hold frames when late", "note": "", "default": "on", "on": "on", "off": "off"}]}
        """.utf8).write(to: dm.appendingPathComponent("launcher.json"))
    }

    func testLaunchOptionsKeepOnlyChoicesAndReachTheEnvironment() throws {
        let app = try makeApp(titleID)
        XCTAssertNil(LaunchSetting.read(app: app.path))   // packed before the settings were
        try writeSettings(app)
        let settings = try XCTUnwrap(LaunchSetting.read(app: app.path))
        XCTAssertEqual(settings.map(\.env), ["DM_FPS_TARGET", "DM_RENDER_SCALE", "DM_FPS_HOLD"])
        let file = temporary.appendingPathComponent("library.json")
        let library = GameLibrary(file: file)
        let id = try library.addApp(app)
        let store = SavedChoices(app: app.path, titleID: titleID)
        XCTAssertEqual(library.games[0].launchEnvironment(settings), [:], "the rows of launcher.json are saved choices, not launch overrides")
        store.set(settings[0], "60")
        store.set(settings[1], "1.00")   // the default, as a slider writes it: not kept
        store.set(settings[2], "off")
        XCTAssertEqual(store.raw("DM_FPS_TARGET") as? String, "60")
        XCTAssertNil(store.raw("DM_RENDER_SCALE"))
        XCTAssertEqual(store.raw("DM_FPS_HOLD") as? String, "off")
        XCTAssertTrue(GameLibrary(file: file).games[0].launchOptions.isEmpty, "the library file no longer holds them")
        store.set(settings[0], "30")
        XCTAssertNil(store.raw("DM_FPS_TARGET"))
        store.reset(settings)
        XCTAssertFalse(store.hasChoices(settings))
    }

    func testLaunchOptionTheBuildNoLongerOffersFallsBackToItsDefault() throws {
        let app = try makeApp(titleID)
        try writeSettings(app)
        let settings = try XCTUnwrap(LaunchSetting.read(app: app.path))
        let store = SavedChoices(app: app.path, titleID: titleID)
        for (key, value) in [("DM_FPS_TARGET", "120"), ("DM_RENDER_SCALE", "2"), ("DM_FPS_HOLD", "maybe")] {
            CFPreferencesSetAppValue(SavedChoices.key(key) as CFString, value as CFString, store.domain as CFString)
        }
        XCTAssertEqual(settings.map(store.current), ["30", "1.0", "on"])
    }

    func testBannersComeFromTheTitleListAndTakeTheHero() async throws {
        let images = temporary.appendingPathComponent("cdn")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let banner = images.appendingPathComponent("banner.jpg")
        let picture = NSImage(size: NSSize(width: 64, height: 36), flipped: false) { rect in NSColor.orange.setFill(); rect.fill(); return true }
        let tiff = try XCTUnwrap(picture.tiffRepresentation)
        try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [:])).write(to: banner)
        try Data("not an image".utf8).write(to: images.appendingPathComponent("broken.jpg"))
        let list = temporary.appendingPathComponent("US.en.json")
        try Data("""
        {"1": {"id": "\(titleID.lowercased())", "bannerUrl": "\(banner.absoluteString)"},
         "2": {"id": "01007EF00011E000", "bannerUrl": "\(images.appendingPathComponent("broken.jpg").absoluteString)"},
         "3": {"id": "0100000000010000", "bannerUrl": "https://example.com/elsewhere.jpg"},
         "4": {"id": null, "bannerUrl": null}}
        """.utf8).write(to: list)
        let folder = temporary.appendingPathComponent("artwork")
        let store = ArtworkStore(directory: folder, titleList: list, allowsFileURLs: true)
        let added = await store.fetchMissing([titleID, "01007EF00011E000", "0100000000010000", "not-a-title"])
        XCTAssertEqual(added, [titleID])   // the broken image and the host off Nintendo's CDN are skipped
        XCTAssertNotNil(ArtworkStore.cachedBanner(titleID, in: folder))
        XCTAssertNil(ArtworkStore.cachedBanner("01007EF00011E000", in: folder))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("index.json").path))
        let again = await store.fetchMissing([titleID])
        XCTAssertEqual(again, [])   // already there: no download

        let app = try makeApp(titleID)
        var game = LibraryGame(titleID: titleID, name: "Hades", appPath: app.path)
        XCTAssertEqual(GameLibrary.artwork(for: game, repo: temporary.path, banners: folder)?.size, NSSize(width: 64, height: 36))
        let own = temporary.appendingPathComponent("own.png")
        let small = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in NSColor.blue.setFill(); rect.fill(); return true }
        try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(small.tiffRepresentation))?.representation(using: .png, properties: [:])).write(to: own)
        game.artworkPath = own.path
        XCTAssertEqual(GameLibrary.artwork(for: game, repo: temporary.path, banners: folder)?.size, NSSize(width: 8, height: 8))   // the player's own image first
    }

    /// Stop ends the build's whole process group: the script and the tools it started (here two sleeps), even
    /// though the app itself ignores SIGTERM.
    func testStopEndsTheWholeProcessGroup() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("System Python is required") }
        let previous = signal(SIGTERM, SIG_IGN)   // as the running app does
        defer { signal(SIGTERM, previous) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 60 & sleep 60 & wait"]
        BuildModel.inOwnGroup(p, python: "/usr/bin/python3")
        try p.run()
        func members() -> Int {
            let ps = Process(), out = Pipe()
            ps.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            ps.arguments = ["-g", String(p.processIdentifier)]
            ps.standardOutput = out
            try? ps.run(); ps.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").count
        }
        var tries = 0
        while members() < 3 && tries < 50 { usleep(100_000); tries += 1 }
        XCTAssertEqual(members(), 3)   // the shell and its two children, in the leader's group
        let stopped = Date()
        BuildModel.endGroup(p.processIdentifier)
        p.waitUntilExit()
        tries = 0
        while members() > 0 && tries < 30 { usleep(100_000); tries += 1 }
        XCTAssertEqual(members(), 0)
        // Ended by the SIGTERM, well before the SIGKILL 5 s later. The shell may die of it or, when its children went
        // first, return from its wait and exit 0: either way the whole group is gone.
        XCTAssertLessThan(Date().timeIntervalSince(stopped), 3)
    }

    func testProgressDetailReadsTheScriptsCounts() {
        XCTAssertEqual(BuildModel.progressDetail(["step": "splitting", "done": 1203, "total": 19592, "unit": "shaders", "eta": 130]),
                       "splitting · " + NumberFormatter.localizedString(from: 1203, number: .decimal) + " / "
                       + NumberFormatter.localizedString(from: 19592, number: .decimal) + " shaders")
        XCTAssertEqual(BuildModel.progressDetail(["done": 2301, "unit": "files"]), NumberFormatter.localizedString(from: 2301, number: .decimal) + " files")
        XCTAssertTrue(BuildModel.progressDetail(["done": 1_000_000_000, "total": 3_000_000_000, "unit": "B", "est": true]).contains(" / ~"))
        XCTAssertEqual(BuildModel.progressDetail(["step": "booting the game"]), "booting the game")
    }

    /// The stage's clock runs on while the count stands still, and the script's estimate counts down from when it came, then goes.
    func testStageClockCountsOnAndTheEstimateRunsOut() {
        let t0 = Date()
        let stage = Stage(id: 1, name: "shader split", started: t0, eta: 71, etaAt: t0.addingTimeInterval(10))
        XCTAssertEqual(stage.clock(at: t0.addingTimeInterval(42), left: "%@ left"), "0:42 · " + BuildModel.duration(39) + " left")
        XCTAssertEqual(stage.clock(at: t0.addingTimeInterval(125), left: "%@ left"), "2:05")   // the estimate ran out: no stale "1 min 11 s left"
        XCTAssertEqual(stage.clock(at: t0.addingTimeInterval(3725), left: "%@ left"), "1:02:05")
    }

    /// Stop ends the build and leaves no stage behind (a spinner and a percentage of a build that no longer runs).
    @MainActor func testStoppedBuildResetsItsProgress() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("System Python is required for the process fixture") }
        let saved = ["repoPath", "buildTarget", "buildOutputDirectory"].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) } }
        let model = BuildModel()
        model.repoPath = temporary.path
        model.target = "mac-app"
        model.outDir = temporary.path
        model.pythonPath = "/usr/bin/python3"
        model.dotnetPath = "/usr/bin/true"
        model.depsChecked = true
        model.deps = [BuildModel.Dep(id: "test", name: "test", hint: "", present: true, installCmd: [])]
        let marker = temporary.appendingPathComponent("dm/tools/nx_extract/Program.cs")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: marker)
        try BuildModel.requiredTools.filter { $0 != BuildModel.buildScript }.forEach { tool in   // the other files the build checks for (#87)
            let url = temporary.appendingPathComponent(tool)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        let script = temporary.appendingPathComponent("scripts/build_ipa_from_nsp.py")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        import json, time
        print(json.dumps({'ev': 'stage', 'k': 1, 'n': 2, 'name': 'shader split', 'step': 'splitting'}), flush=True)
        print(json.dumps({'ev': 'progress', 'k': 1, 'name': 'shader split', 'step': 'splitting', 'done': 10, 'total': 40, 'unit': 'files', 'frac': 0.25}), flush=True)
        time.sleep(60)
        """.write(to: script, atomically: true, encoding: .utf8)
        let base = temporary.appendingPathComponent("Test [\(titleID)].nsp"), keys = temporary.appendingPathComponent("prod.keys")
        try Data([0]).write(to: base); try Data().write(to: keys)
        model.slots[0].paths = [base.path]; model.slots[3].paths = [keys.path]
        let running = expectation(description: "The stage is reported")
        let started = model.$stages.filter { $0.first?.percent == 25 }.prefix(1).sink { _ in running.fulfill() }
        model.startBuild()
        wait(for: [running], timeout: 10)
        let stopped = expectation(description: "The build ends")
        let ended = model.$running.dropFirst().filter { !$0 }.prefix(1).sink { _ in stopped.fulfill() }
        model.stop()
        wait(for: [stopped], timeout: 10)
        withExtendedLifetime((started, ended)) {}
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(model.stages.isEmpty)
        XCTAssertFalse(model.done)
        XCTAssertEqual(model.doneNote, model.t("msg.stopped"))
    }

    func testPairedDevicesAndSigningTeamsAreRead() {
        let json = """
        {"result": {"devices": [
          {"hardwareProperties": {"reality": "physical", "platform": "iOS", "udid": "00008150-AAAA", "marketingName": "iPhone 17 Pro Max"},
           "deviceProperties": {"name": "Z", "osVersionNumber": "27.0.1"}, "connectionProperties": {"pairingState": "paired", "transportType": "wired"}},
          {"hardwareProperties": {"reality": "physical", "platform": "iOS", "udid": "00008110-BBBB", "marketingName": "iPad mini"},
           "deviceProperties": {"name": "Kunegunde"}, "connectionProperties": {"pairingState": "paired"}},
          {"hardwareProperties": {"reality": "simulated", "platform": "iOS", "udid": "SIM"}, "deviceProperties": {"name": "Simulator"},
           "connectionProperties": {"pairingState": "paired", "transportType": "sameMachine"}},
          {"hardwareProperties": {"reality": "physical", "platform": "iOS", "udid": "UNPAIRED"}, "deviceProperties": {"name": "Other"},
           "connectionProperties": {"pairingState": "unpaired"}}]}}
        """
        let devices = DeviceTools.parseDevices(Data(json.utf8))
        XCTAssertEqual(devices.map(\.id), ["00008150-AAAA", "00008110-BBBB"])   // physical and paired, reachable first
        XCTAssertEqual(devices.map(\.reachable), [true, false])
        let identities = DeviceTools.identities("""
          1) 0123456789ABCDEF0123456789ABCDEF01234567 "Apple Development: Jo Doe (ABCDE12345)"
          2) 89ABCDEF0123456789ABCDEF0123456789ABCDEF "Apple Distribution: Jo Doe (TEAM123456)"
             2 valid identities found
        """)
        XCTAssertEqual(identities, ["Apple Development: Jo Doe (ABCDE12345)"])   // development only: distribution does not sign for a device
        XCTAssertEqual(DeviceTools.team(fromSubject: "subject=UID=X, CN=Apple Development: Jo Doe (ABCDE12345), OU=TEAM123456, O=Jo Doe, C=US"), "TEAM123456")
        XCTAssertNil(DeviceTools.team(fromSubject: "subject=CN=Something"))
    }

    /// An iPhone build with a device and a team: the script prepares the Xcode project, romfs.img is packed as for
    /// sideloading, xcodebuild signs the app without the game files for the device (the first try fails on a taken
    /// App ID, so the retry under the team's own bundle ID runs too), devicectl installs it, the game files go over
    /// once the player answered the transfer question, and the library opens it there. The tools are stand-ins; nothing is signed.
    @MainActor private func runInstallFlow(transfer: Bool) throws -> (BuildModel, [String], URL, URL) {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("System Python is required for the process fixture") }
        let saved = ["repoPath", "buildTarget", "buildOutputDirectory", "installDevice", "signingTeam"].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) } }
        let model = BuildModel()
        model.repoPath = temporary.path
        model.target = "ios"
        model.outDir = temporary.path
        model.pythonPath = "/usr/bin/python3"
        model.dotnetPath = "/usr/bin/true"
        model.depsChecked = true
        model.deps = [BuildModel.Dep(id: "test", name: "test", hint: "", present: true, installCmd: [])]
        model.installDevice = "00008150-AAAA"
        model.signingTeam = "TEAM123456"
        let marker = temporary.appendingPathComponent("dm/tools/nx_extract/Program.cs")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: marker)
        let calls = temporary.appendingPathComponent("calls.txt")
        try BuildModel.requiredTools.filter { $0 != BuildModel.buildScript }.forEach { tool in   // the other files the build checks for (#87)
            let url = temporary.appendingPathComponent(tool)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        let script = temporary.appendingPathComponent("scripts/build_ipa_from_nsp.py")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        import sys, json, pathlib   # stand-in for the NSP script; it takes '--work-dir'
        open('\(calls.path)', 'a').write('script ' + ' '.join(sys.argv[1:]) + '\\n')
        work = pathlib.Path(sys.argv[sys.argv.index('--work-dir') + 1])
        (work / 'xcode/DmIOS.xcodeproj').mkdir(parents=True)
        (work / 'extract/v0/RomFS').mkdir(parents=True); (work / 'extract/v0/RomFS/data.bin').write_bytes(b'game')
        def ev(**e): print(json.dumps(e), flush=True)
        ev(ev='stage', k=1, n=1, name='prepare Xcode')
        ev(ev='say', msg='[12:00:00] app name: Test; version: 1.0; bundle ID: org.nxnative.test')
        ev(ev='stage_end', k=1, name='prepare Xcode', ok=True, summary='', elapsed=1)
        """.write(to: script, atomically: true, encoding: .utf8)
        let packer = temporary.appendingPathComponent("dm/tools/romfs_image.py")   // stand-in: --reuse <RomFS> <image> writes the image
        try FileManager.default.createDirectory(at: packer.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        import sys
        open('\(calls.path)', 'a').write('romfs_image ' + ' '.join(sys.argv[1:]) + '\\n')
        open(sys.argv[3], 'wb').write(b'image')
        """.write(to: packer, atomically: true, encoding: .utf8)
        let xcrun = temporary.appendingPathComponent("xcrun")
        try """
        #!/usr/bin/python3
        import sys, json, pathlib, plistlib   # stand-in for xcrun: xcodebuild -list / build, devicectl install / launch
        a = sys.argv[1:]
        open('\(calls.path)', 'a').write(' '.join(a) + '\\n')
        if a[0] == 'xcodebuild' and '-list' in a:
            print('Command line invocation:'); print(json.dumps({'project': {'schemes': ['DmIOS', 'Test (0100535012974000)']}}))
        elif a[0] == 'xcodebuild':
            if 'PRODUCT_BUNDLE_IDENTIFIER=' not in ' '.join(a):
                # App IDs are global: the plain one is registered to another team, and the app retries under a team variant
                print('error: "iOS Team Provisioning Profile" cannot be registered to your development team', flush=True)
                sys.exit(1)
            app = pathlib.Path(a[a.index('-derivedDataPath') + 1]) / 'Build/Products/Release-iphoneos/DmIOS.app'
            app.mkdir(parents=True, exist_ok=True)   # a re-sign rebuilds over the app the install left there
            with (app / 'Info.plist').open('wb') as f: plistlib.dump({'CFBundleIdentifier': 'org.nxnative.test'}, f)
            print('CodeSign ' + str(app), flush=True)
        elif a[:3] == ['devicectl', 'device', 'install']:
            print('45%', flush=True); print('App installed', flush=True)
        elif a[:4] == ['devicectl', 'device', 'copy', 'to']:
            print('60%', flush=True); print('Copied', flush=True)
        """.write(to: xcrun, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xcrun.path)
        model.xcrunPath = xcrun.path
        let base = temporary.appendingPathComponent("Test [\(titleID)].nsp"), keys = temporary.appendingPathComponent("prod.keys")
        try Data([0]).write(to: base); try Data().write(to: keys)
        model.slots[0].paths = [base.path]; model.slots[3].paths = [keys.path]
        let finished = expectation(description: "Signed and installed")
        let token = model.$done.filter { $0 }.prefix(1).sink { _ in finished.fulfill() }
        let asked = model.$transferAsk.filter { $0 }.prefix(1).sink { _ in model.transferAnswer(transfer) }
        model.startBuild()
        wait(for: [finished], timeout: 20)
        withExtendedLifetime(token) {} ; withExtendedLifetime(asked) {}
        let log = try String(contentsOf: calls, encoding: .utf8).split(separator: "\n").map(String.init)
        return (model, log, calls, base)
    }

    /// The player may rather hand the game files to the device themselves (a fast external drive in Files):
    /// a skipped copy still counts as installed, and nothing is sent over USB.
    @MainActor func testSkippingTheTransferInstallsWithoutCopying() throws {
        let (model, log, _, _) = try runInstallFlow(transfer: false)
        XCTAssertFalse(log.contains { $0.hasPrefix("devicectl device copy") })
        XCTAssertEqual(model.installedOn, "00008150-AAAA")
        XCTAssertEqual(model.doneNote, String(format: model.t("dev.copySkipped"), "iPhone"))
        XCTAssertEqual(model.stages.filter { $0.id >= 1000 }.map(\.state), [.done, .done, .done])   // pack, sign, install — no copy row
    }

    @MainActor func testBuildSignsAndInstallsOnTheChosenDevice() throws {
        let (model, log, calls, base) = try runInstallFlow(transfer: true)
        let work = temporary.appendingPathComponent(titleID + "_build").path
        XCTAssertTrue(log[0].contains("--prepare-xcode --keep-extracted --team-id TEAM123456"))
        XCTAssertFalse(log[0].contains(" -o "))   // no IPA: the project goes to the device
        let build = try XCTUnwrap(log.first { $0.hasPrefix("xcodebuild -project") })
        for part in ["-scheme Test (0100535012974000)", "-destination id=00008150-AAAA", "-derivedDataPath \(work)/xcode-derived-data",
                     "-allowProvisioningUpdates", "DEVELOPMENT_TEAM=TEAM123456", "DM_COPY_ROMFS=NO"] { XCTAssertTrue(build.contains(part), part) }
        // The first sign failed on the taken App ID; the retry ran under the team's bundle ID and kept the same stage row.
        let signs = log.filter { $0.hasPrefix("xcodebuild -project") }
        XCTAssertEqual(signs.count, 2)
        XCTAssertTrue(signs[1].contains("PRODUCT_BUNDLE_IDENTIFIER=org.nxnative.\(titleID).TEAM123456"), String(signs[1]))
        XCTAssertEqual(Set(model.stages.filter { $0.id >= 1000 }.map(\.id)).count, 4)   // a retried stage keeps its row instead of piling up duplicates
        let app = work + "/xcode-derived-data/Build/Products/Release-iphoneos/DmIOS.app"
        let archive = temporary.path + "/games/\(titleID)"
        // the archive is packed before signing, the app installed before the archive goes into its Documents
        let order = ["romfs_image --reuse", "xcodebuild -project", "devicectl device install", "devicectl device copy"].map { step in log.firstIndex { $0.hasPrefix(step) } }
        XCTAssertEqual(order.compactMap { $0 }, order.compactMap { $0 }.sorted())
        XCTAssertEqual(order.compactMap { $0 }.count, 4)
        XCTAssertTrue(log.contains("devicectl device install app --device 00008150-AAAA \(app)"))
        XCTAssertTrue(log.contains("devicectl device copy to --device 00008150-AAAA --source \(archive) --destination Documents/games/\(titleID) --domain-type appDataContainer --domain-identifier org.nxnative.test"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive + "/romfs.img"))
        XCTAssertEqual(model.archivePath, archive)
        XCTAssertEqual(model.installedOn, "00008150-AAAA")
        XCTAssertEqual(model.stages.filter { $0.id >= 1000 }.map(\.state), [.done, .done, .done, .done])
        let library = GameLibrary(file: temporary.appendingPathComponent("library.json"))
        model.slots[0].paths = [base.path]
        let id = try XCTUnwrap(library.rememberInputs(model))
        library.recordCompletedIOS(ipa: model.ipaPath, archive: model.archivePath, app: model.installedAppPath, device: model.installedOn, for: id)
        XCTAssertTrue(library.games[0].onDevice)
        let opened = expectation(description: "Opened on the device")
        model.openOnDevice(udid: model.installedOn, app: model.installedAppPath) { error in XCTAssertNil(error); opened.fulfill() }
        wait(for: [opened], timeout: 10)
        XCTAssertTrue(try String(contentsOf: calls, encoding: .utf8).contains("devicectl device process launch --device 00008150-AAAA org.nxnative.test"))
    }

    /// A deleted app comes back without unpacking, signing or packing anything again: the signed app already in
    /// derived data is installed as it is, and the device keeps the game data (the bundle ID does not change).
    @MainActor func testReinstallInstallsTheSignedAppWithoutBuildingAgain() throws {
        let (model, _, calls, _) = try runInstallFlow(transfer: true)
        let app = model.installedAppPath
        let buildsBefore = try String(contentsOf: calls, encoding: .utf8).split(separator: "\n").filter { $0.hasPrefix("xcodebuild") }.count
        let done = expectation(description: "Reinstalled")
        model.reinstallOnDevice { done.fulfill() }
        wait(for: [done], timeout: 20)
        let log = try String(contentsOf: calls, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(log.filter { $0.hasPrefix("devicectl device install app") }.count, 2)
        XCTAssertEqual(log.last { $0.hasPrefix("devicectl device install app") }, "devicectl device install app --device 00008150-AAAA \(app)")
        XCTAssertEqual(log.filter { $0.hasPrefix("xcodebuild") }.count, buildsBefore)   // no second build
        XCTAssertEqual(log.filter { $0.hasPrefix("romfs_image") }.count, 1)              // the game files are not re-packed
        XCTAssertEqual(model.stages.last?.id, 1004)
        XCTAssertEqual(model.stages.last?.state, .done)
        XCTAssertEqual(model.doneNote, String(format: model.t("dev.reinstalled"), "iPhone"))
        XCTAssertFalse(model.running)
    }

    /// The saved package is an ordinary IPA — Payload/DmIOS.app/… at the archive's root, no __MACOSX — so a
    /// sideloader or another Mac installs it while the signature lasts, without building the game again.
    @MainActor func testSaveIPAWritesAnOrdinaryPayloadArchive() throws {
        let (model, _, _, _) = try runInstallFlow(transfer: true)
        XCTAssertEqual(model.defaultIPAName(), "DmIOS.ipa")
        let ipa = temporary.appendingPathComponent("Test Game.ipa")
        let saved = expectation(description: "Saved the IPA")
        model.saveIPA(to: ipa) { saved.fulfill() }
        wait(for: [saved], timeout: 30)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ipa.path))
        let unzip = Process(), out = Pipe()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-l", ipa.path]
        unzip.standardOutput = out
        try unzip.run(); unzip.waitUntilExit()
        let listing = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(unzip.terminationStatus, 0, listing)
        XCTAssertTrue(listing.contains("Payload/DmIOS.app/Info.plist"), listing)
        XCTAssertFalse(listing.contains("__MACOSX"), listing)
        XCTAssertEqual(model.doneNote, String(format: model.t("dev.savedIPA"), model.shortPath(ipa.path)))
        XCTAssertFalse(model.running)
    }

    /// Both actions name what is missing instead of doing nothing, and a failed reinstall is a note on the installed
    /// app, not a failed build (the app is still on the device).
    @MainActor func testReinstallAndSaveReportAMissingSignedApp() throws {
        let (model, _, _, _) = try runInstallFlow(transfer: true)
        try FileManager.default.removeItem(atPath: model.installedAppPath)
        var reported = expectation(description: "Reinstall says what is missing")
        model.reinstallOnDevice { reported.fulfill() }
        wait(for: [reported], timeout: 10)
        XCTAssertEqual(model.doneNote, String(format: model.t("dev.reinstallMissing"), model.shortPath(model.installedAppPath)))
        XCTAssertTrue(model.done)
        reported = expectation(description: "Save says what is missing")
        let ipa = temporary.appendingPathComponent("missing.ipa")
        model.saveIPA(to: ipa) { reported.fulfill() }
        wait(for: [reported], timeout: 10)
        XCTAssertEqual(model.doneNote, String(format: model.t("dev.saveNeedsApp"), model.shortPath(model.installedAppPath)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ipa.path))
    }

    /// The save panel's name comes from the app, with the separators a game name can carry replaced: a slash would make
    /// a subfolder, a colon shows as a folder in Finder.
    @MainActor func testTheIPANameComesFromTheDisplayNameWithoutPathSeparators() throws {
        let app = temporary.appendingPathComponent("DmIOS.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleDisplayName": "Zelda: Echoes/of Wisdom"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        let model = BuildModel()
        model.installedAppPath = app.path
        XCTAssertEqual(model.defaultIPAName(), "Zelda_ Echoes_of Wisdom.ipa")
    }

    /// The two commands the actions build: a plain devicectl install of the cached app, and ditto's Payload archive.
    func testTheReinstallAndIPARecipes() {
        XCTAssertEqual(BuildModel.reinstallCommand(xcrun: "/x", device: "D", app: "/a/DmIOS.app"),
                       ["/x", "devicectl", "device", "install", "app", "--device", "D", "/a/DmIOS.app"])
        XCTAssertEqual(BuildModel.ipaCommand(payload: "/t/Payload", ipa: "/o/Game.ipa"),
                       ["/usr/bin/ditto", "-c", "-k", "--norsrc", "--keepParent", "/t/Payload", "/o/Game.ipa"])
    }

    /// A re-sign is the install's xcodebuild line (same project, derived data, team) plus the installed app's own bundle
    /// ID, so Xcode reuses the compiled game and the device keeps the app's Documents; then the app is installed again,
    /// with no second romfs pack.
    @MainActor func testResignSignsAgainAndInstallsWithoutRepacking() throws {
        let (model, _, calls, _) = try runInstallFlow(transfer: true)
        let app = model.installedAppPath
        let done = expectation(description: "Re-signed")
        model.resignOnDevice(app: app, device: "00008150-AAAA") { done.fulfill() }
        wait(for: [done], timeout: 30)
        let log = try String(contentsOf: calls, encoding: .utf8).split(separator: "\n").map(String.init)
        let resign = try XCTUnwrap(log.last { $0.hasPrefix("xcodebuild -project") })
        for part in ["-derivedDataPath \(temporary.path)/\(titleID)_build/xcode-derived-data", "-allowProvisioningUpdates",
                     "DEVELOPMENT_TEAM=TEAM123456", "DM_COPY_ROMFS=NO", "PRODUCT_BUNDLE_IDENTIFIER=org.nxnative.test", "build"] {
            XCTAssertTrue(resign.contains(part), part)
        }
        XCTAssertEqual(log.filter { $0.hasPrefix("xcodebuild -project") }.count, 3)   // the install's two signs, then this one
        XCTAssertEqual(log.filter { $0.hasPrefix("romfs_image") }.count, 1)            // the game files are not packed again
        XCTAssertEqual(log.last { $0.hasPrefix("devicectl device install app") },
                       "devicectl device install app --device 00008150-AAAA \(app)")
        XCTAssertEqual(model.doneNote, String(format: model.t("dev.resigned"), "iPhone"))
        XCTAssertFalse(model.running)
    }

    /// A re-sign that cannot work says what to do: a missing cached project, or no signing team chosen.
    @MainActor func testResignReportsAMissingProjectOrTeam() throws {
        let (model, _, _, _) = try runInstallFlow(transfer: true)
        let savedTeam = UserDefaults.standard.string(forKey: "signingTeam")
        defer { UserDefaults.standard.set(savedTeam, forKey: "signingTeam") }
        // An app with a bundle ID but no project beside it: the cached build was moved or removed.
        let orphan = temporary.appendingPathComponent("orphan/xcode-derived-data/Build/Products/Release-iphoneos/DmIOS.app")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundleID], format: .xml, options: 0)
            .write(to: orphan.appendingPathComponent("Info.plist"))
        var reported = expectation(description: "Missing project reported")
        model.resignOnDevice(app: orphan.path, device: "00008150-AAAA") { reported.fulfill() }
        wait(for: [reported], timeout: 10)
        XCTAssertEqual(model.doneNote, String(format: model.t("dev.resignNoProject"),
                                             model.shortPath(temporary.path + "/orphan/xcode/DmIOS.xcodeproj")))
        model.signingTeam = ""
        reported = expectation(description: "Missing team reported")
        model.resignOnDevice(app: model.installedAppPath, device: "00008150-AAAA") { reported.fulfill() }
        wait(for: [reported], timeout: 10)
        XCTAssertEqual(model.doneNote, model.t("dev.resignNoTeam"))
        XCTAssertFalse(model.running)
    }

    func testCorruptLibraryIsReportedWithoutOverwritingIt() throws {
        let file = temporary.appendingPathComponent("library.json")
        let data = Data("broken JSON".utf8)
        try data.write(to: file)
        let library = GameLibrary(file: file)
        XCTAssertNotNil(library.error)
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testInstalledAppsAreFoundAtTopLevelOnly() throws {
        let app = try makeApp(titleID)
        let apps = temporary.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("Games"), withIntermediateDirectories: true)
        let installed = apps.appendingPathComponent(app.lastPathComponent)
        try FileManager.default.copyItem(at: app, to: installed)
        try FileManager.default.moveItem(at: app, to: apps.appendingPathComponent("Games/" + app.lastPathComponent))
        let missing = temporary.appendingPathComponent("NoSuchFolder")
        XCTAssertEqual(GameLibrary.installedApps(in: [apps, missing]).map { $0.resolvingSymlinksInPath().path },
                       [installed.resolvingSymlinksInPath().path])
    }

    func testFolderDiscoveryPrunesGameContentsAndRemembersLocation() throws {
        let app = try makeApp(titleID)
        let nested = temporary.appendingPathComponent("My games/Hades/mac")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let moved = nested.appendingPathComponent(app.lastPathComponent)
        try FileManager.default.moveItem(at: app, to: moved)
        let hidden = temporary.appendingPathComponent("RomFS/ShouldNotScan.app")
        try FileManager.default.createDirectory(at: hidden.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: moved, to: hidden)
        XCTAssertEqual(GameLibrary.builtApps(in: temporary).map { $0.resolvingSymlinksInPath().path }, [moved.resolvingSymlinksInPath().path])
        XCTAssertTrue(GameLibrary.builtApps(in: temporary.appendingPathComponent("unmounted-volume")).isEmpty)
        let state = temporary.appendingPathComponent("library.json")
        let library = GameLibrary(file: state)
        library.applicationFolders = []   // the machine's own /Applications is not part of this test
        let finished = expectation(description: "Folder scan completes")
        let token = library.$scanning.dropFirst().filter { !$0 }.sink { _ in finished.fulfill() }
        library.setFolder(temporary)
        wait(for: [finished], timeout: 3)
        withExtendedLifetime(token) {}
        XCTAssertEqual(GameLibrary(file: state).folder, temporary.path)
        XCTAssertEqual(library.games.map(\.titleID), [titleID])
    }

    /// The enumerator hands out resolved paths (/private/var/…); a test's own URLs keep /var/… — compare both the same way.
    private static func canon(_ path: String) -> String {
        path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
    }

    /// The player drops the base under "<game>/nsp本体/", beside it the update and the DLC: the scan must record the game's
    /// folder and find all three, exactly as picking that folder by hand does (a game auto-scanned game found neither).
    func testAScanFindsTheUpdateAndDLCBesideTheFolderTheBaseSitsIn() throws {
        let fm = FileManager.default
        let game = temporary.appendingPathComponent("马车8")
        let base = game.appendingPathComponent("nsp本体（1）")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let baseNSP = base.appendingPathComponent("[0100152000022000][v0].nsp")
        let update = game.appendingPathComponent("[UPD][v4.0.1][0100152000022800][v1507328][22.5.0].nsp")
        let dlc = game.appendingPathComponent("[0100152000023001][65536].nsz")
        for f in [baseNSP, update, dlc] { try Data([0]).write(to: f) }
        try Data([0]).write(to: game.appendingPathComponent("prod.keys"))
        // Another game in the same library root, its own folder, no update: the climb must stop at its own folder.
        let other = temporary.appendingPathComponent("王国之泪")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        let otherBase = other.appendingPathComponent("[0100F2C0115B6000][v0].nsp")
        try Data([0]).write(to: otherBase)

        let games = GameLibrary.sourceGames(in: temporary, repo: "")
        let mario = try XCTUnwrap(games.first { $0.titleID == "0100152000022000" })
        XCTAssertEqual(Self.canon(mario.sourceFolder), Self.canon(game.path), "the game's folder, not the folder the base package sits in")
        XCTAssertEqual(mario.inputs["base"]?.map(Self.canon), [Self.canon(baseNSP.path)])
        XCTAssertEqual(mario.inputs["update"]?.map(Self.canon), [Self.canon(update.path)], "the update beside the base's folder is found")
        XCTAssertEqual(mario.inputs["dlc"]?.map(Self.canon), [Self.canon(dlc.path)], "so is the DLC")
        XCTAssertEqual(mario.inputs["keys"]?.map(Self.canon), [Self.canon(game.appendingPathComponent("prod.keys").path)])
        XCTAssertEqual(Self.canon(mario.outputDirectory), Self.canon(base.path), "the build folder stays where the build page puts it today")

        let zelda = try XCTUnwrap(games.first { $0.titleID == "0100F2C0115B6000" })
        XCTAssertEqual(Self.canon(zelda.sourceFolder), Self.canon(other.path))
        XCTAssertEqual(zelda.inputs["update"], [], "nothing of the other game leaks in")
        XCTAssertEqual(zelda.inputs["dlc"], [])
    }

    /// Base, update and DLC in one folder: the folder is its own game folder and the climb goes no further.
    func testAScanOfAFlatGameFolderStopsAtThatFolder() throws {
        let flat = temporary.appendingPathComponent("Hades")
        try FileManager.default.createDirectory(at: flat, withIntermediateDirectories: true)
        // An update package carries the base's title ID + 0x800, a DLC one + 0x1000 and up.
        let files = ["[\(titleID)][v0].nsp", "[0100535012974800][v65536].nsp", "[0100535012975001][65536].nsz"]
        for f in files { try Data([0]).write(to: flat.appendingPathComponent(f)) }
        let games = GameLibrary.sourceGames(in: temporary, repo: "")
        let hades = try XCTUnwrap(games.first { $0.titleID == titleID })
        XCTAssertEqual(Self.canon(hades.sourceFolder), Self.canon(flat.path))
        XCTAssertEqual(hades.inputs["base"]?.map(Self.canon), [Self.canon(flat.appendingPathComponent(files[0]).path)])
        XCTAssertEqual(hades.inputs["update"]?.map(Self.canon), [Self.canon(flat.appendingPathComponent(files[1]).path)])
        XCTAssertEqual(hades.inputs["dlc"]?.map(Self.canon), [Self.canon(flat.appendingPathComponent(files[2]).path)])
    }

    func testReadOnlyScanOfConfiguredFolder() throws {
        guard let path = ProcessInfo.processInfo.environment["NX_LAUNCHER_SCAN_FOLDER"] else { throw XCTSkip("Set NX_LAUNCHER_SCAN_FOLDER for a read-only scan of real builds") }
        let apps = GameLibrary.builtApps(in: URL(fileURLWithPath: path))
        XCTAssertFalse(apps.isEmpty)
        for url in apps {
            let metadata = try MacGameBundle.read(url)
            print("Discovered Mac build: \(metadata.name) (\(metadata.titleID))")
        }
    }

    @MainActor func testCompletedBuildAppearsAutomaticallyInCollection() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("System Python is required for the process fixture") }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let saved = ["repoPath", "buildTarget", "buildOutputDirectory"].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) } }
        let model = BuildModel()
        model.repoPath = temporary.path
        model.target = "mac-app"
        model.outDir = temporary.path
        model.pythonPath = "/usr/bin/python3"
        model.dotnetPath = "/usr/bin/true"
        model.depsChecked = true
        model.deps = [BuildModel.Dep(id: "test", name: "test", hint: "", present: true, installCmd: [])]
        let marker = temporary.appendingPathComponent("dm/tools/nx_extract/Program.cs")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: marker)
        try BuildModel.requiredTools.filter { $0 != BuildModel.buildScript }.forEach { tool in   // the other files the build checks for (#87)
            let url = temporary.appendingPathComponent(tool)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        let script = temporary.appendingPathComponent("scripts/build_ipa_from_nsp.py")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        // This is a process contract fixture, not a game build or game data.
        try """
        import sys, pathlib, plistlib, json
        assert sys.argv[sys.argv.index('--progress') + 1] == 'json'
        def ev(**e): print(json.dumps(e), flush=True)
        ev(ev='stage', k=1, n=1, name='Mac app', step='starting')
        ev(ev='progress', k=1, name='Mac app', step='game files', done=1200, total=4800, unit='files', est=False, note='', frac=0.25, eta=90, elapsed=3)
        out = pathlib.Path(sys.argv[sys.argv.index('-o') + 1])
        (out / 'Contents/MacOS').mkdir(parents=True)
        for name in ['nxnative', 'dmhost']:
            (out / 'Contents/MacOS' / name).symlink_to('/usr/bin/true')
        with (out / 'Contents/Info.plist').open('wb') as f:
            plistlib.dump({'DMTitleID': '\(titleID)', 'CFBundleName': 'Test build', 'CFBundleExecutable': 'nxnative'}, f)
        ev(ev='stage_end', k=1, name='Mac app', ok=True, summary='Test build.app', elapsed=4)
        ev(ev='say', msg='[12:00:00] done')
        """.write(to: script, atomically: true, encoding: .utf8)
        let base = temporary.appendingPathComponent("Test [\(titleID)].nsp")
        let keys = temporary.appendingPathComponent("prod.keys")
        try Data([0]).write(to: base)
        try Data().write(to: keys)
        model.slots[0].paths = [base.path]
        model.slots[3].paths = [keys.path]
        let library = GameLibrary(file: temporary.appendingPathComponent("library.json"))
        let host = NSHostingView(rootView: ContentView(model: model, library: library, initialPage: .builds, performStartupChecks: false))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let completed = expectation(description: "Successful app is added without an import")
        let token = library.$games.filter { $0.contains(where: \.isReady) }.prefix(1).sink { _ in completed.fulfill() }
        XCTAssertTrue(model.canBuild)
        window.orderOut(nil) // Registration must work even while the launcher is hidden.
        model.startBuild()
        wait(for: [completed], timeout: 10)
        withExtendedLifetime(token) {}
        // The library can list the app before the model has taken in the script's exit (a slower Mac, CI): wait for both
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in model.done && !model.running }, object: nil)
        wait(for: [settled], timeout: 10)
        XCTAssertTrue(model.done)
        XCTAssertFalse(model.running)
        XCTAssertEqual(model.stages.map(\.name), ["Mac app"])   // from the JSON events, which the log shows as text
        XCTAssertEqual(model.stages.first?.state, .done)
        XCTAssertEqual(model.stages.first?.detail, "Test build.app")
        // The library marker beside the .app: what arms the game launcher's save relocation.
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            temporary.appendingPathComponent(".nx2apple-library").path))
        XCTAssertTrue(model.logTail.contains("✓ Mac app (4s): Test build.app"))
        XCTAssertFalse(model.logTail.contains("\"ev\""))
        XCTAssertEqual(library.games.count, 1)
        XCTAssertTrue(library.games[0].isReady)
        XCTAssertEqual(library.games[0].inputs["base"], [base.path])
    }

    /// Opt-in: the README's screenshots (frontend/screenshots/launcher-*.png), framed as macOS windows. They show a copy of
    /// the user's library with its eShop key art (never the library itself) and no personal paths.
    /// NX_LAUNCHER_README_DIR=<dir> NX_LAUNCHER_README_SETTINGS=<a Mac launcher.json> swift test --filter testReadmeScreenshots
    @MainActor func testReadmeScreenshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_README_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_README_DIR to render the README screenshots") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        let saved = ["repoPath", "buildTarget", "buildOutputDirectory"].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) } }
        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NS Port Builder/library.json")
        let copy = temporary.appendingPathComponent("library.json")
        // The games, without the user's folders: names and title IDs only, and BotW as a finished Mac build (a fixture app)
        let real_ = GameLibrary(file: real)
        let library = GameLibrary(file: copy)
        let botw = "01007EF00011E000", totk = "0100F2C0115B6000"
        let model = BuildModel()
        model.repoPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        model.lang = .en
        model.depsChecked = true
        model.deps = [BuildModel.Dep(id: "test", name: "Xcode", hint: "", present: true, installCmd: [])]
        for game in real_.games.sorted(by: { $0.name < $1.name }) {
            let name = game.name.replacingOccurrences(of: #"\s*\([0-9.]+ GB\)"#, with: "", options: .regularExpression)
            if game.titleID == botw { _ = try library.addApp(makeApp(botw, name: name)) }
            else { model.slots[0].paths = ["/games/\(name) [\(game.titleID)].nsp"]; _ = library.rememberInputs(model) }
        }
        model.slots[0].paths = []
        XCTAssertFalse(library.games.isEmpty, "the user's library is empty")
        let botwID = try XCTUnwrap(library.games.first { $0.titleID == botw }?.id)
        let totkID = library.games.first { $0.titleID == totk }?.id
        if let json = ProcessInfo.processInfo.environment["NX_LAUNCHER_README_SETTINGS"], let app = library.games.first(where: { $0.id == botwID })?.appPath {
            let dm = URL(fileURLWithPath: app).appendingPathComponent("Contents/Resources/dm")
            try FileManager.default.createDirectory(at: dm, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: json), to: dm.appendingPathComponent("launcher.json"))
        }

        /// The view at 2× in a window-shaped frame: rounded corners, the traffic lights, a soft shadow, transparent around.
        func shot<V: View>(_ name: String, _ view: V, size: NSSize, trafficLights: Bool = true) throws {
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))   // artwork, layout
            host.layoutSubtreeIfNeeded()
            let scale: CGFloat = 2
            let content = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            content.size = size
            host.cacheDisplay(in: host.bounds, to: content)
            window.orderOut(nil)
            let pad: CGFloat = 56, radius: CGFloat = 14, full = NSSize(width: size.width + pad * 2, height: size.height + pad * 2)
            let framed = NSImage(size: full, flipped: false) { _ in
                let rect = NSRect(x: pad, y: pad, width: size.width, height: size.height)
                let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.45); shadow.shadowBlurRadius = 36; shadow.shadowOffset = NSSize(width: 0, height: -14)
                shadow.set(); NSColor.black.setFill(); shape.fill()
                NSGraphicsContext.restoreGraphicsState()
                NSGraphicsContext.saveGraphicsState(); shape.addClip()
                content.draw(in: rect)
                for (i, color) in [NSColor(red: 1, green: 0.37, blue: 0.34, alpha: 1), NSColor(red: 1, green: 0.74, blue: 0.18, alpha: 1), NSColor(red: 0.16, green: 0.78, blue: 0.25, alpha: 1)].enumerated() where trafficLights {
                    color.setFill(); NSBezierPath(ovalIn: NSRect(x: rect.minX + 20 + CGFloat(i) * 20, y: rect.maxY - 20 - 12, width: 12, height: 12)).fill()
                }
                NSGraphicsContext.restoreGraphicsState()
                NSColor.white.withAlphaComponent(0.12).setStroke(); shape.lineWidth = 1; shape.stroke()
                return true
            }
            let out = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(full.width * scale), pixelsHigh: Int(full.height * scale),
                                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            out.size = full
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
            framed.draw(in: NSRect(origin: .zero, size: full))
            NSGraphicsContext.restoreGraphicsState()
            try XCTUnwrap(out.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("launcher-\(name).png"))
        }
        let window = NSSize(width: 1280, height: 800)

        // The library while a Mac build of Tears of the Kingdom runs: the stage as the script reports it
        model.target = "mac-app"
        model.running = true
        model.stages = [Stage(id: 1, name: "build nx_extract", state: .done),
                        Stage(id: 2, name: "extract v1114112", state: .done, detail: "41,062 files, 18.3 GB"),
                        Stage(id: 3, name: "rewrite", state: .done, detail: "main, subsdk0, sdk"),
                        Stage(id: 4, name: "shader split", state: .running, detail: "splitting · 10,577 / 41,062 files · 41s left", percent: 26)]
        library.selectedID = botwID
        try shot("library", ContentView(model: model, library: library, activeBuildID: totkID, performStartupChecks: false), size: window)
        model.running = false; model.stages = []

        // The build page, ready to start: example paths, not the user's
        let dir = temporary.appendingPathComponent("games/Tears of the Kingdom")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let nsp = dir.appendingPathComponent("The Legend of Zelda Tears of the Kingdom [0100F2C0115B6000][v0].nsp")
        let update = dir.appendingPathComponent("The Legend of Zelda Tears of the Kingdom [0100F2C0115B6800][v1114112].nsp")
        let keys = dir.appendingPathComponent("prod.keys")
        for f in [nsp, update, keys] { try Data([0]).write(to: f) }
        model.slots[0].paths = [nsp.path]; model.slots[1].paths = [update.path]; model.slots[3].paths = [keys.path]
        model.gameDir = "/Volumes/Games/Tears of the Kingdom"
        model.outDir = "/Volumes/Games"
        try shot("build", ContentView(model: model, library: library, initialPage: .builds, performStartupChecks: false), size: NSSize(width: 1280, height: 940))

        if let upscale = LaunchSetting.read(app: library.games.first { $0.id == botwID }!.appPath)?.first(where: { $0.env == "DM_PRESENT_UPSCALE" }) {
            SavedChoices(app: library.games.first { $0.id == botwID }!.appPath, titleID: "01007EF00011E000").set(upscale, "metalfx")
        }
        try shot("launch-options", LaunchOptionsView(m: model, library: library, gameID: botwID), size: NSSize(width: 600, height: 700), trafficLights: false)   // a sheet: no window controls of its own
    }

    /// Opt-in native rendering for visual QA; it never touches the user's saved library.
    @MainActor func testRenderLauncherForVisualQA() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        let model = BuildModel()
        // Restore any preferences changed while preparing isolated preview data.
        let oldRepo = UserDefaults.standard.object(forKey: "repoPath")
        let oldOutput = UserDefaults.standard.object(forKey: "buildOutputDirectory")
        defer {
            UserDefaults.standard.set(oldRepo, forKey: "repoPath")
            UserDefaults.standard.set(oldOutput, forKey: "buildOutputDirectory")
        }
        model.repoPath = repo
        model.lang = CaptureLanguage.current(.en)
        model.outDir = temporary.path
        model.depsChecked = true
        model.deps = [BuildModel.Dep(id: "test", name: "Xcode", hint: "", present: true, installCmd: [])]
        let library = GameLibrary(file: temporary.appendingPathComponent("preview.json"))
        let examples = [(titleID, "Hades"), ("01007EF00011E000", "The Legend of Zelda: Breath of the Wild"),
                        ("0100000000010000", "Super Mario Odyssey"), ("010093801237C000", "Metroid Dread")]
        for (id, name) in examples.prefix(3) { _ = try library.addApp(makeApp(id, name: name)) }
        // The selected game (Hades) has run: its log is beside the app, so Manage > Show game log is on in the capture.
        try Data().write(to: temporary.appendingPathComponent(GameLog.marker))
        try FileManager.default.createDirectory(at: temporary.appendingPathComponent("log"), withIntermediateDirectories: true)
        try Data("fork patches: none\n".utf8).write(to: temporary.appendingPathComponent("log/\(titleID).log"))
        model.slots[0].paths = ["/preview/Metroid Dread [010093801237C000].nsp"]
        _ = library.rememberInputs(model)
        model.slots[0].paths = []
        library.selectedID = library.games.first?.id
        func capture(_ name: String, width: CGFloat = 1440, height: CGFloat = 1024, page: LauncherPage = .library, activeID: UUID? = nil, empty: Bool = false,
                     search: String? = nil, older: Set<UUID> = [], manageOpen: Bool = false, padRing: Bool = false, only: GameLibrary? = nil) throws {
            let store = only ?? (empty ? GameLibrary(file: temporary.appendingPathComponent("empty.json")) : library)
            let view = ContentView(model: model, library: store, initialPage: page, activeBuildID: activeID, performStartupChecks: false, search: search,
                                   olderTools: older, manageOpen: manageOpen, padRing: padRing)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            host.layoutSubtreeIfNeeded()
            let bounds = host.bounds
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: bounds))
            host.cacheDisplay(in: bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
            window.orderOut(nil)
        }
        try capture("library")
        try capture("library-search", search: "zel")
        try capture("library-small", width: 900, height: 680)
        try capture("manage-menu", manageOpen: true)   // the Manage menu open, mouse look
        try capture("manage-menu-pad", manageOpen: true, padRing: true)   // opened by the controller: the ring on the first row
        try capture("manage-menu-small", width: 900, height: 680, manageOpen: true, padRing: true)
        try capture("library-fullscreen", width: 2000, height: 1125)   // the cards at their widest: the row must fit under the hero
        try capture("empty", empty: true)
        try capture("build", page: .builds)
        try capture("build-small", width: 900, height: 680, page: .builds)
        try capture("settings", page: .settings)
        do {   // #87: a ZIP copy older than the app (no romfs_image.py), without git: auto-update off, then connected at launch, then a build refused
            let zip = temporary.appendingPathComponent("NX2Apple-0.4.5")
            for f in ["dm/tools/nx_extract/Program.cs", BuildModel.buildScript] {
                let url = zip.appendingPathComponent(f)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0]).write(to: url)
            }
            let previous = (model.repoPath, model.autoUpdateRepo, model.repoStatus, model.autoAdopted, model.doneNote)
            defer { (model.repoPath, model.autoUpdateRepo, model.repoStatus, model.autoAdopted, model.doneNote) = previous }
            model.repoPath = zip.path
            model.autoUpdateRepo = false
            try capture("settings-zip-auto-off", page: .settings)
            model.autoUpdateRepo = true
            model.repoStatus = String(format: model.t("repo.adoptedAuto"), "zip-copy-2026-10-27")
            model.autoAdopted = true
            try capture("library-adopted")
            model.autoAdopted = false
            model.repoStatus = ""
            try capture("settings-zip-old-tools", page: .settings)
            model.startBuild()   // refuses: the copy lacks romfs_image.py
            try capture("build-tools-old", height: 1500, page: .builds)
        }
        do {   // a released copy with an update downloaded and verified: Restart now in Settings and in the activity line
            let previous = (model.appInstallability, model.appUpdate, model.appStaged, model.appStatus)
            defer { (model.appInstallability, model.appUpdate, model.appStaged, model.appStatus) = previous }
            let release = AppUpdate.Release(tag: "v0.4.8", url: "https://example.invalid/NX2Apple-macOS-arm64.zip", digest: nil)
            model.appInstallability = .ok
            model.appUpdate = release
            model.appStatus = String(format: model.t("app.found"), release.tag)
            try capture("settings-update-found", page: .settings)
            model.appStaged = AppUpdate.Staged(release: release, app: temporary.appendingPathComponent("NX2Apple.app"))
            model.appStatus = String(format: model.t("app.ready"), release.tag)
            try capture("settings-update-ready", page: .settings)
            try capture("library-update-ready")
        }
        // Games built with older build tools (ToolsAge): the selected one rebuilt from its own inputs, as a recorded build has them
        model.slots[0].paths = ["/preview/Hades [\(titleID)].nsp"]
        _ = library.rememberInputs(model)
        model.slots[0].paths = []
        try capture("library-older-tools", older: [library.games[0].id, library.games[1].id])
        try capture("library-older-tools-small", width: 900, height: 680, older: [library.games[0].id, library.games[1].id])
        do {   // a game with an IPA but no Mac app: Build is the primary button, Reveal in Finder shows the IPA
            let ipa = temporary.appendingPathComponent("Metroid Dread.ipa")
            try Data([0]).write(to: ipa)
            let ipaOnly = LibraryGame(titleID: "010093801237C000", name: "Metroid Dread", ipaPath: ipa.path)
            let file = temporary.appendingPathComponent("ipa-only.json")
            try JSONEncoder().encode([ipaOnly]).write(to: file)
            try capture("library-ipa-only", only: GameLibrary(file: file))
            try capture("manage-menu-ipa-only", manageOpen: true, only: GameLibrary(file: file))
        }
        // An iPhone build with a paired device and a team (example values)
        let previousTarget = model.target
        model.target = "ios"
        model.devicesChecked = true
        model.devices = [AppleDevice(id: "00008150-AAAA", name: "iPhone", model: "iPhone 17 Pro Max", os: "27.0", reachable: true),
                         AppleDevice(id: "00008110-BBBB", name: "iPad mini", model: "iPad mini", os: "26.2", reachable: false)]
        model.teams = [SigningTeam(id: "TEAM123456", identity: "Apple Development: Jo Doe (ABCDE12345)")]
        let previousDevice = model.installDevice, previousTeam = model.signingTeam
        model.installDevice = "00008150-AAAA"; model.signingTeam = "TEAM123456"
        try capture("build-install", height: 1300, page: .builds)
        // #87: signed in to Xcode, no certificate yet (a free personal team and a paid one), and neither account nor certificate
        model.teams = [SigningTeam(id: "FGHIJ67890", identity: "", name: "Jo Doe", personal: true),
                       SigningTeam(id: "KLMNO11111", identity: "", name: "Studio Ltd")]
        model.signingTeam = "FGHIJ67890"
        try capture("build-install-xcode-team", height: 1300, page: .builds)
        model.teams = []; model.signingTeam = ""
        try capture("build-install-no-team", height: 1300, page: .builds)
        model.teams = [SigningTeam(id: "TEAM123456", identity: "Apple Development: Jo Doe (ABCDE12345)")]
        model.signingTeam = "TEAM123456"
        model.installDevice = previousDevice; model.signingTeam = previousTeam; model.target = previousTarget
        // The Free space sheet with a measured build folder (example sizes), two parts picked, then while a build runs
        let measured = BuildFolderSurvey(folder: "/Volumes/Games/Hades/\(titleID)_build",
                                         sizes: [.extracted: 9_800_000_000, .shaders: 5_850_000_000, .oldShaders: 4_400_000_000, .xcode: 2_100_000_000, .caches: 610_000_000], kept: 48_000_000,
                                         oldShaders: [OldShaderVersion(name: "b-157e1b96c8da", bytes: 2_100_000_000), OldShaderVersion(name: "b-a78f966a7b38", bytes: 2_300_000_000)])
        for (name, running) in [("free-space", false), ("free-space-running", true)] {
            model.running = running
            let sheet = NSHostingView(rootView: FreeSpaceView(m: model, game: library.games[0], survey: measured, chosen: [.extracted, .oldShaders])
                .environmentObject(PadFocus()))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 690), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = sheet
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let rep = try XCTUnwrap(sheet.bitmapImageRepForCachingDisplay(in: sheet.bounds))
            sheet.cacheDisplay(in: sheet.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
            window.orderOut(nil)
        }
        model.running = false
        if let json = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_SETTINGS"] {   // a launcher.json from dm/games/settings.py
            let first = library.games[0]
            let dm = URL(fileURLWithPath: first.appPath).appendingPathComponent("Contents/Resources/dm")
            try FileManager.default.createDirectory(at: dm, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: json), to: dm.appendingPathComponent("launcher.json"))
            if let fps = LaunchSetting.read(app: first.appPath)?.first(where: { $0.env == "DM_FPS_TARGET" }) { SavedChoices(app: first.appPath, titleID: first.titleID).set(fps, "60") }
            let host = NSHostingView(rootView: LaunchOptionsView(m: model, library: library, gameID: first.id).environmentObject(PadFocus()))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("launch-options.png"))
            window.orderOut(nil)
            // The same sheet with a controller's focus on the console mode row
            let focus = PadFocus()
            let focused = NSHostingView(rootView: LaunchOptionsView(m: model, library: library, gameID: first.id).environmentObject(focus))
            window.contentView = focused
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            focus.scope = "launch"
            focus.show(default: "opt.DM_OPMODE")
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let focusRep = try XCTUnwrap(focused.bitmapImageRepForCachingDisplay(in: focused.bounds))
            focused.cacheDisplay(in: focused.bounds, to: focusRep)
            try XCTUnwrap(focusRep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("launch-options-focus.png"))
            window.orderOut(nil)
        }
        do {   // the Controls sheet with a few changes, kept in a suite of its own
            let suite = "nxnative-visual-qa-controls"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            defer { defaults.removePersistentDomain(forName: suite) }
            let layout = ControlLayout(defaults: defaults)
            if let up = ControlLayout.functions.first(where: { $0.id == "RUp" }) { layout.assign(up, key: 34) }
            layout.setSends("A", "B"); layout.setSends("B", "A")
            let host = NSHostingView(rootView: ControlsView(m: model, layout: layout).environmentObject(PadFocus()))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("controls.png"))
            window.orderOut(nil)
        }
        let crowded = GameLibrary(file: temporary.appendingPathComponent("crowded.json"))   // more games than the row shows: its pager chevrons
        for (index, name) in ["Hades", "Metroid Dread", "Bayonetta 3", "Pikmin 4", "Splatoon 3", "Kirby and the Forgotten Land", "Xenoblade Chronicles 3", "Fire Emblem Engage"].enumerated() {
            model.slots[0].paths = ["/preview/\(name) [01000000000\(String(format: "%02X", index))000].nsp"]
            _ = crowded.rememberInputs(model)
        }
        model.slots[0].paths = []
        let view = ContentView(model: model, library: crowded, performStartupChecks: false)
        let crowdedHost = NSHostingView(rootView: view)
        let crowdedWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        crowdedWindow.contentView = crowdedHost
        crowdedWindow.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let crowdedRep = try XCTUnwrap(crowdedHost.bitmapImageRepForCachingDisplay(in: crowdedHost.bounds))
        crowdedHost.cacheDisplay(in: crowdedHost.bounds, to: crowdedRep)
        try XCTUnwrap(crowdedRep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("library-crowded.png"))
        func scrollViews(_ view: NSView) -> [NSScrollView] { ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews) }
        if let row = scrollViews(crowdedHost).first(where: { $0.documentView.map { $0.frame.width > $0.frame.height * 3 } ?? false }) {
            row.contentView.scroll(to: NSPoint(x: 600, y: row.contentView.bounds.origin.y))   // scrolled: the left chevron too
            row.reflectScrolledClipView(row.contentView)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let scrolledRep = try XCTUnwrap(crowdedHost.bitmapImageRepForCachingDisplay(in: crowdedHost.bounds))
            crowdedHost.cacheDisplay(in: crowdedHost.bounds, to: scrolledRep)
            try XCTUnwrap(scrolledRep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("library-crowded-scrolled.png"))
        }
        crowdedWindow.orderOut(nil)
        let bars = NSHostingView(rootView: VStack(spacing: 18) {   // a step with a percentage, and one without
            LauncherProgressBar(value: 0.4).frame(width: 480)
            LauncherProgressBar(value: nil).frame(width: 480)
            LauncherProgressBar(value: nil, height: 6).frame(width: 180)
        }.padding(30).background(LauncherPalette.background))
        bars.frame = NSRect(x: 0, y: 0, width: 540, height: 130)
        let barsWindow = NSWindow(contentRect: bars.frame, styleMask: [.titled], backing: .buffered, defer: false)
        barsWindow.contentView = bars
        barsWindow.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let barsRep = try XCTUnwrap(bars.bitmapImageRepForCachingDisplay(in: bars.bounds))
        bars.cacheDisplay(in: bars.bounds, to: barsRep)
        try XCTUnwrap(barsRep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("progress-bars.png"))
        barsWindow.orderOut(nil)
        model.running = true
        model.stages = [Stage(id: 1, name: "Extract game files", state: .running, percent: 40)]
        try capture("building", activeID: library.games[1].id)
        model.running = false

        // ---- Controller layouts (#70): the Controls sheet scrolled to the layout by the controller's focus, Auto with a
        // stand-in Xbox controller, then By label with none connected (a suite of its own; no real controller is read) ----
        do {
            let suite = "nxnative-visual-qa-control-presets"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            defer { defaults.removePersistentDomain(forName: suite) }
            for (name, mode, category) in [("controls-layout-auto", PadMode.auto, "Xbox One" as String?), ("controls-layout-bylabel", .byLabel, nil)] {
                let layout = ControlLayout(defaults: defaults)
                layout.controllerCategory = { category }
                layout.setPadMode(mode)
                let focus = PadFocus()
                let host = NSHostingView(rootView: ControlsView(m: model, layout: layout).environmentObject(focus))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = host
                window.orderFront(nil)
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                focus.scope = "controls"
                focus.show(default: "pad.mode")
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
                window.orderOut(nil)
            }
        }
        // ---- Copy diagnostics (#69): Settings with its row, and the button's Copied confirmation (nothing is copied) ----
        do {
            try capture("settings-diagnostics", height: 1500, page: .settings)
            let buttons = NSHostingView(rootView: HStack(spacing: 14) {
                DiagnosticsButton(m: model, width: BuilderView.settingsButtonWidth)
                DiagnosticsButton(m: model, width: BuilderView.settingsButtonWidth, showCopied: true)
            }.padding(24).background(LauncherPalette.background).environmentObject(PadFocus()))
            buttons.frame = NSRect(x: 0, y: 0, width: 420, height: 90)
            let window = NSWindow(contentRect: buttons.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = buttons
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let rep = try XCTUnwrap(buttons.bitmapImageRepForCachingDisplay(in: buttons.bounds))
            buttons.cacheDisplay(in: buttons.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("diagnostics-copied.png"))
            window.orderOut(nil)
        }
        // ---- Saves (#66): the sheet with a stand-in devicectl and a temporary Mac folder, then its question, reached by the controller ----
        do {
            let game = library.games[0]
            let installed = temporary.appendingPathComponent("DmIOS.app")
            try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.hades"], format: .xml, options: 0)
                .write(to: installed.appendingPathComponent("Info.plist"))
            library.recordCompletedIOS(ipa: "", archive: "", app: installed.path, device: "00008150-AAAA", for: game.id)
            let support = temporary.appendingPathComponent("Application Support")
            let save = SaveTransfer.legacyMacSave(titleID: game.titleID, support: support).appendingPathComponent("data.bin")
            try FileManager.default.createDirectory(at: save.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("mac".utf8).write(to: save)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3 * 86_400)], ofItemAtPath: save.path)
            let device = DeviceControl { args in   // a device whose save is from an hour ago
                guard let i = args.firstIndex(of: "--json-output") else { return (false, "ERROR: not in the visual QA") }
                if args.starts(with: ["device", "info", "apps"]) {
                    try? JSONSerialization.data(withJSONObject: ["result": ["apps": [["bundleIdentifier": "com.example.hades", "name": game.name]]]]).write(to: URL(fileURLWithPath: args[i + 1]))
                    return (true, "")
                }
                let files = args.contains("--recurse") ? [["name": "data.bin", "fileType": "file", "modificationDate": ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -3600))]] : []
                try? JSONSerialization.data(withJSONObject: ["result": ["files": files]]).write(to: URL(fileURLWithPath: args[i + 1]))
                return (true, "")
            }
            let focus = PadFocus()
            let host = NSHostingView(rootView: SavesView(m: model, library: library, gameID: game.id, devicectl: device, support: support, listDevices: {
                [AppleDevice(id: "00008150-AAAA", name: "Zijad\u{2019}s iPhone", model: "iPhone 17", os: "27.0", reachable: true),
                 AppleDevice(id: "00008150-BBBB", name: "Zijad\u{2019}s iPad", model: "iPad Pro", os: "27.0", reachable: true)]
            }).environmentObject(focus))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            func shot(_ name: String) throws {
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
            }
            try shot("saves")
            focus.scope = "saves"
            focus.show(default: "saves.toDevice")
            focus.activate()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            try shot("saves-confirm")
            window.orderOut(nil)
        }
    }

    /// Issue #52: the failure note names the last real line, not just the exit code.
    func testLastMeaningfulLineSkipsProgressEventsAndBlankLines() {
        let log = """
        [1/7] extract
        {"event":"progress","frac":0.4}

        RuntimeError: no prod.keys in the game folder

        """
        XCTAssertEqual(BuildModel.lastMeaningfulLine(log), "RuntimeError: no prod.keys in the game folder")
        XCTAssertNil(BuildModel.lastMeaningfulLine("\n\n"))
        XCTAssertNil(BuildModel.lastMeaningfulLine("{\"event\":\"stage_end\"}\n"))
    }

    /// Issue #58: a folder holding several games is staged down to the picked one, and its update
    /// and add-on content come along — classified exactly as build_ipa_from_nsp.py:445 does.
    func testSiblingsOfThePickedGameAreClassifiedAsTheScriptDoes() {
        let base = UInt64(0x010015100B514000)
        let app = base & ~UInt64(0xFFF)
        func owner(_ tid: UInt64) -> UInt64 {
            let low = tid & 0xFFF
            return low == 0 ? tid : (low == 0x800 ? tid & ~UInt64(0xFFF) : (tid & ~UInt64(0xFFF)) - 0x1000)
        }
        XCTAssertEqual(owner(base), app, "the base game")
        XCTAssertEqual(owner(base + 0x800), app, "its update")
        XCTAssertEqual(owner(base + 0x1001), app, "add-on content 1")
        XCTAssertNotEqual(owner(UInt64(0x01007EF00011E000)), app, "another game")
        XCTAssertNotEqual(owner(UInt64(0x01007EF00011E800)), app, "another game's update")
    }

    func testTitleIDReadsTheBracketedFormTheFilesUse() {
        XCTAssertEqual(BuildModel.titleID("Mario Wonder [010015100B514000][v0].nsp"), 0x010015100B514000)
        XCTAssertEqual(BuildModel.titleID("/ROMs/TotK [01007EF00011E000].xci"), 0x01007EF00011E000)
        XCTAssertNil(BuildModel.titleID("no title id here.nsp"))
    }

    /// Issue #53: the interpreter floor is the script's own, so Apple's 3.9 is never picked.
    func testThePythonFloorIsTheScriptsOwnThreeTwelve() {
        XCTAssertEqual(BuildModel.minPython.0, 3)
        XCTAssertEqual(BuildModel.minPython.1, 12,
                       "build_ipa_from_nsp.py:1911 refuses anything below 3.12; a lower floor let the "
                       + "app pick /usr/bin/python3 and the build died in the script")
        let (path, _) = BuildModel.findPython()
        XCTAssertFalse(path.isEmpty, "a Mac with any usable interpreter must yield one")
        if let v = BuildModel.pythonVersion(path) {
            let floor = BuildModel.minPython
            XCTAssertTrue(v.0 > floor.0 || (v.0 == floor.0 && v.1 >= floor.1),
                          "picked \(path) at \(v.0).\(v.1), below the \(floor.0).\(floor.1) floor")
        }
    }

    /// A uv-managed Python sits outside every location the app probed, and a GUI launch's PATH
    /// hides ~/.local/bin: uv had a working 3.12 with the packages and the panel still said
    /// "No Python 3.12 or newer found".
    func testUvManagedPythonsAreCandidates() throws {
        let oldShim = BuildModel.uvShimDir, oldRoot = BuildModel.uvPythonRoot
        defer { BuildModel.uvShimDir = oldShim; BuildModel.uvPythonRoot = oldRoot }
        let shim = temporary.appendingPathComponent("local/bin")
        let root = temporary.appendingPathComponent("uv/python")
        let store = root.appendingPathComponent("cpython-3.12.13-macos-aarch64-none/bin")
        for dir in [shim, store] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // uv links python3 / python3.12 shims in ~/.local/bin; the store holds the real binary.
        for dir in [shim, store] {
            for name in ["python3", "python3.12"] {
                try Data("#!/bin/sh\n".utf8).write(to: dir.appendingPathComponent(name))
            }
        }
        BuildModel.uvShimDir = shim.path
        BuildModel.uvPythonRoot = root.path
        let cands = BuildModel.pythonCandidates()
        XCTAssertTrue(cands.contains(shim.appendingPathComponent("python3").path),
                      "the uv shim must be probed: a GUI launch's PATH does not contain ~/.local/bin")
        XCTAssertTrue(cands.contains(shim.appendingPathComponent("python3.12").path))
        XCTAssertTrue(cands.contains(store.appendingPathComponent("python3.12").path),
                      "uv's store holds the interpreter itself, not only the shim")
    }

    /// The panel hands makeVenv() the venv path it hopes to create when findPython() found no
    /// interpreter. That cannot be a base: `-m venv` on it could not even start, so the Python
    /// row stayed red however often 安装 was pressed.
    func testVenvBaseIsNeverTheVenvItHasToCreate() throws {
        let oldShim = BuildModel.uvShimDir, oldRoot = BuildModel.uvPythonRoot, oldVenv = BuildModel.venvDir
        defer {
            BuildModel.uvShimDir = oldShim
            BuildModel.uvPythonRoot = oldRoot
            BuildModel.venvDir = oldVenv
        }
        let shim = temporary.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: shim, withIntermediateDirectories: true)
        // A stand-in interpreter: only its version and its exit status are asked for here.
        let interp = shim.appendingPathComponent("python3.12")
        try Data("#!/bin/sh\n[ \"$1\" = -c ] && echo 3.12\nexit 0\n".utf8).write(to: interp)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: interp.path)
        BuildModel.uvShimDir = shim.path
        BuildModel.uvPythonRoot = temporary.appendingPathComponent("no-uv").path
        BuildModel.venvDir = temporary.appendingPathComponent("no-venv").path

        let wanted = BuildModel.venvPython()      // findPython()'s last resort, and what the panel passes
        let base = try XCTUnwrap(BuildModel.venvBase(preferred: wanted), "a usable interpreter must be found")
        XCTAssertNotEqual(base, wanted, "the venv cannot be the base it is created from")
        let v = try XCTUnwrap(BuildModel.pythonVersion(base))
        XCTAssertTrue(v.0 > BuildModel.minPython.0 || (v.0 == BuildModel.minPython.0 && v.1 >= BuildModel.minPython.1))
        XCTAssertEqual(BuildModel.venvBase(preferred: interp.path), interp.path,
                       "an interpreter that does run at the required version is kept as given")
    }

    /// Issue #73: the extraction writes RomFS.img now, not a RomFS folder. The archive step looked
    /// only for the folder, so every build ended with "archive skipped" after a successful build.
    /// This drives BuildModel.extractedVersion — the function the archive step calls — rather than
    /// restating its predicate, so changing the production code changes what this checks.
    func testTheExtractionIsFoundAsEitherAFolderOrAnImage() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("nspb-extract-" + UUID().uuidString)
        let extract = work.appendingPathComponent("extract")
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: extract.appendingPathComponent("v0"), withIntermediateDirectories: true)
        XCTAssertNil(BuildModel.extractedVersion(in: extract.path), "an empty version folder holds neither shape")
        // what the rewriter writes today
        try Data([0x44, 0x4d, 0x52, 0x4f, 0x4d, 0x46, 0x53, 0x31])
            .write(to: extract.appendingPathComponent("v0").appendingPathComponent("RomFS.img"))
        XCTAssertEqual(BuildModel.extractedVersion(in: extract.path), "v0", "RomFS.img alone must count")
        // and the older shape still works, with the highest version winning
        try FileManager.default.createDirectory(at: extract.appendingPathComponent("v1").appendingPathComponent("RomFS"),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(BuildModel.extractedVersion(in: extract.path), "v1")
    }
}