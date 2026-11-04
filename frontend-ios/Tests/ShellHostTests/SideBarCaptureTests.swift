#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import ShellUI
@testable import ShellHost

/// Visual QA of the library on iPhone Duo's outer display (#622), rendered on the Mac from the fixture games. The Mac has no Duo, so
/// the screen is simulated: the outer display's size (466 x 678 points, from the Simulator's device profile) and a column of safe
/// area on the trailing side where the status bar sits. The column's width is measured from the reporter's screenshots, so it is an
/// estimate. The status bar's place in it is drawn as a light strip with a time. Set NX_SHELL_CAPTURE_DIR to write the PNGs, NX_SHELL_CAPTURE_LANG for the language.
@MainActor
final class SideBarCaptureTests: XCTestCase {
    private var lang: String { ProcessInfo.processInfo.environment["NX_SHELL_CAPTURE_LANG"] ?? "en" }

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["NX_SHELL_CAPTURE_DIR"] != nil else { throw XCTSkip("Set NX_SHELL_CAPTURE_DIR to capture the shell") }
        let code = lang == "zh" ? "zh-Hans" : lang
        if let ui = ShellStrings.bundle.path(forResource: code, ofType: "lproj") { ShellStrings.captureBundle = Bundle(path: ui) }
        if let host = HostStrings.bundle.path(forResource: code, ofType: "lproj") { HostStrings.captureBundle = Bundle(path: host) }
    }
    override func tearDown() async throws {
        ShellStrings.captureBundle = nil
        HostStrings.captureBundle = nil
    }

    /// The view inside a screen of `size` whose safe area leaves `insets` free, with the status bar's column drawn as a dim strip
    /// along the trailing edge's top so the image shows where the system's time and Wi-Fi would be.
    private func capture<V: View>(_ name: String, size: CGSize, insets: EdgeInsets, statusHeight: CGFloat, _ view: V) throws {
        let dir = try XCTUnwrap(ProcessInfo.processInfo.environment["NX_SHELL_CAPTURE_DIR"])
        NSApplication.shared.setActivationPolicy(.accessory)
        let screen = ZStack(alignment: .topTrailing) {
            // The system's vertical bar on the trailing edge, as `toolbarVerticalEdge` reports it on iPhone Duo.
            view.safeAreaPadding(insets).environment(\.shellSideBar, SideBar(edge: .trailing))
            Rectangle().fill(.white.opacity(0.18)).frame(width: insets.trailing, height: statusHeight)
                .overlay { Text("9:41").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.7)) }
                .allowsHitTesting(false)
        }
        let framed = screen.frame(width: size.width, height: size.height).background(ShellPalette.background).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: framed)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -100_000, y: -100_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(lang).png"))
    }

    private func model(_ box: Sandbox) throws -> ShellHostModel {
        try box.giveAppData(Fixtures.orbit)
        let shell = ShellSettingsStore(defaults: UserDefaults(suiteName: "capture-duo-\(UUID().uuidString)")!)
        let model = ShellHostModel(config: box.config(), shellSettings: shell)
        model.reload()
        return model
    }

    /// The outer display upright and on its side, the library and a game's settings open over it.
    func testCaptureTheOuterDisplay() throws {
        let box = try Sandbox()
        let model = try model(box)
        let upright = CGSize(width: 466, height: 678), sideways = CGSize(width: 678, height: 466)
        let uprightInsets = EdgeInsets(top: 0, leading: 0, bottom: 20, trailing: 80)
        let sidewaysInsets = EdgeInsets(top: 0, leading: 0, bottom: 20, trailing: 56)
        try capture("duo-outer-upright", size: upright, insets: uprightInsets, statusHeight: 165,
                    LibraryView(games: model.details, initialSelection: Fixtures.orbit))
        try capture("duo-outer-sideways", size: sideways, insets: sidewaysInsets, statusHeight: 80,
                    LibraryView(games: model.details, initialSelection: Fixtures.orbit))
        try capture("duo-outer-sideways-settings", size: sideways, insets: sidewaysInsets, statusHeight: 80,
                    LibraryView(games: model.details, initialSelection: Fixtures.orbit, initialDetailOpen: true))
        try capture("duo-outer-empty", size: upright, insets: uprightInsets, statusHeight: 165, LibraryView(games: []))
    }
}
#endif
