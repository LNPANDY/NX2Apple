import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
@testable import NXLauncher

@MainActor final class LibraryFinishTests: IsolatedDefaultsTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func host(_ games: [LibraryGame], root: URL, stores: LauncherStores, pad: PadFocus,
                      gamepad: LauncherGamepad = LauncherGamepad(), width: CGFloat = 1280) throws -> (GameLibrary, OffscreenWindow) {
        let file = root.appendingPathComponent("library.json")
        try JSONEncoder().encode(games).write(to: file)
        let library = GameLibrary(file: file)
        let window = OffscreenWindow(size: NSSize(width: width, height: 900))
        window.contentView = NSHostingView(rootView: LauncherView(stores: stores, library: library,
            performStartupChecks: false, gamepad: gamepad, padFocus: pad))
        window.orderFront(nil)
        addTeardownBlock { MainActor.assumeIsolated { window.orderOut(nil); window.contentView = nil; window.close() } }
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        return (library, window)
    }

    func testHeroChipHasBreathingRoomAboveVisibleTitleCapitals() throws {
        let root = try directory(), stores = LauncherStores(defaults: testDefaults), pad = PadFocus()
        testDefaults.set("light", forKey: LauncherAppearance.defaultsKey)
        let game = LibraryGame(titleID: "0100000000000000", name: "Mario Kart", inputs: ["base": ["/tmp/game.nsp"]], sourceFolder: "/tmp")
        let (_, window) = try host([game], root: root, stores: stores, pad: pad)
        window.appearance = NSAppearance(named: .aqua)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let view = try XCTUnwrap(window.contentView)
        // On macOS 26, NSScrollView with .scrollEdgeEffectStyle(.soft) renders transparent in parent cacheDisplay;
        // capture the scroll document's visible rect directly so both macOS 26 and macOS 27 rasterize the hero pixels.
        func findScrollView(_ root: NSView) -> NSScrollView? {
            if let sv = root as? NSScrollView { return sv }
            return root.subviews.lazy.compactMap(findScrollView).first
        }
        let target = findScrollView(view)?.documentView ?? view
        let rect = target === view ? view.bounds : target.visibleRect
        let rep = try XCTUnwrap(target.bitmapImageRepForCachingDisplay(in: rect))
        target.cacheDisplay(in: rect, to: rep)
        let scale = CGFloat(rep.pixelsWide) / rect.width
        let actionInView = try XCTUnwrap(pad.frames["main"]?.first { $0.id == "hero.play" }?.frame)
        let action: CGRect
        if target === view {
            action = actionInView
        } else {
            let inViewAppKit = view.isFlipped ? actionInView : CGRect(x: actionInView.minX, y: view.bounds.height - actionInView.maxY, width: actionInView.width, height: actionInView.height)
            let inTarget = target.convert(inViewAppKit, from: view)
            let topY = target.isFlipped ? (inTarget.minY - rect.minY) : (rect.maxY - inTarget.maxY)
            action = CGRect(x: inTarget.minX - rect.minX, y: topY, width: inTarget.width, height: inTarget.height)
        }
        let x0 = Int(action.minX * scale), x1 = Int((action.minX + 300) * scale)
        var chipBottom: Int?
        for y in 100..<Int(action.minY * scale) {
            for x in x0..<x1 {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent > 0.7 && c.greenComponent > 0.4 && c.blueComponent < 0.45 {
                    chipBottom = y
                    break
                }
            }
        }
        let bottom = try XCTUnwrap(chipBottom, "Expected the actual yellow hero status chip")
        var titleTop: Int?
        for y in (bottom + 1)..<Int(action.minY * scale) {
            var ink = 0
            for x in x0..<x1 {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent < 0.25 && c.greenComponent < 0.25 && c.blueComponent < 0.25 { ink += 1 }
            }
            if ink > Int(20 * scale) { titleTop = y; break }
        }
        let top = try XCTUnwrap(titleTop)
        let visibleGap = CGFloat(top - bottom) / scale
        XCTAssertGreaterThanOrEqual(visibleGap, 10, "Chips need visible breathing room above the title")
        XCTAssertLessThanOrEqual(visibleGap, 18, "Measure visible title ink, not its font line box")
    }

    func testNormalHeroHeightIsThirtyPercentShorterWithUsableMinimums() {
        for available in [CGFloat(500), 650, 900] {
            XCTAssertEqual(LibraryHeroLayout.height(available: available, hasDeviceActions: false), available * 0.7)
        }
        XCTAssertEqual(LibraryHeroLayout.height(available: 200, hasDeviceActions: false), 300)
        XCTAssertEqual(LibraryHeroLayout.height(available: 200, hasDeviceActions: true), 340)
    }

    func testMetadataTransitionKeepsActionPositionAndActivatesCurrentGame() throws {
        let root = try directory(), stores = LauncherStores(defaults: testDefaults), pad = PadFocus()
        let marker = root.appendingPathComponent(EngineLayout.marker)
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: marker)
        stores.repo.path = root.path
        stores.dependencies.checked = true
        stores.dependencies.deps = [Dep(id: "xcode", name: "dep.xcode", hint: "", present: true, installCmd: [])]
        let games = [LibraryGame(titleID: "0100000000000000", name: "Short", inputs: ["base": ["/tmp/first/game.nsp"]], sourceFolder: "/tmp/first"),
                     LibraryGame(titleID: "0100000000001000", name: "The Legend of a Very Long Title: A Journey Across the Entire Kingdom",
                                 inputs: ["base": ["/tmp/second/game.nsp"]], sourceFolder: "/tmp/second")]
        let (library, window) = try host(games, root: root, stores: stores, pad: pad, width: 1000)
        let before = try XCTUnwrap(pad.frames["main"]?.first { $0.id == "hero.play" }?.frame)
        library.selectedID = games[1].id
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let during = try XCTUnwrap(pad.frames["main"]?.first { $0.id == "hero.play" }?.frame)
        XCTAssertEqual(before.minX, during.minX, accuracy: 1)
        XCTAssertEqual(before.maxY, during.maxY, accuracy: 1)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        XCTAssertTrue(window.performKeyEquivalent(with: event))
        XCTAssertEqual(stores.build.gameDir, "/tmp/second")
    }

    func testUninstalledArtifactDoesNotOfferDeviceActionsButRecordedInstallationDoes() throws {
        let root = try directory()
        let app = root.appendingPathComponent("Game.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        for name in ["nxnative", "dmhost"] {
            try FileManager.default.createSymbolicLink(at: app.appendingPathComponent("Contents/MacOS/" + name), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        }
        try PropertyListSerialization.data(fromPropertyList: ["DMTitleID": "0100000000000000", "CFBundleExecutable": "nxnative"], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let mobile = URL(fileURLWithPath: ShellInstall.appPath(root: root.appendingPathComponent("shell").path))
        try FileManager.default.createDirectory(at: mobile, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.shell"], format: .xml, options: 0)
            .write(to: mobile.appendingPathComponent("Info.plist"))
        var game = LibraryGame(titleID: "0100000000000000", name: "Both platforms", appPath: app.path)
        game.iosAppPath = mobile.path
        let pad = PadFocus(), stores = LauncherStores(defaults: testDefaults)
        let (library, _) = try host([game], root: root, stores: stores, pad: pad)
        XCTAssertFalse(pad.frames["main", default: []].contains { $0.id == "hero.device" || $0.id == "hero.resign" })
        game.installedDevice = "test-device"
        library.upsert(game)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        let frames = pad.frames["main", default: []]
        let play = try XCTUnwrap(frames.first { $0.id == "hero.play" }?.frame)
        for id in ["hero.resign", "hero.device", "hero.manage"] {
            let rect = try XCTUnwrap(frames.first { $0.id == id }?.frame)
            XCTAssertEqual(rect.height, 44, accuracy: 1)
            XCTAssertEqual(rect.midY, play.midY, accuracy: 1)
        }
    }

    func testProfileHelpConsumesControllerActionsAndReturnsWithoutBuilding() throws {
        let root = try directory(), stores = LauncherStores(defaults: testDefaults), pad = PadFocus(), gamepad = LauncherGamepad()
        let profile = root.appendingPathComponent("dm/games/known/game.tsv")
        try FileManager.default.createDirectory(at: profile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("title_id\t0100000000001000\n".utf8).write(to: profile)
        _ = VerifiedProfiles.titleIDs(engineRoot: root.path)
        stores.repo.path = root.path
        let game = LibraryGame(titleID: "0100000000000000", name: "Unverified", inputs: ["base": ["/tmp/game.nsp"]], sourceFolder: "/tmp/game")
        let (library, _) = try host([game], root: root, stores: stores, pad: pad, gamepad: gamepad)
        XCTAssertTrue(pad.frames["main", default: []].contains { $0.id == "hero.profile" })
        pad.show(default: "hero.profile"); pad.activate()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        gamepad.perform(.right); gamepad.perform(.a)
        XCTAssertEqual(library.selectedID, game.id)
        XCTAssertTrue(stores.build.gameDir.isEmpty, "A dismisses the explanation instead of activating content behind it")
        XCTAssertFalse(stores.build.running)
    }
}
