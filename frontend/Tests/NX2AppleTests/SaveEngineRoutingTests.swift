import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
@testable import NXLauncher

/// Regression tests verifying save engine routing and deletion isolation across nxnative, MacNativeGames, S2Arm, and nxkit.
final class SaveEngineRoutingTests: IsolatedDefaultsTestCase {
    private var root: URL!
    private var support: URL!
    private var home: URL!
    private var out: URL!
    private let fm = FileManager.default
    private let totkTID = "0100F2C0115B6000"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fm.temporaryDirectory.appendingPathComponent("save-routing-" + UUID().uuidString, isDirectory: true)
        support = root.appendingPathComponent("support", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        out = root.appendingPathComponent("out", isDirectory: true)
        for dir in [support!, home!, out!] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func write(_ url: URL, content: String = "x") throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    private func fakeApp(_ name: String, titleID: String, upstream: EngineUpstreamKind) throws -> URL {
        let app = out.appendingPathComponent(name, isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        let exe: String
        var extra: [String: Any] = [:]
        switch upstream {
        case .nxnative, .kidWithSword, .noLagKart:
            exe = "nxnative"
            try fm.createSymbolicLink(at: macOS.appendingPathComponent("dmhost"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        case .macNativeGames:
            exe = "TOTK"
            extra["DMUpstream"] = "macnativegames"
        case .s2arm:
            exe = "s2arm-launch"
            extra["DMUpstream"] = "s2arm"
            try fm.createSymbolicLink(at: macOS.appendingPathComponent("s2arm-host"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
            try Data("lib".utf8).write(to: macOS.appendingPathComponent("libs2a_vaguard.dylib"))
        case .nxkit:
            exe = NxkitBuilder.hostName
            extra["DMUpstream"] = "nxkit"
            let res = app.appendingPathComponent("Contents/Resources/nxkit", isDirectory: true)
            try fm.createDirectory(at: res, withIntermediateDirectories: true)
            try Data("r".utf8).write(to: res.appendingPathComponent("romfs"))
        }
        try fm.createSymbolicLink(at: macOS.appendingPathComponent(exe), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        var info: [String: Any] = [
            "CFBundleExecutable": exe,
            "CFBundleIdentifier": "test.\(upstream.rawValue).\(titleID)",
            "CFBundleDisplayName": name,
            "DMTitleID": titleID,
        ]
        for (k, v) in extra { info[k] = v }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    func testDeletingSingleS2ArmBuildNeverTouchesCoexistingNxnativeSaves() throws {
        let nxApp = try fakeApp("TOTK.app", titleID: totkTID, upstream: .nxnative)
        let s2armApp = try fakeApp("TOTK [S2Arm].app", titleID: totkTID, upstream: .s2arm)

        // Seed library + support nxnative saves AND S2Arm's own SaveData/ryu-data saves.
        try write(out.appendingPathComponent(".nx2apple-library"), content: "")
        let nxLibSave = out.appendingPathComponent("save/\(totkTID)/slot_00/progress.sav")
        let nxStdSave = support.appendingPathComponent("nxnative/\(totkTID)/save/slot_00/progress.sav")
        let s2aSave = support.appendingPathComponent("NX2Apple/s2arm-data/\(totkTID)/SaveData/save/slot_00/progress.sav")
        let s2aRyuSave = support.appendingPathComponent("NX2Apple/s2arm-data/\(totkTID)/ryu-data/bis/user/save/0000000000000001/0/progress.sav")
        let s2aState = support.appendingPathComponent("NX2Apple/s2arm-data/\(totkTID)/ryu-data/savedata-state.txt")
        let s2aCheats = support.appendingPathComponent("NX2Apple/s2arm-data/\(totkTID)/cheats/c.txt")
        for u in [nxLibSave, nxStdSave, s2aSave, s2aRyuSave, s2aState, s2aCheats] { try write(u) }

        var game = LibraryGame(titleID: totkTID, name: "TOTK", appPath: s2armApp.path)
        game.outputDirectory = out.path
        game.macBuilds = [
            EngineUpstreamKind.nxnative.rawValue: LibraryMacBuild(upstream: .nxnative, appPath: nxApp.path),
            EngineUpstreamKind.s2arm.rawValue: LibraryMacBuild(upstream: .s2arm, appPath: s2armApp.path),
        ]

        let plan = GameDeletion.plan(for: game, shellRoot: "", upstream: .s2arm, home: home.path, support: support)
        let savePaths = Set(plan.saves?.paths ?? [])
        XCTAssertFalse(savePaths.contains(out.appendingPathComponent("save/\(totkTID)").path))
        XCTAssertFalse(savePaths.contains(support.appendingPathComponent("nxnative/\(totkTID)/save").path))
        XCTAssertTrue(savePaths.contains(support.appendingPathComponent("NX2Apple/s2arm-data/\(totkTID)/SaveData").path))
        XCTAssertTrue(savePaths.contains(support.appendingPathComponent("NX2Apple/s2arm-data/\(totkTID)/ryu-data/bis/user/save").path))

        XCTAssertTrue(plan.run(saves: true, trash: { try self.fm.removeItem(at: $0) }).isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: nxLibSave.path), "nxnative library save must stay intact")
        XCTAssertTrue(fm.fileExists(atPath: nxStdSave.path), "nxnative support save must stay intact")
        XCTAssertFalse(fm.fileExists(atPath: s2aSave.path), "S2Arm SaveData must be removed")
        XCTAssertFalse(fm.fileExists(atPath: s2aRyuSave.path), "S2Arm ryu-data save must be removed")
        XCTAssertTrue(fm.fileExists(atPath: s2aCheats.path), "S2Arm non-save cheats folder stays")
    }

    func testDeletingSingleMNGBuildRemovesOnlyMNGProfileSavesAndPreservesNxnative() throws {
        let nxApp = try fakeApp("TOTK.app", titleID: totkTID, upstream: .nxnative)
        let mngApp = try fakeApp("TOTK [MacNativeGames].app", titleID: totkTID, upstream: .macNativeGames)

        try write(out.appendingPathComponent(".nx2apple-library"), content: "")
        let nxLibSave = out.appendingPathComponent("save/\(totkTID)/slot_00/progress.sav")
        let nxStdSave = support.appendingPathComponent("nxnative/\(totkTID)/save/slot_00/progress.sav")
        let mngSave = support.appendingPathComponent("MacNativeGames/TOTK/profile/save/abcdef0123456789abcdef0123456789/progress.sav")
        let mngUsers = support.appendingPathComponent("MacNativeGames/TOTK/profile/users.txt")
        let mngBackup = support.appendingPathComponent("MacNativeGames/TOTK/data/backups/20261124/save/slot_00")
        let mngShader = support.appendingPathComponent("MacNativeGames/TOTK/shader-cache/a.metal")
        for u in [nxLibSave, nxStdSave, mngSave, mngUsers, mngBackup, mngShader] { try write(u) }

        var game = LibraryGame(titleID: totkTID, name: "TOTK", appPath: mngApp.path)
        game.outputDirectory = out.path
        game.macBuilds = [
            EngineUpstreamKind.nxnative.rawValue: LibraryMacBuild(upstream: .nxnative, appPath: nxApp.path),
            EngineUpstreamKind.macNativeGames.rawValue: LibraryMacBuild(upstream: .macNativeGames, appPath: mngApp.path),
        ]

        let plan = GameDeletion.plan(for: game, shellRoot: "", upstream: .macNativeGames, home: home.path, support: support)
        XCTAssertTrue(plan.run(saves: true, trash: { try self.fm.removeItem(at: $0) }).isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: nxLibSave.path), "nxnative library save must survive single MNG deletion")
        XCTAssertTrue(fm.fileExists(atPath: nxStdSave.path), "nxnative support save must survive single MNG deletion")
        XCTAssertFalse(fm.fileExists(atPath: mngSave.path), "MNG profile save must be removed")
        XCTAssertFalse(fm.fileExists(atPath: mngUsers.path), "MNG users.txt must be removed")
        XCTAssertFalse(fm.fileExists(atPath: mngBackup.path), "MNG backup must be removed")
        XCTAssertTrue(fm.fileExists(atPath: mngShader.path), "Non-save MNG shader cache stays")
    }

    func testDeletingSingleNxkitBuildWithLibraryMarkerNeverTouchesNxnativeSaves() throws {
        let nxApp = try fakeApp("TOTK.app", titleID: totkTID, upstream: .nxnative)
        let nxkitApp = try fakeApp("TOTK [nxkit].app", titleID: totkTID, upstream: .nxkit)

        try write(out.appendingPathComponent(".nx2apple-library"), content: "")
        let nxLibSave = out.appendingPathComponent("save/\(totkTID)/slot_00/progress.sav")
        let nxStdSave = support.appendingPathComponent("nxnative/\(totkTID)/save/slot_00/progress.sav")
        let nxkitSave = support.appendingPathComponent("nxkit/\(totkTID)/save/slot_00/progress.sav")
        for u in [nxLibSave, nxStdSave, nxkitSave] { try write(u) }

        var game = LibraryGame(titleID: totkTID, name: "TOTK", appPath: nxkitApp.path)
        game.outputDirectory = out.path
        game.macBuilds = [
            EngineUpstreamKind.nxnative.rawValue: LibraryMacBuild(upstream: .nxnative, appPath: nxApp.path),
            EngineUpstreamKind.nxkit.rawValue: LibraryMacBuild(upstream: .nxkit, appPath: nxkitApp.path),
        ]

        let plan = GameDeletion.plan(for: game, shellRoot: "", upstream: .nxkit, home: home.path, support: support)
        XCTAssertTrue(plan.run(saves: true, trash: { try self.fm.removeItem(at: $0) }).isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: nxLibSave.path))
        XCTAssertTrue(fm.fileExists(atPath: nxStdSave.path))
        XCTAssertFalse(fm.fileExists(atPath: nxkitSave.path))
    }

    @MainActor func testExternalEnginesSkipCloudGateAndGameStartSaveEnvironment() throws {
        let mngApp = try fakeApp("TOTK [MacNativeGames].app", titleID: totkTID, upstream: .macNativeGames)
        let s2armApp = try fakeApp("TOTK [S2Arm].app", titleID: totkTID, upstream: .s2arm)
        let libDir = root.appendingPathComponent("lib", isDirectory: true)
        try fm.createDirectory(at: libDir, withIntermediateDirectories: true)
        let defaults = TestDefaults.make("save-routing-gate")
        let lib = GameLibrary(file: libDir.appendingPathComponent("lib.json"), defaults: defaults)

        for app in [mngApp, s2armApp] {
            let game = LibraryGame(titleID: totkTID, name: "TOTK", appPath: app.path)
            XCTAssertNil(CloudSaveStart.plan(for: game))
            let env = GameStart.environment(
                for: game,
                library: lib,
                controls: ControlLayout(defaults: defaults),
                repo: root.path,
                labels: { $0 },
                player: PlayerProfile(id: "p2", name: "Bob"),
                saves: (SaveGlobalSettings(cloudFolder: "icloud", cloudOn: true, saveRoot: "/Volumes/Saves"),
                        SaveGameOverride(cloud: .folder("/Volumes/Cloud"), saveFolder: "/Volumes/CustomSave")),
                defaults: defaults
            )
            XCTAssertNil(env["DM_SAVE"])
            XCTAssertNil(env["DM_SAVE_SYNC"])
            XCTAssertNil(env["DM_PSO_USER"])
            XCTAssertNil(env["NXKIT_SAVE"])
        }
    }

    func testExternalSaveTextsExistAcrossAllLocalesAndHaveNoSemicolons() {
        for lang in Lang.all {
            for key in ["mng.cloud.externalNote", "mng.saves.externalNote"] {
                let text = L10n.string(key, lang)
                XCTAssertNotEqual(text, key)
                XCTAssertFalse(text.contains(";") || text.contains("\u{FF1B}"), "\(lang.code) \(key) contains semicolon")
            }
        }
    }

    @MainActor func testMNGSaveNoticesRenderAndCaptureEnglishAndChinese() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let captureDir = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let captureDir {
            try fm.createDirectory(at: captureDir, withIntermediateDirectories: true)
        }

        let fakeMNG = root.appendingPathComponent("fake-mng", isDirectory: true)
        try fm.createDirectory(at: fakeMNG.appendingPathComponent("games/totk"), withIntermediateDirectories: true)
        try Data("# mng\n".utf8).write(to: fakeMNG.appendingPathComponent("build_app.py"))

        let mngApp = try fakeApp("TOTK [MacNativeGames].app", titleID: totkTID, upstream: .macNativeGames)
        let nxApp = try fakeApp("TOTK.app", titleID: totkTID, upstream: .nxnative)
        let baseNSP = root.appendingPathComponent("TOTK [0100F2C0115B6000].nsp")
        try Data([0]).write(to: baseNSP)

        for lang in CaptureLanguage.all([Lang.en, Lang.zh]) {
            let defaults = TestDefaults.make("mng-ui-shot-\(lang.code)")
            let stores = LauncherStores(defaults: defaults)
            stores.localizer.lang = lang
            stores.build.upstreamChanged = {}
            stores.build.macNativeGamesPath = fakeMNG.path
            stores.build.updateSlot("base") { $0.paths = [baseNSP.path] }
            stores.build.selectUpstream(.macNativeGames)

            let libDir = root.appendingPathComponent("lib-\(lang.code)", isDirectory: true)
            try fm.createDirectory(at: libDir, withIntermediateDirectories: true)
            let library = GameLibrary(file: libDir.appendingPathComponent("library.json"), defaults: defaults)
            var game = LibraryGame(titleID: totkTID, name: "The Legend of Zelda: Tears of the Kingdom", appPath: mngApp.path)
            game.inputs["base"] = [baseNSP.path]
            game.macBuilds = [
                EngineUpstreamKind.nxnative.rawValue: LibraryMacBuild(upstream: .nxnative, appPath: nxApp.path),
                EngineUpstreamKind.macNativeGames.rawValue: LibraryMacBuild(upstream: .macNativeGames, appPath: mngApp.path),
            ]
            library.games = [game]

            let switcher = EngineSwitcherCard(build: stores.build)
            let batchSheet = BuildSelectedSheet(
                library: library,
                queue: stores.queue,
                engineID: "nxnative",
                target: BuildTarget.mac,
                macOnlyNoteKey: "upstream.mngMacOnly",
                macNativeGamesSelected: true,
                activeUpstream: .macNativeGames,
                close: {}
            )
            let savesSection = VStack(alignment: .leading, spacing: 18) {
                GameSavesSection(game: game, settings: stores.saveSettings, players: stores.players)
                CloudSavesCard(game: game, overrides: stores.saveSettings, players: stores.players)
            }

            func checkAndCapture<V: View>(_ name: String, width: CGFloat, _ view: V) throws {
                let framed = view
                    .environmentObject(stores.localizer)
                    .environmentObject(PadFocus())
                    .padding(24)
                    .frame(width: width)
                    .background(LauncherPalette.background)
                    .font(.manrope(13))
                    .preferredColorScheme(.dark)
                let host = NSHostingView(rootView: framed)
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                XCTAssertGreaterThan(host.fittingSize.width, 100)
                XCTAssertGreaterThan(host.fittingSize.height, 60)
                guard let captureDir else { return }
                let window = OffscreenWindow(size: host.frame.size)
                window.contentView = host
                window.orderFront(nil)
                defer { window.orderOut(nil); window.contentView = nil; window.close() }
                RunLoop.main.run(until: Date().addingTimeInterval(0.35))
                host.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(
                    to: captureDir.appendingPathComponent("\(name)-\(lang.code).png")
                )
            }

            try checkAndCapture("mng-engine-switcher", width: 760, switcher)
            try checkAndCapture("mng-build-selected", width: 720, batchSheet)
            try checkAndCapture("mng-game-saves", width: 620, savesSection)
        }

        // S2Arm is not public-facing yet: CloudSavesCard renders empty (no dedicated S2Arm UI).
        let s2armApp = try fakeApp("TOTK [S2Arm].app", titleID: totkTID, upstream: .s2arm)
        let s2armGame = LibraryGame(titleID: totkTID, name: "TOTK", appPath: s2armApp.path)
        let s2armDefaults = TestDefaults.make("s2arm-hidden-cloud")
        let s2armStores = LauncherStores(defaults: s2armDefaults)
        let s2armCloudHost = NSHostingView(
            rootView: CloudSavesCard(game: s2armGame, overrides: s2armStores.saveSettings, players: s2armStores.players)
                .environmentObject(s2armStores.localizer)
                .environmentObject(PadFocus())
        )
        XCTAssertEqual(s2armCloudHost.fittingSize, .zero)
    }
}
