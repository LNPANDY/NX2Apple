#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import ShellUI

/// Visual QA of the touch controls settings (#347), rendered on the Mac: the shell settings page with the Touch controls group, at
/// each size. Set NX_SHELL_CAPTURE_DIR to write the PNGs, NX_SHELL_CAPTURE_LANG (en, zh, de, ...) for the language.
@MainActor
final class TouchControlsCaptureTests: XCTestCase {
    private var lang: String { ProcessInfo.processInfo.environment["NX_SHELL_CAPTURE_LANG"] ?? "en" }

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["NX_SHELL_CAPTURE_DIR"] != nil else { throw XCTSkip("Set NX_SHELL_CAPTURE_DIR to capture the shell") }
        if let path = ShellStrings.bundle.path(forResource: lang == "zh" ? "zh-Hans" : lang, ofType: "lproj") {
            ShellStrings.captureBundle = Bundle(path: path)
        }
    }
    override func tearDown() async throws { ShellStrings.captureBundle = nil }

    private func capture<V: View>(_ name: String, width: CGFloat, height: CGFloat, _ view: V) throws {
        let dir = try XCTUnwrap(ProcessInfo.processInfo.environment["NX_SHELL_CAPTURE_DIR"])
        NSApplication.shared.setActivationPolicy(.accessory)
        let host = NSHostingView(rootView: view.frame(width: width, height: height).background(ShellPalette.background).environment(\.colorScheme, .dark))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -100_000, y: -100_000), size: host.frame.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(lang).png"))
    }

    /// A store of its own, so the capture never reads or writes the Mac's settings.
    private func store(_ values: [String: String] = [:]) -> ShellSettingsStore {
        let name = "touch-capture-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        for (key, value) in values { defaults.set(value, forKey: key) }
        return ShellSettingsStore(defaults: defaults)
    }

    func testCaptureTheSettingsPage() throws {
        try capture("touch-settings", width: 402, height: 1400, ShellSettingsView(store: store(), actions: ShellActions(), onClose: {}))
    }

    /// The group alone at each size, at a phone's width and an iPad panel's.
    func testCaptureEachSize() throws {
        for size in ShellSettingsStore.touchSizes { try captureGroup("touch-size-\(size)", [ShellSettingsStore.touchSizeKey: size]) }
    }

    /// Each place of the left stick, at medium and with the large size.
    func testCaptureEachStickPlace() throws {
        for place in ShellSettingsStore.touchStickPlaces {
            try captureGroup("touch-stick-\(place)", [ShellSettingsStore.touchStickKey: place])
            try captureGroup("touch-stick-\(place)-large", [ShellSettingsStore.touchStickKey: place, ShellSettingsStore.touchSizeKey: "large"])
        }
    }

    /// The layout editor (#414): a phone held sideways and upright, 2D and 3D, a chosen control, a moved one, a refused spot, and an
    /// iPad upright with the controls below the picture.
    func testCaptureTheLayoutEditor() throws {
        var moved = TouchLayout()
        moved[.threeD, .face] = TouchLayout.Offset(dx: -4, dy: -3)
        moved[.threeD, .stick] = TouchLayout.Offset(dx: 0, dy: -4)
        moved[.threeD, .plus] = TouchLayout.Offset(dx: 2, dy: 1)
        let store = store([ShellSettingsStore.touchLayoutKey: moved.encoded])
        func editor(_ kind: TouchLayout.Kind, upright: PadScreen? = nil, select: TouchLayout.Control? = nil, rejected: Bool = false, held: Bool = false) -> TouchLayoutEditorModel {
            let m = TouchLayoutEditorModel(store: store, sideways: .proMax, upright: upright, kind: kind)
            if let select { held ? m.pickUp(select) : m.select(select) }
            if rejected { m.nudge(dx: 40, dy: 0) }   // the stick toward the diamond: no room
            return m
        }
        try capture("touch-editor-phone-sideways", width: 932, height: 430, TouchLayoutEditorView(model: editor(.threeD, select: .stick), close: {}))
        try capture("touch-editor-phone-upright", width: 402, height: 874, TouchLayoutEditorView(model: editor(.threeD, select: .face), close: {}))
        try capture("touch-editor-2d", width: 932, height: 430, TouchLayoutEditorView(model: editor(.twoD), close: {}))
        try capture("touch-editor-refused", width: 932, height: 430, TouchLayoutEditorView(model: editor(.threeD, select: .stick, rejected: true), close: {}))
        try capture("touch-editor-held", width: 932, height: 430, TouchLayoutEditorView(model: editor(.threeD, select: .plus, held: true), close: {}))
        try capture("touch-editor-ipad-upright", width: 1032, height: 1376,
                    TouchLayoutEditorView(model: editor(.threeDSplit, upright: .iPadUpright, select: .x), close: {}))
        try capture("touch-settings-arranged", width: 402, height: 1400, ShellSettingsView(store: store, actions: ShellActions(), onClose: {}))
    }

    /// The editor on real screens, inside each device's safe area (what the view gets on the device), with the outside drawn black: the
    /// smallest and the largest iPhone held sideways, an iPhone with a notch, and an iPad held sideways. A chosen control in 3D.
    func testCaptureTheLayoutEditorOnDevices() throws {
        struct Device { var name: String; var window: CGSize; var insets: EdgeInsets; var pad = false }
        let devices = [
            Device(name: "se", window: CGSize(width: 667, height: 375), insets: EdgeInsets()),
            Device(name: "mini", window: CGSize(width: 812, height: 375), insets: EdgeInsets(top: 0, leading: 50, bottom: 21, trailing: 50)),
            Device(name: "promax", window: CGSize(width: 956, height: 440), insets: EdgeInsets(top: 0, leading: 62, bottom: 21, trailing: 62)),
            Device(name: "ipad", window: CGSize(width: 1376, height: 1032), insets: EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0), pad: true),
        ]
        for d in devices {
            let screens = TouchLayoutScreens.device(window: d.window, insets: d.insets, isPad: d.pad)
            let m = TouchLayoutEditorModel(store: store(), sideways: screens.sideways, upright: screens.upright, kind: .threeD)
            m.select(.face)
            let view = TouchLayoutEditorView(model: m, close: {}).padding(d.insets).background(Color.black)
            try capture("touch-editor-device-\(d.name)", width: d.window.width, height: d.window.height, view)
            // The end of the column, with a moved control and Reset all asking: nothing below is cut off, it scrolls.
            let asking = TouchLayoutEditorModel(store: store(), sideways: screens.sideways, upright: screens.upright, kind: .threeD)
            asking.select(.face); asking.nudge(dx: -2, dy: -2); asking.askReset()
            try capture("touch-editor-device-\(d.name)-end", width: d.window.width, height: d.window.height,
                        TouchLayoutEditorView(model: asking, close: {}).padding(d.insets).background(Color.black))
            let none = TouchLayoutEditorModel(store: store(), sideways: screens.sideways, upright: screens.upright, kind: .twoD)
            try capture("touch-editor-device-\(d.name)-2d", width: d.window.width, height: d.window.height,
                        TouchLayoutEditorView(model: none, close: {}).padding(d.insets).background(Color.black))
        }
    }

    private func captureGroup(_ name: String, _ values: [String: String]) throws {
        let s = store(values)
        let group = SettingsGroup(title: ShellStrings.text("Touch controls")) {
            TouchControlsPreview(size: s.touchSize, stick: s.touchStick)
            TouchControlsNote()
            SettingControl(gameID: ShellSettingsRows.gameID, row: ShellSettingsRows.touchSizeRow(s), change: { _ in })
            SettingControl(gameID: ShellSettingsRows.gameID, row: ShellSettingsRows.touchStickRow(s), change: { _ in })
        }.padding(24)
        try capture(name, width: 402, height: 640, group)
    }
}
#endif
