import AppKit
import SwiftUI
import XCTest
@testable import NXLauncher

/// LNPANDY/NX2Apple#1458: the content of a button takes the button's foreground. "Launching…" had a cream spinner on the cream
/// primary, so it was invisible.
final class DesignButtonForegroundTests: IsolatedDefaultsTestCase {
    /// The spinner inside the primary style is drawn in accentOn (black): the rendered button holds dark pixels on its cream.
    @MainActor func testSpinnerInThePrimaryButtonIsDrawnInAccentOn() throws {
        let dark = try darkShare(of: Button {} label: { DSSpinner(size: 40).padding(24) }.buttonStyle(LauncherActionButtonStyle(.rounded(8))))
        XCTAssertGreaterThan(dark, 0.03, "the spinner's arc is black on the cream")
        let empty = try darkShare(of: Button {} label: { Color.clear.frame(width: 40, height: 40).padding(24) }.buttonStyle(LauncherActionButtonStyle(.rounded(8))))
        XCTAssertLessThan(empty, 0.005, "the cream itself is not dark")
    }

    /// Each style hands its content one colour (DSButtonForeground), read here through the environment the styles set.
    @MainActor func testEachStyleSetsItsForeground() throws {
        final class Seen { var colours: [String: Color?] = [:] }
        let seen = Seen()
        struct Probe: View {
            let name: String
            let seen: Seen
            @Environment(\.dsButtonForeground) private var colour
            var body: some View { Color.clear.frame(width: 10, height: 10).onAppear { seen.colours[name] = colour } }
        }
        let view = VStack {
            Button {} label: { Probe(name: "primary", seen: seen) }.buttonStyle(LauncherActionButtonStyle())
            Button {} label: { Probe(name: "flat", seen: seen) }.buttonStyle(LauncherSecondaryButtonStyle())
            Button {} label: { Probe(name: "destructive", seen: seen) }.buttonStyle(DSDestructiveButtonStyle())
            Button {} label: { Probe(name: "disabled", seen: seen) }.buttonStyle(LauncherActionButtonStyle()).disabled(true)
            Button {} label: { Probe(name: "icon", seen: seen) }.buttonStyle(LauncherIconButtonStyle())
        }
        _ = try render(view)
        XCTAssertEqual(seen.colours["primary"], DSButtonForeground.primary)
        XCTAssertEqual(seen.colours["flat"], DSButtonForeground.flat)
        XCTAssertEqual(seen.colours["destructive"], DSButtonForeground.destructive)
        XCTAssertEqual(seen.colours["disabled"], DSButtonForeground.disabled)
        XCTAssertEqual(seen.colours["icon"], DSButtonForeground.flat)
    }

    @MainActor private func render<V: View>(_ view: V) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.launcherAppearance().environmentObject(PadFocus()))
        let window = OffscreenWindow(size: NSSize(width: 200, height: 200), styleMask: [.borderless])
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// The share of the button's pixels that are near black.
    @MainActor private func darkShare<V: View>(of view: V) throws -> Double {
        let rep = try render(view)
        var dark = 0, total = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 1) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 1) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.9 else { continue }
                total += 1
                if c.redComponent < 0.25 && c.greenComponent < 0.25 && c.blueComponent < 0.25 { dark += 1 }
            }
        }
        return total == 0 ? 0 : Double(dark) / Double(total)
    }
}
