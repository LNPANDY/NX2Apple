import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
import NXCore
import NXModel

@MainActor final class RunningBuildPageTests: IsolatedDefaultsTestCase {
    private func texts(in view: NSView, pressing button: String? = nil) -> Set<String> {
        var labels: Set<String> = []
        var action: NSObject?
        let press = NSSelectorFromString("accessibilityPerformPress")
        func visit(_ node: NSObject) {
            for selector in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                let sel = NSSelectorFromString(selector)
                if node.responds(to: sel), let value = node.perform(sel)?.takeUnretainedValue() as? String {
                    labels.insert(value)
                    if value == button && node.responds(to: press) { action = node }
                }
            }
            let children = NSSelectorFromString("accessibilityChildren")
            if node.responds(to: children), let next = node.perform(children)?.takeUnretainedValue() as? [NSObject] {
                next.forEach(visit)
            }
        }
        visit(view.window ?? view)
        if let button {
            XCTAssertNotNil(action, "\(button) in \(labels.sorted())")
            _ = action?.perform(press)
        }
        return labels
    }

    func testRunningBuildPageAndOtherPages() throws {
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApplication.shared.accessibilityAttributeValue(enhanced)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApplication.shared.accessibilitySetValue(previous ?? false, forAttribute: enhanced) }
        let stores = LauncherStores(localizer: Localizer(.en), defaults: testDefaults)
        let build = stores.build
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent(EngineLayout.marker)
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: marker)
        stores.repo.path = directory.path
        stores.dependencies.checked = true
        stores.dependencies.deps = [Dep(id: "xcode", name: "Xcode", hint: "", present: true, installCmd: [])]
        stores.deviceStore.checked = true
        build.target = BuildTarget.mac
        build.outDir = "/Volumes/Games"
        let package = directory.appendingPathComponent("Marble Orchard [0100000000010000].nsp")
        let keys = directory.appendingPathComponent("prod.keys")
        try Data().write(to: package)
        try Data().write(to: keys)
        build.updateSlot("base") { $0.paths = [package.path] }
        build.updateSlot("keys") { $0.paths = [keys.path] }
        build.running = true
        build.stages = [Stage(id: 1, name: "Shaders", state: .running, detail: "20 / 50", percent: 40)]
        let library = GameLibrary(file: directory.appendingPathComponent("library.json"))
        let window = OffscreenWindow(size: NSSize(width: 1050, height: 850))
        defer { window.orderOut(nil) }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.16)) }
        func show(_ page: LauncherPage) -> NSView {
            let view = LauncherView(stores: stores, library: library, initialPage: page, performStartupChecks: false)
            let host = NSHostingView(rootView: view)
            window.contentView = host
            window.orderFront(nil)
            settle()
            return host
        }
        let host = show(.builds)
        if let folder = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] {
            let output = URL(fileURLWithPath: folder)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for lang in Lang.all {
                stores.localizer.lang = lang
                build.stages = [Stage(id: 1, name: stores.localizer.t("stage.mac_shaders"), state: .running, detail: "20 / 50", percent: 40)]
                settle()
                host.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(lang.code + ".png"))
            }
            stores.localizer.lang = .en
            settle()
        }
        let running = texts(in: host)
        XCTAssertFalse(running.contains(build.t("section.files")))
        XCTAssertFalse(running.contains(build.t("section.target")))
        XCTAssertFalse(running.contains(build.t("library.viewBuild")))
        XCTAssertTrue(running.contains(build.t("section.progress")), "\(running.sorted())")
        XCTAssertTrue(running.contains(build.t("btn.stop")))
        XCTAssertTrue(running.contains(build.t("section.log")))
        _ = texts(in: host, pressing: build.t("section.setup"))
        settle()
        XCTAssertTrue(texts(in: host).contains(build.t("section.files")))
        _ = texts(in: host, pressing: build.t("section.setup"))
        settle()
        XCTAssertFalse(texts(in: host).contains(build.t("section.files")))
        build.stages[0].isScanningLastShaderFiles = true
        settle()
        XCTAssertTrue(texts(in: host).contains(build.t("prog.lastShaderFiles")))
        build.target = BuildTarget.ios
        stores.deviceStore.exportIPA = true
        stores.deviceStore.sendWhere = SendWhere.drive
        build.send = .copying(done: 1, total: 2)
        settle()
        XCTAssertTrue(texts(in: host).contains(build.t("dev.section")), "an active transfer stays available")
        build.running = false
        build.doneNote = build.t("msg.stopped")
        settle()
        XCTAssertTrue(texts(in: host).contains(build.t("section.files")))
        build.running = true
        settle()
        XCTAssertFalse(texts(in: host).contains(build.t("section.target")))
        build.running = false
        build.failure = BuildFailure(kind: .cloudFolder, gameName: nil)
        settle()
        XCTAssertTrue(texts(in: host).contains(build.t("section.target")))
        build.running = true
        let settings = show(.settings)
        XCTAssertTrue(texts(in: settings).contains(build.t("library.viewBuild")))
        _ = texts(in: settings, pressing: build.t("library.viewBuild"))
        settle()
        XCTAssertFalse(texts(in: settings).contains(build.t("library.viewBuild")))
        XCTAssertTrue(texts(in: settings).contains(build.t("section.progress")))
        XCTAssertTrue(texts(in: show(.library)).contains(build.t("library.viewBuild")))
    }
}
