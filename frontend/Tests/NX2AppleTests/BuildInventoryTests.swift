import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
@testable import NXLauncher

@MainActor final class BuildInventoryTests: IsolatedDefaultsTestCase {
    func testArtifactFiltersDoNotTreatRecordedDeviceAsAnExistingBuild() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var game = LibraryGame(titleID: "0100000000000000", name: "Test")
        game.installedDevice = "Test device"
        let missing = BuildInventoryEntry(game)
        XCTAssertTrue(BuildInventoryFilter.notBuilt.includes(missing))
        XCTAssertFalse(BuildInventoryFilter.built.includes(missing))
        let ipa = directory.appendingPathComponent("game.ipa")
        try Data().write(to: ipa)
        game.ipaPath = ipa.path
        let exported = BuildInventoryEntry(game)
        XCTAssertEqual(exported.mobile, .ipa)
        XCTAssertTrue(BuildInventoryFilter.built.includes(exported))
        XCTAssertFalse(BuildInventoryFilter.notBuilt.includes(exported))
        XCTAssertTrue(BuildInventoryFilter.owned.includes(exported))
    }

    func testHubActionsOpenBuilderAndBackKeepsDraft() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = LauncherStores(defaults: testDefaults)
        let marker = directory.appendingPathComponent(EngineLayout.marker)
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: marker)
        stores.repo.path = directory.path
        stores.dependencies.checked = true
        stores.dependencies.deps = [Dep(id: "xcode", name: "dep.xcode", hint: "", present: true, installCmd: [])]
        let file = directory.appendingPathComponent("library.json")
        try JSONEncoder().encode([LibraryGame(titleID: "0100000000000000", name: "Test", inputs: ["base": ["/tmp/test.nsp"]])]).write(to: file)
        let library = GameLibrary(file: file)
        let pad = PadFocus()
        let view = LauncherView(stores: stores, library: library, initialPage: .builds, performStartupChecks: false, padFocus: pad)
        let window = OffscreenWindow(size: NSSize(width: 1100, height: 850))
        window.contentView = NSHostingView(rootView: view)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
        settle()
        XCTAssertTrue(pad.frames["main", default: []].contains { $0.id == "builds.first" })
        XCTAssertTrue(pad.frames["main", default: []].contains { $0.id == "builds.supported" })
        XCTAssertFalse(pad.frames["main", default: []].contains { $0.id == "top.build" })
        pad.show(default: "builds.first"); pad.activate(); settle()
        XCTAssertTrue(pad.frames["main", default: []].contains { $0.id == "builds.back" })
        stores.build.gameDir = "/tmp/draft"
        pad.focused = "builds.back"; pad.activate(); settle()
        XCTAssertEqual(stores.build.gameDir, "/tmp/draft")
        XCTAssertTrue(pad.frames["main", default: []].contains { $0.id == "builds.resume" })
        stores.build.running = true
        settle()
        pad.focused = "builds.first"; pad.activate(); settle()
        XCTAssertEqual(stores.build.gameDir, "/tmp/draft", "New build must not clear running inputs")
        XCTAssertFalse(pad.frames["main", default: []].contains { $0.id == "builds.back" })
        pad.focused = "builds.resume"; pad.activate(); settle()
        XCTAssertTrue(stores.build.running)
        XCTAssertTrue(pad.frames["main", default: []].contains { $0.id == "builds.back" })
        pad.focused = "builds.back"; pad.activate(); settle()
        XCTAssertTrue(stores.build.running, "Returning to the inventory must not stop work")
        stores.build.running = false
    }

    func testVerticalRowHandlerCanRevealAnUnmaterializedRowAndFallBackAtEdge() {
        let pad = PadFocus()
        pad.setFrames([.init(id: "row", frame: CGRect(x: 0, y: 0, width: 100, height: 40)),
                       .init(id: "footer", frame: CGRect(x: 0, y: 100, width: 100, height: 40))], scope: "main")
        var revealed: Int?
        pad.register("row", .init(vertical: { direction in revealed = direction; pad.focused = "next"; return true }))
        pad.focused = "row"; pad.move(dx: 0, dy: 1)
        XCTAssertEqual(revealed, 1)
        XCTAssertEqual(pad.focused, "next")
        pad.register("row", .init(vertical: { _ in false }))
        pad.focused = "row"; pad.move(dx: 0, dy: 1)
        XCTAssertEqual(pad.focused, "footer")
    }
}
