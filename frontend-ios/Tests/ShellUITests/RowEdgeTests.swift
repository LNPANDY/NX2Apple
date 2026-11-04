#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import ShellUI

/// #511: on the iPhone Duo outer screen the system keeps a strip at the trailing edge (the status bar sits there), so
/// the library gets a trailing safe-area inset. The row of covers is sized for the width inside the safe area, but a
/// scroll view draws its content under the insets, so the third card showed in the strip, cut at the screen edge.
/// These tests render the upright library with such a strip and look at the pixels in it.
@MainActor
final class RowEdgeTests: XCTestCase {
    private let screen = CGSize(width: 440, height: 520)
    /// What is left inside the safe area (370 points) holds two whole covers, as on the outer screen.
    private let strip: CGFloat = 70

    private func games(_ count: Int) -> [GameDetail] {
        let titles = ["The Legend of Zelda: Tears of the Kingdom", "Hollow Knight: Silksong", "Hades II", "Celeste"]
        return (0..<count).map { GameDetail(game: GameTile(id: "0100\($0)", title: titles[$0 % titles.count])) }
    }

    /// The library rendered at the outer screen's size with a clear strip at the trailing edge, as a bitmap.
    private func render(_ count: Int) throws -> NSBitmapImageRep {
        let view = LibraryView(games: games(count))
            .safeAreaInset(edge: .trailing, spacing: 0) { Color.clear.frame(width: strip) }
            .frame(width: screen.width, height: screen.height)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
        NSApplication.shared.setActivationPolicy(.accessory)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: screen)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -100_000, y: -100_000), size: screen),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let dir = ProcessInfo.processInfo.environment["NX_SHELL_CAPTURE_DIR"] {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("row-edge-\(count).png"))
        }
        return rep
    }

    /// How many points in the strip, below the hero, differ from the page colour: a card drawn there shows up.
    private func drawnInStrip(_ rep: NSBitmapImageRep) -> Int {
        let scaleX = CGFloat(rep.pixelsWide) / screen.width, scaleY = CGFloat(rep.pixelsHigh) / screen.height
        let page = NSColor(ShellPalette.background).usingColorSpace(.sRGB) ?? .black
        var count = 0
        // Below the hero (a little under half the screen) and above the bottom bar.
        for y in stride(from: screen.height * 0.45, to: screen.height * 0.8, by: 2) {
            for x in stride(from: screen.width - strip + 4, to: screen.width, by: 2) {
                guard let color = rep.colorAt(x: Int(x * scaleX), y: Int(y * scaleY))?.usingColorSpace(.sRGB) else { continue }
                let distance = abs(color.redComponent - page.redComponent) + abs(color.greenComponent - page.greenComponent)
                    + abs(color.blueComponent - page.blueComponent)
                let black = color.redComponent + color.greenComponent + color.blueComponent
                if distance > 0.06 && black > 0.06 { count += 1 }
            }
        }
        return count
    }

    func testTwoGamesLeaveTheStripEmpty() throws {
        XCTAssertEqual(drawnInStrip(try render(2)), 0)
    }

    /// The bug: with a third game its card was drawn in the strip and cut at the screen edge.
    func testMoreThanTwoGamesDrawNoCardInTheStrip() throws {
        XCTAssertEqual(drawnInStrip(try render(4)), 0, "a card is drawn under the trailing inset and cut at the screen edge")
    }
}
#endif
