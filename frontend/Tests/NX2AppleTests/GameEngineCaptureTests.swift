import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
import NXLauncher

/// The build card's optional files with the game engine file row (LNPANDY/NX2Apple#626): none chosen, and one chosen for the base
/// game. A stand-in archive (a manifest only, no engine file) and an empty base game file: no game data.
@MainActor final class GameEngineCaptureTests: IsolatedDefaultsTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-engine-file-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    // MARK: Visual QA (matched by --filter testRenderLauncherForVisualQA)

    @MainActor func testRenderLauncherForVisualQAGameEngineFile() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        let stores = LauncherStores(defaults: testDefaults); let model = stores.build
        model.lang = CaptureLanguage.current(.en)
        model.outDir = ""   // the default place, not a folder of this Mac
        model.gameEngines = [:]   // not the archives this Mac keeps
        let tid = "0100D59022590000"
        let base = temporary.appendingPathComponent("Scott Pilgrim EX [\(tid)].nsp")
        try Data([0]).write(to: base)
        model.slots[0].paths = [base.path]
        func capture(_ name: String) throws {
            let card = FilesCard(build: model, extrasOpen: .constant(true))
                .environmentObject(stores.localizer)
                .padding(24).frame(width: 960)
                .background(LauncherPalette.background)
                .preferredColorScheme(.dark)
            let host = NSHostingView(rootView: card)
            let window = OffscreenWindow(size: host.fittingSize, styleMask: [.titled, .closable, .resizable])
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
            window.orderOut(nil)
        }
        try capture("build-engine-file-none")
        let manifest = GameArchive.Manifest(titleID: tid, name: "Scott Pilgrim EX", updates: [65536],
                                            base: .init(commit: "c", remote: "r", pin: "641d1480021a", engineID: "641d1480021a-58e5b33e2be5"),
                                            patched: ["dm/host/hle.c"], author: "AmperageOverspend")
        model.gameEngines = [tid: .init(titleID: tid, sha256: String(repeating: "0", count: 64), folder: temporary.path, manifest: manifest)]
        try capture("build-engine-file-chosen")
    }
}
