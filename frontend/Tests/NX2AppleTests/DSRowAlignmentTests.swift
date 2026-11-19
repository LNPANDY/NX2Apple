import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
import NXLauncher

/// The alignment rule of a row (frontend/README.md, "Design tokens and components"): the leading slot's content and the trailing
/// control share one vertical centre, the centre of the text block (title and subtitle), with one or more text lines and with a
/// message under them. Measured on the rendered pixels: the dot is drawn pure red, the trailing control a pure green block.
final class DSRowAlignmentTests: IsolatedDefaultsTestCase {
    private static let red = Color(.sRGB, red: 1, green: 0, blue: 0)
    private static let green = Color(.sRGB, red: 0, green: 1, blue: 0)

    /// The rows of pixels a colour covers, in points from the top, and the height of the whole image in points.
    struct Span { let top: CGFloat; let bottom: CGFloat; var centre: CGFloat { (top + bottom) / 2 } }

    @MainActor static func render<V: View>(_ view: V, width: CGFloat) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.frame(width: width).fixedSize(horizontal: false, vertical: true)
            .environmentObject(PadFocus()).background(Color.black))
        let size = NSSize(width: width, height: max(host.fittingSize.height, 1))
        let window = OffscreenWindow(size: size)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        return rep
    }

    /// The vertical span of the pixels whose colour `matches` (sRGB components), in points from the top.
    static func span(in rep: NSBitmapImageRep, where matches: (CGFloat, CGFloat, CGFloat) -> Bool) -> Span? {
        let scale = CGFloat(rep.pixelsHigh) / rep.size.height
        var top: Int?, bottom: Int?
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.9,
                      matches(c.redComponent, c.greenComponent, c.blueComponent) else { continue }
                if top == nil { top = y }
                bottom = y
                break
            }
        }
        guard let top, let bottom else { return nil }
        return Span(top: CGFloat(top) / scale, bottom: CGFloat(bottom + 1) / scale)
    }
    static func isRed(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Bool { r > 0.7 && g < 0.3 && b < 0.3 }
    static func isGreen(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Bool { g > 0.7 && r < 0.4 && b < 0.4 }

    @MainActor private func assertCentred(_ name: String, detail: String = "", detail2: String = "", message: DSRowMessage? = nil,
                                          title: String = "Your games folder", width: CGFloat = 640, file: StaticString = #filePath, line: UInt = #line) throws {
        let row = CardRow(title, detail: detail, detail2: detail2, dot: Self.red, message: message) {
            Self.green.frame(width: 40, height: 20)
        }
        let rep = try Self.render(row, width: width)
        if let dir = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("rowalign-\(name).png"))
        }
        let dot = try XCTUnwrap(Self.span(in: rep, where: Self.isRed), "\(name): no dot", file: file, line: line)
        let control = try XCTUnwrap(Self.span(in: rep, where: Self.isGreen), "\(name): no control", file: file, line: line)
        XCTAssertEqual(dot.centre, control.centre, accuracy: 1, "\(name): the dot's centre \(dot.centre) is not the control's \(control.centre)", file: file, line: line)
    }

    @MainActor func testTheDotAndTheControlShareOneCentre() throws {
        try assertCentred("title only")
        try assertCentred("title and subtitle", detail: "Not set")
        try assertCentred("title, subtitle and path", detail: "On iCloud Drive", detail2: "~/Library/Mobile Documents/com~apple~CloudDocs/NX2Apple")
        try assertCentred("two line subtitle", detail: String(repeating: "A subtitle that wraps onto a second line. ", count: 4), width: 520)
        try assertCentred("two line title", title: String(repeating: "A long title that wraps ", count: 4), width: 420)
    }

    /// A message under the text block makes the row grow downwards, and dot and control stay on the title and subtitle.
    @MainActor func testAMessageDoesNotMoveTheDotOrTheControl() throws {
        try assertCentred("message", detail: "Not set", message: .warning("Choose a folder before you build a game."))
        try assertCentred("long message", detail: "Not set",
                          message: .error(String(repeating: "This message wraps onto several lines under the row. ", count: 5)), width: 520)
    }

    /// A notice's detail wraps (never cut), the notice grows, and its symbol stays centred on the title and detail.
    @MainActor func testANoticeWrapsItsDetailAndKeepsItsSymbolCentred() throws {
        let tone = try XCTUnwrap(NSColor(DSTone.error.color).usingColorSpace(.sRGB))
        func isTone(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Bool {
            abs(r - tone.redComponent) < 0.08 && abs(g - tone.greenComponent) < 0.08 && abs(b - tone.blueComponent) < 0.08
        }
        func notice(_ detail: String) -> LauncherNotice {
            LauncherNotice(LauncherNoticeItem(id: "test", tone: .error, title: "The engine could not be downloaded from GitHub.", detail: detail,
                                              action: .init(title: "Try again") {}))
        }
        let short = try Self.render(notice("Check your connection."), width: 640)
        let long = try Self.render(notice(String(repeating: "Check your internet connection and that github.com can be reached, then press Try again. ", count: 3)
                                          + "Games cannot be built without the engine."), width: 640)
        XCTAssertGreaterThan(long.size.height, short.size.height + 30, "the detail wraps onto more lines")
        for (name, rep) in [("short", short), ("long", long)] {
            let symbol = try XCTUnwrap(Self.span(in: rep, where: isTone), "\(name): no symbol")
            XCTAssertEqual(symbol.centre, rep.size.height / 2, accuracy: 1, "\(name): the symbol is not centred on the notice")
        }
    }
}
