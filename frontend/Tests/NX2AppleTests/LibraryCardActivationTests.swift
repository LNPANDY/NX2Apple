import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXModel
@testable import NXLauncher

@MainActor final class LibraryCardActivationTests: IsolatedDefaultsTestCase {
    func testControllerSelectionAndKeyboardActivationUseTheSameGame() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let games = [LibraryGame(titleID: "0100000000000000", name: "First", inputs: ["base": ["/tmp/first.nsp"]], sourceFolder: "/tmp/first"),
                     LibraryGame(titleID: "0100000000000001", name: "Second", inputs: ["base": ["/tmp/second.nsp"]], sourceFolder: "/tmp/second")]
        let file = directory.appendingPathComponent("library.json")
        try JSONEncoder().encode(games).write(to: file)
        let stores = LauncherStores(defaults: testDefaults)
        let marker = directory.appendingPathComponent("dm/tools/nx_extract/Program.cs")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: marker)
        stores.repo.path = directory.path
        stores.dependencies.checked = true
        XCTAssertTrue(stores.dependencies.allPresent)
        let library = GameLibrary(file: file)
        let pad = PadFocus()
        let window = OffscreenWindow(size: NSSize(width: 1100, height: 800))
        window.contentView = NSHostingView(rootView: LauncherView(stores: stores, library: library, performStartupChecks: false, padFocus: pad))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        pad.show(default: "card." + games[1].id.uuidString)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(library.selectedID, games[1].id)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        XCTAssertTrue(window.performKeyEquivalent(with: event))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(stores.build.gameDir, "/tmp/second", "Return must not activate the previous hero")
    }
}
