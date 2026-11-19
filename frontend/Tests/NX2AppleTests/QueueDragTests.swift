import SwiftUI
import XCTest
@testable import NXCore
@testable import NXModel
@testable import NXLauncher
@testable import NX2Apple

@MainActor final class QueueDragTests: IsolatedDefaultsTestCase {
    func testDragCursorRestoresAfterPickupEnds() {
        let previous = NSCursor.current
        defer { previous.set() }
        let probe = QueuePointerInput.Probe()
        probe.autoscrolling = true
        XCTAssertEqual(NSCursor.current, .closedHand)
        probe.autoscrolling = false
        XCTAssertEqual(NSCursor.current, .arrow)
    }

    func testRowDragPreviewsBothDirectionsWithVariableHeightsAndFixedResultSlots() {
        let a = UUID(), result = UUID(), b = UUID(), c = UUID()
        let ids = [a, result, b, c]
        let frames = [a: CGRect(x: 0, y: 0, width: 800, height: 84),
                      result: CGRect(x: 0, y: 85, width: 800, height: 100),
                      b: CGRect(x: 0, y: 186, width: 800, height: 110),
                      c: CGRect(x: 0, y: 297, width: 800, height: 84)]
        var drag = QueueRowDrag(source: a, ids: ids, movable: [a, b, c], frames: frames)
        XCTAssertEqual(drag.order, ids)
        drag.translation = 400
        XCTAssertEqual(drag.order, [b, result, c, a])
        XCTAssertEqual(drag.displacement(a), 297, "pointer travel clamps to the last movable row")
        XCTAssertEqual(drag.displacement(b), -186)
        XCTAssertEqual(drag.displacement(c), -85)
        XCTAssertEqual(drag.order[1], result, "settled/running groups retain their slot")
        drag.translation = 0
        XCTAssertEqual(drag.order, ids, "dragging back restores the untouched queue preview")
        XCTAssertEqual(drag.displacement(b), 0)
        var upward = QueueRowDrag(source: c, ids: ids, movable: [a, b, c], frames: frames)
        upward.translation = -1000
        XCTAssertEqual(upward.order, [c, result, a, b])
        XCTAssertEqual(upward.displacement(c), -297)
    }

    func testHandleGestureCommitsOnlyOnReleaseAndEscapeDiscardsPreview() throws {
        let queue = BuildQueueStore(file: nil, engineID: { "engine" }, busy: { false }, start: { _ in nil })
        queue.enqueue((0..<3).map { QueueEntry(titleID: "\($0)", name: "Game \($0)", target: BuildTarget.mac,
            inputs: ["base": ["/sample/game.nsp"]], outputDirectory: "/sample", engineID: "engine") })
        let original = queue.games.map(\.id), focus = PadFocus()
        let host = NSHostingView(rootView: BuildQueueCard(queue: queue, onSelectGames: {})
            .environmentObject(Localizer(.en)).environmentObject(focus).padScope("main", focus))
        let window = OffscreenWindow(size: .init(width: 900, height: 500))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.orderOut(nil); window.close() }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
        settle()
        func send(_ kind: NSEvent.EventType, _ point: CGPoint) throws {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            settle()
        }
        func handle(_ id: UUID) throws -> CGPoint {
            let frame = try XCTUnwrap(focus.frame(of: "set.build.queue.remove." + id.uuidString))
            return CGPoint(x: frame.midX + 44, y: host.bounds.height - frame.midY)
        }
        let start = try handle(original[0])
        try send(.leftMouseDown, start)
        try send(.leftMouseDragged, CGPoint(x: start.x - 100, y: start.y - 180))
        XCTAssertEqual(queue.games.map(\.id), original, "pickup previews do not persist")
        try send(.leftMouseUp, CGPoint(x: start.x - 100, y: start.y - 180))
        XCTAssertEqual(queue.games.map(\.id), [original[1], original[2], original[0]])
        let beforeCancel = queue.games.map(\.id), again = try handle(original[1])
        try send(.leftMouseDown, again)
        try send(.leftMouseDragged, CGPoint(x: again.x, y: again.y - 180))
        func probe(in view: NSView) -> QueuePointerInput.Probe? {
            (view as? QueuePointerInput.Probe) ?? view.subviews.lazy.compactMap { probe(in: $0) }.first
        }
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        try XCTUnwrap(probe(in: host)).receive(escape)
        try send(.leftMouseUp, CGPoint(x: again.x, y: again.y - 180))
        XCTAssertEqual(queue.games.map(\.id), beforeCancel)
    }

    func testOrderingControlsSwitchBetweenControllerPointerAndNativeKeyboard() throws {
        let queue = BuildQueueStore(file: nil, engineID: { "engine" }, busy: { false }, start: { _ in nil })
        queue.enqueue((0..<3).map { QueueEntry(titleID: "\($0)", name: "Game \($0)", target: BuildTarget.mac,
            inputs: ["base": ["/sample/game.nsp"]], outputDirectory: "/sample", engineID: "engine") })
        let focus = PadFocus()
        let host = NSHostingView(rootView: BuildQueueCard(queue: queue, onSelectGames: {})
            .environmentObject(Localizer(.en)).environmentObject(focus).padScope("main", focus)
            .background(LauncherPalette.background))
        let window = OffscreenWindow(size: .init(width: 900, height: 500))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.orderOut(nil); window.close() }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        settle()
        let middle = queue.games[1].id.uuidString
        let up = "set.build.queue.up." + middle, remove = "set.build.queue.remove." + middle
        XCTAssertNil(focus.frame(of: up))
        XCTAssertNotNil(focus.frame(of: remove))
        focus.show(default: remove); settle()
        XCTAssertNotNil(focus.frame(of: up))
        focus.focused = up
        let move = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: .init(x: 10, y: 10), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
        func probe(in view: NSView) -> QueuePointerInput.Probe? {
            (view as? QueuePointerInput.Probe) ?? view.subviews.lazy.compactMap { probe(in: $0) }.first
        }
        // OffscreenWindow deliberately cannot become key; exercise the monitor's event handler directly.
        let input = try XCTUnwrap(probe(in: host))
        input.receive(try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDragged, location: .init(x: 10, y: 10), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)))
        input.receive(move)
        settle()
        XCTAssertFalse(focus.visible)
        XCTAssertNil(focus.frame(of: up))
        XCTAssertEqual(focus.focused, remove)
        let tab = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        input.receive(tab)
        settle()
        XCTAssertFalse(focus.visible, "native keyboard mode need not enable the controller ring")
        XCTAssertNotNil(focus.frame(of: up))
        XCTAssertEqual(queue.games.map(\.name), ["Game 0", "Game 1", "Game 2"])
    }
}
