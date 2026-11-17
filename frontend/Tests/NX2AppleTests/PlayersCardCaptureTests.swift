import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher
@testable import NXModel

/// Visual QA of Settings > Library > Players, whose note says that games show the player's name (#1128). Matched by --filter
/// testRenderPlayersCardForVisualQA; NX_CAPTURE_LANG picks the language.
final class PlayersCardCaptureTests: IsolatedDefaultsTestCase {
    @MainActor func testRenderPlayersCardForVisualQA() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        let lang = CaptureLanguage.current(.en)
        let loc = Localizer(lang)
        let players = PlayerProfileStore(defaults: testDefaults) { loc.t("players.default") }
        players.rename(PlayerProfile.defaultID, to: "Bartek")
        players.create(name: "Ana")
        let view = VStack { PlayersCard(players: players).environmentObject(loc) }
            .padding(24).frame(width: 760).background(LauncherPalette.background)
        let host = NSHostingView(rootView: view)
        let window = OffscreenWindow(size: NSSize(width: 760, height: 360), styleMask: [.titled, .closable, .resizable])
        window.contentView = host
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("players-card-\(lang.code).png"))
        window.orderOut(nil)
    }
}
