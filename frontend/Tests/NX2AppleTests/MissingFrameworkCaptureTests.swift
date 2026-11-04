import XCTest
import SwiftUI
import AppKit
@testable import NX2Apple
@testable import NXCore
import NXModel
@testable import NXLauncher

/// Visual QA of the missing-framework message (LNPANDY/NX2Apple#491, matched by --filter testRenderMissingFrameworkForVisualQA).
/// The Builds page's action card with the note a handoff leaves when the game's framework is not in the build folder.
final class MissingFrameworkCaptureTests: IsolatedDefaultsTestCase {
    @MainActor func testRenderMissingFrameworkForVisualQA() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let lang = ProcessInfo.processInfo.environment["NX_CAPTURE_LANG"].flatMap { Lang.find($0) } ?? .en
        let stores = LauncherStores(defaults: testDefaults); let model = stores.build
        stores.localizer.lang = lang
        var installer = ShellInstaller(xcrun: "/usr/bin/xcrun", repo: "/nonexistent", python: "/usr/bin/python3", root: "/nonexistent",
                                       device: "", team: "")
        installer.lang = lang
        let missing = "/Users/me/Library/Application Support/NX2Apple/builds/Super Mario Odyssey/shell-framework/DmGame0100000000010000.framework"
        // NX_CAPTURE_NOTE puts a note of the old wording into the card for the "before" image
        model.doneNote = ProcessInfo.processInfo.environment["NX_CAPTURE_NOTE"]
            ?? installer.export(framework: missing, titleID: "0100000000010000", name: "Super Mario Odyssey").message
        let card = ActionCard(build: model, dependencies: stores.dependencies, repo: stores.repo)
            .environmentObject(stores.localizer).padding(24).frame(width: 760)
            .background(Color(white: 0.09)).environment(\.colorScheme, .dark)
        NSApplication.shared.setActivationPolicy(.accessory)
        let host = NSHostingView(rootView: card)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor(white: 0.09, alpha: 1).cgColor
        let window = OffscreenWindow(size: host.frame.size)
        window.contentView = host
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let name = ProcessInfo.processInfo.environment["NX_CAPTURE_NAME"] ?? "missing-framework"
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(name)-\(lang.code).png"))
        window.orderOut(nil)
    }
}
