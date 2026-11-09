import XCTest
import SwiftUI
@testable import NX2Apple
@testable import NXCore
import NXModel
@testable import NXLauncher

/// Settings > App: the switch for the check of a new Mac app's first start (#1005, `MacPreflight`).
@MainActor final class PreflightSettingTests: IsolatedDefaultsTestCase {
    func testTheSettingIsInEveryLanguage() throws {
        let all = LocalizationFiles.load()
        XCTAssertGreaterThanOrEqual(all.count, 7)   // the seven the launcher shipped with, and any language added since
        for (code, texts) in all {
            for key in ["settings.preflightAfterBuild", "settings.preflightAfterBuildNote", "stage.preflight"] {
                XCTAssertFalse(texts[key, default: ""].isEmpty, "\(code): \(key)")
                if code != "en" { XCTAssertNotEqual(texts[key], all["en"]?[key], "\(code): \(key) is not the English text") }
            }
        }
    }

    // MARK: Visual QA (matched by --filter testRenderLauncherForVisualQA)

    /// The whole Settings page, tall enough for the App card's last rows.
    func testRenderLauncherForVisualQAPreflightSetting() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-preflight-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let stores = LauncherStores(defaults: testDefaults)
        stores.build.lang = CaptureLanguage.current(.en)
        stores.dependencies.checked = true
        stores.dependencies.deps = [Dep(id: "test", name: "Xcode", hint: "", present: true, installCmd: [])]
        let library = GameLibrary(file: temporary.appendingPathComponent("preview.json"))
        let host = NSHostingView(rootView: LauncherView(stores: stores, library: library, initialPage: .settings, performStartupChecks: false))
        let window = OffscreenWindow(size: NSSize(width: 1440, height: 2300), styleMask: [.titled, .closable, .resizable])
        window.contentView = host
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("settings-app.png"))
        window.orderOut(nil)
    }
}
