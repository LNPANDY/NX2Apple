import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
import NXLauncher

/// Visual QA of the keys chosen once in Settings, LNPANDY/NX2Apple#996 (matched by --filter testRenderSavedKeysForVisualQA). The
/// Settings page with no keys saved, with keys saved and with saved keys that are gone, and the Builds page whose empty keys row
/// shows the saved keys. The keys and the game are stand-in files in a temporary folder: no key, no game data.
final class SavedKeysCaptureTests: IsolatedDefaultsTestCase {
    @MainActor func testRenderSavedKeysForVisualQA() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = NSTemporaryDirectory() + "saved-keys-capture-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: root) }
        let keys = root + "/Switch/prod.keys", game = root + "/Games/Sample Game [0100000000010000][v0].nsp"
        for path in [keys, game] {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            // The keys file names header_key with zeros (no key), so the row's key check has nothing to say about it.
            FileManager.default.createFile(atPath: path, contents: path == keys ? Data(("header_key = " + String(repeating: "0", count: 64) + "\n").utf8) : Data())
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        let lang = CaptureLanguage.current(.en)

        func shot(_ name: String, page: LauncherPage, _ setUp: (LauncherStores) -> Void) throws {
            let stores = LauncherStores(defaults: testDefaults); let model = stores.build
            model.lang = lang
            MainActor.assumeIsolated { stores.dependencies.checked = true }
            MainActor.assumeIsolated { stores.dependencies.deps = [Dep(id: "test", name: "Xcode", hint: "", present: true, installCmd: [])] }
            setUp(stores)
            let library = GameLibrary(file: URL(fileURLWithPath: root + "/preview.json"))
            let host = NSHostingView(rootView: LauncherView(stores: stores, library: library, initialPage: page, performStartupChecks: false))
            let window = OffscreenWindow(size: NSSize(width: 1440, height: 1024), styleMask: [.titled, .closable, .resizable])
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("keys-\(name)-\(lang.code).png"))
            window.orderOut(nil)
        }

        try shot("0-settings-unset", page: .settings) { _ in }
        try shot("1-settings-saved", page: .settings) { $0.build.saveKeys(keys) }
        try shot("2-settings-missing", page: .settings) { $0.build.saveKeys(root + "/Moved/prod.keys") }
        try shot("3-builds-without-saved-keys", page: .builds) { $0.build.forgetSavedKeys(); $0.build.take(picked: [game], kind: .base) }
        try shot("4-builds-saved-keys", page: .builds) { $0.build.saveKeys(keys); $0.build.take(picked: [game], kind: .base) }
        LauncherStores(defaults: testDefaults).build.forgetSavedKeys()   // the test leaves no key in its defaults
    }
}
