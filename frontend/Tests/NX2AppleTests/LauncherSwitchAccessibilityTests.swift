import AppKit
import SwiftUI
import XCTest
@testable import NXLauncher

/// What VoiceOver gets from the launcher's switch (#591), read from the accessibility tree of a hosting view.
/// SwiftUI builds that tree only when the app has an assistive client, so the test asks for it the way a client does.
@MainActor final class LauncherSwitchAccessibilityTests: XCTestCase {
    private static let client = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")

    override func setUp() async throws {
        await MainActor.run { NSApplication.shared.accessibilitySetValue(true, forAttribute: Self.client) }
    }

    override func tearDown() async throws {
        await MainActor.run { NSApplication.shared.accessibilitySetValue(false, forAttribute: Self.client) }
    }

    /// The first element under a switch hosted in a window.
    private func element(isOn: Bool) throws -> NSObject {
        let view = Toggle("Game vibration", isOn: .constant(isOn)).labelsHidden().toggleStyle(LauncherSwitchStyle())
        let host = NSHostingView(rootView: view.frame(width: 200, height: 80))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return try XCTUnwrap((host.value(forKey: "accessibilityChildren") as? [NSObject])?.first, "the switch is in the tree")
    }

    func testTheSwitchIsASwitchWithItsNameAndState() throws {
        let on = try element(isOn: true)
        XCTAssertEqual(on.value(forKey: "accessibilityRole") as? String, NSAccessibility.Role.checkBox.rawValue)
        XCTAssertEqual(on.value(forKey: "accessibilitySubrole") as? String, NSAccessibility.Subrole.toggle.rawValue)
        XCTAssertEqual(on.value(forKey: "accessibilityLabel") as? String, "Game vibration")
        XCTAssertEqual((on.value(forKey: "accessibilityValue") as? NSNumber)?.intValue, 1)

        let off = try element(isOn: false)
        XCTAssertEqual((off.value(forKey: "accessibilityValue") as? NSNumber)?.intValue, 0)
    }
}
