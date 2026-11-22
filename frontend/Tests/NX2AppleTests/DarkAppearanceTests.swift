import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

/// The launcher is dark only (LNPANDY/NX2Apple#1458): no Appearance setting, every token one Dark value, and a Light or System
/// choice an older version saved is ignored.
final class DarkAppearanceTests: IsolatedDefaultsTestCase {
    private func resolved(_ color: Color, _ name: NSAppearance.Name) -> NSColor {
        var result = NSColor.clear
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance { result = NSColor(color).usingColorSpace(.sRGB)! }
        return result
    }

    func testTokensResolveTheSameInAWindowThatIsLight() {
        for (name, token) in [("background", LauncherPalette.background), ("surface", LauncherPalette.surface), ("card", LauncherPalette.card),
                              ("cream", LauncherPalette.cream), ("ink", LauncherPalette.ink(0.1)), ("ready", LauncherPalette.ready)] {
            XCTAssertEqual(resolved(token, .aqua), resolved(token, .darkAqua), "\(name) has one value")
        }
        XCTAssertLessThan(Double(resolved(LauncherPalette.background, .aqua).redComponent), 0.1, "the page is dark")
    }

    func testThereIsNoAppearanceSettingOrString() {
        for key in ["settings.appearance", "appearance.system", "appearance.light", "appearance.dark"] {
            XCTAssertEqual(L10n.string(key, .en), key, "\(key) is gone with the setting")
        }
    }

    /// A page scrolled back to its top rests below the scroll view's top inset (a full-size content view's title bar): at 0 the
    /// first rows were clipped under the top bar.
    @MainActor func testScrollMemoryTopIsBelowTheInset() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        final class Flipped: NSView { override var isFlipped: Bool { true } }
        scroll.documentView = Flipped(frame: NSRect(x: 0, y: 0, width: 400, height: 2000))
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 28, left: 0, bottom: 0, right: 0)
        XCTAssertEqual(ScrollMemory.topOffset(of: scroll), -28)
        scroll.contentInsets = NSEdgeInsets()
        XCTAssertEqual(ScrollMemory.topOffset(of: scroll), 0)
    }

    /// An old saved "light" choice and a Light window: the launcher still draws its Dark page.
    @MainActor func testAnOldLightChoiceIsIgnored() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        testDefaults.set("light", forKey: "appearance")
        let fixtures = GalleryFixtures()
        let host = NSHostingView(rootView: fixtures.view(.libraryFew).launcherAppearance().defaultAppStorage(testDefaults))
        let window = OffscreenWindow(size: NSSize(width: GalleryScene.size.width, height: GalleryScene.size.height), styleMask: [.titled, .closable, .resizable])
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let pixel = try XCTUnwrap(rep.colorAt(x: 4, y: rep.pixelsHigh - 4)?.usingColorSpace(.sRGB))
        XCTAssertLessThan(Double(pixel.redComponent), 0.2, "the page is dark, not a Light page")
    }
}
