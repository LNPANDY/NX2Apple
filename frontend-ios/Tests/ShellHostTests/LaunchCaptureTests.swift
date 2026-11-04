#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import ShellHost
@testable import ShellUI

/// Opt-in visual QA of the real host before Play and while it prepares a launch. The fixture contains no game assets.
@MainActor
final class LaunchCaptureTests: XCTestCase {
    @MainActor private final class HeldLauncher: GameLauncher {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var started = false

        func launch(_ game: LaunchableGame) async throws {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                started = true
            }
        }

        func finish() {
            continuation?.resume()
            continuation = nil
        }
    }

    func testCaptureBeforeAndDuringLaunch() async throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_SHELL_CAPTURE_DIR"] else {
            throw XCTSkip("Set NX_SHELL_CAPTURE_DIR to capture the shell")
        }
        let language = ProcessInfo.processInfo.environment["NX_SHELL_CAPTURE_LANG"] ?? "en"
        let locale = language == "zh" ? "zh-Hans" : language
        if let path = ShellStrings.bundle.path(forResource: locale, ofType: "lproj") {
            ShellStrings.captureBundle = try XCTUnwrap(Bundle(path: path))
        }
        defer { ShellStrings.captureBundle = nil }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let box = try Sandbox()
        try box.giveAppData()
        // Keep one fictional, playable entry so both captures show the same library without unrelated error fixtures.
        for game in try FileManager.default.contentsOfDirectory(at: box.games, includingPropertiesForKeys: nil)
            where game.lastPathComponent != Fixtures.orbit {
            try FileManager.default.removeItem(at: game)
        }
        let suite = "shellhost.capture.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let launcher = HeldLauncher()
        let model = ShellHostModel(config: box.config(), launcher: launcher, shellSettings: ShellSettingsStore(defaults: defaults))
        let view = ShellHostView(model: model, initialSelection: Fixtures.orbit)
            .environment(\.locale, Locale(identifier: locale))
        try capture(view, to: output.appendingPathComponent("launch-before-\(language).png"))

        let launch = Task { await model.playNow(Fixtures.orbit) }
        defer { launcher.finish() }
        for _ in 0..<200 where !launcher.started { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(launcher.started, "The fixture launch must remain suspended while its loading state is captured")
        XCTAssertTrue(model.launchingGame)
        try capture(view, to: output.appendingPathComponent("launch-preparing-\(language).png"))
        launcher.finish()
        await launch.value
        XCTAssertFalse(model.launchingGame)
    }

    private func capture<V: View>(_ view: V, to file: URL) throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let host = NSHostingView(rootView: view.frame(width: 402, height: 874)
            .background(ShellPalette.background).environment(\.colorScheme, .dark))
        host.frame = NSRect(x: 0, y: 0, width: 402, height: 874)
        let window = NSWindow(contentRect: NSRect(x: -100_000, y: -100_000, width: 402, height: 874),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
    }
}
#endif
