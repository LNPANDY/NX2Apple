import XCTest
import SwiftUI
import AppKit
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
@testable import NXLauncher

/// Visual QA of the engine update row when Experimental is not ahead of Stable, LNPANDY/NX2Apple#1095 (matched by
/// --filter testRenderEngineChannelForVisualQA). The Tools card of the release app. The standing is set on the store, so nothing
/// is fetched and nothing is installed.
final class EngineChannelCaptureTests: IsolatedDefaultsTestCase {
    @MainActor func testRenderEngineChannelForVisualQA() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let lang = CaptureLanguage.current(.en)

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
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("engine-\(name)-\(lang.code).png"))
            window.orderOut(nil)
        }

        stores.engineSync.selection.channel = .stable
        stores.engineSync.setStanding(.unknown)
        try shot("0-stable-as-before")
        stores.engineSync.setStanding(.notAhead)
        try shot("1-stable-experimental-not-ahead")
        stores.engineSync.selection.channel = .experimental
        stores.engineSync.setStanding(.unknown)
        try shot("2-experimental-as-before")
        stores.engineSync.setStanding(.notAhead)
        try shot("3-experimental-back-to-stable")
    }
}
