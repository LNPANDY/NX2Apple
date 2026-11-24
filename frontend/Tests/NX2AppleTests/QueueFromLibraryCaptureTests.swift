import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
import NXLauncher

/// Visual QA of LNPANDY/NX2Apple#1112 (matched by --filter testRenderQueueFromLibraryForVisualQA): the library while another game
/// builds, its selected game not built, then the same game once it is in the build queue. The game is a stand-in file in a temporary
/// folder: no key, no game data, and no build runs.
final class QueueFromLibraryCaptureTests: IsolatedDefaultsTestCase {
    @MainActor func testRenderQueueFromLibraryForVisualQA() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = NSTemporaryDirectory() + "queue-from-library-capture-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: root) }
        let nsp = root + "/Games/Sample Game [0100000000010000][v0].nsp"
        try FileManager.default.createDirectory(atPath: (nsp as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: nsp, contents: Data())
        NSApplication.shared.setActivationPolicy(.accessory)
        let lang = CaptureLanguage.current(.en)
        let wasStatic = LauncherGlass.forceStatic
        LauncherGlass.forceStatic = true
        defer { LauncherGlass.forceStatic = wasStatic }

        func shot(_ name: String, queued: Bool) throws {
            let stores = LauncherStores(defaults: testDefaults)
            stores.build.lang = lang
            stores.dependencies.checked = true
            stores.dependencies.deps = [Dep(id: "test", name: "Xcode", hint: "", present: true, installCmd: [])]
            stores.build.running = true   // another game builds
            let library = GameLibrary(file: URL(fileURLWithPath: root + "/library-\(name).json"))
            var game = LibraryGame(titleID: "0100000000010000", name: "Sample Game")
            game.inputs["base"] = [nsp]
            library.upsert(game)
            library.selectedID = game.id
            if queued {
                stores.queue.enqueue([QueueEntry(game: game, engineID: stores.engineSync.selection.engineID, target: stores.build.target,
                                                 batch: UUID(), packageAfter: false)])
            }
            let host = NSHostingView(rootView: LauncherView(stores: stores, library: library, initialPage: .library, performStartupChecks: false))
            let window = OffscreenWindow(size: NSSize(width: 1280, height: 800), styleMask: [.titled, .closable, .resizable, .fullSizeContentView])
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("queue-\(name)-\(lang.code).png"))
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            stores.queue.cancelQueued()
            stores.build.running = false
        }

        try shot("0-during-build", queued: false)
        try shot("1-queued", queued: true)
    }
}
