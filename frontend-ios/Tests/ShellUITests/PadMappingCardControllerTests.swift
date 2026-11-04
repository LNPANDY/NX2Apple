#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import ShellUI

/// On a device with a controller the mapping card is a menu: the D-pad moves its focus, A picks, B closes (#495). Its drawing
/// is for touch and VoiceOver. It must not take a controller's state, and it must not be a focus target that takes or traps
/// the controller's focus.
@MainActor
final class PadMappingCardControllerTests: XCTestCase {
    private var rows: [SettingRow] {
        let swap = SettingRow(id: "pad.swapAB", label: "Swap A and B",
                              kind: .choice([SettingOption("on", "On"), SettingOption("off", "Off")]), value: "on", fromShell: false)
        return [swap] + PadMap.buttons.map { button in
            SettingRow(id: "pad.\(button)", label: PadMap.label(button), kind: .choice(PadMap.options),
                       value: button == "ZR" ? "ZL" : button, fromShell: button != "ZR")
        }
    }

    private func card(open: @escaping (String) -> Void = { _ in }) -> PadMappingCard {
        PadMappingCard(title: "All games", rows: rows, inherited: nil, openRow: nil, open: open, pick: { _, _ in },
                       backToList: {}, reset: {}, close: {})
    }

    /// The card has no input for a controller's state: nothing held, no snapshot. The host sends `PadSnapshot`s only to the
    /// button test (`onButtonTest`).
    func testTheCardTakesNoControllerState() {
        for child in Mirror(reflecting: card()).children {
            // By the type's name, so an optional snapshot counts too (a nil of any optional is `is PadSnapshot?`).
            let type = String(describing: Swift.type(of: child.value))
            XCTAssertFalse(type.contains("PadSnapshot"), "\(child.label ?? "?") is a controller snapshot: \(type)")
            XCTAssertFalse(type.contains("PadElement"), "\(child.label ?? "?") holds controller buttons: \(type)")
        }
    }

    /// The card's focus targets are its close button, the swap, the 16 rows and Reset. The drawing adds none, and the D-pad
    /// goes from the close button straight to the swap and from there down the rows.
    func testTheDrawingIsNoFocusTarget() throws {
        var targets: [FocusTarget] = []
        let view = card()
            .frame(width: 480, height: 3000)
            .coordinateSpace(name: "shell")
            .onPreferenceChange(FocusTargets.self) { targets = $0.filter { $0.frame.width > 1 } }
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 3000)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        let expected = Set(["map.close", "map.swap.on", "map.swap.off", "map.reset"] + PadMap.buttons.map { "map.row.pad.\($0)" })
        XCTAssertEqual(Set(targets.map(\.id)), expected)
        XCTAssertEqual(FocusNavigation.next(from: "map.close", action: .down, targets: targets)?.hasPrefix("map.swap."), true)
        XCTAssertEqual(FocusNavigation.next(from: "map.swap.on", action: .down, targets: targets), "map.row.pad.A")
    }
}
#endif
