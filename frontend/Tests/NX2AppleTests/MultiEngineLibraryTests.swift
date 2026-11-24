import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel

@MainActor final class MultiEngineLibraryTests: IsolatedDefaultsTestCase {
    private var root: URL!
    private let fm = FileManager.default
    private let tid = "0100535012974000"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fm.temporaryDirectory.appendingPathComponent("multi-engine-lib-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func makeDefaults() -> UserDefaults {
        TestDefaults.make("multi-engine-lib")
    }

    @discardableResult
    private func createFakeBundle(at url: URL, titleID: String, name: String, upstream: EngineUpstreamKind, chain: String? = nil) throws -> URL {
        let macOS = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        let exe: String
        let domain = TestPreferences.domain(in: root, "lib-\(upstream.rawValue)-\(titleID)")
        let bundleID: String
        var plist: [String: Any] = [
            "DMTitleID": titleID,
            "CFBundleDisplayName": name,
        ]
        switch upstream {
        case .nxnative:
            exe = "nxnative"
            try fm.createSymbolicLink(at: macOS.appendingPathComponent("dmhost"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
            bundleID = domain
        case .kidWithSword, .noLagKart:
            exe = "nxnative"
            try fm.createSymbolicLink(at: macOS.appendingPathComponent("dmhost"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
            bundleID = upstream.personalMacBundleID(titleID: titleID) ?? domain
        case .macNativeGames:
            exe = "macnativegames"
            bundleID = domain
            plist["DMUpstream"] = "macnativegames"
        case .s2arm:
            exe = "s2arm-host"
            bundleID = domain
            plist["DMUpstream"] = "s2arm"
            try Data("lib".utf8).write(to: macOS.appendingPathComponent("libs2a_vaguard.dylib"))
        case .nxkit:
            exe = NxkitBuilder.hostName
            bundleID = domain
            let res = url.appendingPathComponent("Contents/Resources/nxkit", isDirectory: true)
            try fm.createDirectory(at: res, withIntermediateDirectories: true)
            try Data("k".utf8).write(to: res.appendingPathComponent("romfs"))
        }
        try fm.createSymbolicLink(at: macOS.appendingPathComponent(exe), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        plist["CFBundleExecutable"] = exe
        plist["CFBundleIdentifier"] = bundleID
        if let chain { plist["DMChain"] = chain }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        return url
    }

    func testScanMergesMultipleEngineAppsIntoOneCardAndPersistsDefault() throws {
        let defaults = makeDefaults()

        let scanRoot = root.appendingPathComponent("Library", isDirectory: true)
        let nxURL = try createFakeBundle(at: scanRoot.appendingPathComponent("Hades.app"), titleID: tid, name: "Hades", upstream: .nxnative)
        let mngURL = try createFakeBundle(at: scanRoot.appendingPathComponent("Hades [MacNativeGames].app"), titleID: tid, name: "Hades", upstream: .macNativeGames)
        let s2armURL = try createFakeBundle(at: scanRoot.appendingPathComponent("Hades [S2Arm].app"), titleID: tid, name: "Hades", upstream: .s2arm)

        let libFile = root.appendingPathComponent("library.json")
        let lib = GameLibrary(file: libFile, defaults: defaults)
        _ = try lib.mergeDiscoveredApp(nxURL)
        _ = try lib.mergeDiscoveredApp(mngURL)
        _ = try lib.mergeDiscoveredApp(s2armURL)

        XCTAssertEqual(lib.games.count, 1, "All engine builds of the same titleID must merge onto one card")
        let game = try XCTUnwrap(lib.games.first)
        XCTAssertEqual(game.sortedMacBuilds.map(\.upstream), [.nxnative, .macNativeGames, .s2arm])
        XCTAssertEqual(game.appPath, nxURL.standardizedFileURL.path, "Default resolves to nxnative first when no preference exists")

        lib.setPreferredMacUpstream(.macNativeGames, for: game.id)
        let updated = try XCTUnwrap(lib.games.first)
        XCTAssertEqual(updated.activeMacUpstream(defaults: defaults), .macNativeGames)
        XCTAssertEqual(updated.appPath, mngURL.standardizedFileURL.path)
        XCTAssertEqual(updated.targetingMacBuild(.s2arm)?.appPath, s2armURL.standardizedFileURL.path)
        XCTAssertEqual(DefaultBuildPreference.get(titleID: tid, defaults: defaults), .macNativeGames)

        // Reload from disk and verify default persists via UserDefaults + library snapshot.
        let reloaded = GameLibrary(file: libFile, defaults: defaults)
        XCTAssertEqual(reloaded.games.first?.activeMacUpstream(defaults: defaults), .macNativeGames)
        XCTAssertEqual(reloaded.games.first?.appPath, mngURL.standardizedFileURL.path)

        // Real folder discovery (`setFolder` + `discover()`) across the same root merges all engines into the single card.
        let discoveredLib = GameLibrary(file: root.appendingPathComponent("discovered.json"), defaults: defaults)
        discoveredLib.applicationFolders = []
        discoveredLib.setFolder(scanRoot)
        discoveredLib.discover(repo: root.appendingPathComponent("empty-repo").path)
        let deadline = Date().addingTimeInterval(3)
        while discoveredLib.scanning && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertFalse(discoveredLib.scanning)
        XCTAssertEqual(discoveredLib.games.count, 1)
        XCTAssertEqual(discoveredLib.games.first?.sortedMacBuilds.map(\.upstream), [.nxnative, .macNativeGames, .s2arm])
    }

    func testCheckReadRevalidatePrunesDeletedAndCorruptedBuildsAndFallsBack() throws {
        let defaults = makeDefaults()

        let nxURL = try createFakeBundle(at: root.appendingPathComponent("Hades.app"), titleID: tid, name: "Hades", upstream: .nxnative)
        let mngURL = try createFakeBundle(at: root.appendingPathComponent("Hades [MacNativeGames].app"), titleID: tid, name: "Hades", upstream: .macNativeGames)
        let volumes = root.appendingPathComponent("FakeVolumes", isDirectory: true)
        try fm.createDirectory(at: volumes, withIntermediateDirectories: true)

        let libFile = root.appendingPathComponent("library.json")
        let lib = GameLibrary(file: libFile, volumes: volumes.path, defaults: defaults)
        let id = try lib.mergeDiscoveredApp(nxURL)
        _ = try lib.mergeDiscoveredApp(mngURL)
        lib.setPreferredMacUpstream(.macNativeGames, for: id)

        // Add an external-disk nxkit build whose volume is currently unmounted; prune must keep it.
        var game = try XCTUnwrap(lib.games.first)
        let externalPath = volumes.appendingPathComponent("ExternalSSD/Hades [nxkit].app").path
        game.macBuilds[EngineUpstreamKind.nxkit.rawValue] = LibraryMacBuild(upstream: .nxkit, appPath: externalPath)
        lib.upsert(game)

        // Delete the preferred MacNativeGames bundle on disk.
        try fm.removeItem(at: mngURL)
        XCTAssertTrue(lib.pruneMultiBuilds(volumes: volumes.path))

        let afterMissing = try XCTUnwrap(lib.games.first)
        XCTAssertNil(afterMissing.macBuild(for: .macNativeGames))
        XCTAssertNotNil(afterMissing.macBuild(for: .nxnative))
        XCTAssertNotNil(afterMissing.macBuild(for: .nxkit), "Unmounted external volume build must not be pruned")
        XCTAssertEqual(afterMissing.appPath, nxURL.standardizedFileURL.path, "Active build must fall back to nxnative")

        // Replace remaining nxnative bundle with a different game's TitleID; prune must drop mismatched entry.
        let otherPlist: [String: Any] = ["DMTitleID": "0100000000010000", "CFBundleExecutable": "nxnative"]
        try PropertyListSerialization.data(fromPropertyList: otherPlist, format: .xml, options: 0)
            .write(to: nxURL.appendingPathComponent("Contents/Info.plist"))
        MacGameBundle.invalidateCache(forApp: nxURL.path)
        XCTAssertTrue(lib.pruneMultiBuilds(volumes: volumes.path))
        let afterMismatch = try XCTUnwrap(lib.games.first)
        XCTAssertNil(afterMismatch.macBuild(for: .nxnative))
    }

    func testRecordCompletedAppSetsDefaultOnlyForNonFastRefresh() throws {
        let defaults = makeDefaults()

        let nxURL = try createFakeBundle(at: root.appendingPathComponent("Hades.app"), titleID: tid, name: "Hades", upstream: .nxnative)
        let mngURL = try createFakeBundle(at: root.appendingPathComponent("Hades [MacNativeGames].app"), titleID: tid, name: "Hades", upstream: .macNativeGames)
        let lib = GameLibrary(file: root.appendingPathComponent("library.json"), defaults: defaults)

        var game = LibraryGame(titleID: tid, name: "Hades")
        lib.upsert(game)

        lib.recordCompletedApp(path: nxURL.path, commit: "c1", for: game.id, isFastRefresh: false)
        XCTAssertEqual(lib.games.first?.activeMacUpstream(defaults: defaults), .nxnative)

        lib.recordCompletedApp(path: mngURL.path, commit: "c2", for: game.id, isFastRefresh: false)
        XCTAssertEqual(lib.games.first?.activeMacUpstream(defaults: defaults), .macNativeGames)
        XCTAssertEqual(lib.games.first?.appPath, mngURL.path)

        // Fast refresh updates nxnative without hijacking user's MacNativeGames default.
        lib.recordCompletedApp(path: nxURL.path, commit: "c3", for: game.id, isFastRefresh: true)
        game = try XCTUnwrap(lib.games.first)
        XCTAssertEqual(game.activeMacUpstream(defaults: defaults), .macNativeGames)
        XCTAssertEqual(game.appPath, mngURL.path)
        XCTAssertEqual(game.macBuild(for: .nxnative)?.toolsCommit, "c3")
    }

    func testFastRefreshTargetsOnlyNxnativeAndSkipsPureTunedBuilds() throws {
        let defaults = makeDefaults()

        let nxURL = try createFakeBundle(at: root.appendingPathComponent("Hades.app"), titleID: tid, name: "Hades", upstream: .nxnative)
        let mngURL = try createFakeBundle(at: root.appendingPathComponent("Hades [MacNativeGames].app"), titleID: tid, name: "Hades", upstream: .macNativeGames)
        let lib = GameLibrary(file: root.appendingPathComponent("library.json"), defaults: defaults)
        let id = try lib.mergeDiscoveredApp(nxURL)
        _ = try lib.mergeDiscoveredApp(mngURL)
        lib.setPreferredMacUpstream(.macNativeGames, for: id)

        let gameWithBoth = try XCTUnwrap(lib.games.first)
        // Even with MacNativeGames set as active default, fast refresh must target nxnative .app only.
        XCTAssertEqual(gameWithBoth.nxnativeMacBuildForRefresh?.appPath, nxURL.standardizedFileURL.path)

        let stores = LauncherStores(defaults: defaults)
        XCTAssertEqual(URL(fileURLWithPath: stores.build.nxnativeWorkDirectory(baseOut: root.path, tidHex: tid, upstream: .nxnative)).lastPathComponent, "\(tid)_build")
        XCTAssertEqual(URL(fileURLWithPath: stores.build.nxnativeWorkDirectory(baseOut: root.path, tidHex: tid, upstream: .macNativeGames)).lastPathComponent, "\(tid)_mng_build")
        XCTAssertEqual(URL(fileURLWithPath: stores.build.nxnativeWorkDirectory(baseOut: root.path, tidHex: tid, upstream: .s2arm)).lastPathComponent, "\(tid)_s2arm_build")
        XCTAssertEqual(URL(fileURLWithPath: stores.build.nxnativeWorkDirectory(baseOut: root.path, tidHex: tid, upstream: .nxkit)).lastPathComponent, "\(tid)_nxkit_build")
        XCTAssertEqual(URL(fileURLWithPath: stores.build.nxnativeWorkDirectory(baseOut: root.path, tidHex: tid, upstream: .kidWithSword)).lastPathComponent, "\(tid)_kidwithsword_build")
        XCTAssertEqual(URL(fileURLWithPath: stores.build.nxnativeWorkDirectory(baseOut: root.path, tidHex: tid, upstream: .noLagKart)).lastPathComponent, "\(tid)_nolagkart_build")
        let fastEntry = RefreshQueueBuilder.makeEntry(
            game: gameWithBoth,
            target: BuildTarget.mac,
            fastRefresh: true,
            batch: UUID(),
            stores: stores,
            libraryFolder: root.path
        )
        XCTAssertEqual(fastEntry.upstream, .nxnative)
        XCTAssertEqual(fastEntry.existingAppPath, nxURL.standardizedFileURL.path)
        XCTAssertNotEqual(fastEntry.existingAppPath, mngURL.standardizedFileURL.path)

        // Pure tuned game (only MNG, no nxnative, no iOS) must not be treated as a refreshable nxnative Mac build.
        lib.removeBuildArtifact(upstream: .nxnative, for: id)
        let tunedOnly = try XCTUnwrap(lib.games.first)
        XCTAssertNil(tunedOnly.nxnativeMacBuildForRefresh)
        let launcher = LauncherView(stores: stores, library: lib, performStartupChecks: false, artworkStore: ArtworkStore(directory: root.appendingPathComponent("art")))
        let targets = launcher.resolvedRefreshTargets(for: tunedOnly)
        XCTAssertFalse(targets.hasMac)
    }

    func testFreeSpaceProtectionAndSingleVsAllDeletionIsolation() throws {
        let out = root.appendingPathComponent("out", isDirectory: true)
        let shell = root.appendingPathComponent("shell", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)

        let nxApp = try createFakeBundle(at: out.appendingPathComponent("Hades.app"), titleID: tid, name: "Hades", upstream: .nxnative)
        let mngApp = try createFakeBundle(at: out.appendingPathComponent("Hades [MacNativeGames].app"), titleID: tid, name: "Hades", upstream: .macNativeGames)
        let nxkitApp = try createFakeBundle(at: out.appendingPathComponent("Hades [nxkit].app"), titleID: tid, name: "Hades", upstream: .nxkit)

        // Build work directories + shared saves + shell framework + library marker
        for rel in [
            ".nx2apple-library",
            "\(tid)_build/extract/a",
            "\(tid)_mng_build/extract/b",
            "\(tid)_nxkit_build/extract/c",
            "save/\(tid)/0/save.bin",
            "../shell/frameworks/DmGame\(tid).framework/DmGame",
        ] {
            let url = out.appendingPathComponent(rel).standardizedFileURL
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("data".utf8).write(to: url)
        }
        var shellLib = ShellLibrary(games: [.init(titleID: tid, name: "Hades", framework: shell.appendingPathComponent("frameworks/DmGame\(tid).framework").path)])
        shellLib.bundleID = "org.nxnative.shell"
        try shellLib.save(root: shell.path)

        var game = LibraryGame(titleID: tid, name: "Hades", appPath: mngApp.path, ipaPath: out.appendingPathComponent("\(tid).ipa").path)
        game.outputDirectory = out.path
        game.macBuilds = [
            EngineUpstreamKind.nxnative.rawValue: LibraryMacBuild(upstream: .nxnative, appPath: nxApp.path),
            EngineUpstreamKind.macNativeGames.rawValue: LibraryMacBuild(upstream: .macNativeGames, appPath: mngApp.path),
            EngineUpstreamKind.nxkit.rawValue: LibraryMacBuild(upstream: .nxkit, appPath: nxkitApp.path),
        ]
        game.ipaBuilds = [
            EngineUpstreamKind.nxnative.rawValue: out.appendingPathComponent("\(tid).ipa").path,
            EngineUpstreamKind.kidWithSword.rawValue: out.appendingPathComponent("\(tid)-kidwithsword.ipa").path,
        ]
        try Data("i".utf8).write(to: out.appendingPathComponent("\(tid).ipa"))
        try Data("k".utf8).write(to: out.appendingPathComponent("\(tid)-kidwithsword.ipa"))

        // FreeSpace must protect every built .app and .ipa across engines.
        let protected = Set(BuildFolder.protectedPaths(for: game))
        XCTAssertTrue(protected.contains(BuildFolder.resolved(nxApp.path)))
        XCTAssertTrue(protected.contains(BuildFolder.resolved(mngApp.path)))
        XCTAssertTrue(protected.contains(BuildFolder.resolved(nxkitApp.path)))
        XCTAssertTrue(protected.contains(BuildFolder.resolved(out.appendingPathComponent("\(tid).ipa").path)))
        XCTAssertTrue(protected.contains(BuildFolder.resolved(out.appendingPathComponent("\(tid)-kidwithsword.ipa").path)))

        // Deleting only MacNativeGames removes MNG app + _mng_build and keeps nxnative/nxkit/saves/shell intact.
        let mngPlan = GameDeletion.plan(for: game, shellRoot: shell.path, upstream: .macNativeGames, home: home.path, support: support)
        XCTAssertEqual(mngPlan.items.first { $0.kind == .macApp }?.paths, [mngApp.path])
        XCTAssertNil(mngPlan.shellRoot, "Single-engine deletion must leave shared iOS shell untouched")
        XCTAssertNil(mngPlan.saves, "Shared save must stay while nxnative still uses it")
        let mngFailed = mngPlan.run(saves: true, trash: { try fm.removeItem(at: $0) })
        XCTAssertTrue(mngFailed.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: mngApp.path))
        XCTAssertFalse(fm.fileExists(atPath: out.appendingPathComponent("\(tid)_mng_build").path))
        XCTAssertTrue(fm.fileExists(atPath: nxApp.path))
        XCTAssertTrue(fm.fileExists(atPath: nxkitApp.path))
        XCTAssertTrue(fm.fileExists(atPath: out.appendingPathComponent("save/\(tid)/0/save.bin").path))
        XCTAssertTrue(fm.fileExists(atPath: shell.appendingPathComponent("frameworks/DmGame\(tid).framework").path))

        // Full deletion removes everything remaining.
        let fullPlan = GameDeletion.plan(for: game, shellRoot: shell.path, upstream: nil, home: home.path, support: support)
        XCTAssertNotNil(fullPlan.shellRoot)
        XCTAssertNotNil(fullPlan.saves)
        _ = fullPlan.run(saves: false, trash: { try fm.removeItem(at: $0) })
        XCTAssertFalse(fm.fileExists(atPath: nxApp.path))
        XCTAssertFalse(fm.fileExists(atPath: nxkitApp.path))
        XCTAssertFalse(fm.fileExists(atPath: shell.appendingPathComponent("frameworks/DmGame\(tid).framework").path))
        XCTAssertTrue(fm.fileExists(atPath: out.appendingPathComponent("save/\(tid)/0/save.bin").path), "saves=false keeps shared saves")
    }
}
