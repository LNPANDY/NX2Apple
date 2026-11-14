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
        let stores = LauncherStores(defaults: testDefaults)
        stores.deviceStore.exportIPA = true

        var gameA = LibraryGame(titleID: tidFast, name: "Mario Kart 8")
        gameA.appPath = try makeMacApp(titleID: tidFast, name: "Mario Kart 8")

        var gameB = LibraryGame(titleID: tidFull, name: "BotW")
        gameB.inputs = ["base": [temporary.appendingPathComponent("botw.nsp").path]]

        let fullFirst = RefreshQueueBuilder.makeEntry(
            game: gameB,
            target: BuildTarget.ios,
            fastRefresh: false,
            externalImgPath: "/Volumes/USB/botw.img",
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
        let stores = LauncherStores(defaults: testDefaults)
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

        let launcher = LauncherView(stores: stores, library: library, performStartupChecks: false, olderTools: [dualGame.id])
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
}
