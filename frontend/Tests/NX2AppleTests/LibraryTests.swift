import XCTest
import SwiftUI
import Combine
@testable import NX2Apple
@testable import NXCore
import NXModel
@testable import NXLauncher

@MainActor final class LibraryTests: IsolatedDefaultsTestCase {
    private var temporary: URL!
    private let titleID = "0100535012974000"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    /// Every test app carries this bundle ID, so a saved choice goes to a preferences domain of this run and never to a real game's,
    /// a plist in the test's folder (`TestPreferences`).
    private var bundleID: String { TestPreferences.domain(in: temporary, "library") }

    override func tearDownWithError() throws {
        CFPreferencesAppSynchronize(bundleID as CFString)
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

    /// The library opens on the player's own games: Owned is the default, also for the "all" an earlier build may have stored.
    func testLibraryFilterDefaultsToOwned() throws {
        let defaults = TestDefaults.make("nxnative-tests-filter")
        XCTAssertEqual(LibraryFilter.load(defaults), .owned)
        defaults.set("all", forKey: "libraryFilter")
        XCTAssertEqual(LibraryFilter.load(defaults), .owned)
        LibraryFilter.built.save(defaults)
        XCTAssertEqual(LibraryFilter.load(defaults), .built)
    }

    func testLibraryTitleOrderUsesNumbersAndKeepsSelection() {
        let ten = LibraryGame(titleID: "C", name: "Quest 10")
        let two = LibraryGame(titleID: "B", name: "Quest 2")
        let anotherTwo = LibraryGame(titleID: "A", name: "Quest 2")
        let games = [ten, two, anotherTwo]
        XCTAssertEqual(LibraryFilter.owned.visibleGames(games).map(\.id), [anotherTwo.id, two.id, ten.id])
        XCTAssertEqual(LibraryFilter.owned.visibleGames(games, matching: "qUeSt 2").map(\.id), [anotherTwo.id, two.id])
        XCTAssertTrue(LibraryFilter.built.visibleGames(games).isEmpty)
        XCTAssertEqual(LibraryFilter.owned.reconcile(games: games, selectedID: nil, focused: nil).selectedID, anotherTwo.id)
        XCTAssertEqual(LibraryFilter.owned.reconcile(games: games, selectedID: ten.id, focused: nil).selectedID, ten.id)
    }

    func testCommandFFromBuildsOpensLibrarySearch() throws {
        let stores = LauncherStores(defaults: testDefaults)
        let library = GameLibrary(file: temporary.appendingPathComponent("library.json"))
        let view = LauncherView(stores: stores, library: library, initialPage: .builds, performStartupChecks: false)
        let window = OffscreenWindow(size: NSSize(width: 1100, height: 800))
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let find = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                  timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                  characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        XCTAssertTrue(window.performKeyEquivalent(with: find))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        func searchField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.placeholderString == stores.localizer.t("library.search") { return field }
            return view.subviews.lazy.compactMap { searchField(in: $0) }.first
        }
        XCTAssertNotNil(searchField(in: host), "the search field is now in the window")
    }

    func testMinimumWidthToolbarKeepsControlsOnOneLine() throws {
        let stores = LauncherStores(defaults: testDefaults)
        stores.build.lang = Lang("fr")
        stores.appUpdates.update = .init(tag: "v9.9.9", url: "", digest: nil)
        let library = GameLibrary(file: temporary.appendingPathComponent("library.json"))
        let pad = PadFocus()
        let view = LauncherView(stores: stores, library: library, performStartupChecks: false, search: "zel", padFocus: pad)
        let window = OffscreenWindow(size: NSSize(width: 1440, height: 680))
        window.contentView = NSHostingView(rootView: view)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        let singleLine = try XCTUnwrap(pad.frames["main"])
        window.setContentSize(NSSize(width: 900, height: 680))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let targets = try XCTUnwrap(pad.frames["main"])
        for id in ["tab.library", "tab.builds", "tab.settings", "top.build"] {
            let frame = try XCTUnwrap(targets.first { $0.id == id }?.frame, id)
            let wide = try XCTUnwrap(singleLine.first { $0.id == id }?.frame, id)
            XCTAssertLessThanOrEqual(frame.height, wide.height + 1, "The top bar should fit a single line: " + id)
        }
        pad.show(default: "tab.library")
        pad.horizontal(1)
        XCTAssertEqual(pad.focused, "tab.builds")
        pad.horizontal(1)
        XCTAssertEqual(pad.focused, "tab.settings")
    }

    /// Built hides the games without a build. The selection moves to a game it shows, and a controller's focus on a hidden card
    /// is dropped, so A cannot start a game that is not on screen.
    func testBuiltFilterKeepsSelectionAndFocusOnShownGames() throws {
        let built = LibraryGame(titleID: titleID, name: "Hades", appPath: try makeApp(titleID).path)
        let unbuilt = LibraryGame(titleID: "0100000000010000", name: "Celeste")
        let games = [unbuilt, built]
        XCTAssertEqual(games.filter(LibraryFilter.owned.includes).map(\.id), [unbuilt.id, built.id])
        XCTAssertEqual(games.filter(LibraryFilter.built.includes).map(\.id), [built.id])

        let hidden = LibraryFilter.built.reconcile(games: games, selectedID: unbuilt.id, focused: "card." + unbuilt.id.uuidString)
        XCTAssertEqual(hidden.selectedID, built.id)
        XCTAssertNil(hidden.focused)

        let shown = LibraryFilter.built.reconcile(games: games, selectedID: built.id, focused: "card." + built.id.uuidString)
        XCTAssertEqual(shown.selectedID, built.id)
        XCTAssertEqual(shown.focused, "card." + built.id.uuidString)

        let elsewhere = LibraryFilter.built.reconcile(games: games, selectedID: unbuilt.id, focused: "top.build")
        XCTAssertEqual(elsewhere.focused, "top.build", "a focus outside the row stays")

        let none = LibraryFilter.built.reconcile(games: [unbuilt], selectedID: unbuilt.id, focused: nil)
        XCTAssertNil(none.selectedID)
        XCTAssertEqual(LibraryFilter.owned.reconcile(games: games, selectedID: nil, focused: nil).selectedID, unbuilt.id)
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

    /// A game without a Mac build has an empty path. That path is not read as the current folder, even when the current folder is a game.
    func testAGameWithoutAnAppIsNotReady() throws {
        let app = try makeApp(titleID)
        let previous = FileManager.default.currentDirectoryPath
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(app.path))
        defer { FileManager.default.changeCurrentDirectoryPath(previous) }
        XCTAssertFalse(LibraryGame(titleID: titleID, name: "Hades").isReady)
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
        library.setArtwork(GameArtwork(hero: ArtworkChoice(source: .imported(image.lastPathComponent))), for: id)
        let restored = GameLibrary(file: file)
        XCTAssertEqual(restored.artworkDirectory, temporary.appendingPathComponent("state/artwork", isDirectory: true),
                       "a library kept elsewhere never touches the player's artwork folder")
        XCTAssertEqual(restored.games.count, 1)
        XCTAssertEqual(restored.games.first?.artwork.hero?.source, .imported("my-picture.png"))
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

    func testBuildOfPathKeyedEntryReplacesTheEntryOfTheSameGame() throws {
        let app = try makeApp(titleID)
        let file = temporary.appendingPathComponent("library.json")
        var existing = LibraryGame(titleID: titleID, name: "Hades")
        existing.appPath = app.path
        existing.artworkPath = "/some/external/artwork.jpg"
        // A base package whose name carries no title ID is keyed by its path until the build finishes.
        var pending = LibraryGame(titleID: "/games/Hades.nsp", name: "Hades")
        pending.inputs = ["base": ["/games/Hades.nsp"]]
        try JSONEncoder().encode([existing, pending]).write(to: file)
        let library = GameLibrary(file: file)
        library.recordCompletedApp(path: app.path, for: pending.id)
        XCTAssertEqual(library.games.count, 1)
        XCTAssertEqual(library.games[0].titleID, titleID)
        XCTAssertEqual(library.games[0].artworkPath, "/some/external/artwork.jpg")
        XCTAssertEqual(library.games[0].inputs["base"], ["/games/Hades.nsp"])
        XCTAssertTrue(library.games[0].isReady)
        XCTAssertEqual(library.selectedID, library.games[0].id)
    }

    func testBuildOfPathKeyedEntryTakesTheOldEntrysImagesAlong() throws {
        let app = try makeApp(titleID)
        let file = temporary.appendingPathComponent("library.json")
        var existing = LibraryGame(titleID: titleID, name: "Hades")
        existing.appPath = app.path
        existing.artwork.hero = ArtworkChoice(source: .imported("mine.jpg"), focus: ArtworkFocus(x: 0.2, y: 0.5))
        var pending = LibraryGame(titleID: "/games/Hades.nsp", name: "Hades")
        pending.inputs = ["base": ["/games/Hades.nsp"]]
        try JSONEncoder().encode([existing, pending]).write(to: file)
        let library = GameLibrary(file: file)
        let from = ArtworkStore.customDirectory(for: existing.id, in: library.artworkDirectory)
        try FileManager.default.createDirectory(at: from, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: from.appendingPathComponent("mine.jpg"))
        library.recordCompletedApp(path: app.path, for: pending.id)
        XCTAssertEqual(library.games[0].artwork.hero, existing.artwork.hero)
        let to = ArtworkStore.customDirectory(for: pending.id, in: library.artworkDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: to.appendingPathComponent("mine.jpg").path), "the image goes to the entry that stays")
        XCTAssertFalse(FileManager.default.fileExists(atPath: from.path))
    }

    func testRebuildingSameGameKeepsOneEntryAndCustomArtwork() throws {
        let app = try makeApp(titleID)
        let library = GameLibrary(file: temporary.appendingPathComponent("library.json"))
        let first = try library.addApp(app)
        library.setArtwork(GameArtwork(hero: ArtworkChoice(source: .imported("artwork.jpg"))), for: first)
        XCTAssertEqual(try library.addApp(app), first)
        XCTAssertEqual(library.games.count, 1)
        XCTAssertEqual(library.games[0].artwork.hero?.source, .imported("artwork.jpg"))
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
        ProcessGroups.inOwnGroup(p, python: "/usr/bin/python3")
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
        ProcessGroups.endGroup(p.processIdentifier)
        p.waitUntilExit()
        tries = 0
        while members() > 0 && tries < 30 { usleep(100_000); tries += 1 }
        XCTAssertEqual(members(), 0)
        // Ended by the SIGTERM, well before the SIGKILL 5 s later. The shell may die of it or, when its children went
        // first, return from its wait and exit 0: either way the whole group is gone.
        XCTAssertLessThan(Date().timeIntervalSince(stopped), 3)
    }

    /// Stop ends the build and leaves no stage behind (a spinner and a percentage of a build that no longer runs).
    @MainActor func testStoppedBuildResetsItsProgress() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("System Python is required for the process fixture") }
        let modelStores = LauncherStores(defaults: testDefaults); let model = modelStores.build
        modelStores.repo.path = temporary.path
        model.target = "mac-app"
        model.outDir = temporary.path
        MainActor.assumeIsolated { modelStores.dependencies.pythonPath = "/usr/bin/python3" }
        MainActor.assumeIsolated { modelStores.dependencies.dotnetPath = "/usr/bin/true" }
        MainActor.assumeIsolated { modelStores.dependencies.checked = true }
        MainActor.assumeIsolated { modelStores.dependencies.deps = [Dep(id: "test", name: "test", hint: "", present: true, installCmd: [])] }
        let marker = temporary.appendingPathComponent("dm/tools/nx_extract/Program.cs")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: marker)
        try RepoLayout.requiredTools.filter { $0 != RepoLayout.buildScript }.forEach { tool in   // the other files the build checks for (#87)
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
        wait(for: [running], timeout: 30)   // a CI runner starts the script slowly
        let stopped = expectation(description: "The build ends")
        let ended = model.$running.dropFirst().filter { !$0 }.prefix(1).sink { _ in stopped.fulfill() }
        model.stop()
        wait(for: [stopped], timeout: 30)
        withExtendedLifetime((started, ended)) {}
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(model.stages.isEmpty)
        XCTAssertFalse(model.done)
        XCTAssertEqual(model.doneNote, model.t("msg.stopped"))
    }

    /// Xcode 27.2 may give a device only in `properties`, without `reality`. A missing reality is physical, a simulated one,
    /// another platform and an unpaired device are left out (#488).
    func testDevicesAreReadFromTheOldAndTheNewDevicectlLayout() {
        func parse(_ device: String) -> [AppleDevice] {
            DeviceTools.parseDevices(Data("{\"result\": {\"devices\": [\(device)]}}".utf8))
        }
        let old = parse("""
        {"hardwareProperties": {"reality": "physical", "platform": "iOS", "udid": "OLD-1", "marketingName": "iPhone 17"},
         "deviceProperties": {"name": "Old", "osVersionNumber": "26.1"}, "connectionProperties": {"pairingState": "paired", "transportType": "wired"}}
        """)
        XCTAssertEqual(old, [AppleDevice(id: "OLD-1", name: "Old", model: "iPhone 17", os: "26.1", reachable: true, transport: "wired")])
        let new = parse("""
        {"properties": {"hardware": {"platform": "iOS", "udid": "NEW-1", "marketingName": "iPad mini"},
         "software": {"osVersionNumber": {"stringValue": "26.2.1", "components": [26, 2, 1]}}, "state": {"name": "Pad"},
         "connection": {"pairingState": "paired", "transportType": "localNetwork"}}}
        """)
        XCTAssertEqual(new, [AppleDevice(id: "NEW-1", name: "Pad", model: "iPad mini", os: "26.2.1", reachable: true, transport: "localNetwork")])
        XCTAssertEqual(parse("""
        {"properties": {"hardware": {"reality": "simulated", "platform": "iOS", "udid": "SIM-1"}, "connection": {"pairingState": "paired"}}}
        """), [])
        XCTAssertEqual(parse("""
        {"properties": {"hardware": {"platform": "watchOS", "udid": "WATCH-1"}, "connection": {"pairingState": "paired"}}}
        """), [])
        XCTAssertEqual(parse("""
        {"properties": {"hardware": {"platform": "iOS", "udid": "UN-1"}, "connection": {"pairingState": "unpaired"}}}
        """), [])
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

    /// An action on the installed app names what is missing instead of doing nothing, and a failed reinstall is a note on
    /// the installed app, not a failed build (the app is still on the device).
    @MainActor func testReinstallAndSaveReportAMissingSignedApp() throws {
        let modelStores = LauncherStores(xcrun: "/usr/bin/true", defaults: testDefaults); let model = modelStores.build
        model.installedOn = "00008150-AAAA"
        model.installedAppPath = temporary.path + "/gone/DmShell.app"
        var reported = expectation(description: "Reinstall says what is missing")
        model.reinstallOnDevice { reported.fulfill() }
        wait(for: [reported], timeout: 10)
        XCTAssertEqual(model.doneNote, String(format: model.t("dev.reinstallMissing"), model.shortPath(model.installedAppPath)))
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
        let modelStores = LauncherStores(defaults: testDefaults); let model = modelStores.build
        model.installedAppPath = app.path
        XCTAssertEqual(model.defaultIPAName(), "Zelda_ Echoes_of Wisdom.ipa")
    }

    /// The two commands the actions build: a plain devicectl install of the cached app, and ditto's Payload archive.
    func testTheReinstallAndIPARecipes() {
        XCTAssertEqual(BuildCommands.reinstallCommand(xcrun: "/x", device: "D", app: "/a/DmIOS.app"),
                       ["/x", "devicectl", "device", "install", "app", "--device", "D", "/a/DmIOS.app"])
        XCTAssertEqual(BuildCommands.ipaCommand(payload: "/t/Payload", ipa: "/o/Game.ipa"),
                       ["/usr/bin/ditto", "-c", "-k", "--norsrc", "--keepParent", "/t/Payload", "/o/Game.ipa"])
    }

    /// An app from before the shared app has no project to sign again: the note says to build the game again. Without a team
    /// the note asks for one first.
    @MainActor func testResignOfAnOlderAppAsksForANewBuild() throws {
        let modelStores = LauncherStores(defaults: testDefaults); let model = modelStores.build
        let older = temporary.appendingPathComponent("0100_build/xcode-derived-data/Build/Products/Release-iphoneos/DmIOS.app").path
        modelStores.deviceStore.signingTeam = "TEAM123456"
        var reported = expectation(description: "Older app reported")
        model.resignOnDevice(app: older, device: "00008150-AAAA") { reported.fulfill() }
        wait(for: [reported], timeout: 10)
        XCTAssertEqual(model.doneNote, model.t("dev.resignOlder"))
        XCTAssertFalse(model.running)
        modelStores.deviceStore.signingTeam = ""
        reported = expectation(description: "Missing team reported")
        model.resignOnDevice(app: older, device: "00008150-AAAA") { reported.fulfill() }
        wait(for: [reported], timeout: 10)
        XCTAssertEqual(model.doneNote, model.t("dev.resignNoTeam"))
    }

    /// The shared app's project is gone (the shell folder was removed): the note names it.
    @MainActor func testResignReportsAMissingSharedProject() throws {
        let modelStores = LauncherStores(defaults: testDefaults); let model = modelStores.build
        modelStores.deviceStore.signingTeam = "TEAM123456"
        let shared = temporary.appendingPathComponent("shell/derived-data/Build/Products/Release-iphoneos/DmShell.app")
        let reported = expectation(description: "Missing project reported")
        model.resignOnDevice(app: shared.path, device: "00008150-AAAA") { reported.fulfill() }
        wait(for: [reported], timeout: 10)
        let project = try XCTUnwrap(ShellInstall.paths(ofApp: shared.path)).project
        XCTAssertEqual(model.doneNote, String(format: model.t("dev.resignNoProject"), model.shortPath(project)))
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

    /// The base sits in "<game>/nsz本体/", the update in "<game>/升级档v1.1.3/" and the DLC in "<game>/DLC/" (sibling
    /// subfolders under the game's folder, with no package directly in "<game>/"): the climb must still reach "<game>/"
    /// and a rescan must lift a previously recorded subfolder sourceFolder to it.
    func testAScanFindsTheUpdateAndDLCInSiblingSubfolders() throws {
        let fm = FileManager.default
        let game = temporary.appendingPathComponent("小丑牌")
        let baseDir = game.appendingPathComponent("nsz本体")
        let updDir = game.appendingPathComponent("升级档v1.1.3")
        let dlcDir = game.appendingPathComponent("DLC")
        for d in [baseDir, updDir, dlcDir] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        let baseNSZ = baseDir.appendingPathComponent("小丑牌[0100CD801CE5E000][US][v0].nsz")
        let updNSZ = updDir.appendingPathComponent("小丑牌[0100CD801CE5E800][US][v393216].nsz")
        let dlcNSZ = dlcDir.appendingPathComponent("小丑牌[0100CD801CE5F001][v65536].nsz")
        for f in [baseNSZ, updNSZ, dlcNSZ] { try Data([0]).write(to: f) }

        let games = GameLibrary.sourceGames(in: temporary, repo: "")
        let balatro = try XCTUnwrap(games.first { $0.titleID == "0100CD801CE5E000" })
        XCTAssertEqual(Self.canon(balatro.sourceFolder), Self.canon(game.path), "climbs out of nsz本体 when a sibling subfolder holds the update")
        XCTAssertEqual(balatro.inputs["base"]?.map(Self.canon), [Self.canon(baseNSZ.path)])
        XCTAssertEqual(balatro.inputs["update"]?.map(Self.canon), [Self.canon(updNSZ.path)])
        XCTAssertEqual(balatro.inputs["dlc"]?.map(Self.canon), [Self.canon(dlcNSZ.path)])

        // An earlier scan recorded the base subfolder as sourceFolder and missed the sibling update: discover() repairs both.
        let state = temporary.appendingPathComponent("library.json")
        var stale = LibraryGame(titleID: "0100CD801CE5E000", name: "Balatro")
        stale.inputs = ["base": [baseNSZ.path], "update": [], "dlc": [], "keys": []]
        stale.sourceFolder = baseDir.path
        try JSONEncoder().encode([stale]).write(to: state)
        let library = GameLibrary(file: state)
        library.applicationFolders = []
        let finished = expectation(description: "Rescan repairs sibling update and sourceFolder")
        let token = library.$scanning.dropFirst().filter { !$0 }.sink { _ in finished.fulfill() }
        library.setFolder(temporary)
        wait(for: [finished], timeout: 3)
        withExtendedLifetime(token) {}
        let repaired = try XCTUnwrap(library.games.first { $0.titleID == "0100CD801CE5E000" })
        XCTAssertEqual(Self.canon(repaired.sourceFolder), Self.canon(game.path))
        XCTAssertEqual(repaired.inputs["update"]?.map(Self.canon), [Self.canon(updNSZ.path)])
        XCTAssertEqual(repaired.inputs["dlc"]?.map(Self.canon), [Self.canon(dlcNSZ.path)])
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

    func testAScanRetainsCollectionEnumerationWhenRootHoldsANUPBesideAGameFolder() throws {
        let fm = FileManager.default
        let collection = temporary.appendingPathComponent("Collection")
        let nupURL = collection.appendingPathComponent("GameA.nup")
        let dumpB = collection.appendingPathComponent("DumpB")
        try fm.createDirectory(at: dumpB.appendingPathComponent("base/exefs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dumpB.appendingPathComponent("base/romfs"), withIntermediateDirectories: true)

        var nup = [UInt8](repeating: 0, count: 0x80 + 0x30 + 0x40)
        func put(_ o: Int, _ v: UInt64, _ n: Int) { for i in 0..<n { nup[o + i] = UInt8(v >> (8 * UInt64(i)) & 0xFF) } }
        nup.replaceSubrange(0..<4, with: [0x4E, 0x55, 0x50, 0x01])
        put(0x08, 0x80, 8); put(0x40, UInt64(nup.count), 8); put(0x48, 1, 4)
        nup.replaceSubrange(0x80..<0x84, with: [0x54, 0x4F, 0x43, 0x01])
        put(0xB0, 0x040074A01BF12000, 8)
        try Data(nup).write(to: nupURL)
        try GameFolderCaptureTests.npdm(programID: 0x0400A3A01EE4C000).write(to: dumpB.appendingPathComponent("base/exefs/main.npdm"))

        for root in [collection, temporary!] {
            XCTAssertEqual(GameFolder.resolve(root.path), root.path, "failed for \(root.path)")
            XCTAssertFalse(GameFolder.isCandidate(root.path), "failed for \(root.path)")
            let games = GameLibrary.sourceGames(in: root, repo: "")
            XCTAssertEqual(Set(games.map(\.titleID)), ["040074A01BF12000", "0400A3A01EE4C000"], "failed for \(root.path)")
            let gameA = try XCTUnwrap(games.first { $0.titleID == "040074A01BF12000" })
            let gameB = try XCTUnwrap(games.first { $0.titleID == "0400A3A01EE4C000" })
            XCTAssertEqual(Self.canon(gameA.sourceFolder), Self.canon(collection.path))
            XCTAssertEqual(gameA.inputs[GameLibrary.folderInput]?.map(Self.canon), [Self.canon(nupURL.path)])
            XCTAssertEqual(Self.canon(gameB.sourceFolder), Self.canon(dumpB.path))
            XCTAssertEqual(gameB.inputs[GameLibrary.folderInput]?.map(Self.canon), [Self.canon(dumpB.path)])
        }
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

    private func hiddenBuildWindow(stores: LauncherStores, library: GameLibrary) -> NSWindow {
        let view = LauncherView(stores: stores, library: library, initialPage: .builds, performStartupChecks: false)
        let appeared = expectation(description: "Build view appeared")
        let window = OffscreenWindow(size: NSSize(width: 1100, height: 800))
        window.contentView = NSHostingView(rootView: view.onAppear { appeared.fulfill() })
        window.orderFront(nil)
        wait(for: [appeared], timeout: 5)
        window.orderOut(nil) // Registration must work even while the launcher is hidden.
        return window
    }

    func testBuildStartingAtFirstAppearanceKeepsItsLibraryEntry() throws {
        let stores = LauncherStores(defaults: testDefaults)
        let model = stores.build
        model.slots[0].paths = [temporary.appendingPathComponent("Test [\(titleID)].nsp").path]
        model.target = "mac-app"
        model.outDir = temporary.path
        let app = try makeApp(titleID)
        let library = GameLibrary(file: temporary.appendingPathComponent("library.json"))
        let window = hiddenBuildWindow(stores: stores, library: library)
        defer { window.close() }

        // Start before the initial idle notification's deferred work, then finish on the next main-queue turn.
        model.running = true
        let finished = expectation(description: "Completion callbacks ran")
        DispatchQueue.main.async {
            model.macAppPath = app.path
            model.running = false
            model.done = true
            DispatchQueue.main.async { finished.fulfill() }
        }
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(library.games.first?.appPath, app.path)
    }

    @MainActor func testCompletedBuildAppearsAutomaticallyInCollection() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("System Python is required for the process fixture") }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let modelStores = LauncherStores(defaults: testDefaults); let model = modelStores.build
        model.lang = .en   // the script's stage name as English shows it, whatever the Mac's language
        modelStores.repo.path = temporary.path
        model.target = "mac-app"
        model.outDir = temporary.path
        MainActor.assumeIsolated { modelStores.dependencies.pythonPath = "/usr/bin/python3" }
        MainActor.assumeIsolated { modelStores.dependencies.dotnetPath = "/usr/bin/true" }
        MainActor.assumeIsolated { modelStores.dependencies.checked = true }
        MainActor.assumeIsolated { modelStores.dependencies.deps = [Dep(id: "test", name: "test", hint: "", present: true, installCmd: [])] }
        let marker = temporary.appendingPathComponent("dm/tools/nx_extract/Program.cs")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: marker)
        try RepoLayout.requiredTools.filter { $0 != RepoLayout.buildScript }.forEach { tool in   // the other files the build checks for (#87)
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
        let window = hiddenBuildWindow(stores: modelStores, library: library)
        defer { window.close() }
        let completed = expectation(description: "Successful app is added without an import")
        let libraryToken = library.$games.filter { $0.contains(where: \.isReady) }.prefix(1).sink { _ in completed.fulfill() }
        let settled = expectation(description: "Build process finished successfully")
        let buildToken = model.$running.combineLatest(model.$done).first { !$0 && $1 }.sink { _ in settled.fulfill() }
        XCTAssertTrue(model.canBuild)
        model.startBuild()
        // A ready app and the process exit may arrive in either order. The timeout only guards against a hang on CI.
        wait(for: [completed, settled], timeout: 120)
        withExtendedLifetime((libraryToken, buildToken)) {}
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
        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NS Port Builder/library.json")
        let copy = temporary.appendingPathComponent("library.json")
        // The games, without the user's folders: names and title IDs only, and BotW as a finished Mac build (a fixture app)
        let real_ = GameLibrary(file: real)
        let library = GameLibrary(file: copy)
        let botw = "01007EF00011E000", totk = "0100F2C0115B6000"
        let modelStores = LauncherStores(defaults: testDefaults); let model = modelStores.build
        modelStores.repo.path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        model.lang = .en
        MainActor.assumeIsolated { modelStores.dependencies.checked = true }
        MainActor.assumeIsolated { modelStores.dependencies.deps = [Dep(id: "test", name: "Xcode", hint: "", present: true, installCmd: [])] }
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
            let window = OffscreenWindow(size: size)
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
        try shot("library", LauncherView(stores: modelStores, library: library, activeBuildID: totkID, performStartupChecks: false), size: window)
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
        try shot("build", LauncherView(stores: modelStores, library: library, initialPage: .builds, performStartupChecks: false), size: NSSize(width: 1280, height: 940))

        if let upscale = LaunchSetting.read(app: library.games.first { $0.id == botwID }!.appPath)?.first(where: { $0.env == "DM_PRESENT_UPSCALE" }) {
            SavedChoices(app: library.games.first { $0.id == botwID }!.appPath, titleID: "01007EF00011E000").set(upscale, "metalfx")
        }
        try shot("launch-options", LaunchOptionsView(m: model, library: library, gameID: botwID).environmentObject(modelStores.localizer), size: NSSize(width: 600, height: 700), trafficLights: false)   // a sheet: no window controls of its own
    }

    /// Opt-in native rendering for visual QA; it never touches the user's saved library.
    @MainActor func testRenderLauncherForVisualQA() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        let modelStores = LauncherStores(defaults: testDefaults); let model = modelStores.build
        modelStores.repo.path = repo
        model.lang = CaptureLanguage.current(.en)
        model.outDir = temporary.path
        MainActor.assumeIsolated { modelStores.dependencies.checked = true }
        MainActor.assumeIsolated { modelStores.dependencies.deps = [Dep(id: "test", name: "Xcode", hint: "", present: true, installCmd: [])] }
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
            let view = LauncherView(stores: modelStores, library: store, initialPage: page, activeBuildID: activeID, performStartupChecks: false, search: search,
                                   olderTools: older, manageOpen: manageOpen, padRing: padRing)
            let host = NSHostingView(rootView: view)
            let window = OffscreenWindow(size: NSSize(width: width, height: height), styleMask: [.titled, .closable, .resizable])
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
        try capture("library-small-search", width: 900, height: 680, search: "zel")
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
            for f in ["dm/tools/nx_extract/Program.cs", RepoLayout.buildScript] {
                let url = zip.appendingPathComponent(f)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0]).write(to: url)
            }
            let previous = (modelStores.repo.path, modelStores.repo.autoUpdate, modelStores.repo.status, modelStores.repo.autoAdopted, model.doneNote)
            defer { (modelStores.repo.path, modelStores.repo.autoUpdate, modelStores.repo.status, modelStores.repo.autoAdopted, model.doneNote) = previous }
            modelStores.repo.path = zip.path
            modelStores.repo.autoUpdate = false
            try capture("settings-zip-auto-off", page: .settings)
            modelStores.repo.autoUpdate = true
            modelStores.repo.status = String(format: model.t("repo.adoptedAuto"), "zip-copy-2026-10-27")
            modelStores.repo.autoAdopted = true
            try capture("library-adopted")
            modelStores.repo.autoAdopted = false
            modelStores.repo.status = ""
            try capture("settings-zip-old-tools", page: .settings)
            model.startBuild()   // refuses: the copy lacks romfs_image.py
            try capture("build-tools-old", height: 1500, page: .builds)
        }
        do {   // a released copy with an update downloaded and verified: Restart now in Settings and in the activity line
            let previous = (modelStores.appUpdates.installability, modelStores.appUpdates.update, modelStores.appUpdates.staged, modelStores.appUpdates.status)
            defer { (modelStores.appUpdates.installability, modelStores.appUpdates.update, modelStores.appUpdates.staged, modelStores.appUpdates.status) = previous }
            let release = AppUpdate.Release(tag: "v0.4.8", url: "https://example.invalid/NX2Apple-macOS-arm64.zip", digest: nil)
            modelStores.appUpdates.installability = .ok
            modelStores.appUpdates.update = release
            modelStores.appUpdates.status = String(format: model.t("app.found"), release.tag)
            try capture("settings-update-found", page: .settings)
            modelStores.appUpdates.staged = AppUpdate.Staged(release: release, app: temporary.appendingPathComponent("NX2Apple.app"))
            modelStores.appUpdates.status = String(format: model.t("app.ready"), release.tag)
            try capture("settings-update-ready", page: .settings)
            try capture("library-update-ready")
            try capture("library-small-update", width: 900, height: 680)
            try capture("library-small-search-update", width: 900, height: 680, search: "zel")
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
        modelStores.deviceStore.checked = true
        modelStores.deviceStore.devices = [AppleDevice(id: "00008150-AAAA", name: "iPhone", model: "iPhone 17 Pro Max", os: "27.0", reachable: true),
                         AppleDevice(id: "00008110-BBBB", name: "iPad mini", model: "iPad mini", os: "26.2", reachable: false)]
        modelStores.deviceStore.teams = [SigningTeam(id: "TEAM123456", identity: "Apple Development: Jo Doe (ABCDE12345)")]
        let previousDevice = modelStores.deviceStore.installDevice, previousTeam = modelStores.deviceStore.signingTeam
        modelStores.deviceStore.installDevice = "00008150-AAAA"; modelStores.deviceStore.signingTeam = "TEAM123456"
        try capture("build-install", height: 1300, page: .builds)
        // #87: signed in to Xcode, no certificate yet (a free personal team and a paid one), and neither account nor certificate
        modelStores.deviceStore.teams = [SigningTeam(id: "FGHIJ67890", identity: "", name: "Jo Doe", personal: true),
                       SigningTeam(id: "KLMNO11111", identity: "", name: "Studio Ltd")]
        modelStores.deviceStore.signingTeam = "FGHIJ67890"
        try capture("build-install-xcode-team", height: 1300, page: .builds)
        modelStores.deviceStore.teams = []; modelStores.deviceStore.signingTeam = ""
        try capture("build-install-no-team", height: 1300, page: .builds)
        modelStores.deviceStore.teams = [SigningTeam(id: "TEAM123456", identity: "Apple Development: Jo Doe (ABCDE12345)")]
        modelStores.deviceStore.signingTeam = "TEAM123456"
        modelStores.deviceStore.installDevice = previousDevice; modelStores.deviceStore.signingTeam = previousTeam; model.target = previousTarget
        // The Free space sheet with a measured build folder (example sizes), two parts picked, then while a build runs
        let measured = BuildFolderSurvey(folder: "/Volumes/Games/Hades/\(titleID)_build",
                                         sizes: [.extracted: 9_800_000_000, .shaders: 5_850_000_000, .oldShaders: 4_400_000_000, .xcode: 2_100_000_000, .caches: 610_000_000], kept: 48_000_000,
                                         oldShaders: [OldShaderVersion(name: "b-157e1b96c8da", bytes: 2_100_000_000), OldShaderVersion(name: "b-a78f966a7b38", bytes: 2_300_000_000)])
        for (name, running) in [("free-space", false), ("free-space-running", true)] {
            model.running = running
            let sheet = NSHostingView(rootView: FreeSpaceView(m: model, game: library.games[0], survey: measured, chosen: [.extracted, .oldShaders])
                .environmentObject(PadFocus()).environmentObject(modelStores.localizer))
            let window = OffscreenWindow(size: NSSize(width: 560, height: 690))
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
            let host = NSHostingView(rootView: LaunchOptionsView(m: model, library: library, gameID: first.id).environmentObject(PadFocus()).environmentObject(modelStores.localizer))
            let window = OffscreenWindow(size: NSSize(width: 600, height: 700))
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("launch-options.png"))
            window.orderOut(nil)
            // The same sheet with a controller's focus on the console mode row
            let focus = PadFocus()
            let focused = NSHostingView(rootView: LaunchOptionsView(m: model, library: library, gameID: first.id).environmentObject(focus).environmentObject(modelStores.localizer))
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
            let defaults = TestDefaults.make("nxnative-visual-qa-controls")
            let layout = ControlLayout(defaults: defaults)
            if let up = ControlLayout.functions.first(where: { $0.id == "RUp" }) { layout.assign(up, key: 34) }
            layout.setSends("A", "B"); layout.setSends("B", "A")
            let host = NSHostingView(rootView: ControlsView(layout: layout).environmentObject(PadFocus()).environmentObject(modelStores.localizer))
            let window = OffscreenWindow(size: NSSize(width: 600, height: 700))
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
        let view = LauncherView(stores: modelStores, library: crowded, performStartupChecks: false)
        let crowdedHost = NSHostingView(rootView: view)
        let crowdedWindow = OffscreenWindow(size: NSSize(width: 1280, height: 900))
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
        let barsWindow = OffscreenWindow(size: bars.frame.size)
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
            let defaults = TestDefaults.make("nxnative-visual-qa-control-presets")
            for (name, mode, category) in [("controls-layout-auto", PadMode.auto, "Xbox One" as String?), ("controls-layout-bylabel", .byLabel, nil)] {
                let layout = ControlLayout(defaults: defaults)
                layout.controllerCategory = { category }
                layout.setPadMode(mode)
                let focus = PadFocus()
                let host = NSHostingView(rootView: ControlsView(layout: layout).environmentObject(focus).environmentObject(modelStores.localizer))
                let window = OffscreenWindow(size: NSSize(width: 600, height: 700))
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
                DiagnosticsButton(report: modelStores.diagnostics)
                DiagnosticsButton(report: modelStores.diagnostics, showCopied: true)
            }.launcherRowControls().padding(24).background(LauncherPalette.background).environmentObject(PadFocus()).environmentObject(modelStores.localizer))
            buttons.frame = NSRect(x: 0, y: 0, width: 420, height: 90)
            let window = OffscreenWindow(size: buttons.frame.size)
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
            library.recordCompletedIOS(archive: "", app: installed.path, device: "00008150-AAAA", for: game.id)
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
            }).environmentObject(focus).environmentObject(modelStores.localizer))
            let window = OffscreenWindow(size: NSSize(width: 600, height: 520))
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

    /// Issue #53: the interpreter floor is the script's own, so Apple's 3.9 is never picked.
    func testThePythonFloorIsTheScriptsOwnThreeTwelve() {
        XCTAssertEqual(Toolchain.minPython.0, 3)
        XCTAssertEqual(Toolchain.minPython.1, 12,
                       "build_ipa_from_nsp.py:1911 refuses anything below 3.12; a lower floor let the "
                       + "app pick /usr/bin/python3 and the build died in the script")
        let (path, _) = Toolchain.findPython()
        XCTAssertFalse(path.isEmpty, "a Mac with any usable interpreter must yield one")
        if let v = Toolchain.pythonVersion(path) {
            let floor = Toolchain.minPython
            XCTAssertTrue(v.0 > floor.0 || (v.0 == floor.0 && v.1 >= floor.1),
                          "picked \(path) at \(v.0).\(v.1), below the \(floor.0).\(floor.1) floor")
        }
    }

    /// A uv-managed Python sits outside every location the app probed, and a GUI launch's PATH
    /// hides ~/.local/bin: uv had a working 3.12 with the packages and the panel still said
    /// "No Python 3.12 or newer found".
    func testUvManagedPythonsAreCandidates() throws {
        let oldShim = Toolchain.uvShimDir, oldRoot = Toolchain.uvPythonRoot
        defer { Toolchain.uvShimDir = oldShim; Toolchain.uvPythonRoot = oldRoot }
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
        Toolchain.uvShimDir = shim.path
        Toolchain.uvPythonRoot = root.path
        let cands = Toolchain.pythonCandidates()
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
        let oldShim = Toolchain.uvShimDir, oldRoot = Toolchain.uvPythonRoot, oldVenv = Toolchain.venvDir
        defer {
            Toolchain.uvShimDir = oldShim
            Toolchain.uvPythonRoot = oldRoot
            Toolchain.venvDir = oldVenv
        }
        let shim = temporary.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: shim, withIntermediateDirectories: true)
        // A stand-in interpreter: only its version and its exit status are asked for here.
        let interp = shim.appendingPathComponent("python3.12")
        try Data("#!/bin/sh\n[ \"$1\" = -c ] && echo 3.12\nexit 0\n".utf8).write(to: interp)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: interp.path)
        Toolchain.uvShimDir = shim.path
        Toolchain.uvPythonRoot = temporary.appendingPathComponent("no-uv").path
        Toolchain.venvDir = temporary.appendingPathComponent("no-venv").path

        let wanted = Toolchain.venvPython()      // findPython()'s last resort, and what the panel passes
        let base = try XCTUnwrap(Toolchain.venvBase(preferred: wanted), "a usable interpreter must be found")
        XCTAssertNotEqual(base, wanted, "the venv cannot be the base it is created from")
        let v = try XCTUnwrap(Toolchain.pythonVersion(base))
        XCTAssertTrue(v.0 > Toolchain.minPython.0 || (v.0 == Toolchain.minPython.0 && v.1 >= Toolchain.minPython.1))
        XCTAssertEqual(Toolchain.venvBase(preferred: interp.path), interp.path,
                       "an interpreter that does run at the required version is kept as given")
    }

    /// Issue #73: the extraction writes RomFS.img now, not a RomFS folder. The archive step looked
    /// only for the folder, so every build ended with "archive skipped" after a successful build.
    /// This drives RomFSArchive.extractedVersion — the function the archive step calls — rather than
    /// restating its predicate, so changing the production code changes what this checks.
    func testTheExtractionIsFoundAsEitherAFolderOrAnImage() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("nspb-extract-" + UUID().uuidString)
        let extract = work.appendingPathComponent("extract")
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: extract.appendingPathComponent("v0"), withIntermediateDirectories: true)
        XCTAssertNil(RomFSArchive.extractedVersion(in: extract.path), "an empty version folder holds neither shape")
        // what the rewriter writes today
        try Data([0x44, 0x4d, 0x52, 0x4f, 0x4d, 0x46, 0x53, 0x31])
            .write(to: extract.appendingPathComponent("v0").appendingPathComponent("RomFS.img"))
        XCTAssertEqual(RomFSArchive.extractedVersion(in: extract.path), "v0", "RomFS.img alone must count")
        // and the older shape still works, with the highest version winning
        try FileManager.default.createDirectory(at: extract.appendingPathComponent("v1").appendingPathComponent("RomFS"),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(RomFSArchive.extractedVersion(in: extract.path), "v1")
    }

    func testSharedShellInstallAndSyncPropagateToAllShellGames() throws {
        let shellRoot = temporary.appendingPathComponent("shell")
        let shellApp = shellRoot.appendingPathComponent("derived-data/Build/Products/Release-iphoneos/DmShell.app")
        try FileManager.default.createDirectory(at: shellApp, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: shellApp.appendingPathComponent("Info.plist"))
        try Data("profile".utf8).write(to: shellApp.appendingPathComponent("embedded.mobileprovision"))
        try ShellLibrary(games: [
            ShellLibrary.Game(titleID: "0100CD801CE5E000", name: "Balatro", framework: "DmGame0100CD801CE5E000.framework"),
            ShellLibrary.Game(titleID: "0100E65002BB8000", name: "Stardew Valley", framework: "DmGame0100E65002BB8000.framework"),
        ]).save(root: shellRoot.path)

        let file = temporary.appendingPathComponent("library.json")
        let g1 = LibraryGame(titleID: "0100CD801CE5E000", name: "Balatro")
        let g2 = LibraryGame(titleID: "0100E65002BB8000", name: "Stardew Valley")
        let g3 = LibraryGame(titleID: "01007EF00011E000", name: "Breath of the Wild")
        try JSONEncoder().encode([g1, g2, g3]).write(to: file)

        let library = GameLibrary(file: file)
        library.recordCompletedIOS(archive: "", app: shellApp.path, device: "00008150-TESTDEVICE", for: g1.id)
        XCTAssertEqual(library.games[0].iosAppPath, shellApp.path)
        XCTAssertEqual(library.games[0].installedDevice, "00008150-TESTDEVICE")
        XCTAssertEqual(library.games[1].iosAppPath, shellApp.path, "other games in shell.json share DmShell.app")
        XCTAssertEqual(library.games[1].installedDevice, "00008150-TESTDEVICE")
        XCTAssertEqual(library.games[2].iosAppPath, "", "a game outside shell.json is untouched")

        library.recordSharedAppInstalled(app: shellApp.path, device: "00008150-SECOND")
        XCTAssertEqual(library.games[0].installedDevice, "00008150-SECOND")
        XCTAssertEqual(library.games[1].installedDevice, "00008150-SECOND")

        // If an external tool cleared iosAppPath on one of the shared-shell games while a peer entry kept its provenance, syncSharedApp restores it.
        var cleared = library.games
        cleared[1].iosAppPath = ""
        cleared[1].installedDevice = ""
        try JSONEncoder().encode(cleared).write(to: file)
        let reloaded = GameLibrary(file: file)
        XCTAssertFalse(reloaded.games[1].onDevice)
        reloaded.syncSharedApp(root: shellRoot.path)
        XCTAssertTrue(reloaded.games[1].onDevice)
        XCTAssertEqual(reloaded.games[1].iosAppPath, shellApp.path)
        XCTAssertEqual(reloaded.games[1].installedDevice, "00008150-SECOND")
    }

    func testSyncSharedAppDoesNotInferInstallFromSignedLocalAppAfterFailedInstall() throws {
        let shellRoot = temporary.appendingPathComponent("shell-failed-install")
        let shellApp = shellRoot.appendingPathComponent("derived-data/Build/Products/Release-iphoneos/DmShell.app")
        try FileManager.default.createDirectory(at: shellApp, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: shellApp.appendingPathComponent("Info.plist"))
        // Signing succeeded and shell.json was saved before devicectl failed, leaving embedded.mobileprovision on disk.
        try Data("profile".utf8).write(to: shellApp.appendingPathComponent("embedded.mobileprovision"))
        try ShellLibrary(games: [
            ShellLibrary.Game(titleID: "0100CD801CE5E000", name: "Balatro", framework: "DmGame0100CD801CE5E000.framework"),
        ]).save(root: shellRoot.path)

        let ipa = temporary.appendingPathComponent("Balatro.ipa")
        try Data("ipa".utf8).write(to: ipa)

        let file = temporary.appendingPathComponent("library.json")
        var uninstalled = LibraryGame(titleID: "0100CD801CE5E000", name: "Balatro")
        uninstalled.ipaPath = ipa.path
        try JSONEncoder().encode([uninstalled]).write(to: file)

        let library = GameLibrary(file: file)
        library.syncSharedApp(root: shellRoot.path)
        XCTAssertFalse(library.games[0].onDevice, "a signed local DmShell.app without recorded install provenance must not mark the game as installed")
        XCTAssertEqual(library.games[0].installedDevice, "")
        XCTAssertEqual(library.games[0].iosAppPath, "")
        XCTAssertEqual(library.games[0].ipaPath, ipa.path, "remembered IPA path must not be cleared when the shared app was never installed")
    }

    func testSyncSharedAppDoesNotMarkNewGameInstalledWhenItsDeviceInstallFailedAfterEarlierPeerSucceeded() throws {
        let shellRoot = temporary.appendingPathComponent("shell-partial-install")
        let shellApp = shellRoot.appendingPathComponent("derived-data/Build/Products/Release-iphoneos/DmShell.app")
        try FileManager.default.createDirectory(at: shellApp, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: shellApp.appendingPathComponent("Info.plist"))
        try Data("profile".utf8).write(to: shellApp.appendingPathComponent("embedded.mobileprovision"))

        let ipaB = temporary.appendingPathComponent("Stardew.ipa")
        try Data("ipa".utf8).write(to: ipaB)

        let file = temporary.appendingPathComponent("library.json")
        let gameA = LibraryGame(titleID: "0100CD801CE5E000", name: "Balatro")
        var gameB = LibraryGame(titleID: "0100E65002BB8000", name: "Stardew Valley")
        gameB.ipaPath = ipaB.path
        try JSONEncoder().encode([gameA, gameB]).write(to: file)

        // 1. Install game A successfully.
        let entryA = ShellLibrary.Game(titleID: "0100CD801CE5E000", name: "Balatro", framework: "DmGame0100CD801CE5E000.framework")
        let entryB = ShellLibrary.Game(titleID: "0100E65002BB8000", name: "Stardew Valley", framework: "DmGame0100E65002BB8000.framework")
        try ShellLibrary(games: [entryA]).save(root: shellRoot.path)
        let library = GameLibrary(file: file)
        library.recordCompletedIOS(archive: "", app: shellApp.path, device: "EXISTING-DEVICE", for: gameA.id)
        XCTAssertTrue(library.games[0].onDevice)
        XCTAssertFalse(library.games[1].onDevice)
        XCTAssertEqual(library.games[1].ipaPath, ipaB.path)

        // 2. Build B so the current shared shell.json contains A and B, but let B's device install fail.
        try ShellLibrary(games: [entryA, entryB]).save(root: shellRoot.path)

        // 3. Restart the launcher.
        let relaunched = GameLibrary(file: file)
        relaunched.syncSharedApp(root: shellRoot.path)
        XCTAssertTrue(relaunched.games[0].onDevice)
        XCTAssertEqual(relaunched.games[0].installedDevice, "EXISTING-DEVICE")
        XCTAssertEqual(relaunched.games[0].iosAppPath, shellApp.path)
        XCTAssertFalse(relaunched.games[1].onDevice, "B's failed device install must not be marked installed from A's earlier receipt")
        XCTAssertEqual(relaunched.games[1].installedDevice, "")
        XCTAssertEqual(relaunched.games[1].iosAppPath, "")
        XCTAssertEqual(relaunched.games[1].ipaPath, ipaB.path, "B's remembered IPA must stay intact after a failed device install")
    }
}