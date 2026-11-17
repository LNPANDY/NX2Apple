import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
import NXLauncher

/// Visual QA of the Build files row on the Builds page (BuildStore+BuildFiles.swift), matched by --filter
/// testRenderBuildFilesForVisualQA: no folder chosen, a folder chosen, and a folder on a drive that is not connected. The game is a
/// stand-in file in a temporary folder: no key, no game data.
final class BuildFilesCaptureTests: IsolatedDefaultsTestCase {
    @MainActor func testRenderBuildFilesForVisualQA() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = NSTemporaryDirectory() + "build-files-capture-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: root) }
        let game = root + "/Games/Sample Game [0100000000010000][v0].nsp"
        try FileManager.default.createDirectory(atPath: (game as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: game, contents: Data())
        NSApplication.shared.setActivationPolicy(.accessory)
        let lang = CaptureLanguage.current(.en)

        func shot(_ name: String, _ setUp: (BuildStore) -> Void) throws {
            let stores = LauncherStores(defaults: testDefaults); let model = stores.build
            model.lang = lang
            MainActor.assumeIsolated { stores.dependencies.checked = true }
            MainActor.assumeIsolated { stores.dependencies.deps = [Dep(id: "test", name: "Xcode", hint: "", present: true, installCmd: [])] }
            model.take(picked: [game], kind: .base)
            model.gameDir = "/Users/Shared/Switch"
            model.outDir = "/Users/Shared/Games"
            setUp(model)
            let library = GameLibrary(file: URL(fileURLWithPath: root + "/preview.json"))
            let host = NSHostingView(rootView: LauncherView(stores: stores, library: library, initialPage: .builds, initialBuildEditorOpen: true, performStartupChecks: false))
            let window = OffscreenWindow(size: NSSize(width: 1440, height: 1800), styleMask: [.titled, .closable, .resizable])
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("build-files-\(name)-\(lang.code).png"))
            window.orderOut(nil)
        }

        try shot("0-default") { $0.buildFilesFolder = "" }
        try shot("1-chosen") { $0.buildFilesFolder = "/Users/Shared/Switch Builds" }
        // A /Volumes folder that is no mount point counts as a drive that is not connected (BuildFilesFolder.driveMissing).
        try shot("2-drive-offline") { $0.buildFilesFolder = "/Volumes/External/Switch/Builds" }
        LauncherStores(defaults: testDefaults).build.buildFilesFolder = ""
    }
}
