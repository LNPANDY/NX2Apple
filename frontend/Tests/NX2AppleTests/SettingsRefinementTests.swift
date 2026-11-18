import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
@testable import NXLauncher

@MainActor final class SettingsRefinementTests: IsolatedDefaultsTestCase {
    private struct WaitingRelease: ReleaseSource {
        func latestRelease() async -> Data? { try? await Task.sleep(nanoseconds: 800_000_000); return nil }
        func download(_ url: URL, to file: URL) async -> Bool { false }
    }

    func testBusyUpdateKeepsItsControllerTargetUntilCompletion() throws {
        let stores = LauncherStores(defaults: TestDefaults.make("settings.busy"))
        let updates = AppUpdateStore(localizer: stores.localizer, runner: SystemProcessRunner(), releases: WaitingRelease(), defaults: TestDefaults.make("settings.busy.updater"))
        let focus = PadFocus()
        let host = NSHostingView(rootView: AppCard(updates: updates, buildRunning: false, notify: .constant(true), notifyAvailable: true,
            returnAfterPlay: .constant(true), preflightAfterBuild: .constant(true), onRunSetup: nil,
            uninstallPlan: { Uninstall.plan(home: "/tmp/unused-settings-test", gamesFolder: "", outputFolder: "", checkouts: [], defaultsDomain: nil) }, part: .updates)
            .environmentObject(stores.localizer).environmentObject(focus).padScope("main", focus))
        let window = OffscreenWindow(size: .init(width: 900, height: 400))
        window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.orderOut(nil); window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        focus.focused = "set.appCheck"; focus.show(default: nil)
        updates.checkForUpdate()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(updates.busy)
        XCTAssertNotNil(focus.frame(of: "set.appCheck"))
        XCTAssertEqual(focus.focused, "set.appCheck")
        focus.activate()
        XCTAssertTrue(updates.busy, "busy target has no operation")
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertFalse(updates.busy)
        XCTAssertNotNil(focus.frame(of: "set.appCheck"))
    }

    func testEngineInstallCompletionMovesFocusToCheck() {
        let stores = LauncherStores(defaults: TestDefaults.make("settings.engine.focus"))
        stores.engineSync.bundle = URL(fileURLWithPath: "/tmp/unused-settings-engine")
        let engine = EngineUpdate.Engine(id: String(repeating: "b", count: 40), version: "9.0")
        stores.engineSync.applyOutcome(.available(engine), channel: .stable, quiet: false)
        let focus = PadFocus()
        let host = NSHostingView(rootView: ToolsCard(repo: stores.repo, engine: stores.engineSync, dependencies: stores.dependencies, buildRunning: false,
            shellCache: { EmptyView() }, builder: { EmptyView() }, diagnostics: { EmptyView() })
            .environmentObject(stores.localizer).environmentObject(focus).padScope("main", focus))
        let window = OffscreenWindow(size: .init(width: 1000, height: 1400))
        window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.orderOut(nil); window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNotNil(focus.frame(of: "set.engineInstall"))
        focus.focused = "set.engineInstall"; focus.show(default: nil)
        stores.engineSync.applyOutcome(.current(engine), channel: .stable, quiet: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNil(focus.frame(of: "set.engineInstall"))
        XCTAssertEqual(focus.focused, "set.engineCheck")
        XCTAssertNotNil(focus.frame(of: "set.engineCheck"))
    }

    func testRowHeightIsScopedAndUpdateActionFootprintDoesNotChangeWithState() {
        for settings in [false, true] {
            let host = NSHostingView(rootView: CardRow("Example") { Text("Value") }
                .environment(\.launcherSettingsLayout, settings).frame(width: 700))
            XCTAssertEqual(host.fittingSize.height, settings ? 64 : 52, accuracy: 0.5)
        }
        for lang in Lang.all {
            for key in ["repo.check", "settings.update.checking", "settings.update.preparing", "settings.update.downloading", "settings.update.install", "app.restartNow"] {
                for primary in [false, true] {
                    let text = String(format: L10n.string(key, lang), 100)
                    let host = NSHostingView(rootView: SettingsUpdateAction(text, busy: !primary, prominent: primary, action: {}))
                    XCTAssertEqual(host.fittingSize.width, LauncherControl.width, accuracy: 0.5, "\(lang) \(key)")
                    XCTAssertEqual(host.fittingSize.height, 36, accuracy: 0.5)
                }
            }
        }
    }

    func testSettingsCategoriesInBothAppearancesAndSupplementaryHelpOwnsFocus() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent(EngineLayout.marker)
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: marker)
        for dark in [false, true] {
            for category in SettingsCategory.allCases {
                let stores = LauncherStores(defaults: TestDefaults.make("settings.refinement"))
                stores.repo.path = root.path
                stores.dependencies.checked = true
                stores.dependencies.deps = [Dep(id: "xcode", name: "dep.xcode", hint: "", present: true, installCmd: [])]
                let focus = PadFocus()
                let library = GameLibrary(file: root.appendingPathComponent("library.json"))
                let page = SettingsPage(build: stores.build, updates: stores.appUpdates, repo: stores.repo,
                    engine: stores.engineSync, dependencies: stores.dependencies, library: library,
                    players: stores.players, sticks: stores.sticks, saveSettings: stores.saveSettings,
                    onRunSetup: {}, category: .constant(category))
                    .environmentObject(stores.localizer).environmentObject(focus).padScope("main", focus)
                    .background(LauncherPalette.background)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: page)
                let window = OffscreenWindow(size: .init(width: 1000, height: 1400))
                window.contentView = host; window.orderFront(nil)
                defer { window.contentView = nil; window.orderOut(nil); window.close() }
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                XCTAssertNotNil(focus.frame(of: "set.category"))
                if category == .general {
                    XCTAssertNotNil(focus.frame(of: "set.display"), "incoming display choice keeps controller navigation")
                }
                if category == .controls {
                    focus.focused = "set.padMerge.help"; focus.show(default: nil); focus.activate()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                    XCTAssertEqual(focus.scope, "set.padMerge.help.popover")
                    XCTAssertTrue(focus.cancel())
                    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                    XCTAssertEqual(focus.scope, "main")
                    XCTAssertEqual(focus.focused, "set.padMerge.help")
                }
                if let path = ProcessInfo.processInfo.environment["NX_SETTINGS_CAPTURE_DIR"] {
                    let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let directory = URL(fileURLWithPath: path)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("settings-\(category.rawValue)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }
}
