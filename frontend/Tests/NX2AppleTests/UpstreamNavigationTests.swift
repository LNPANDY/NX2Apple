import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
@testable import NXLauncher

@MainActor final class UpstreamNavigationTests: IsolatedDefaultsTestCase {
    func testEngineCardsSettingsChoicesAndMacOnlyTargetKeepControllerNavigation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldMNG = MacNativeGamesBuilder.featureEnabled, oldS2 = S2ArmBuilder.featureEnabled
        MacNativeGamesBuilder.featureEnabled = true; S2ArmBuilder.featureEnabled = true
        defer { MacNativeGamesBuilder.featureEnabled = oldMNG; S2ArmBuilder.featureEnabled = oldS2 }
        let stores = LauncherStores(defaults: testDefaults), pad = PadFocus()
        let build = stores.build
        let dropdowns = LauncherDropdownState()
        build.macNativeGamesPath = ""; build.s2armPath = ""; build.buildUpstream = .nxnative
        let window = OffscreenWindow(size: .init(width: 900, height: 500))
        defer { build.running = false; window.contentView = nil; window.orderOut(nil); window.close() }
        func host<V: View>(_ view: V) {
            window.contentView = NSHostingView(rootView: view.environmentObject(stores.localizer)
                .environmentObject(pad).padScope("main", pad).launcherDropdownHost(dropdowns, pad: pad))
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        host(EngineSwitcherCard(build: build))
        pad.show(default: "set.build.engine"); pad.activate()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(pad.scope, "engineDropdown")
        for id in ["nxnative", "download.macnativegames", "download.s2arm"] {
            XCTAssertNotNil(pad.frame(of: "set.build.engine." + id))
        }
        let current = try XCTUnwrap(pad.frame(of: "set.build.engine.nxnative"))
        for id in ["macnativegames", "s2arm"] {
            let download = try XCTUnwrap(pad.frame(of: "set.build.engine.download." + id))
            XCTAssertLessThan(download.maxY - current.minY, 260, "Engine dropdown rows must remain compact")
        }
        XCTAssertTrue(PadKeyboardInput.handle(125, focus: pad, back: dropdowns.close))
        XCTAssertEqual(pad.focused, "set.build.engine.download.macnativegames")
        pad.move(dx: 0, dy: -1)
        XCTAssertEqual(pad.focused, "set.build.engine.nxnative")
        dropdowns.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(pad.scope, "main")
        build.running = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(pad.frames["main", default: []].contains { $0.id.hasPrefix("set.build.engine.") })
        build.running = false
        for kind in [EngineUpstreamKind.macNativeGames, .s2arm] {
            let directory = root.appendingPathComponent(kind.rawValue)
            let markers = EngineUpstream.descriptor(for: kind).markerPaths + (kind == .s2arm ? [S2ArmBuilder.macOneClickScript] : [])
            for marker in markers {
                let file = directory.appendingPathComponent(marker)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: file)
            }
            if kind == .macNativeGames { build.macNativeGamesPath = directory.path }
            else { build.s2armPath = directory.path }
        }
        host(EngineSwitcherCard(build: build))
        pad.show(default: "set.build.engine"); pad.activate()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        pad.focused = "set.build.engine.macnativegames"; pad.activate()
        XCTAssertEqual(build.buildUpstream, .macNativeGames)
        XCTAssertEqual(build.target, BuildTarget.mac)
        host(TargetCard(build: build))
        XCTAssertNotNil(pad.frame(of: "set.build.target." + BuildTarget.mac))
        XCTAssertNil(pad.frame(of: "set.build.target.ios"))
        host(UpstreamBuilderRow(build: build))
        for id in ["set.upstream", "set.upstream.mngFolder", "set.upstream.s2armFolder"] {
            XCTAssertNotNil(pad.frame(of: id))
        }
        pad.focused = "set.upstream"; pad.horizontal(1)
        XCTAssertEqual(build.buildUpstream, .s2arm)
    }

    func testEngineDropdownScrollsCleanlyInShortWindow() throws {
        let oldMNG = MacNativeGamesBuilder.featureEnabled, oldS2 = S2ArmBuilder.featureEnabled
        MacNativeGamesBuilder.featureEnabled = true; S2ArmBuilder.featureEnabled = true
        defer { MacNativeGamesBuilder.featureEnabled = oldMNG; S2ArmBuilder.featureEnabled = oldS2 }
        let stores = LauncherStores(defaults: testDefaults), pad = PadFocus()
        let dropdowns = LauncherDropdownState()
        let window = OffscreenWindow(size: .init(width: 900, height: 240))
        defer { window.contentView = nil; window.orderOut(nil); window.close() }
        window.contentView = NSHostingView(rootView: EngineSwitcherCard(build: stores.build)
            .environmentObject(stores.localizer)
            .environmentObject(pad)
            .padScope("main", pad)
            .launcherDropdownHost(dropdowns, pad: pad))
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        pad.show(default: "set.build.engine"); pad.activate()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(pad.scope, "engineDropdown")
        XCTAssertNotNil(pad.frame(of: "set.build.engine.nxnative"))
        dropdowns.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(pad.scope, "main")
    }
}
