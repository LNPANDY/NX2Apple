#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import ShellUI
@testable import ShellHost

/// Visual QA of the library on iPhone Duo's outer display (#622), rendered on the Mac from the fixture games. The screen is
/// simulated with the values the iPhone Duo Simulator (iOS 27.2) reported: the outer display's size, its safe area (a column of 84
/// points on one side, 34 at the bottom) and its occluded areas (the status bar, the camera), which are drawn as light areas.
/// Set NX_SHELL_CAPTURE_DIR to write the PNGs, NX_SHELL_CAPTURE_LANG for the language.
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

    /// The view inside a screen of `size` whose safe area leaves `insets` free, with the occluded areas of `bar` drawn as light
    /// shapes, so the image shows where the system's time and the camera are.
    private func capture<V: View>(_ name: String, size: CGSize, insets: EdgeInsets, bar: SideBar, _ view: V) throws {
        let dir = try XCTUnwrap(ProcessInfo.processInfo.environment["NX_SHELL_CAPTURE_DIR"])
        NSApplication.shared.setActivationPolicy(.accessory)
        let screen = ZStack(alignment: .topLeading) {
            view.safeAreaPadding(insets).environment(\.shellSideBar, bar)
            ForEach(Array(bar.occlusions.enumerated()), id: \.offset) { _, area in
                RoundedRectangle(cornerRadius: min(area.width, area.height) / 2).fill(.white.opacity(0.18))
                    .frame(width: area.width, height: area.height).offset(x: area.minX, y: area.minY)
            }
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
        let insets = EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 84)
        let uprightBar = SideBar(edge: .trailing, occlusions: [CGRect(x: 382, y: 0, width: 84, height: 174),
                                                               CGRect(x: 399.67, y: 29.33, width: 37, height: 37)])
        let sidewaysBar = SideBar(edge: .trailing, occlusions: [CGRect(x: 594, y: 384, width: 84, height: 82),
                                                                CGRect(x: 611.67, y: 399.67, width: 37, height: 37)])
        try capture("duo-outer-upright", size: upright, insets: insets, bar: uprightBar,
                    LibraryView(games: model.details, initialSelection: Fixtures.orbit))
        try capture("duo-outer-upright-settings", size: upright, insets: insets, bar: uprightBar,
                    LibraryView(games: model.details, initialSelection: Fixtures.orbit, initialDetailOpen: true))
        try capture("duo-outer-sideways", size: sideways, insets: insets, bar: sidewaysBar,
                    LibraryView(games: model.details, initialSelection: Fixtures.orbit))
        try capture("duo-outer-sideways-settings", size: sideways, insets: insets, bar: sidewaysBar,
                    LibraryView(games: model.details, initialSelection: Fixtures.orbit, initialDetailOpen: true))
        try capture("duo-outer-empty", size: upright, insets: insets, bar: uprightBar, LibraryView(games: []))
    }
}
#endif
