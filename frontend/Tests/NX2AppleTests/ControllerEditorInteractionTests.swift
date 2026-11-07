import XCTest
import SwiftUI
@testable import NX2Apple
@testable import NXCore
import NXModel
@testable import NXLauncher

@MainActor final class ControllerEditorInteractionTests: IsolatedDefaultsTestCase {
    private func settle(_ seconds: Double = 0.25) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    func testParentLaunchSheetRoutesControllerIntoNestedEditorAndBack() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("controller-routing-" + UUID().uuidString)
        let app = temporary.appendingPathComponent("Game.app")
        let exe = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: exe, withIntermediateDirectories: true)
        for name in ["nxnative", "dmhost"] { try FileManager.default.createSymbolicLink(at: exe.appendingPathComponent(name), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true")) }
        let domain = TestPreferences.domain(in: temporary, "routing")
        let info: [String: Any] = ["DMTitleID": "0100000000000000", "CFBundleIdentifier": domain, "CFBundleExecutable": "nxnative", "DMControllerMappings": 1]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let storage = SystemControllerPreferences(domain: domain)
        defer {
            _ = storage.synchronize()
            try? FileManager.default.removeItem(at: temporary)
        }
        let library = GameLibrary(file: temporary.appendingPathComponent("library.json"))
        let id = try library.addApp(app)
        library.selectedID = id
        let pad = LauncherGamepad(), focus = PadFocus()
        let stores = LauncherStores(defaults: testDefaults)
        let host = NSHostingView(rootView: LauncherView(stores: stores, library: library, performStartupChecks: false, gamepad: pad, padFocus: focus))
        NSApplication.shared.setActivationPolicy(.accessory)
        let window = OffscreenWindow(size: NSSize(width: 1280, height: 900), styleMask: [.titled, .closable, .resizable])
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        settle(0.5)
        pad.perform(.x)
        settle(0.6)
        XCTAssertEqual(focus.scope, "launch")
        focus.show(default: "opt.controllerMapping")
        XCTAssertEqual(focus.focused, "opt.controllerMapping")
        pad.perform(.a)
        settle(0.6)
        XCTAssertEqual(focus.scope, "controls", "the parent must activate the nested scope")
        focus.show(default: "steam.L4")
        XCTAssertEqual(focus.focused, "steam.L4")
        pad.perform(.right)
        settle()
        XCTAssertEqual(ControllerPreferences(storage: storage).steam.buttons[16], 0, "the real gamepad action reaches the nested row")
        pad.perform(.b)
        settle(0.6)
        XCTAssertEqual(focus.scope, "launch", "B dismisses only the nested editor")
        focus.show(default: "opt.controllerMapping")
        XCTAssertEqual(focus.focused, "opt.controllerMapping", "parent remains presented and navigable")
        pad.perform(.a)
        settle(0.6)
        XCTAssertEqual(focus.scope, "controls")
        let dm = app.appendingPathComponent("Contents/Resources/dm")
        try FileManager.default.createDirectory(at: dm, withIntermediateDirectories: true)
        try "DM_SAVED_CHOICES=0".write(to: dm.appendingPathComponent("env.txt"), atomically: true, encoding: .utf8)
        let beforeDisableWhileOpen = ControllerPreferences(storage: storage).steam
        focus.show(default: "steam.L4")
        pad.perform(.right)
        settle()
        XCTAssertEqual(ControllerPreferences(storage: storage).steam, beforeDisableWhileOpen,
                       "retained row handlers must recheck env.txt before writing")
        focus.show(default: "controls.done")
        pad.perform(.a)
        settle(0.6)
        XCTAssertEqual(focus.scope, "launch", "Done also restores the parent scope")
        let beforeDisabled = ControllerPreferences(storage: storage).steam
        focus.show(default: "opt.controllerMapping")
        pad.perform(.a)
        settle(0.6)
        XCTAssertEqual(focus.scope, "controls")
        focus.show(default: "steam.L4")
        XCTAssertEqual(focus.focused, "controls.done", "disabled editor replaces stale controls frames with its own Done target")
        pad.perform(.right)
        pad.perform(.a)
        settle(0.6)
        XCTAssertEqual(focus.scope, "launch", "the disabled-saving panel can be dismissed with the gamepad")
        XCTAssertEqual(ControllerPreferences(storage: storage).steam, beforeDisabled)
        pad.perform(.b)
        settle(0.6)
        XCTAssertEqual(focus.scope, "main")
    }

    func testStandardMapFailureStaysVisibleBelowTheScrolledEditor() throws {
        let memory = EditorMemory()
        let store = ControllerMappingStore(preferences: ControllerPreferences(storage: memory))
        let layout = ControlLayout(keyMap: nil, padMap: nil) { store.setMap($0, value: $1) }
        let localizer = Localizer()
        localizer.lang = CaptureLanguage.current(.en)
        let focus = PadFocus()
        let host = NSHostingView(rootView: ControlsView(layout: layout, gameName: "Hades", mappingStore: store)
            .environmentObject(localizer).environmentObject(focus).launcherDropdownHost())
        NSApplication.shared.setActivationPolicy(.accessory)
        let window = OffscreenWindow(size: NSSize(width: 600, height: 700))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        settle(0.4)
        focus.scope = "controls"
        focus.show(default: "pad.A")
        settle(0.4)
        let healthyFooter = try footerWarningPixels(host)
        memory.syncOK = false
        focus.horizontal(1)
        settle(0.4)
        XCTAssertTrue(store.saveFailed)
        XCTAssertGreaterThan(try footerWarningPixels(host), healthyFooter + 20,
                             "the failed standard-map write must render its warning in the fixed footer below the scroll view")
        if let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] {
            let output = URL(fileURLWithPath: directory).appendingPathComponent("controller-mapping-save-failure.png")
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output)
        }
        memory.syncOK = true
        focus.horizontal(-1)
        settle(0.3)
        XCTAssertFalse(store.saveFailed)
        XCTAssertLessThanOrEqual(try footerWarningPixels(host), healthyFooter + 5)
    }

    /// Offscreen NSHostingView exposes no AX children. Check the rendered warning in the bottom 80 points instead.
    /// The healthy footer has gray text and cream controls, so amber pixels identify a visible persistence warning.
    private func footerWarningPixels<V: View>(_ host: NSHostingView<V>) throws -> Int {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let footerHeight = Int(80 * CGFloat(bitmap.pixelsHigh) / host.bounds.height)
        var warningPixels = 0
        for y in stride(from: max(0, bitmap.pixelsHigh - footerHeight), to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.6, color.greenComponent > 0.2, color.blueComponent < 0.4,
                   color.redComponent - color.greenComponent > 0.15 { warningPixels += 1 }
            }
        }
        return warningPixels
    }

}

private final class EditorMemory: ControllerPreferenceStorage {
    var values: [String: Any] = [:]
    var syncOK = true
    func read(_ key: String) -> Any? { values[key] }
    func write(_ key: String, value: Any?) { values[key] = value }
    func synchronize() -> Bool { syncOK }
}
