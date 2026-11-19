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

    func testBuildsTabOpensWorkbenchDirectlyAndKeepsDraftAcrossTabs() throws {
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
        let window = OffscreenWindow(size: NSSize(width: 1100, height: 1400))
        window.contentView = NSHostingView(rootView: view)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
        settle()
        let ids = Set(pad.frames["main", default: []].map(\.id))
        XCTAssertTrue(ids.contains("set.build.engine"))
        XCTAssertTrue(ids.contains("set.build.folder"))
        XCTAssertTrue(ids.contains("set.build.file.base"))
        XCTAssertTrue(ids.contains("set.build.queue.select"))
        XCTAssertFalse(ids.contains("builds.back"))
        stores.build.gameDir = "/tmp/draft"
        pad.show(default: "tab.library"); pad.activate(); settle()
        XCTAssertEqual(stores.build.gameDir, "/tmp/draft")
        stores.build.running = true
        settle()
        XCTAssertTrue(pad.frames["main", default: []].contains { $0.id == "build.activity" })
        pad.focused = "build.activity"; pad.activate(); settle()
        XCTAssertTrue(stores.build.running)
        XCTAssertFalse(pad.frames["main", default: []].contains { $0.id == "build.activity" })
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
