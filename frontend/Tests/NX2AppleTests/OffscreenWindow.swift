import AppKit
import CoreGraphics
import XCTest

/// The window every rendering test uses. A test needs a live window so SwiftUI lays out and `cacheDisplay` draws, never one anybody can see.
/// It sits far outside every display, is never key or main, and AppKit may not pull it back onto a screen. Ordering it in does not
/// activate the app. The titled style stays the default because the launcher draws under its transparent title bar.
final class OffscreenWindow: NSWindow {
    /// Far outside any arrangement of displays, in both axes.
    static let origin = NSPoint(x: -100_000, y: -100_000)

    init(size: NSSize, styleMask: NSWindow.StyleMask = [.titled]) {
        super.init(contentRect: NSRect(origin: Self.origin, size: size), styleMask: styleMask, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        // a titled window was already moved onto a screen by the initializer, so put it back
        setFrame(NSRect(origin: Self.origin, size: frame.size), display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// A titled window is moved back onto a screen when it is ordered in. This one stays where it is.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// The windows of this process that a person could see: shown, and with their frame on a display.
    @MainActor static func visibleOnScreen() -> [NSWindow] {
        let displays = NSScreen.screens.map(\.frame)
        return NSApp.windows.filter { window in window.isVisible && displays.contains { $0.intersects(window.frame) } }
    }

    /// The same question asked of the window server: windows of this process on a display, whatever AppKit thinks.
    static func serverWindowsOnDisplays() -> [[String: Any]] {
        let displays = NSScreen.screens.map(\.frame)
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        return list.filter { info in
            guard (info[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier,
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }) else { return false }
            // CGWindow bounds have the origin at the top left of the main display, NSScreen frames at the bottom left: test both
            let flipped = CGRect(x: bounds.minX, y: mainHeight - bounds.maxY, width: bounds.width, height: bounds.height)
            return displays.contains { $0.intersects(bounds) || $0.intersects(flipped) }
        }
    }
}

final class OffscreenWindowTests: IsolatedDefaultsTestCase {
    /// Windows of the helper are shown (as the render tests do) and must be on no display, for AppKit and for the window server.
    @MainActor func testRenderWindowsAreNeverOnAnyDisplay() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let windows = [OffscreenWindow(size: NSSize(width: 1440, height: 1500)),
                       OffscreenWindow(size: NSSize(width: 1280, height: 800), styleMask: [.borderless]),
                       OffscreenWindow(size: NSSize(width: 900, height: 1300), styleMask: [.titled, .closable, .resizable])]
        for window in windows {
            window.contentView = NSView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
            window.orderFront(nil)
        }
        defer { for window in windows { window.orderOut(nil); window.contentView = nil; window.close() } }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        for window in windows { XCTAssertTrue(window.isVisible, "ordered in, so layout and drawing work") }
        XCTAssertEqual(OffscreenWindow.visibleOnScreen(), [], "no window of the tests is on a display")
        XCTAssertEqual(OffscreenWindow.serverWindowsOnDisplays().count, 0, "the window server shows none either")
        XCTAssertNil(NSApp.keyWindow)
    }
}
