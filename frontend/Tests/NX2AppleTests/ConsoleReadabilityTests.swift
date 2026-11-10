import XCTest
import SwiftUI
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

/// Console mode over bright art: every hint has a real glyph for every controller family, the top bar keeps its contrast, unplayable
/// tiles are darkened rather than see-through, and a ready game in Needs attention says why.
@MainActor final class ConsoleReadabilityTests: IsolatedDefaultsTestCase {
    private let roles: [ConsoleGlyphs.Role] = [.activate, .back, .options, .menu, .launchOptions, .manage, .select, .play, .previousTab, .nextTab, .quickMenu]
    private let families: [ConsoleGlyphs.Family] = [.xbox, .playStation, .nintendo, .keyboard, .neutral]

    private func assertDrawable(_ glyph: ConsoleGlyphs.Glyph, _ context: String) {
        switch glyph {
        case .symbol(let name):
            XCTAssertTrue(ConsoleGlyphs.usable(name), "\(context): \(name) is a bare shape or missing")
        case .key(let text), .letter(let text):
            XCTAssertFalse(text.trimmingCharacters(in: .whitespaces).isEmpty, "\(context): an empty key cap")
        case .keySymbol(let name):
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), "\(context): \(name)")
        }
    }

    /// Every role on every family, with and without Swap A and B, through both paths the hints use, never an empty shape.
    func testEveryHintGlyphIsARealSymbolOrAKeyCap() {
        // what a DualSense reports for its Options and Create buttons: their bare outline
        let dualSense = ConsoleGlyphs(family: .playStation, reported: [.menu: "capsule.portrait", .select: "capsule.portrait", .a: "xmark.circle"])
        let sets = families.map { ConsoleGlyphs(family: $0) } + [dualSense, ConsoleGlyphs(family: .xbox, reported: [.menu: "no.such.symbol"])]
        for glyphs in sets {
            for role in roles {
                assertDrawable(glyphs.glyph(for: role), "\(glyphs.family) \(role)")
                for swap in [false, true] { assertDrawable(glyphs.hintGlyph(role, swapAB: swap), "\(glyphs.family) \(role) swap \(swap)") }
            }
        }
        XCTAssertEqual(dualSense.hintGlyph(.menu, swapAB: false), .symbol("line.3.horizontal.circle"), "PlayStation's Options: the three lines it prints")
        XCTAssertEqual(ConsoleGlyphs(family: .xbox).hintGlyph(.menu, swapAB: false), .symbol("line.3.horizontal.circle"), "Xbox's Menu")
        XCTAssertEqual(ConsoleGlyphs(family: .nintendo).hintGlyph(.menu, swapAB: false), .symbol("plus.circle"), "Nintendo's +")
        XCTAssertEqual(ConsoleGlyphs.keyboard.hintGlyph(.menu, swapAB: false), .key("M"))
        XCTAssertEqual(ConsoleGlyphs(family: .playStation, reported: [.menu: "line.3.horizontal.circle.fill"]).hintGlyph(.menu, swapAB: false),
                       .symbol("line.3.horizontal.circle.fill"), "a symbol that says what the button is stays the controller's own")
    }

    /// White text on the bar's fill keeps 4.5:1 over pure white art, with the top scrim and even without it.
    func testTheTopBarKeepsItsContrastOnWhiteArt() {
        func luminance(_ v: Double) -> Double { let c = v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4); return c }
        func contrast(over background: Double) -> Double { 1.05 / (luminance(background) + 0.05) }
        let scrimAtBar = 0.55 * (1 - 66 / ConsoleBackdrop.scrimHeight)   // the bar's middle, 66 pt down
        let underScrim = 1 - scrimAtBar
        XCTAssertGreaterThanOrEqual(contrast(over: underScrim * (1 - ConsoleBarFill.opacity)), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(over: 1 - ConsoleBarFill.opacity), 4.5, "the fill alone")
    }

    func testAReadyGameWithOlderToolsSaysWhyItNeedsAttention() {
        var mario = ConsoleGame(id: "m", title: "Mario", version: "", platforms: [.mac], artwork: nil, status: .ready)
        mario.olderTools = true
        XCTAssertEqual(ConsoleHome.sections([mario]).first?.row, .attention)
        XCTAssertNotNil(L10n.table["library.olderToolsShort"])
        XCTAssertNotNil(L10n.table["library.olderTools"])
    }

    /// Opt-in: the home screen and a game page over bright art at 1920 x 1080, German, a PlayStation pad's glyphs, a ready game built
    /// with older tools focused and games that are not built beside it. NX_CONSOLE_ART names a real cover (a cached hero), else a
    /// bright synthetic one is drawn.
    func testCaptureBrightArtwork() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_CONSOLE_CAPTURE_DIR"] else { throw XCTSkip("Set NX_CONSOLE_CAPTURE_DIR to capture") }
        NSApplication.shared.setActivationPolicy(.accessory)
        let art = ProcessInfo.processInfo.environment["NX_CONSOLE_ART"].flatMap(NSImage.init(contentsOfFile:)) ?? Self.brightImage()
        let driver = MockConsoleDriver(scenario: .full, lang: .de, animated: false)
        for i in driver.state.games.indices { driver.state.games[i].artwork = art; driver.state.games[i].hero = art }
        if let i = driver.state.games.firstIndex(where: { $0.id == "demo.0" }) { driver.state.games[i].olderTools = true }
        driver.state.controllers = [.init(id: "pad", name: "DualSense", player: 1, kind: .gamepad, battery: 0.75)]
        let glyphs = ConsoleGlyphs(family: .playStation, reported: [.menu: "capsule.portrait", .select: "capsule.portrait"])
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, setup) in [("bright-home", {}), ("bright-attention", { driver.focus("demo.3") }), ("bright-gamePage", { driver.openGamePage("demo.0") })] as [(String, () -> Void)] {
            setup()
            let host = NSHostingView(rootView: ConsoleView(driver: driver, lang: .de, glyphs: glyphs).transaction { $0.disablesAnimations = true }.frame(width: 1920, height: 1080))
            let window = OffscreenWindow(size: NSSize(width: 1920, height: 1080), styleMask: [.borderless])
            window.contentView = host
            window.orderBack(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
            window.orderOut(nil); window.contentView = nil; window.close()
        }
    }

    /// A bright, busy cover: a white to yellow sky with a few saturated shapes, the worst case for white text in the top right.
    static func brightImage() -> NSImage {
        NSImage(size: NSSize(width: 1920, height: 1080), flipped: false) { rect in
            NSGradient(colors: [.white, NSColor(red: 1, green: 0.95, blue: 0.6, alpha: 1)])?.draw(in: rect, angle: -60)
            NSColor(red: 0.95, green: 0.3, blue: 0.2, alpha: 1).setFill(); NSBezierPath(ovalIn: NSRect(x: 1300, y: 600, width: 300, height: 300)).fill()
            NSColor(red: 0.3, green: 0.75, blue: 0.95, alpha: 1).setFill(); NSBezierPath(rect: NSRect(x: 200, y: 100, width: 600, height: 250)).fill()
            return true
        }
    }
}
