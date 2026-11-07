import XCTest
import SwiftUI
import AppKit
@testable import NX2Apple
import NXCore
@testable import NXModel
@testable import NXLauncher

/// The failed automatic-install recovery in every launcher language, without a connected device.
@MainActor final class ShellDataRecoveryCaptureTests: IsolatedDefaultsTestCase {
    func testRenderFailedTransferRecovery() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else {
            throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views")
        }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let stores = LauncherStores(defaults: testDefaults)
        let model = stores.build
        let title = "04007EF01F8AE000"
        model.target = "ios"
        model.failure = BuildFailure(kind: .shellDataIncomplete, gameName: nil)
        model.shellRetry = ("/fixture/DmGame.framework", title, "Fixture Game", "/fixture/games/" + title)
        model.revealItem = { _ in } // Capture the recovery instructions without opening Finder.
        model.copyWithFinder(oneGame: false)
        NSApplication.shared.setActivationPolicy(.accessory)
        for lang in Lang.all {
            stores.localizer.lang = lang
            let view = BuildFailureCard(m: model).environmentObject(stores.localizer)
                .padding(24).frame(width: 760).background(Color(white: 0.09)).environment(\.colorScheme, .dark)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.wantsLayer = true
            host.layer?.backgroundColor = NSColor(white: 0.09, alpha: 1).cgColor
            let window = OffscreenWindow(size: host.frame.size)
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("transfer-recovery-\(lang.code).png"))
            window.orderOut(nil)
        }
    }
}
