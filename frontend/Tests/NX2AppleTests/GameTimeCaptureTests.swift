import AppKit
import SwiftUI
import XCTest
import NXModel
@testable import NXCore
@testable import NXLauncher
@testable import NX2Apple

@MainActor final class GameTimeCaptureTests: IsolatedDefaultsTestCase {
    func testRenderLibraryPlayTime() throws {
        guard let destination = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else {
            throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture the library")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let title = "0100535012974000", fm = FileManager.default
        let app = root.appendingPathComponent("Sample game.app")
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        for name in ["nxnative", "dmhost"] {
            try fm.createSymbolicLink(at: app.appendingPathComponent("Contents/MacOS/" + name), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        }
        let domain = TestPreferences.domain(in: root, "game-time")
        try PropertyListSerialization.data(fromPropertyList: ["DMTitleID": title, "CFBundleDisplayName": "Sample game", "CFBundleExecutable": "nxnative", "CFBundleIdentifier": domain], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data().write(to: root.appendingPathComponent(GameLog.marker))
        let now = Date()
        let history = root.appendingPathComponent("save/playtime/" + title + "/local.json")
        try fm.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
        let day = DateFormatter(); day.calendar = Calendar(identifier: .gregorian); day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy-MM-dd"
        try JSONSerialization.data(withJSONObject: ["version": 2, "days": [day.string(from: now): ["550e8400-e29b-41d4-a716-446655440000": 7_500_000]], "lastActivityAt": UInt64(now.timeIntervalSince1970 * 1000)])
            .write(to: history)
        let library = GameLibrary(file: root.appendingPathComponent("library.json"))
        let id = try library.addApp(app)
        var game = try XCTUnwrap(library.games.first); game.lastPlayed = now; library.upsert(game); library.selectedID = id
        let stores = LauncherStores(defaults: testDefaults)
        stores.repo.path = root.path; stores.build.outDir = root.path; stores.build.lang = CaptureLanguage.current(.en)
        stores.dependencies.checked = true; stores.dependencies.deps = []
        NSApplication.shared.setActivationPolicy(.accessory)
        let host = NSHostingView(rootView: LauncherView(stores: stores, library: library, initialPage: .library, performStartupChecks: false))
        let window = OffscreenWindow(size: NSSize(width: 1280, height: 800), styleMask: [.titled, .closable, .resizable])
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host; window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
        let output = URL(fileURLWithPath: destination); try fm.createDirectory(at: output, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("game-time-library.png"))
        window.orderOut(nil)
    }
}
