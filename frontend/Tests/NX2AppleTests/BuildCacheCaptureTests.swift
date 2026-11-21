import XCTest
import SwiftUI
import AppKit
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
@testable import NXLauncher

/// Visual QA of the nxkit work folder and build seeds rows (Settings, Tools, under the shell cache; matched by
/// --filter testRenderBuildCacheRowsForVisualQA). The whole Tools card in four states. Every path is fake and the defaults are the
/// test suite's, so nothing is moved and no real folder is touched. The drives are folders of a temp directory.
final class BuildCacheCaptureTests: IsolatedDefaultsTestCase {
    @MainActor func testRenderBuildCacheRowsForVisualQA() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let lang = CaptureLanguage.current(.en)
        for key in ["shellRoot", BuildCacheRoots.nxkitKey, BuildCacheRoots.seedKey] { testDefaults.removeObject(forKey: key) }

        // the connected drive "External" exists under this fake /Volumes, "Gone" does not
        let volumes = FileManager.default.temporaryDirectory.appendingPathComponent("capture-volumes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: volumes.appendingPathComponent("External"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: volumes) }

        let stores = LauncherStores(volumesRoot: volumes.path, defaults: testDefaults); let model = stores.build
        model.launcherEnvironment = [:]   // no DM_SEED_CACHE_DIR of this Mac
        stores.localizer.lang = lang
        stores.engineSync.bundle = URL(fileURLWithPath: "/Applications/NX2Apple.app/Contents/Resources/engine")
        stores.engineSync.status = ""
        MainActor.assumeIsolated { stores.dependencies.checked = true }
        MainActor.assumeIsolated { stores.dependencies.deps = [Dep(id: "test", name: "Xcode", hint: "", present: true, installCmd: [])] }

        func shot(_ name: String) throws {
            let card = ToolsCard(repo: stores.repo, engine: stores.engineSync, dependencies: stores.dependencies, buildRunning: model.running,
                                 shellCache: { ShellCacheRow(build: model); BuildCacheRows(build: model) }, builder: { EmptyView() }) { DiagnosticsButton(report: { _, _ in }) }
            let framed = card.environmentObject(stores.localizer).environmentObject(PadFocus()).padding(24).frame(width: 860).background(Color(white: 0.09)).environment(\.colorScheme, .dark)
            NSApplication.shared.setActivationPolicy(.accessory)
            let host = NSHostingView(rootView: framed)
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
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("build-cache-\(name)-\(lang.code).png"))
            window.orderOut(nil)
        }

        let home = model.home
        let nxkitDefault = BuildCacheRoots.defaultNxkitRoot(home: home)
        let external = volumes.appendingPathComponent("External").path
        try shot("0-default")

        testDefaults.set(external + "/NX2Apple-nxkit", forKey: BuildCacheRoots.nxkitKey)
        testDefaults.set(external + "/NX2Apple-build-seeds/build-seeds", forKey: BuildCacheRoots.seedKey)
        try shot("1-moved")

        testDefaults.set(volumes.path + "/Gone/NX2Apple-nxkit", forKey: BuildCacheRoots.nxkitKey)
        testDefaults.removeObject(forKey: BuildCacheRoots.seedKey)
        try shot("2-drive-not-connected")

        testDefaults.removeObject(forKey: BuildCacheRoots.nxkitKey)
        model.nxkitMove = .confirm(ShellRootMove.Plan(source: nxkitDefault, destination: external + "/NX2Apple-nxkit", bytes: 41_800_000_000,
                                                        free: 812_000_000_000, sameVolume: false, sourceExists: true, problem: nil))
        try shot("3-confirm-nxkit-other-drive")
    }
}

