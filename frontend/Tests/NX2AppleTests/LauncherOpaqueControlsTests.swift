import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXLauncher

@MainActor final class LauncherOpaqueControlsTests: IsolatedDefaultsTestCase {
    func testActionsKeepKeyboardActivationAndDisabledState() throws {
        for primary in [false, true] {
            var presses = 0
            func control(disabled: Bool) -> AnyView {
                let button = Button("Continue") { presses += 1 }.keyboardShortcut(.return, modifiers: []).disabled(disabled)
                return primary ? AnyView(button.buttonStyle(LauncherActionButtonStyle()))
                    : AnyView(button.buttonStyle(LauncherSecondaryButtonStyle()))
            }
            let host = NSHostingView(rootView: control(disabled: false))
            let window = OffscreenWindow(size: NSSize(width: 300, height: 100))
            window.contentView = host; window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            XCTAssertTrue(window.performKeyEquivalent(with: event))
            XCTAssertEqual(presses, 1)
            host.rootView = control(disabled: true)
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            _ = window.performKeyEquivalent(with: event)
            XCTAssertEqual(presses, 1)
        }
    }

    func testControlFillsAreOpaqueAndSelectedTextContrastsInBothAppearances() {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                for fill in [LauncherPalette.secondaryFill, LauncherPalette.secondaryHover, LauncherPalette.secondaryPressed,
                             LauncherPalette.menuFill, LauncherPalette.dropdownFill, LauncherPalette.segmentTrack, LauncherPalette.segmentSelected] {
                    XCTAssertEqual(NSColor(fill).alphaComponent, 1, accuracy: 0.001)
                }
                XCTAssertNotEqual(NSColor(LauncherPalette.segmentSelected), NSColor(LauncherPalette.segmentSelectedText))
            }
        }
    }

    func testDropdownPresentationStylesShareTheStandardHeight() {
        for style in [LauncherDropdownStyle.pill, .button] {
            let host = NSHostingView(rootView: LauncherDropdown(options: [("recent", "Recently played")],
                                                               selection: "recent", style: style) { _ in })
            XCTAssertEqual(host.fittingSize.height, LauncherControl.height)
        }
    }

    func testSecondaryActionsHugTheirLabelsWithinTheSharedColumn() {
        let short = NSHostingView(rootView: Button("OK") {}.buttonStyle(LauncherSecondaryButtonStyle()).launcherRowControls())
        let long = NSHostingView(rootView: Button("Check for updates") {}.buttonStyle(LauncherSecondaryButtonStyle()).launcherRowControls())
        XCTAssertEqual(short.fittingSize.height, 36)
        XCTAssertEqual(long.fittingSize.height, 36)
        XCTAssertLessThan(short.fittingSize.width, long.fittingSize.width)
        XCTAssertLessThanOrEqual(long.fittingSize.width, LauncherControl.width)
    }
}
