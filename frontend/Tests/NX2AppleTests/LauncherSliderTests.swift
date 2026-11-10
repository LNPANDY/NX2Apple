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

    /// The steps count from the lower bound, not from zero: with 1...9 and a step of 2, Right from 1 goes to 3, not 4.
    func testStepsCountFromTheLowerBound() {
        let odd = 1.0...9.0
        XCTAssertEqual(LauncherSlider.moved(1, by: 1, range: odd, step: 2), 3, accuracy: 1e-9)
        XCTAssertEqual(LauncherSlider.moved(3, by: 1, range: odd, step: 2), 5, accuracy: 1e-9)
        XCTAssertEqual(LauncherSlider.moved(5, by: -1, range: odd, step: 2), 3, accuracy: 1e-9)
        XCTAssertEqual(LauncherSlider.moved(9, by: 1, range: odd, step: 2), 9, accuracy: 1e-9)
        XCTAssertEqual(LauncherSlider.snapped(4.2, range: odd, step: 2), 5, accuracy: 1e-9)
        XCTAssertEqual(LauncherSlider.snapped(3.9, range: odd, step: 2), 3, accuracy: 1e-9)
    }

    /// SwiftUI builds the accessibility tree only when the app has an assistive client, so the test asks for it the way a client does.
    func testVoiceOverGetsASliderWithItsNameAndValueAndCanMoveIt() throws {
        var changes: [Double] = []
        let slider = LauncherSlider(value: 0.75, range: range, step: 0.05) { changes.append($0) }
            .accessibilityLabel("Render scale").accessibilityValue("75%")
        let (element, window) = try accessibilityElement(slider)
        defer { window.close() }
        XCTAssertEqual(element.value(forKey: "accessibilityRole") as? String, NSAccessibility.Role.slider.rawValue)
        XCTAssertEqual(element.value(forKey: "accessibilityLabel") as? String, "Render scale")
        XCTAssertEqual((element.value(forKey: "accessibilityValue") as? NSNumber)?.doubleValue ?? 0, 0.75, accuracy: 1e-9,
                       "value: \(String(describing: element.value(forKey: "accessibilityValue")))")
        XCTAssertEqual(element.value(forKey: "accessibilityValueDescription") as? String, "75%", "what VoiceOver reads")
        XCTAssertTrue(element.perform(NSSelectorFromString("accessibilityPerformIncrement")) != nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(changes.first ?? 0, 0.8, accuracy: 1e-9, "changes: \(changes)")
    }

    /// The arrow keys and VoiceOver land on the same value when the range does not start at a multiple of the step.
    func testArrowKeysAndVoiceOverAgreeOnARangeThatStartsOffTheStep() throws {
        var changes: [Double] = []
        let slider = LauncherSlider(value: 1, range: 1...9, step: 2) { changes.append($0) }.accessibilityLabel("Frames")
        let (element, window) = try accessibilityElement(slider)
        defer { window.close() }
        XCTAssertTrue(element.perform(NSSelectorFromString("accessibilityPerformIncrement")) != nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(changes.first ?? 0, LauncherSlider.moved(1, by: 1, range: 1...9, step: 2), accuracy: 1e-9, "changes: \(changes)")
    }

    private func accessibilityElement(_ slider: some View) throws -> (NSObject, NSWindow) {
        NSApplication.shared.accessibilitySetValue(true, forAttribute: Self.client)
        let host = NSHostingView(rootView: slider.frame(width: 200, height: 40))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let element = try XCTUnwrap((host.value(forKey: "accessibilityChildren") as? [NSObject])?.first, "the slider is in the tree")
        return (element, window)
    }
}
