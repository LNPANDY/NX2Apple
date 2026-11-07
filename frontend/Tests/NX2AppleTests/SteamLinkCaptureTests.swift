import XCTest
import SwiftUI
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

/// Controlled before/after states, not evidence of a live Steam Link session.
@MainActor final class SteamLinkCaptureTests: IsolatedDefaultsTestCase {
    func testCaptureSteamControllerStates() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_STEAM_CAPTURE_DIR"] else {
            throw XCTSkip("Set NX_STEAM_CAPTURE_DIR for Steam controller inventory and glyph captures")
        }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        for lang in Lang.all {
            for accepted in [false, true] {
                for screen in ["home", "controllers"] {
                    let driver = MockConsoleDriver(scenario: .few, lang: lang, animated: false)
                    var snapshot = SteamLinkGamepads.snapshot(id: "steam-capture", slot: 0)
                    snapshot.playerIndex = 1
                    driver.state.controllers = accepted ? [snapshot.controller] : []
                    if screen == "controllers" { driver.openControllers() }
                    let gamepad = LauncherGamepad(steam: nil, observeSystem: false, appIsActive: { false })
                    let view = ConsoleView(driver: driver, lang: lang, gamepad: gamepad,
                                           glyphs: .fallback(steamConnected: accepted))
                        .transaction { $0.disablesAnimations = true }.frame(width: 1280, height: 800)
                    let host = NSHostingView(rootView: view)
                    let window = OffscreenWindow(size: NSSize(width: 1280, height: 800), styleMask: [.borderless])
                    window.contentView = host
                    window.orderBack(nil)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                    host.layoutSubtreeIfNeeded()
                    let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to:
                        output.appendingPathComponent("\(screen)-\(accepted ? "after" : "before")-\(lang.code).png"))
                    window.orderOut(nil)
                    window.contentView = nil
                    window.close()
                    gamepad.deactivate()
                }
            }
        }
    }
}
