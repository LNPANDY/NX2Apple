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

    private func wait(in view: NSView, for visible: [String], without hidden: [String] = [],
                      file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while true {
            view.layoutSubtreeIfNeeded()
            let actual = texts(in: view)
            if actual.isSuperset(of: visible) && actual.isDisjoint(with: hidden) { return }
            if Date() >= deadline {
                XCTFail("Missing \(Set(visible).subtracting(actual)), still visible \(actual.intersection(hidden))", file: file, line: line)
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func withLauncher(on page: LauncherPage, _ check: (LauncherStores, NSView) throws -> Void) throws {
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
        let view = LauncherView(stores: stores, library: library, initialPage: page, performStartupChecks: false)
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.orderFront(nil)
        try check(stores, host)
    }

    func testRunningSetupAnnouncesItsStateAndRevealsTheInputs() throws {
        try withLauncher(on: .builds) { stores, host in
            let build = stores.build
            let setup = build.t("section.setup"), files = build.t("section.files"), target = build.t("section.target")
            let collapsed = build.t("onboarding.collapsed"), expanded = build.t("onboarding.expanded")
            wait(in: host, for: [setup, build.gameName + ", " + collapsed, build.t("section.progress"),
                                 build.t("btn.stop"), build.t("section.log")], without: [files, target, build.t("library.viewBuild")])
            _ = texts(in: host, pressing: setup)
            wait(in: host, for: [files, target, build.gameName + ", " + expanded])
            _ = texts(in: host, pressing: setup)
            wait(in: host, for: [build.gameName + ", " + collapsed], without: [files, target])
        }
    }

    func testRunningProgressShowsTheFinalShaderScanAndAnActiveTransfer() throws {
        try withLauncher(on: .builds) { stores, host in
            let build = stores.build
            build.stages[0].isScanningLastShaderFiles = true
            wait(in: host, for: [build.t("prog.lastShaderFiles")])
            build.target = BuildTarget.ios
            stores.deviceStore.exportIPA = true
            stores.deviceStore.sendWhere = SendWhere.drive
            build.send = .copying(done: 1, total: 2)
            wait(in: host, for: [build.t("dev.section")])
        }
    }

    func testShaderRebuildNoticeKeepsProgressAndStopVisibleWithoutADialog() throws {
        try withLauncher(on: .builds) { stores, host in
            let build = stores.build
            build.ingest("{\"ev\":\"shaders_stale\",\"reason\":\"chain\"}\n{\"ev\":\"progress\",\"k\":1,\"name\":\"mac shaders\",\"frac\":0.5,\"done\":25,\"total\":50}\n")
            XCTAssertNil(NSApp.modalWindow)
            wait(in: host, for: [build.t("msg.shadersStale.title"), build.t("msg.shadersStale.chain"),
                                 build.t("btn.stop"), "50%"])
            XCTAssertTrue(build.running)
            stores.localizer.lang = .de
            wait(in: host, for: [build.t("msg.shadersStale.title"), build.t("msg.shadersStale.chain"), build.t("btn.stop")])
        }
    }

    func testStoppingOrFailingRestoresTheSetupCards() throws {
        try withLauncher(on: .builds) { stores, host in
            let build = stores.build
            let files = build.t("section.files"), target = build.t("section.target"), setup = build.t("section.setup")
            wait(in: host, for: [setup], without: [files, target])
            build.running = false
            build.doneNote = build.t("msg.stopped")
            wait(in: host, for: [files, target], without: [setup])
            build.running = true
            wait(in: host, for: [setup], without: [files, target])
            build.running = false
            build.failure = BuildFailure(kind: .cloudFolder, gameName: nil)
            wait(in: host, for: [files, target], without: [setup])
        }
    }

    func testLibraryAndSettingsCanReturnToBuildsWithoutRepeatingTheActivityBar() throws {
        for page in [LauncherPage.library, .settings] {
            try withLauncher(on: page) { stores, host in
                let viewBuild = stores.build.t("library.viewBuild")
                wait(in: host, for: [viewBuild])
                _ = texts(in: host, pressing: viewBuild)
                wait(in: host, for: [stores.build.t("section.progress")], without: [viewBuild])
            }
        }
    }

    func testCaptureRunningBuilds() throws {
        guard let folder = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else {
            throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture the running Builds page")
        }
        let output = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try withLauncher(on: .builds) { stores, host in
            for lang in Lang.all {
                stores.localizer.lang = lang
                let stage = stores.localizer.t("stage.mac_shaders")
                stores.build.stages = [Stage(id: 1, name: stage, state: .running, detail: "20 / 50", percent: 40)]
                wait(in: host, for: [stores.localizer.t("build.heading"), stage])
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(lang.code + ".png"))
            }
        }
    }

    func testCaptureShaderRebuildNotice() throws {
        guard let folder = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else {
            throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture the shader notice")
        }
        let output = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try withLauncher(on: .builds) { stores, host in
            stores.build.ingest("{\"ev\":\"shaders_stale\",\"reason\":\"chain\"}\n")
            for lang in Lang.all {
                stores.localizer.lang = lang
                let stage = stores.localizer.t("stage.mac_shaders")
                stores.build.stages = [Stage(id: 1, name: stage, state: .running, detail: "20 / 50", percent: 40)]
                wait(in: host, for: [stores.localizer.t("msg.shadersStale.chain"), stage])
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                    .write(to: output.appendingPathComponent("after-\(lang.code).png"))
            }
        }
    }
}
