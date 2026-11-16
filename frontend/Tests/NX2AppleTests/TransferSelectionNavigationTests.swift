import SwiftUI
import XCTest
@testable import NXCore
@testable import NXModel
@testable import NXLauncher
@testable import NX2Apple

@MainActor final class TransferSelectionNavigationTests: IsolatedDefaultsTestCase {
    func testReturnConfirmsSendSelectionEvenWhenARowHasDirectionalFocus() throws {
        let stores = LauncherStores(defaults: testDefaults)
        let transfers = TransferQueueStore(file: nil, perform: { _, _, _ in })
        stores.build.transfers = transfers
        stores.build.sharedAppDataSources = { [.init(titleID: "0100000000000000", name: "Game", archive: "/unused")] }
        stores.deviceStore.installDevice = "fixture-device"
        let pad = PadFocus()
        var closed = false
        let window = OffscreenWindow(size: .init(width: 700, height: 500))
        window.contentView = NSHostingView(rootView: SendSelectedSheet(mode: .device, build: stores.build) { closed = true }
            .environmentObject(stores.localizer).environmentObject(pad))
        window.orderFront(nil)
        defer { window.contentView = nil; window.orderOut(nil); window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        pad.show(default: "sendSelected.game.0100000000000000")
        XCTAssertFalse(PadKeyboardInput.handle(36, focus: pad, back: {}))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        XCTAssertTrue(window.performKeyEquivalent(with: event))
        XCTAssertTrue(closed)
        withExtendedLifetime(transfers) {}
    }

    func testSelectedTransferSheetOwnsFocusTogglesAndRestoresItsParent() {
        let stores = LauncherStores(defaults: testDefaults)
        stores.build.sharedAppDataSources = {
            [TransferSource(titleID: "0100000000000000", name: "Fixture game", archive: "/unused-transfer-fixture")]
        }
        stores.deviceStore.installDevice = "fixture-device"
        let pad = PadFocus()
        pad.scope = "main"; pad.focused = "set.build.install.selectGames"
        var closed = false
        let host = NSHostingView(rootView: SendSelectedSheet(mode: .device, build: stores.build) { closed = true }
            .environmentObject(stores.localizer).environmentObject(pad))
        let window = OffscreenWindow(size: .init(width: 700, height: 500))
        window.contentView = host; window.orderFront(nil)
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        settle()
        XCTAssertEqual(pad.scope, "sendSelected")
        XCTAssertNotNil(pad.frame(of: "sendSelected.game.0100000000000000"))
        XCTAssertNotNil(pad.frame(of: "sendSelected.confirm"))
        pad.show(default: nil); XCTAssertTrue(PadKeyboardInput.handle(49, focus: pad, back: {})); settle()
        XCTAssertNil(pad.frame(of: "sendSelected.confirm"), "unchecking the only game disables sending")
        pad.focused = "sendSelected.all"; pad.activate(); settle()
        XCTAssertNotNil(pad.frame(of: "sendSelected.confirm"))
        XCTAssertTrue(pad.cancel()); XCTAssertTrue(closed)
        window.contentView = nil; settle()
        XCTAssertEqual(pad.scope, "main")
        XCTAssertEqual(pad.focused, "set.build.install.selectGames")
        window.orderOut(nil); window.close()
    }
    func testRetryHandsFocusToPersistentQueueAction() {
        let stores = LauncherStores(defaults: testDefaults)
        let queue = BuildQueueStore(file: nil, engineID: { "engine" }, busy: { false }, start: { _ in nil })
        queue.enqueue([QueueEntry(gameID: UUID(), titleID: "0100000000000000", name: "Fixture", target: BuildTarget.mac,
                                  inputs: [:], outputDirectory: "/unused", engineID: "engine")])
        queue.start(); queue.buildEnded(succeeded: false, reason: "fixture")
        let pad = PadFocus()
        let id = queue.games[0].id.uuidString
        let host = NSHostingView(rootView: BuildQueueCard(queue: queue, onSelectGames: {})
            .environmentObject(stores.localizer).environmentObject(pad).padScope("main", pad))
        let window = OffscreenWindow(size: .init(width: 800, height: 450))
        window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.orderOut(nil); window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        pad.focused = "set.build.queue.retry." + id; pad.show(default: nil); pad.activate()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(queue.games[0].waiting, true)
        XCTAssertEqual(pad.focused, "set.build.queue.remove." + id)
        XCTAssertNotNil(pad.frame(of: pad.focused ?? ""))
    }

    func testSelectionKeyboardTabsInBothDirectionsAndBackCancels() {
        let pad = PadFocus()
        pad.setFrames([.init(id: "row", frame: .init(x: 0, y: 0, width: 200, height: 64)),
                       .init(id: "confirm", frame: .init(x: 100, y: 100, width: 100, height: 36))], scope: "main")
        pad.focused = "row"
        var toggled = false, cancelled = false
        pad.register("row", .init(activate: { toggled.toggle() }))
        XCTAssertTrue(PadKeyboardInput.handle(48, focus: pad, back: {}))
        XCTAssertEqual(pad.focused, "confirm")
        _ = PadKeyboardInput.handle(48, shift: true, focus: pad, back: {})
        XCTAssertEqual(pad.focused, "row")
        _ = PadKeyboardInput.handle(49, focus: pad, back: {})
        XCTAssertTrue(toggled)
        _ = PadKeyboardInput.handle(53, focus: pad, back: { cancelled = true })
        XCTAssertTrue(cancelled)
        XCTAssertFalse(PadKeyboardInput.handle(0, focus: pad, back: {}), "Unrelated keys stay native")
    }

}
