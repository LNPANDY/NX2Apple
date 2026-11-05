import AppKit
import SwiftUI
import XCTest
@testable import NXLauncher

/// The launcher's slider: its steps and limits, and what VoiceOver gets from it (#591).
@MainActor final class LauncherSliderTests: XCTestCase {
    private let range = 0.5...1.0
    private static let client = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")

    override func tearDown() async throws {
        await MainActor.run { NSApplication.shared.accessibilitySetValue(false, forAttribute: Self.client) }
    }

    func testDraggingSnapsToTheStepInsideTheRange() {
        XCTAssertEqual(LauncherSlider.snapped(0.63, range: range, step: 0.05), 0.65, accuracy: 1e-9)
        XCTAssertEqual(LauncherSlider.snapped(0.1, range: range, step: 0.05), 0.5, accuracy: 1e-9)
        XCTAssertEqual(LauncherSlider.snapped(4, range: range, step: 0.05), 1, accuracy: 1e-9)
        XCTAssertEqual(LauncherSlider.snapped(0.63, range: range, step: 0), 0.63, accuracy: 1e-9, "no step, no snapping")
    }

    func testAnArrowKeyMovesOneStepAndStopsAtTheEnds() {
        XCTAssertEqual(LauncherSlider.moved(0.75, by: 1, range: range, step: 0.05), 0.8, accuracy: 1e-9)
        XCTAssertEqual(LauncherSlider.moved(0.75, by: -1, range: range, step: 0.05), 0.7, accuracy: 1e-9)
        XCTAssertEqual(LauncherSlider.moved(1, by: 1, range: range, step: 0.05), 1, accuracy: 1e-9)
        XCTAssertEqual(LauncherSlider.moved(0.5, by: -1, range: range, step: 0.05), 0.5, accuracy: 1e-9)
        XCTAssertEqual(LauncherSlider.moved(0.75, by: 1, range: range, step: 0), 0.775, accuracy: 1e-9)
    }

    /// SwiftUI builds the accessibility tree only when the app has an assistive client, so the test asks for it the way a client does.
    func testVoiceOverGetsASliderWithItsNameAndValueAndCanMoveIt() throws {
        NSApplication.shared.accessibilitySetValue(true, forAttribute: Self.client)
        var changes: [Double] = []
        let slider = LauncherSlider(value: 0.75, range: range, step: 0.05) { changes.append($0) }
            .accessibilityLabel("Render scale").accessibilityValue("75%")
        let host = NSHostingView(rootView: slider.frame(width: 200, height: 40))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let element = try XCTUnwrap((host.value(forKey: "accessibilityChildren") as? [NSObject])?.first, "the slider is in the tree")
        XCTAssertEqual(element.value(forKey: "accessibilityRole") as? String, NSAccessibility.Role.slider.rawValue)
        XCTAssertEqual(element.value(forKey: "accessibilityLabel") as? String, "Render scale")
        XCTAssertEqual((element.value(forKey: "accessibilityValue") as? NSNumber)?.doubleValue ?? 0, 0.75, accuracy: 1e-9,
                       "value: \(String(describing: element.value(forKey: "accessibilityValue")))")
        XCTAssertEqual(element.value(forKey: "accessibilityValueDescription") as? String, "75%", "what VoiceOver reads")
        XCTAssertTrue(element.perform(NSSelectorFromString("accessibilityPerformIncrement")) != nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(changes.first ?? 0, 0.8, accuracy: 1e-9, "changes: \(changes)")
    }
}
