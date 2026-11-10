import XCTest
import SwiftUI
import AppKit
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

/// The console's prompts that show over the desktop follow the app appearance. Inside the console mode they stay dark.
/// `NX_LAUNCHER_CAPTURE_DIR=<dir>` also writes the renders as PNGs.
@MainActor final class ConsolePromptAppearanceTests: IsolatedDefaultsTestCase {
    private func render<V: View>(_ name: String, _ view: V, light: Bool, size: NSSize) throws -> NSBitmapImageRep {
        NSApplication.shared.setActivationPolicy(.accessory)
        let host = NSHostingView(rootView: view.environmentObject(PadFocus()).frame(width: size.width, height: size.height).background(LauncherPalette.background))
        let window = OffscreenWindow(size: size, styleMask: [.titled, .closable, .resizable, .fullSizeContentView])
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let dir = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] {
            let url = URL(fileURLWithPath: dir)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent("\(name).png"))
        }
        return rep
    }

    private func luminance(_ rep: NSBitmapImageRep, x: Int, y: Int) throws -> Double {
        let scale = Double(rep.pixelsWide) / rep.size.width   // x and y are points, colorAt takes pixels
        let c = try XCTUnwrap(rep.colorAt(x: Int(Double(x) * scale), y: Int(Double(y) * scale))?.usingColorSpace(.sRGB))
        return 0.2126 * Double(c.redComponent) + 0.7152 * Double(c.greenComponent) + 0.0722 * Double(c.blueComponent)
    }

    func testEntryPromptFollowsTheAppearanceOverTheDesktop() throws {
        let size = NSSize(width: 900, height: 600)
        func prompt() -> some View { ConsoleConnectionPrompt(lang: Lang("en"), enterConsole: {}, dismissPrompt: {}) }
        // the card's top left inside, away from text
        let (x, y) = (Int(size.width / 2) - 270, Int(size.height / 2) - 40)
        let light = try render("console-entry-prompt-light", prompt(), light: true, size: size)
        XCTAssertGreaterThan(try luminance(light, x: x, y: y), 0.85, "a light card over the desktop in Light")
        let dark = try render("console-entry-prompt-dark", prompt(), light: false, size: size)
        XCTAssertLessThan(try luminance(dark, x: x, y: y), 0.25)
        let inConsole = try render("console-entry-prompt-in-console", prompt().consoleDarkAppearance(), light: true, size: size)
        XCTAssertLessThan(try luminance(inConsole, x: x, y: y), 0.25, "dark inside the console mode even when the app is Light")
    }

    func testToastFollowsTheAppearanceOverTheDesktop() throws {
        let size = NSSize(width: 500, height: 100)
        func toast() -> some View { ConsoleToastView(toast: ConsoleToast(message: "Controller connected")).frame(width: size.width, height: size.height, alignment: .leading) }
        let light = try render("console-toast-light", toast(), light: true, size: size)
        XCTAssertGreaterThan(try luminance(light, x: 28, y: 50), 0.85)
        let dark = try render("console-toast-dark", toast(), light: false, size: size)
        XCTAssertLessThan(try luminance(dark, x: 28, y: 50), 0.25)
        let inConsole = try render("console-toast-in-console", toast().consoleDarkAppearance(), light: true, size: size)
        XCTAssertLessThan(try luminance(inConsole, x: 28, y: 50), 0.25)
    }
}
