import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
@testable import NXLauncher

@MainActor final class BatchRefreshAndImgGuideTests: IsolatedDefaultsTestCase {
    private var temporary: URL!
    private let fm = FileManager.default
    private let tidFast = "0100152000022000"
    private let tidFull = "010012101468C000"

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporary = fm.temporaryDirectory.appendingPathComponent("nx-batch-refresh-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporary {
            try? fm.removeItem(at: temporary)
        }
        try super.tearDownWithError()
    }

    private final class NoopRunningProcess: RunningProcess {
        var processIdentifier: Int32 { 0 }
        var isRunning: Bool { false }
    }

    private final class NoopProcessRunner: ProcessRunner, @unchecked Sendable {
        func capture(_ launch: ProcessLaunch) -> ProcessResult { ProcessResult(status: 0, out: "") }
        func stream(_ launch: ProcessLaunch, line: @escaping (String) -> Void) -> Bool { true }
        func streamLines(_ launch: ProcessLaunch, started: @escaping (RunningProcess) -> Void, line: @escaping (String) -> Void) -> ProcessResult {
            ProcessResult(status: 0, out: "")
        }
        func start(_ launch: ProcessLaunch, onOutput: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> RunningProcess {
            DispatchQueue.global(qos: .userInitiated).async { onExit(0) }
            return NoopRunningProcess()
        }
    }

    private func makeStores() -> LauncherStores {
        LauncherStores(runner: NoopProcessRunner(), xcrun: "/usr/bin/true", defaults: testDefaults)
    }

    private func makeArtworkStore() -> ArtworkStore {
        ArtworkStore(
            directory: temporary.appendingPathComponent("artwork"),
            titleList: temporary.appendingPathComponent("none-titles.json"),
            allowsFileURLs: true
        )
    }

    private func makeMacApp(titleID: String, name: String) throws -> String {
        let app = temporary.appendingPathComponent(name + ".app")
        let exeDir = app.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: exeDir, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: exeDir.appendingPathComponent("nxnative"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        try fm.createSymbolicLink(at: exeDir.appendingPathComponent("dmhost"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        let info: [String: Any] = [
            "DMTitleID": titleID,
            "CFBundleDisplayName": name,
            "CFBundleExecutable": "nxnative",
            "CFBundleIdentifier": "org.example.test." + titleID.lowercased(),
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app.path
    }

    func testRefreshQueueBuilderFastFirstAndPlatformPackagingFlags() throws {
        let batch = UUID()
        let stores = makeStores()
        stores.deviceStore.exportIPA = true

        var gameA = LibraryGame(titleID: tidFast, name: "Mario Kart 8 Deluxe")
        gameA.appPath = try makeMacApp(titleID: tidFast, name: "Mario Kart 8 Deluxe")

        var gameB = LibraryGame(titleID: tidFull, name: "Metroid Prime Remastered")
        gameB.inputs = ["base": [temporary.appendingPathComponent("metroid.nsp").path]]

        let fullFirst = RefreshQueueBuilder.makeEntry(
            game: gameB,
            target: BuildTarget.ios,
            fastRefresh: false,
            externalImgPath: "/Volumes/USB/metroid.img",
            batch: batch,
            stores: stores,
            libraryFolder: temporary.path
        )
        let macFast = RefreshQueueBuilder.makeEntry(
            game: gameA,
            target: BuildTarget.mac,
            fastRefresh: true,
            batch: batch,
            stores: stores,
            libraryFolder: temporary.path
        )
        let iosFast = RefreshQueueBuilder.makeEntry(
            game: gameA,
            target: BuildTarget.ios,
            fastRefresh: true,
            externalImgPath: "/Volumes/USB/mk8.img",
            batch: batch,
            stores: stores,
            libraryFolder: temporary.path
        )

        XCTAssertTrue(macFast.locksTarget)
        XCTAssertFalse(macFast.packageAfter)
        XCTAssertEqual(macFast.existingAppPath, gameA.appPath)
        XCTAssertNil(macFast.externalImgPath)

        XCTAssertTrue(iosFast.locksTarget)
        XCTAssertTrue(iosFast.packageAfter)
        XCTAssertEqual(iosFast.externalImgPath, "/Volumes/USB/mk8.img")

        let ordered = RefreshQueueBuilder.orderedEntries([fullFirst, macFast, iosFast])
        XCTAssertEqual(ordered.map(\.fastRefresh), [true, true, false])
        XCTAssertEqual(ordered.map(\.target), [BuildTarget.mac, BuildTarget.ios, BuildTarget.ios])
    }

    func testSheetsAndDualPlatformStatusRenderCleanlyOffscreen() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let stores = makeStores()
        let artwork = makeArtworkStore()
        stores.deviceStore.devices = [
            AppleDevice(id: "UDID-1", name: "Player iPhone", model: "iPhone 17 Pro", os: "27.0", reachable: true, transport: "wired")
        ]
        stores.deviceStore.installDevice = "UDID-1"

        var dualGame = LibraryGame(titleID: tidFast, name: "Mario Kart 8 Deluxe")
        dualGame.appPath = try makeMacApp(titleID: tidFast, name: "Mario Kart 8 Deluxe")
        let shellRoot = temporary.appendingPathComponent("shell").path
        let fwDir = ShellInstall.mirroredFramework(root: shellRoot, titleID: tidFast)
        try fm.createDirectory(atPath: fwDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: fwDir + "/game.manifest.json"))
        try Data("bin".utf8).write(to: URL(fileURLWithPath: fwDir + "/DmGame" + tidFast))
        dualGame.iosAppPath = shellRoot
        dualGame.hasShellFramework = true

        let libFile = temporary.appendingPathComponent("library.json")
        let library = GameLibrary(file: libFile)
        library.upsert(dualGame)

        let assessFast = GameRefreshAssessment(
            heroState: .specificFast(version: "1.5.0"),
            hasSpecificUpdate: true,
            versionLabel: "1.5.0",
            canFastRefreshMac: true,
            canFastRefreshIOS: true,
            needsMissingImgGuideIOS: false,
            missingOriginalPackage: false,
            expectedRomfsIdentity: "DMROMFSID1 size=64 index=deadbeef"
        )
        let toolsAge = ToolsAge(older: [dualGame.id], assessments: [dualGame.id: assessFast])

        let launcher = LauncherView(stores: stores, library: library, performStartupChecks: false, olderTools: [dualGame.id], artworkStore: artwork)
        XCTAssertTrue(dualGame.isReady)
        XCTAssertTrue(dualGame.hasIOSBuild)

        let batchSheet = BatchRefreshSheet(
            library: library,
            toolsAge: toolsAge,
            stores: stores,
            appVersion: "1.5.0",
            onConfirmed: {},
            close: {}
        )
        .environmentObject(stores.localizer)
        .environmentObject(PadFocus())

        let guideCtx = MissingImgGuideContext(
            game: dualGame,
            assessment: GameRefreshAssessment(
                heroState: .specificFull(version: "1.5.0"),
                hasSpecificUpdate: true,
                versionLabel: "1.5.0",
                canFastRefreshMac: true,
                canFastRefreshIOS: false,
                needsMissingImgGuideIOS: true,
                missingOriginalPackage: true,
                expectedRomfsIdentity: "DMROMFSID1 size=64 index=deadbeef"
            )
        )
        let guideSheet = MissingImgGuideSheet(
            context: guideCtx,
            stores: stores,
            devices: stores.deviceStore,
            libraryFolder: temporary.path,
            chooseImgURL: { nil },
            onResolvedImg: { _ in },
            onFallbackFullRebuild: {},
            close: {}
        )
        .environmentObject(stores.localizer)
        .environmentObject(PadFocus())

        for host in [
            NSHostingView(rootView: AnyView(batchSheet)),
            NSHostingView(rootView: AnyView(guideSheet)),
            NSHostingView(rootView: AnyView(launcher.status(dualGame, prominent: true).environmentObject(stores.localizer))),
        ] {
            let win = OffscreenWindow(size: NSSize(width: 720, height: 640))
            win.contentView = host
            win.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.width, 0)
            XCTAssertGreaterThan(host.fittingSize.height, 0)
            win.orderOut(nil)
        }
    }

    func testMultilingualAfterScreenshotsAndLayoutBounds() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let captureDir = ProcessInfo.processInfo.environment["NX_RC3_AFTER_CAPTURE_DIR"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        if let captureDir {
            try fm.createDirectory(at: captureDir, withIntermediateDirectories: true)
        }

        let stores = makeStores()
        let artwork = makeArtworkStore()
        stores.dependencies.checked = true
        stores.deviceStore.devices = [
            AppleDevice(id: "UDID-RC3", name: "Player iPhone", model: "iPhone 17 Pro", os: "27.0", reachable: true, transport: "wired")
        ]
        stores.deviceStore.installDevice = "UDID-RC3"

        let shellRoot = temporary.appendingPathComponent("shell-rc3").path
        for tid in ["0400486024DEC000", tidFast, "0100E65002BB8000"] {
            let fwDir = ShellInstall.mirroredFramework(root: shellRoot, titleID: tid)
            try fm.createDirectory(atPath: fwDir, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: URL(fileURLWithPath: fwDir + "/game.manifest.json"))
            try Data("bin".utf8).write(to: URL(fileURLWithPath: fwDir + "/DmGame" + tid))
        }

        var oot = LibraryGame(titleID: "0400486024DEC000", name: "The Legend of Zelda: Ocarina of Time")
        oot.iosAppPath = shellRoot
        oot.hasShellFramework = true

        var mk8 = LibraryGame(titleID: tidFast, name: "Mario Kart 8 Deluxe")
        mk8.iosAppPath = shellRoot
        mk8.hasShellFramework = true

        var stardew = LibraryGame(titleID: "0100E65002BB8000", name: "Stardew Valley")
        stardew.appPath = try makeMacApp(titleID: "0100E65002BB8000", name: "Stardew Valley")
        stardew.iosAppPath = shellRoot
        stardew.hasShellFramework = true

        let library = GameLibrary(file: temporary.appendingPathComponent("library-rc3.json"))
        library.applicationFolders = []
        library.upsert(oot)
        library.upsert(mk8)
        library.upsert(stardew)
        library.selectedID = oot.id

        let assessOOT = GameRefreshAssessment(
            heroState: .specificFast(version: "1.5.0"),
            hasSpecificUpdate: true,
            versionLabel: "1.5.0",
            canFastRefreshMac: false,
            canFastRefreshIOS: true,
            needsMissingImgGuideIOS: false,
            missingOriginalPackage: false,
            hasUsableSeed: true,
            expectedRomfsIdentity: "DMROMFSID1 size=64 index=aabbccdd"
        )
        let assessMK8 = GameRefreshAssessment(
            heroState: .specificFull(version: "1.5.0"),
            hasSpecificUpdate: true,
            versionLabel: "1.5.0",
            canFastRefreshMac: false,
            canFastRefreshIOS: false,
            needsMissingImgGuideIOS: true,
            missingOriginalPackage: true,
            hasUsableSeed: true,
            expectedRomfsIdentity: "DMROMFSID1 size=128 index=11223344"
        )
        let assessStardew = GameRefreshAssessment(
            heroState: .generalSync(fast: false),
            hasSpecificUpdate: false,
            versionLabel: "1.5.0",
            canFastRefreshMac: false,
            canFastRefreshIOS: false,
            needsMissingImgGuideIOS: false,
            missingOriginalPackage: true,
            hasUsableSeed: false,
            expectedRomfsIdentity: nil
        )
        let assessments: [UUID: GameRefreshAssessment] = [
            oot.id: assessOOT,
            mk8.id: assessMK8,
            stardew.id: assessStardew,
        ]
        let olderSet: Set<UUID> = [oot.id, mk8.id, stardew.id]
        let toolsAge = ToolsAge(older: olderSet, assessments: assessments)

        let supported: [SupportedGame] = [
            SupportedGame(titleID: "0400486024DEC000", name: "The Legend of Zelda: Ocarina of Time", edition: .switch2, version: "1.0.0", notes: "Shader and compatibility improvements updated in 1.5.0."),
            SupportedGame(titleID: tidFast, name: "Mario Kart 8 Deluxe", edition: .switch1, version: "3.0.4", notes: "Timing and Metal rendering stability improvements in 1.5.0."),
            SupportedGame(titleID: "01005CA01580E000", name: "Persona 5 Royal", edition: .switch1, version: "1.0.2", notes: "Rendering and stability improvements updated in 1.5.0."),
            SupportedGame(titleID: tidFull, name: "Metroid Prime Remastered", edition: .switch1, version: "1.1.0", notes: "Compatibility improvements shipped in 1.4.0."),
            SupportedGame(titleID: "0100E65002BB8000", name: "Stardew Valley", edition: .switch1, version: "1.6.15", notes: "Playable on Mac and iOS."),
        ]
        XCTAssertEqual(GameUpdateCatalog.catalogVersion(for: "0400486024DEC000"), "1.5.0")
        XCTAssertEqual(GameUpdateCatalog.catalogVersion(for: tidFast), "1.5.0")
        XCTAssertEqual(GameUpdateCatalog.catalogVersion(for: "01005CA01580E000"), "1.5.0")
        XCTAssertEqual(GameUpdateCatalog.catalogVersion(for: tidFull), "1.4.0")
        XCTAssertNil(GameUpdateCatalog.catalogVersion(for: "0100E65002BB8000"))
        XCTAssertNil(GameUpdateCatalog.catalogVersion(for: "0100D9F01D474000"))

        func renderAndCapture<V: View>(_ fileBase: String, _ view: V, light: Bool, size: NSSize) throws {
            let root = view
                .environmentObject(PadFocus())
                .environmentObject(stores.localizer)
                .launcherDropdownHost()
                .frame(width: size.width, height: size.height)
                .background(LauncherPalette.background)
            let host = NSHostingView(rootView: root)
            let window = OffscreenWindow(size: size, styleMask: [.titled, .closable, .resizable, .fullSizeContentView])
            window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
            window.contentView = host
            window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(captureDir == nil ? 0.02 : 0.30))
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.width, 0, "Zero fitting width for \(fileBase)")
            XCTAssertGreaterThan(host.fittingSize.height, 0, "Zero fitting height for \(fileBase)")
            XCTAssertGreaterThan(host.bounds.width, 0, "Zero bounds width for \(fileBase)")
            XCTAssertGreaterThan(host.bounds.height, 0, "Zero bounds height for \(fileBase)")
            if let captureDir {
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                try png.write(to: captureDir.appendingPathComponent("\(fileBase)-\(light ? "light" : "dark").png"))
            }
        }

        let guideCtx = MissingImgGuideContext(game: mk8, assessment: assessMK8)
        let langs = captureDir == nil ? ["en", "zh"] : ["zh", "en", "ja"]
        let appearances = captureDir == nil ? [false] : [true, false]

        for code in langs {
            stores.localizer.lang = Lang(code)
            let libSize = NSSize(width: 1440, height: 960)
            let compactSize = NSSize(width: 900, height: 680)
            let sheetSize = NSSize(width: 680, height: 640)
            let guideSize = NSSize(width: 680, height: 680)

            for light in appearances {
                try renderAndCapture(
                    "library-\(code)",
                    LauncherView(
                        stores: stores,
                        library: library,
                        initialPage: .library,
                        performStartupChecks: false,
                        olderTools: olderSet,
                        toolsAssessments: assessments,
                        artworkStore: artwork
                    ),
                    light: light,
                    size: libSize
                )
                try renderAndCapture(
                    "batch-refresh-\(code)",
                    BatchRefreshSheet(
                        library: library,
                        toolsAge: toolsAge,
                        stores: stores,
                        appVersion: "1.5.0",
                        onConfirmed: {},
                        close: {}
                    ),
                    light: light,
                    size: sheetSize
                )
                try renderAndCapture(
                    "supported-games-\(code)",
                    SupportedGamesSheet(
                        games: supported,
                        owned: { id in library.games.first { $0.titleID == id } },
                        covers: .saved(in: URL(fileURLWithPath: "/nonexistent"), maxPixel: SupportedGamesSheet.coverPixels),
                        showInLibrary: { _ in },
                        appVersion: "1.5.0"
                    ),
                    light: light,
                    size: sheetSize
                )
            }

            try renderAndCapture(
                "library-900-\(code)",
                LauncherView(
                    stores: stores,
                    library: library,
                    initialPage: .library,
                    performStartupChecks: false,
                    olderTools: olderSet,
                    toolsAssessments: assessments,
                    artworkStore: artwork
                ),
                light: true,
                size: compactSize
            )
            try renderAndCapture(
                "missing-img-guide-\(code)",
                MissingImgGuideSheet(
                    context: guideCtx,
                    stores: stores,
                    devices: stores.deviceStore,
                    libraryFolder: temporary.path,
                    chooseImgURL: { nil },
                    onResolvedImg: { _ in },
                    onFallbackFullRebuild: {},
                    close: {}
                ),
                light: true,
                size: guideSize
            )
        }
    }

    func testShellRootIOSBuildProbeInSingleAndBatchRefresh() throws {
        let shellRoot = temporary.appendingPathComponent("shell-probe").path
        let fwDir = ShellInstall.mirroredFramework(root: shellRoot, titleID: tidFast)
        try fm.createDirectory(atPath: fwDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: fwDir + "/game.manifest.json"))
        try Data("bin".utf8).write(to: URL(fileURLWithPath: fwDir + "/DmGame" + tidFast))

        testDefaults.set(shellRoot, forKey: "shellRoot")
        let stores = makeStores()
        let artwork = makeArtworkStore()
        XCTAssertEqual(stores.build.shellCachePath, shellRoot)

        // Simulate a library record whose stale metadata lacks iosAppPath/hasShellFramework/IPA,
        // and whose lastTarget was Mac, while the actual iOS framework exists under shellRoot.
        var game = LibraryGame(titleID: tidFast, name: "Mario Kart 8 Deluxe")
        game.lastTarget = BuildTarget.mac
        XCTAssertFalse(game.hasIOSBuild)
        XCTAssertTrue(game.hasIOSBuild(shellRoot: shellRoot))
        XCTAssertFalse(game.hasIOSBuild(shellRoot: temporary.appendingPathComponent("missing-shell").path))

        let library = GameLibrary(file: temporary.appendingPathComponent("library-probe.json"))
        library.upsert(game)

        let assess = GameRefreshAssessment(
            heroState: .specificFast(version: "1.5.0"),
            hasSpecificUpdate: true,
            versionLabel: "1.5.0",
            canFastRefreshMac: false,
            canFastRefreshIOS: true,
            needsMissingImgGuideIOS: false,
            missingOriginalPackage: false,
            hasUsableSeed: true,
            expectedRomfsIdentity: "DMROMFSID1 size=64 index=deadbeef"
        )
        let toolsAge = ToolsAge(older: [game.id], assessments: [game.id: assess])

        let launcher = LauncherView(
            stores: stores,
            library: library,
            performStartupChecks: false,
            olderTools: [game.id],
            artworkStore: artwork
        )
        let targets = launcher.resolvedRefreshTargets(for: game)
        XCTAssertFalse(targets.hasMac)
        XCTAssertTrue(targets.hasIOS)

        let fallbackOnlyLauncher = LauncherView(
            stores: stores,
            library: library,
            performStartupChecks: false,
            olderTools: [game.id],
            artworkStore: artwork
        )
        XCTAssertEqual(fallbackOnlyLauncher.refreshableGames.map(\.id), [game.id])

        launcher.enqueueSingleGameRefresh(game, assessment: assess, externalIOSImgPath: nil)
        XCTAssertEqual(stores.queue.entries.count, 1)
        XCTAssertEqual(stores.queue.entries.first?.target, BuildTarget.ios)
        XCTAssertEqual(stores.queue.entries.first?.fastRefresh, true)

        let batchSheet = BatchRefreshSheet(
            library: library,
            toolsAge: toolsAge,
            stores: stores,
            appVersion: "1.5.0",
            onConfirmed: {},
            close: {}
        )
        let batchTargets = batchSheet.candidateTargetsForTesting()
        XCTAssertEqual(batchTargets.count, 1)
        XCTAssertEqual(batchTargets.first?.id, game.id)
        XCTAssertEqual(batchTargets.first?.hasMac, false)
        XCTAssertEqual(batchTargets.first?.hasIOS, true)
    }
}
