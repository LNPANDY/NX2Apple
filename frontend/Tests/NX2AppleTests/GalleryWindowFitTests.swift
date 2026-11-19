import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
import NXLauncher

/// The state gallery's detail pane draws a scene smaller when it is narrower than the scene, so it never scrolls sideways (#1458).
@MainActor final class GalleryWindowFitTests: IsolatedDefaultsTestCase {
    func testTheScaleFitsTheWidthAndNeverEnlarges() {
        XCTAssertEqual(GalleryWindow.fit(CGSize(width: 1280, height: 800), into: 1000), 1000 / 1280, accuracy: 0.0001)
        XCTAssertEqual(GalleryWindow.fit(CGSize(width: 900, height: 680), into: 1200), 1)
        XCTAssertEqual(GalleryWindow.fit(CGSize(width: 1280, height: 800), into: 0), 1)
    }

    /// The window with the sidebar: the gallery's own scroll views (the sidebar and the detail pane, not the scene's rows inside
    /// it) are never wider than their visible part.
    func testTheDetailPaneNeverScrollsSideways() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let window = OffscreenWindow(size: NSSize(width: 1280, height: 860), styleMask: [.titled, .resizable])
        defer { window.contentView = nil; window.orderOut(nil); window.close() }
        window.contentView = NSHostingView(rootView: GalleryWindow().launcherAppearance())
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        var scrolls: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView { scrolls.append(scroll); return }   // a scroll view inside it belongs to the scene
            view.subviews.forEach(walk)
        }
        walk(try XCTUnwrap(window.contentView))
        XCTAssertFalse(scrolls.isEmpty)
        for scroll in scrolls {
            guard let document = scroll.documentView else { continue }
            XCTAssertLessThanOrEqual(document.frame.width, scroll.contentView.bounds.width + 1, "a scroll view scrolls sideways")
        }
    }
}
