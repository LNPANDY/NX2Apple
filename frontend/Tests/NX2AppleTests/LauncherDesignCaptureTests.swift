import XCTest
import SwiftUI
import AppKit
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher
import NXModel

/// Opt-in renders of every GalleryScene at 1280 x 800 for the design review of LNPANDY/NX2Apple#1458, one PNG per scene.
/// `NX_LAUNCHER_CAPTURE_DIR=<dir> swift test --filter LauncherDesignCaptureTests`, `NX_CAPTURE_LANG=de` for another language.
@MainActor final class LauncherDesignCaptureTests: IsolatedDefaultsTestCase {
    func testRenderDesignScenes() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        let lang = CaptureLanguage.current(.en)
        let fixtures = GalleryFixtures(lang: lang)
        let size = NSSize(width: GalleryScene.size.width, height: GalleryScene.size.height)
        for scene in GalleryScene.allCases {
            let host = NSHostingView(rootView: fixtures.view(scene))
            let window = OffscreenWindow(size: size, styleMask: [.titled, .closable, .resizable, .fullSizeContentView])
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(scene.rawValue)-\(lang.code).png"))
            window.orderOut(nil); window.contentView = nil; window.close()
        }
    }
}
