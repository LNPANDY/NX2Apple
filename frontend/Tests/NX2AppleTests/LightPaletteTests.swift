import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

/// The Light scheme's own roles (near-black primary action, white segments, gray switch tracks, white selectable cards) and Dark
/// left exactly as it was.
final class LightPaletteTests: IsolatedDefaultsTestCase {
    private func resolved(_ color: Color, _ name: NSAppearance.Name) -> NSColor {
        var result = NSColor.clear
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance { result = NSColor(color).usingColorSpace(.sRGB)! }
        return result
    }

    private func assertColor(_ color: Color, _ appearance: NSAppearance.Name, hex: UInt32, alpha: Double = 1, _ name: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let c = resolved(color, appearance)
        XCTAssertEqual(Double(c.redComponent), Double((hex >> 16) & 0xFF) / 255, accuracy: 0.004, name, file: file, line: line)
        XCTAssertEqual(Double(c.greenComponent), Double((hex >> 8) & 0xFF) / 255, accuracy: 0.004, name, file: file, line: line)
        XCTAssertEqual(Double(c.blueComponent), Double(hex & 0xFF) / 255, accuracy: 0.004, name, file: file, line: line)
        XCTAssertEqual(Double(c.alphaComponent), alpha, accuracy: 0.004, name, file: file, line: line)
    }

    func testLightTokensHaveTheirSpecifiedValues() {
        let light = NSAppearance.Name.aqua
        assertColor(LauncherPalette.background, light, hex: 0xF2F1EE, "page")
        assertColor(LauncherPalette.card, light, hex: 0xFFFFFF, "card")
        assertColor(LauncherPalette.cardBorder, light, hex: 0x000000, alpha: 0.08, "card hairline")
        assertColor(LauncherPalette.topBarRule, light, hex: 0x000000, alpha: 0.08, "top bar rule")
        assertColor(LauncherPalette.cream, light, hex: 0x18181B, "primary fill")
        assertColor(LauncherPalette.onCream, light, hex: 0xFFFFFF, "primary text")
        assertColor(LauncherPalette.primaryHover, light, hex: 0x2A2A2E, "primary hover")
        assertColor(LauncherPalette.primaryPressed, light, hex: 0x000000, "primary pressed")
        assertColor(LauncherPalette.actionBorder, light, hex: 0x000000, alpha: 0, "no primary border")
        assertColor(LauncherPalette.secondaryFill, light, hex: 0xF4F3F0, "secondary fill")
        assertColor(LauncherPalette.secondaryHover, light, hex: 0xECEBE7, "secondary hover")
        assertColor(LauncherPalette.secondaryPressed, light, hex: 0xE4E3DF, "secondary pressed")
        assertColor(LauncherPalette.secondaryBorder, light, hex: 0x000000, alpha: 0.10, "secondary hairline")
        assertColor(LauncherPalette.menuFill, light, hex: 0xF4F3F0, "menu button")
        assertColor(LauncherPalette.dropdownFill, light, hex: 0xF4F3F0, "pop-up")
        assertColor(LauncherPalette.segmentTrack, light, hex: 0xE9E8E4, "segment track")
        assertColor(LauncherPalette.segmentSelected, light, hex: 0xFFFFFF, "segment pill")
        assertColor(LauncherPalette.segmentSelectedBorder, light, hex: 0x000000, alpha: 0.10, "segment pill hairline")
        assertColor(LauncherPalette.segmentSelectedText, light, hex: 0x18181B, "segment text chosen")
        assertColor(LauncherPalette.segmentText, light, hex: 0x5F6068, "segment text")
        assertColor(LauncherPalette.switchOnTrack, light, hex: 0x18181B, "switch on")
        assertColor(LauncherPalette.switchOnKnob, light, hex: 0xFFFFFF, "switch knob on")
        assertColor(LauncherPalette.switchOffTrack, light, hex: 0xD9D8D4, "switch off")
        assertColor(LauncherPalette.switchOffKnob, light, hex: 0xFFFFFF, "switch knob off")
        assertColor(LauncherPalette.selectableFill, light, hex: 0xFFFFFF, "selectable card")
        assertColor(LauncherPalette.selectableBorder, light, hex: 0x000000, alpha: 0.10, "selectable hairline")
        assertColor(LauncherPalette.selectedFill, light, hex: 0xFFFFFF, "selected card: no gray fill")
        assertColor(LauncherPalette.selectedBorder, light, hex: 0x18181B, "selected border")
        assertColor(LauncherPalette.radioOff, light, hex: 0xA1A1A6, "empty radio")
        assertColor(LauncherPalette.radioOn, light, hex: 0x18181B, "filled radio")
        assertColor(LauncherPalette.text, light, hex: 0x18181B, "text")
        assertColor(LauncherPalette.secondaryText, light, hex: 0x5F6068, "secondary text")
        assertColor(LauncherPalette.tertiaryText, light, hex: 0x8E8E93, "tertiary text")
        assertColor(LauncherPalette.textStrong, light, hex: 0x18181B, "strong text")
        assertColor(LauncherPalette.notice, light, hex: 0x875600, "Switch 2 badge")
        assertColor(LauncherPalette.ready, light, hex: 0x167646, "ready")
        assertColor(LauncherPalette.building, light, hex: 0x875600, "attention")
        assertColor(LauncherPalette.danger, light, hex: 0xB42328, "destructive")
    }

    /// Dark is the launcher's palette from before Light: every new role resolves to what the views drew there.
    func testDarkTokensKeepTheirValues() {
        let dark = NSAppearance.Name.darkAqua
        func same(_ a: Color, _ b: NSColor, _ name: String) {
            let x = resolved(a, dark), y = b.usingColorSpace(.sRGB)!
            for (u, v) in [(x.redComponent, y.redComponent), (x.greenComponent, y.greenComponent), (x.blueComponent, y.blueComponent), (x.alphaComponent, y.alphaComponent)] {
                XCTAssertEqual(Double(u), Double(v), accuracy: 0.004, name)
            }
        }
        let cream = NSColor(srgbRed: 1, green: 0.94, blue: 0.84, alpha: 1)
        func white(_ a: CGFloat) -> NSColor { NSColor.white.withAlphaComponent(a) }
        same(LauncherPalette.background, NSColor(srgbRed: 0.055, green: 0.055, blue: 0.06, alpha: 1), "page")
        same(LauncherPalette.card, NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 0.75), "card")
        same(LauncherPalette.cardBorder, white(0.06), "card hairline")
        same(LauncherPalette.cream, cream, "cream")
        same(LauncherPalette.primaryHover, cream, "no hover change in Dark")
        same(LauncherPalette.primaryPressed, cream, "no pressed change in Dark")
        same(LauncherPalette.onCream, .black, "text on cream")
        same(LauncherPalette.actionBorder, .clear, "no border")
        same(LauncherPalette.secondaryFill, white(0.055), "secondary fill")
        same(LauncherPalette.secondaryPressed, white(0.13), "secondary pressed")
        same(LauncherPalette.secondaryBorder, white(0.10), "secondary hairline")
        same(LauncherPalette.menuFill, white(0.07), "top bar button")
        same(LauncherPalette.dropdownFill, white(0.06), "pop-up")
        same(LauncherPalette.dropdownOpenBorder, white(0.18), "open pop-up")
        same(LauncherPalette.segmentTrack, white(0.06), "segment track")
        same(LauncherPalette.segmentTrackBorder, white(0.08), "segment track hairline")
        same(LauncherPalette.segmentSelected, cream, "segment pill")
        same(LauncherPalette.segmentSelectedText, .black, "segment text chosen")
        same(LauncherPalette.segmentText, white(0.75), "segment text")
        same(LauncherPalette.switchOnTrack, cream, "switch on")
        same(LauncherPalette.switchOnKnob, .black, "switch knob on")
        same(LauncherPalette.switchOffTrack, white(0.14), "switch off")
        same(LauncherPalette.switchOffKnob, white(0.85), "switch knob off")
        same(LauncherPalette.selectedFill, cream.withAlphaComponent(0.05), "selected card")
        same(LauncherPalette.selectedFillStrong, cream.withAlphaComponent(0.07), "onboarding selected card")
        same(LauncherPalette.selectedBorder, cream.withAlphaComponent(0.7), "selected border")
        same(LauncherPalette.radioOff, white(0.25), "empty radio")
        same(LauncherPalette.notice, cream.withAlphaComponent(0.85), "Switch 2 badge")
        same(LauncherPalette.noticeBorder, cream.withAlphaComponent(0.35), "Switch 2 badge border")
        same(LauncherPalette.textStrong, .white, "strong text")
    }

    /// The focus ring and the selected tile's underline: quieter in Light (the primary at 0.55), Dark exactly the cream it was.
    func testFocusRingIsQuieterInLightAndUnchangedInDark() {
        assertColor(LauncherPalette.focusRing, .aqua, hex: 0x18181B, alpha: 0.55, "Light focus ring")
        assertColor(LauncherPalette.selectionUnderline, .aqua, hex: 0x18181B, alpha: 0.55, "Light tile underline")
        XCTAssertEqual(resolved(LauncherPalette.focusRing, .darkAqua), resolved(LauncherPalette.accent, .darkAqua), "Dark ring is the cream")
        XCTAssertEqual(resolved(LauncherPalette.selectionUnderline, .darkAqua), resolved(LauncherPalette.cream, .darkAqua), "Dark underline is the cream")
        XCTAssertEqual(LauncherPalette.focusRingWidth, 2)
        XCTAssertEqual(LauncherPalette.selectionUnderlineHeight, 3)
    }

    func testPrimaryActionFillFollowsItsState() {
        func hex(_ c: Color) -> NSColor { resolved(c, .aqua) }
        XCTAssertEqual(hex(LauncherActionButtonStyle.fill(light: true, pressed: false, hovered: false)), hex(LauncherPalette.cream))
        XCTAssertEqual(hex(LauncherActionButtonStyle.fill(light: true, pressed: false, hovered: true)), hex(LauncherPalette.primaryHover))
        XCTAssertEqual(hex(LauncherActionButtonStyle.fill(light: true, pressed: true, hovered: true)), hex(LauncherPalette.primaryPressed))
        XCTAssertEqual(resolved(LauncherActionButtonStyle.fill(light: false, pressed: true, hovered: true), .darkAqua),
                       resolved(LauncherPalette.cream, .darkAqua), "Dark keeps the cream in every state")
    }

    func testStatusAndTertiaryContrast() {
        for page in [NSColor.white, NSColor(srgbRed: 0xF2 / 255.0, green: 0xF1 / 255.0, blue: 0xEE / 255.0, alpha: 1)] {
            for status in [0x167646, 0x875600, 0xB42328] as [UInt32] {
                let c = NSColor(srgbRed: CGFloat((status >> 16) & 0xFF) / 255, green: CGFloat((status >> 8) & 0xFF) / 255, blue: CGFloat(status & 0xFF) / 255, alpha: 1)
                XCTAssertGreaterThanOrEqual(LauncherPalette.contrast(c, page), 4.5)
            }
        }
    }

    /// The console mode is dark whatever the appearance choice: the window is Dark while it shows.
    func testConsoleModeIsDarkWhileTheChoiceIsLight() {
        XCTAssertEqual(LauncherAppearance.scheme(stored: "light", forceDark: true), .dark)
        XCTAssertEqual(LauncherAppearance.scheme(stored: "light", forceDark: false), .light)
        XCTAssertNil(LauncherAppearance.scheme(stored: "system", forceDark: false))
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
}

/// The console root draws its Dark background while the saved appearance is Light (the console mode is never light).
@MainActor final class ConsoleDarkInLightTests: IsolatedDefaultsTestCase {
    func testConsoleRootResolvesDarkTokensWhileTheChoiceIsLight() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        LauncherAppearance.light.save(testDefaults)   // the view reads it through defaultAppStorage below, never the shared domain
        let driver = MockConsoleDriver(scenario: .full)
        let root = ConsoleView(driver: driver, lang: .en).frame(width: 1440, height: 1024)
            .background(LauncherPalette.background).launcherAppearance().defaultAppStorage(testDefaults)
        let host = NSHostingView(rootView: root)
        let window = OffscreenWindow(size: NSSize(width: 1440, height: 1024), styleMask: [.titled, .closable, .resizable])
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("console-light-choice.png"))
        }
        // a corner of the backdrop, away from artwork and text
        let pixel = try XCTUnwrap(rep.colorAt(x: 4, y: rep.pixelsHigh - 4)?.usingColorSpace(.sRGB))
        XCTAssertLessThan(Double(pixel.redComponent), 0.2, "the console's backdrop is dark, not the Light page")
    }
}
