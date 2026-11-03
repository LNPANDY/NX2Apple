import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher
@testable import NXModel

/// #336: Settings > Controls with its Home button row, as on macOS 27 and before it. Set NX_LAUNCHER_CAPTURE_DIR to keep the PNGs
/// (NX_CAPTURE_LANG picks the language).
@MainActor final class HomeButtonCaptureTests: XCTestCase {
    func testRenderControlsCard() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let lang = CaptureLanguage.current(.en)
        let stores = LauncherStores(); stores.localizer.lang = lang
        for (name, open) in [("controls-macos27", { } as (() -> Void)?), ("controls-macos26", nil)] {
            let card = ControlsCard(controlChanges: 0, padMerge: .constant(false), consolePrompt: .constant(true), startInConsole: .constant(false),
                                    onOpenControls: {}, onOpenControllers: {}, onOpenHomeSettings: open)
                .environmentObject(stores.localizer).environmentObject(PadFocus()).padding(24).frame(width: 760).background(LauncherPalette.background).preferredColorScheme(.dark)
            let host = NSHostingView(rootView: card)
            let window = OffscreenWindow(size: NSSize(width: 760, height: 700), styleMask: [.borderless])
            window.contentView = host
            window.orderBack(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            host.setFrameSize(host.fittingSize); host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(name)-\(lang.code).png"))
            window.orderOut(nil); window.contentView = nil; window.close()
        }
    }
}
