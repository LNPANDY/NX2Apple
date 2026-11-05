import XCTest
import SwiftUI
import AppKit
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
@testable import NXLauncher

/// Visual QA of Move cache folder, LNPANDY/NX2Apple#427 (matched by --filter testRenderShellCacheForVisualQA). The Tools card of the
/// release app in every state of the move. The states are set on the store, so nothing is moved and no folder is touched: the
/// cache row only reads the saved place, which the test restores.
final class ShellCacheCaptureTests: IsolatedDefaultsTestCase {
    @MainActor func testRenderShellCacheForVisualQA() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let lang = CaptureLanguage.current(.en)
        testDefaults.removeObject(forKey: "shellRoot")

        let stores = LauncherStores(defaults: testDefaults); let model = stores.build
        stores.localizer.lang = lang
        stores.engineSync.bundle = URL(fileURLWithPath: "/Applications/NX2Apple.app/Contents/Resources/engine")   // the release app's rows
        stores.engineSync.status = ""
        MainActor.assumeIsolated { stores.dependencies.checked = true }
        MainActor.assumeIsolated { stores.dependencies.deps = [Dep(id: "test", name: "Xcode", hint: "", present: true, installCmd: [])] }

        func shot(_ name: String) throws {
            let card = ToolsCard(repo: stores.repo, engine: stores.engineSync, dependencies: stores.dependencies, buildRunning: model.running,
                                 shellCache: { ShellCacheRow(build: model) }, builder: { ExperimentalBuilderRow(build: model) }) { DiagnosticsButton(report: { _, _ in }) }
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
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("cache-\(name)-\(lang.code).png"))
            window.orderOut(nil)
        }

        let home = NSHomeDirectory(), defaultRoot = ShellRootMigration.defaultRoot(home: home)
        let drive = "/Volumes/T7 Shield/Switch/NX2Apple-shell"
        try shot("0-default")

        model.shellMove = .confirm(ShellRootMove.Plan(source: defaultRoot, destination: drive, bytes: 23_400_000_000, free: 812_000_000_000,
                                                      sameVolume: false, sourceExists: true, problem: nil))
        try shot("1-confirm-other-drive")
        model.shellMove = .confirm(ShellRootMove.Plan(source: defaultRoot, destination: home + "/Games/NX2Apple-shell", bytes: 23_400_000_000,
                                                      free: 96_000_000_000, sameVolume: true, sourceExists: true, problem: nil))
        try shot("2-confirm-same-drive")
        model.shellMove = .confirm(ShellRootMove.Plan(source: defaultRoot, destination: drive, bytes: 23_400_000_000, free: 9_100_000_000,
                                                      sameVolume: false, sourceExists: true, problem: .noSpace(needed: 23_400_000_000, free: 9_100_000_000)))
        try shot("3-no-space")
        model.shellMove = .confirm(ShellRootMove.Plan(source: defaultRoot, destination: drive, bytes: 23_400_000_000, free: 812_000_000_000,
                                                      sameVolume: false, sourceExists: true, problem: nil))
        model.running = true
        try shot("4-build-running")
        model.shellMove = .moving(phase: .copying, done: 8_700_000_000, total: 23_400_000_000)
        try shot("5-copying")
        model.shellMove = .moving(phase: .checking, done: 17_900_000_000, total: 23_400_000_000)
        try shot("6-checking")
        model.running = false
        model.shellMove = .stopped(defaultRoot)
        try shot("7-stopped")
        model.shellMove = .failed("The disk “T7 Shield” was ejected", stays: defaultRoot)   // the store drops the system text's full stop
        try shot("8-failed")

        testDefaults.set(drive, forKey: "shellRoot")   // read only: the row shows the saved place
        model.shellMove = .moved(drive)
        try shot("9-moved")
        model.shellMove = .movedOldStays(drive, old: defaultRoot)
        try shot("10-moved-old-stays")
        model.shellMove = .idle
        try shot("11-custom-place")
        model.shellMove = .confirm(ShellRootMove.Plan(source: drive, destination: defaultRoot, bytes: 23_400_000_000, free: 96_000_000_000,
                                                      sameVolume: false, sourceExists: true, problem: nil))
        try shot("12-back-to-default")
    }
}
