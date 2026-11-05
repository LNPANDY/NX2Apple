import XCTest
import SwiftUI
import AppKit
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
@testable import NXLauncher

/// Visual QA of the experimental builder setting, LNPANDY/NX2Apple#749 (matched by --filter testRenderExperimentalBuilderForVisualQA). The Tools card of the
/// release app and of a checkout: the switch off, on with an nxb found, and on without one. The nxb is a stand-in file in a temporary folder.
final class ExperimentalBuilderCaptureTests: IsolatedDefaultsTestCase {
    @MainActor func testRenderExperimentalBuilderForVisualQA() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let lang = CaptureLanguage.current(.en)
        let folder = NSTemporaryDirectory() + "nxbuild-capture-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let nxb = folder + "/nxb"
        FileManager.default.createFile(atPath: nxb, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])

        let stores = LauncherStores(defaults: testDefaults); let model = stores.build
        stores.localizer.lang = lang
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
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("builder-\(name)-\(lang.code).png"))
            window.orderOut(nil)
        }

        stores.engineSync.bundle = URL(fileURLWithPath: "/Applications/NX2Apple.app/Contents/Resources/engine")   // the release app's rows
        model.experimentalBuilder = false
        try shot("release-0-off")
        model.experimentalBuilder = true; model.experimentalBuilderPath = nxb
        try shot("release-1-on")
        model.experimentalBuilderPath = folder + "/gone/nxb"
        try shot("release-2-not-found")
        stores.engineSync.bundle = nil   // a checkout's rows
        model.experimentalBuilder = false
        try shot("checkout-0-off")
        model.experimentalBuilder = true; model.experimentalBuilderPath = nxb
        try shot("checkout-1-on")
    }
}
