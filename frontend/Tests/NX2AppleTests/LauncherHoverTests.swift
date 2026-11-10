import AppKit
import SwiftUI
import XCTest
import NXCore
import NXModel
@testable import NXLauncher
@testable import NX2Apple

@MainActor final class LauncherHoverTests: IsolatedDefaultsTestCase {
    private var nativeCapture: Bool { ProcessInfo.processInfo.environment["NX_NATIVE_HOVER_CAPTURE"] == "1" }
    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    /// Deliver native tracking events without moving the user's pointer or activating a test window.
    @discardableResult private func hover(_ host: NSView, entered: Bool, at point: NSPoint? = nil) throws -> Int {
        let event = try XCTUnwrap(NSEvent.enterExitEvent(with: entered ? .mouseEntered : .mouseExited,
            location: .zero, modifierFlags: [], timestamp: 0, windowNumber: host.window!.windowNumber,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        var count = 0
        for view in descendants(host).compactMap({ $0 as? LauncherHoverRegion.TrackingView }) {
            if entered, let point, !view.visibleRect.contains(view.convert(point, from: host)) { continue }
            count += 1
            if entered { view.mouseEntered(with: event) } else { view.mouseExited(with: event) }
        }
        settle()
        return count
    }

    private func snapshot(_ host: NSView) throws -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded()
        // cacheDisplay omits compositor effects such as brightness. Native visual QA is opt-in because window capture
        // needs screen-recording access and a briefly visible synthetic window. It never activates that window.
        if nativeCapture {
            guard CGPreflightScreenCaptureAccess() else { throw XCTSkip("macOS has not granted screen capture access") }
            let window = try XCTUnwrap(host.window)
            let origin = window.frame.origin
            defer { window.setFrameOrigin(origin) }
            if let screen = NSScreen.main {
                window.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - window.frame.width - 20,
                                             y: screen.visibleFrame.maxY - window.frame.height - 20))
            }
            window.display()
            settle()
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
            defer { try? FileManager.default.removeItem(at: file) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "capture only the synthetic test window")
            let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: file)))
            let rect = host.convert(host.bounds, to: nil)
            let scale = CGFloat(image.pixelsWide) / window.frame.width
            let crop = NSRect(x: rect.minX * scale, y: (window.frame.height - rect.maxY) * scale,
                              width: rect.width * scale, height: rect.height * scale)
            return NSBitmapImageRep(cgImage: try XCTUnwrap(image.cgImage?.cropping(to: crop)))
        }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func light(_ image: NSBitmapImageRep) -> Double {
        var total = 0.0
        for y in stride(from: 0, to: image.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: image.pixelsWide, by: 3) {
                if let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    total += color.redComponent + color.greenComponent + color.blueComponent
                }
            }
        }
        return total
    }

    func testSecondaryButtonBrightensWithoutMovingAndRestoresOnExit() throws {
        guard nativeCapture else { throw XCTSkip("Set NX_NATIVE_HOVER_CAPTURE=1 to verify compositor output") }
        let view = Button("Choose…") {}.buttonStyle(LauncherSecondaryButtonStyle())
            .frame(width: 260, height: 100).background(LauncherPalette.background).preferredColorScheme(.dark)
        let host = NSHostingView(rootView: view)
        let window = OffscreenWindow(size: NSSize(width: 260, height: 100))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        settle()
        let size = host.fittingSize
        let idleImage = try snapshot(host)
        let idle = light(idleImage)
        let region = try XCTUnwrap(descendants(host).compactMap { $0 as? LauncherHoverRegion.TrackingView }.first)
        let corner = region.convert(NSPoint(x: 0.5, y: 0.5), to: host)
        let x = Int(corner.x * CGFloat(idleImage.pixelsWide) / host.bounds.width)
        let y = Int(corner.y * CGFloat(idleImage.pixelsHigh) / host.bounds.height)
        try hover(host, entered: true)
        let hoveredImage = try snapshot(host)
        XCTAssertGreaterThan(light(hoveredImage), idle + 1)
        XCTAssertEqual(hoveredImage.colorAt(x: x, y: y), idleImage.colorAt(x: x, y: y),
                       "transparent pixels outside the rounded corner must not brighten")
        XCTAssertEqual(host.fittingSize, size)
        try hover(host, entered: false)
        XCTAssertEqual(light(try snapshot(host)), idle, accuracy: 0.01)
    }

    func testDisabledControlIgnoresHoverAndRemovalDetachesItsCursorRegion() throws {
        func control(disabled: Bool) -> some View {
            Button("Choose…") {}.buttonStyle(LauncherSecondaryButtonStyle()).disabled(disabled)
                .frame(width: 260, height: 100).background(LauncherPalette.background).preferredColorScheme(.dark)
        }
        let host = NSHostingView(rootView: AnyView(control(disabled: false)))
        let window = OffscreenWindow(size: NSSize(width: 260, height: 100))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        settle()
        let region = try XCTUnwrap(descendants(host).compactMap { $0 as? LauncherHoverRegion.TrackingView }.first)
        XCTAssertTrue(region.enabled)
        XCTAssertNil(region.hitTest(.zero), "the pointer region must not take button clicks")
        try hover(host, entered: true)
        host.rootView = AnyView(control(disabled: true))
        settle()
        XCTAssertFalse(region.enabled, "disabling a hovered control removes its hand cursor")
        let disabled = light(try snapshot(host))
        try hover(host, entered: false)
        XCTAssertEqual(light(try snapshot(host)), disabled, accuracy: 0.01)
        try hover(host, entered: true)
        XCTAssertEqual(light(try snapshot(host)), disabled, accuracy: 0.01)
        host.rootView = AnyView(EmptyView())
        settle()
        XCTAssertNil(region.window, "removing a hovered control removes its cursor rectangle from the window")
        XCTAssertFalse(descendants(host).contains { $0 is LauncherHoverRegion.TrackingView })
    }

    private final class CursorProbe: LauncherHoverRegion.TrackingView {
        var cursors: [NSCursor] = []
        override func addCursorRect(_ rect: NSRect, cursor: NSCursor) { cursors.append(cursor) }
    }

    func testOnlyEnabledControlsRegisterTheNativePointingHand() {
        let region = CursorProbe(frame: NSRect(x: 0, y: 0, width: 100, height: 36))
        region.resetCursorRects()
        XCTAssertEqual(region.cursors, [.pointingHand])
        region.cursors = []
        region.enabled = false
        region.resetCursorRects()
        XCTAssertTrue(region.cursors.isEmpty)
    }

    func testPlainButtonKeepsHitTestingAndKeyboardActivation() throws {
        var presses = 0
        func control(_ key: KeyEquivalent, disabled: Bool = false) -> some View {
            Button("Choose…") { presses += 1 }
                .buttonStyle(.plain).launcherHover().keyboardShortcut(key, modifiers: []).disabled(disabled)
                .frame(width: 260, height: 100)
        }
        let host = NSHostingView(rootView: control(.return))
        let window = OffscreenWindow(size: NSSize(width: 260, height: 100))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        settle()
        let target = try XCTUnwrap(host.hitTest(NSPoint(x: 130, y: 50)))
        XCTAssertFalse(target is LauncherHoverRegion.TrackingView, "the button still receives pointer hits")
        for (key, characters, code) in [(KeyEquivalent.return, "\r", UInt16(36)), (KeyEquivalent.space, " ", UInt16(49))] {
            host.rootView = control(key)
            settle()
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code))
            let previous = presses
            XCTAssertTrue(window.performKeyEquivalent(with: event))
            XCTAssertEqual(presses, previous + 1)
            host.rootView = control(key, disabled: true)
            settle()
            _ = window.performKeyEquivalent(with: event)
            XCTAssertEqual(presses, previous + 1, "disabled buttons do not activate")
        }
    }

    func testLibraryHoverRegionsKeepSelectionAndFocus() throws {
        let output = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"].map { URL(fileURLWithPath: $0) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let games = [LibraryGame(titleID: "0100000000000001", name: "Example Game"),
                     LibraryGame(titleID: "0100000000000002", name: "Another Game")]
        let file = temporary.appendingPathComponent("library.json")
        try JSONEncoder().encode(games).write(to: file)
        for lang in CaptureLanguage.all(Lang.all) {
            let stores = LauncherStores(defaults: testDefaults)
            stores.localizer.lang = lang
            let library = GameLibrary(file: file)
            library.selectedID = games[0].id
            let focus = PadFocus()
            let view = LauncherView(stores: stores, library: library, performStartupChecks: false, padFocus: focus)
            let host = NSHostingView(rootView: view)
            let window = OffscreenWindow(size: NSSize(width: 1100, height: 780))
            window.contentView = host
            window.orderFront(nil)
            settle()
            if let output {
                try XCTUnwrap(snapshot(host).representation(using: .png, properties: [:]))
                    .write(to: output.appendingPathComponent("\(lang.code)-idle.png"))
            }
            let frames = try XCTUnwrap(focus.frames["main"])
            for (name, id) in [("card", "card." + games[1].id.uuidString), ("hero", "hero.play"), ("topbar", "top.build")] {
                let frame = try XCTUnwrap(frames.first { $0.id == id }?.frame)
                XCTAssertEqual(try hover(host, entered: true, at: NSPoint(x: frame.midX, y: frame.midY)), 1,
                               "hover must not spread to a sibling control")
                XCTAssertEqual(library.selectedID, games[0].id, "hover does not change selection")
                XCTAssertNil(focus.focused, "hover does not change controller focus")
                if let output {
                    let image = try snapshot(host)
                    try XCTUnwrap(image.representation(using: .png, properties: [:]))
                        .write(to: output.appendingPathComponent("\(lang.code)-\(name).png"))
                }
                try hover(host, entered: false)
            }
            window.orderOut(nil)

            guard let output else { continue }
            let button = Button(stores.localizer.t("data.choose")) {}.buttonStyle(LauncherSecondaryButtonStyle())
                .frame(width: 320, height: 120).background(LauncherPalette.background).preferredColorScheme(.dark)
            let buttonHost = NSHostingView(rootView: button)
            let buttonWindow = OffscreenWindow(size: NSSize(width: 320, height: 120))
            buttonWindow.contentView = buttonHost
            buttonWindow.orderFront(nil)
            settle()
            try hover(buttonHost, entered: true)
            try XCTUnwrap(snapshot(buttonHost).representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("\(lang.code)-secondary.png"))
            buttonWindow.orderOut(nil)
        }
    }
}
