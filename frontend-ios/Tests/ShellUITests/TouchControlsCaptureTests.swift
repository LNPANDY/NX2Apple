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
        for size in ShellSettingsStore.touchSizes {
            let s = store([ShellSettingsStore.touchSizeKey: size])
            let group = SettingsGroup(title: ShellStrings.text("Touch controls")) {
                TouchControlsPreview(size: s.touchSize)
                TouchControlsNote()
                SettingControl(gameID: ShellSettingsRows.gameID, row: ShellSettingsRows.touchSizeRow(s), change: { _ in })
            }.padding(24)
            try capture("touch-size-\(size)", width: 402, height: 520, group)
        }
    }
}
#endif
