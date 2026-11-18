import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXLauncher

@MainActor final class PadFocusAppearanceTests: IsolatedDefaultsTestCase {
    func testArtworkSuccessCheckUsesBlackInDarkAndWhiteInLight() throws {
        for dark in [false, true] {
            let host = NSHostingView(rootView: ArtworkOutcomeBadge(.success, artworkSize: 100).padding(18)
                .background(Color.gray).environment(\.colorScheme, dark ? .dark : .light))
            let window = OffscreenWindow(size: NSSize(width: 80, height: 80))
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host; window.orderFront(nil)
            defer { window.contentView = nil; window.orderOut(nil) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            var ink = 0, white = 0
            for y in 36..<57 { for x in 36..<57 {
                let color = try XCTUnwrap(bitmap.colorAt(x: Int(Double(x) * Double(bitmap.pixelsWide) / host.bounds.width),
                    y: Int(Double(y) * Double(bitmap.pixelsHigh) / host.bounds.height))?.usingColorSpace(.sRGB))
                if max(color.redComponent, color.greenComponent, color.blueComponent) < 0.15 { ink += 1 }
                if min(color.redComponent, color.greenComponent, color.blueComponent) > 0.85 { white += 1 }
            } }
            XCTAssertGreaterThan(dark ? ink : white, 5)
            XCTAssertEqual(dark ? white : ink, 0)
        }
    }

    func testFocusFollowsCapsuleCircleAndCardBoundsInBothAppearances() throws {
        for dark in [false, true] {
            for (name, width, height, radius) in [("capsule", 120.0, 36.0, nil as CGFloat?),
                                                   ("circle", 36.0, 36.0, nil),
                                                   ("card", 180.0, 90.0, CGFloat(14))] {
                let focus = PadFocus()
                let shape = AnyView(Group {
                    if let radius { RoundedRectangle(cornerRadius: radius).fill(Color.gray) }
                    else if name == "circle" { Circle().fill(Color.gray) }
                    else { Capsule().fill(Color.gray) }
                }.frame(width: width, height: height)
                    .padTarget("control", scope: "main", radius: radius, focusColor: .red))
                let host = NSHostingView(rootView: shape.padding(12).background(Color.black)
                    .environmentObject(focus).environment(\.colorScheme, dark ? .dark : .light).padScope("main", focus))
                let window = OffscreenWindow(size: NSSize(width: width + 24, height: height + 24))
                window.contentView = host; window.orderFront(nil)
                defer { window.orderOut(nil); window.contentView = nil; window.close() }
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                focus.show(default: "control")
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                XCTAssertEqual(focus.frames["main"]?.first?.frame.size, CGSize(width: width, height: height))
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                func red(_ x: Double, _ y: Double) -> Bool {
                    let pixel = bitmap.colorAt(x: Int(x * Double(bitmap.pixelsWide) / host.bounds.width),
                                               y: Int(y * Double(bitmap.pixelsHigh) / host.bounds.height))!.usingColorSpace(.sRGB)!
                    return pixel.redComponent > 0.7 && pixel.greenComponent < 0.4
                }
                XCTAssertTrue(red(12 + width / 2, 13), name)
                XCTAssertTrue(red(13, 12 + height / 2), name)
                if name == "circle" { XCTAssertFalse(red(13, 22), "A circle must not acquire continuous-corner ticks") }
                XCTAssertFalse(red(12, 12), "Focus must follow the rounded corner: \(name)")
                XCTAssertFalse(red(8, 12 + height / 2), "Focus must not extend outside the control: \(name)")
                if let path = ProcessInfo.processInfo.environment["NX_FOCUS_CAPTURE_DIR"] {
                    let output = URL(fileURLWithPath: path)
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }
}
