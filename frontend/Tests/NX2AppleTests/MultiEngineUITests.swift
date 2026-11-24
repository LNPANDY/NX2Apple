import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
@testable import NXLauncher

@MainActor final class MultiEngineUITests: IsolatedDefaultsTestCase {
    private var root: URL!
    private let fm = FileManager.default
    private let botwTID = "01007EF00011E000" // Has MacNativeGames tuned engine available

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fm.temporaryDirectory.appendingPathComponent("multi-engine-ui-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
        try super.tearDownWithError()
    }

    @discardableResult
    private func makeBundle(name: String, titleID: String, upstream: EngineUpstreamKind) throws -> URL {
        let app = root.appendingPathComponent(name)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        let exe = upstream == .macNativeGames ? "macnativegames" : "nxnative"
        try fm.createSymbolicLink(at: macOS.appendingPathComponent(exe), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        if upstream != .macNativeGames {
            try fm.createSymbolicLink(at: macOS.appendingPathComponent("dmhost"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        }
        var plist: [String: Any] = [
            "DMTitleID": titleID,
            "CFBundleDisplayName": "Breath of the Wild",
            "CFBundleExecutable": exe,
            "CFBundleIdentifier": TestPreferences.domain(in: root, "\(upstream.rawValue)-\(titleID)"),
        ]
        if upstream != .nxnative { plist["DMUpstream"] = upstream.rawValue }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    func testCardAndHeroBadgeVisibilityRules() throws {
        let t: (String) -> String = { L10n.string($0, .en) }
        let nxURL = try makeBundle(name: "BOTW.app", titleID: botwTID, upstream: .nxnative)
        let mngURL = try makeBundle(name: "BOTW [MacNativeGames].app", titleID: botwTID, upstream: .macNativeGames)

        // Single nxnative build -> tuned badge remains "Tuned available" (never claims MNG built it).
        let singleNX = LibraryArtworkState(
            mac: true,
            ios: false,
            attention: .none,
            macUpstream: .nxnative,
            tunedEngines: [.macNativeGames],
            builtMacUpstreams: [.nxnative]
        )
        XCTAssertNil(singleNX.activeBuiltEngine)
        XCTAssertEqual(LibraryGameCard.tunedBadge(for: singleNX, t: t)?.title, "Tuned available")
        XCTAssertEqual(LibraryGameCard.tunedBadge(for: singleNX, t: t)?.isBuilt, false)

        // Single nxnative build with NO tuned engine available -> no badge at all.
        let singlePlain = LibraryArtworkState(
            mac: true,
            ios: false,
            attention: .none,
            macUpstream: .nxnative,
            tunedEngines: [],
            builtMacUpstreams: [.nxnative]
        )
        XCTAssertNil(LibraryGameCard.tunedBadge(for: singlePlain, t: t))

        // Multiple builds (`nxnative` active + `MacNativeGames` present) -> displays active engine pill `nxnative`.
        let multiNXActive = LibraryArtworkState(
            mac: true,
            ios: false,
            attention: .none,
            macUpstream: .nxnative,
            tunedEngines: [.macNativeGames],
            builtMacUpstreams: [.nxnative, .macNativeGames]
        )
        XCTAssertEqual(multiNXActive.activeBuiltEngine, .nxnative)
        XCTAssertEqual(LibraryGameCard.tunedBadge(for: multiNXActive, t: t)?.title, "nxnative")
        XCTAssertEqual(LibraryGameCard.tunedBadge(for: multiNXActive, t: t)?.isBuilt, true)

        // Single non-nxnative build (`MacNativeGames`) -> displays `MacNativeGames`.
        let defaults = TestDefaults.make("ui-badge")
        let lib = GameLibrary(file: root.appendingPathComponent("library.json"), defaults: defaults)
        let id = try lib.mergeDiscoveredApp(mngURL)
        let mngOnly = try XCTUnwrap(lib.games.first)
        XCTAssertEqual(LauncherView.tunedMetadataBadge(for: mngOnly, t: t)?.title, "MacNativeGames")
        XCTAssertEqual(lib.artworkState(for: mngOnly).activeBuiltEngine, .macNativeGames)

        // Adding nxnative while MNG is default keeps MNG badge, and switching to nxnative updates badge to nxnative.
        _ = try lib.mergeDiscoveredApp(nxURL)
        lib.setPreferredMacUpstream(.macNativeGames, for: id)
        XCTAssertEqual(LauncherView.tunedMetadataBadge(for: try XCTUnwrap(lib.games.first), t: t)?.title, "MacNativeGames")

        lib.setPreferredMacUpstream(.nxnative, for: id)
        let switched = try XCTUnwrap(lib.games.first)
        XCTAssertEqual(LauncherView.tunedMetadataBadge(for: switched, t: t)?.title, "nxnative")
        XCTAssertEqual(lib.artworkState(for: switched).activeBuiltEngine, .nxnative)
    }

    func testManageMenuMultiBuildItems() throws {
        let t: (String) -> String = { L10n.string($0, .en) }
        let game = LibraryGame(titleID: botwTID, name: "Breath of the Wild")
        var launched: [EngineUpstreamKind] = []
        var switched: [EngineUpstreamKind] = []

        // Single build: no multi-engine switch/launch rows.
        let singleItems = ManageItem.list(
            game: game,
            labels: t,
            running: false,
            olderTools: false,
            activeBuildID: nil,
            hasBuildFolder: false,
            deviceName: "iPhone",
            activeUpstream: .nxnative,
            builtUpstreams: [.nxnative],
            actions: ManageActions()
        )
        XCTAssertFalse(singleItems.contains { $0.id.hasPrefix("launch.") || $0.id.hasPrefix("default.") })

        // Multiple builds: shows launch + set-default for other built engines.
        let multiItems = ManageItem.list(
            game: game,
            labels: t,
            running: false,
            olderTools: false,
            activeBuildID: nil,
            hasBuildFolder: false,
            deviceName: "iPhone",
            activeUpstream: .nxnative,
            builtUpstreams: [.nxnative, .macNativeGames],
            actions: ManageActions(
                launchWithEngine: { launched.append($0) },
                setDefaultEngine: { switched.append($0) }
            )
        )
        let launchRow = try XCTUnwrap(multiItems.first { $0.id == "launch.macnativegames" })
        let defaultRow = try XCTUnwrap(multiItems.first { $0.id == "default.macnativegames" })
        XCTAssertEqual(launchRow.title, "Launch with MacNativeGames")
        XCTAssertEqual(defaultRow.title, "Set MacNativeGames as default")
        launchRow.run()
        defaultRow.run()
        XCTAssertEqual(launched, [.macNativeGames])
        XCTAssertEqual(switched, [.macNativeGames])
    }

    func testConsoleModeMultiBuildSwitchAndPerEngineLaunch() throws {
        let defaults = TestDefaults.make("console-multi")
        let nxURL = try makeBundle(name: "BOTW.app", titleID: botwTID, upstream: .nxnative)
        let mngURL = try makeBundle(name: "BOTW [MacNativeGames].app", titleID: botwTID, upstream: .macNativeGames)
        let lib = GameLibrary(file: root.appendingPathComponent("library.json"), defaults: defaults)
        let id = try lib.mergeDiscoveredApp(nxURL)
        _ = try lib.mergeDiscoveredApp(mngURL)

        var launchedPaths: [String] = []
        let driver = LiveConsoleDriver(
            launchGracePeriod: 0,
            library: lib,
            controls: ControlLayout(),
            repo: { "" },
            lang: { .en },
            labels: { L10n.string($0, .en) },
            pads: { [] },
            steamPads: { [] },
            launch: { game, _, done in
                launchedPaths.append(game.appPath)
                done(42, nil)
            },
            artwork: { _, _ in nil },
            observeSystem: false
        )
        driver.refresh()
        let firstConsole = try XCTUnwrap(driver.state.games.first)
        XCTAssertEqual(firstConsole.activeMacEngine, .nxnative)
        XCTAssertEqual(firstConsole.builtMacEngines, [.nxnative, .macNativeGames])
        XCTAssertEqual(firstConsole.activeEngineBadgeName, "nxnative")

        // Switch default in console mode to MacNativeGames.
        driver.setDefaultMacEngine(id.uuidString, upstream: .macNativeGames)
        let updatedConsole = try XCTUnwrap(driver.state.games.first)
        XCTAssertEqual(updatedConsole.activeMacEngine, .macNativeGames)
        XCTAssertEqual(updatedConsole.activeEngineBadgeName, "MacNativeGames")
        XCTAssertEqual(lib.games.first?.appPath, mngURL.standardizedFileURL.path)

        // Launch explicitly with nxnative without overwriting default MacNativeGames preference.
        driver.launchWithMacEngine(id.uuidString, upstream: .nxnative)
        let deadline = Date().addingTimeInterval(2)
        while launchedPaths.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(launchedPaths, [nxURL.standardizedFileURL.path])
        XCTAssertEqual(lib.games.first?.activeMacUpstream(defaults: defaults), .macNativeGames)
    }

    func testMacNativeGamesAndKidWithSwordSwitchAndLaunchWithoutRebuild() throws {
        let t: (String) -> String = { L10n.string($0, .en) }
        let ootTID = EngineUpstreamKind.ootSwitch2TitleID
        let defaults = TestDefaults.make("mng-kws-ui")
        let mngURL = try makeBundle(name: "Ocarina [MacNativeGames].app", titleID: ootTID, upstream: .macNativeGames)
        let kwsURL = try makeBundle(name: "Ocarina [Kid with Sword].app", titleID: ootTID, upstream: .kidWithSword)

        let lib = GameLibrary(file: root.appendingPathComponent("mng-kws-ui.json"), defaults: defaults)
        var game = LibraryGame(titleID: ootTID, name: "Ocarina of Time")
        lib.upsert(game)
        lib.recordCompletedApp(path: mngURL.path, commit: "c1", for: game.id, isFastRefresh: false)
        lib.recordCompletedApp(path: kwsURL.path, commit: "c2", for: game.id, isFastRefresh: false)

        XCTAssertEqual(lib.games.count, 1)
        game = try XCTUnwrap(lib.games.first)
        XCTAssertEqual(game.sortedMacBuilds.map(\.upstream), [.macNativeGames, .kidWithSword])
        XCTAssertEqual(game.activeMacUpstream(defaults: defaults), .kidWithSword)
        XCTAssertEqual(LauncherView.tunedMetadataBadge(for: game, t: t)?.title, "Kid with Sword")

        let manageItems = ManageItem.list(
            game: game,
            labels: t,
            running: false,
            olderTools: false,
            activeBuildID: nil,
            hasBuildFolder: false,
            deviceName: "iPhone",
            activeUpstream: .kidWithSword,
            builtUpstreams: [.macNativeGames, .kidWithSword],
            actions: ManageActions()
        )
        XCTAssertEqual(manageItems.first { $0.id == "launch.macnativegames" }?.title, "Launch with MacNativeGames")
        XCTAssertEqual(manageItems.first { $0.id == "default.macnativegames" }?.title, "Set MacNativeGames as default")

        var launchedPaths: [String] = []
        let driver = LiveConsoleDriver(
            launchGracePeriod: 0,
            library: lib,
            controls: ControlLayout(),
            repo: { "" },
            lang: { .en },
            labels: { L10n.string($0, .en) },
            pads: { [] },
            steamPads: { [] },
            launch: { launched, _, done in
                launchedPaths.append(launched.appPath)
                done(7, nil)
            },
            artwork: { _, _ in nil },
            observeSystem: false
        )
        driver.refresh()
        let consoleGame = try XCTUnwrap(driver.state.games.first)
        XCTAssertEqual(consoleGame.builtMacEngines, [.macNativeGames, .kidWithSword])
        XCTAssertEqual(consoleGame.activeMacEngine, .kidWithSword)
        XCTAssertEqual(consoleGame.activeEngineBadgeName, "Kid with Sword")

        driver.launchWithMacEngine(game.id.uuidString, upstream: .macNativeGames)
        let deadline = Date().addingTimeInterval(2)
        while launchedPaths.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(launchedPaths, [mngURL.standardizedFileURL.path])
        XCTAssertEqual(lib.games.first?.activeMacUpstream(defaults: defaults), .kidWithSword)

        driver.setDefaultMacEngine(game.id.uuidString, upstream: .macNativeGames)
        XCTAssertEqual(driver.state.games.first?.activeMacEngine, .macNativeGames)
        XCTAssertEqual(LauncherView.tunedMetadataBadge(for: try XCTUnwrap(lib.games.first), t: t)?.title, "MacNativeGames")
    }

    func testAllNewLocalizationKeysExistWithoutSemicolons() throws {
        let keys = [
            "library.engineActive.help",
            "library.engineBuiltSummary.help",
            "library.switchBuild.menu",
            "library.launchWithEngine",
            "library.setDefaultEngine",
            "library.defaultBuildTag",
            "delete.scope.label",
            "delete.scope.single",
            "delete.scope.all",
            "delete.scope.engine",
            "console.manage.engineBuilds",
            "console.manage.setDefault",
            "shell.sharedSinglePerGameNote",
        ]
        for lang in Lang.all {
            for key in keys {
                let value = L10n.string(key, lang)
                XCTAssertFalse(value.isEmpty, "Empty \(key) for \(lang.code)")
                XCTAssertNotEqual(value, key, "Missing \(key) for \(lang.code)")
                XCTAssertFalse(value.contains(";"), "ASCII semicolon in \(key)[\(lang.code)]")
                XCTAssertFalse(value.contains("；"), "Fullwidth semicolon in \(key)[\(lang.code)]")
            }
        }
    }

    func testRenderMultiEngineScreenshotsWhenRequested() throws {
        let env = ProcessInfo.processInfo.environment
        guard let outDir = env["NX_LAUNCHER_CAPTURE_DIR"], !outDir.isEmpty else { return }
        let code = env["NX_CAPTURE_LANG"] ?? "en"
        let lang = Lang.all.first { $0.code == code } ?? .en
        let outURL = URL(fileURLWithPath: outDir, isDirectory: true)
        try fm.createDirectory(at: outURL, withIntermediateDirectories: true)

        func renderPNG<V: View>(_ view: V, size: CGSize, fitHeight: Bool = false, file: String) throws {
            let wasStatic = LauncherGlass.forceStatic
            LauncherGlass.forceStatic = true
            defer { LauncherGlass.forceStatic = wasStatic }
            let sizedView: AnyView = fitHeight
                ? AnyView(view.frame(width: size.width).fixedSize(horizontal: false, vertical: true).launcherAppearance())
                : AnyView(view.frame(width: size.width, height: size.height).launcherAppearance())
            let host = NSHostingView(rootView: sizedView)
            let finalSize: CGSize
            if fitHeight {
                host.frame = NSRect(origin: .zero, size: CGSize(width: size.width, height: max(size.height, 2000)))
                host.layoutSubtreeIfNeeded()
                finalSize = CGSize(width: size.width, height: max(size.height, ceil(host.fittingSize.height)))
            } else {
                finalSize = size
            }
            host.frame = NSRect(origin: .zero, size: finalSize)
            let window = NSWindow(
                contentRect: NSRect(origin: NSPoint(x: -100_000, y: -100_000), size: finalSize),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
            window.contentView = host
            window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds),
                  let png = ({ host.cacheDisplay(in: host.bounds, to: rep); return rep.representation(using: .png, properties: [:]) })() else {
                XCTFail("Failed to render \(file)")
                return
            }
            try png.write(to: outURL.appendingPathComponent(file))
        }

        let defaults = TestDefaults.make("multi-shot-\(lang.code)")
        let stores = LauncherStores(localizer: Localizer(lang), defaults: defaults)
        let nxURL = try makeBundle(name: "BOTW.app", titleID: botwTID, upstream: .nxnative)
        let mngURL = try makeBundle(name: "BOTW [MacNativeGames].app", titleID: botwTID, upstream: .macNativeGames)
        let lib = GameLibrary(file: root.appendingPathComponent("shot-lib-\(lang.code).json"), defaults: defaults)
        let gameID = try lib.mergeDiscoveredApp(nxURL)
        _ = try lib.mergeDiscoveredApp(mngURL)
        lib.setPreferredMacUpstream(.macNativeGames, for: gameID)
        lib.selectedID = gameID
        let game = try XCTUnwrap(lib.games.first)
        let artStore = ArtworkStore(directory: root.appendingPathComponent("shot-art-\(lang.code)"))

        let launcher = LauncherView(
            stores: stores,
            library: lib,
            performStartupChecks: false,
            artworkStore: artStore
        )
        .environmentObject(stores.localizer)
        .environmentObject(PadFocus())
        try renderPNG(launcher, size: CGSize(width: 1180, height: 760), file: "hero_multibuild_\(lang.code).png")

        let plan = GameDeletion(
            titleID: botwTID,
            items: [
                .init(kind: .macApp, paths: [mngURL.path], bytes: 1_200_000_000),
                .init(kind: .buildFolder, paths: [root.appendingPathComponent("\(botwTID)_mng_build/extract").path], bytes: 6_400_000_000),
            ],
            saves: nil,
            shellRoot: nil
        )
        let deleteSheet = DeleteGameSheet(game: game, shellRoot: "", plan: plan, measures: false, initialScopeUpstream: .macNativeGames)
            .environmentObject(stores.localizer)
            .environmentObject(PadFocus())
        try renderPNG(deleteSheet, size: CGSize(width: 540, height: 420), fitHeight: true, file: "delete_scope_\(lang.code).png")

        stores.build.target = BuildTarget.ios
        stores.deviceStore.exportIPA = true
        let installCard = InstallCard(devices: stores.deviceStore, build: stores.build)
            .padding(24)
            .background(LauncherPalette.background)
            .environmentObject(stores.localizer)
            .environmentObject(PadFocus())
        try renderPNG(installCard, size: CGSize(width: 780, height: 420), fitHeight: true, file: "ios_shell_note_\(lang.code).png")
    }
}
