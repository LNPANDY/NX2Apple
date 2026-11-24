import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher
@testable import NXModel

@MainActor final class PinSelectionCaptureTests: IsolatedDefaultsTestCase {
    private func settle(_ seconds: Double = 0.5) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testCapturePinSelectionScene() throws {
        guard let dir = ProcessInfo.processInfo.environment["NX_PIN_CAPTURE_DIR"],
              let stage = ProcessInfo.processInfo.environment["NX_PIN_CAPTURE_STAGE"] else {
            throw XCTSkip("Set NX_PIN_CAPTURE_DIR and NX_PIN_CAPTURE_STAGE to capture pin-selection screenshots")
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let wasStatic = LauncherGlass.forceStatic
        LauncherGlass.forceStatic = true
        defer { LauncherGlass.forceStatic = wasStatic }

        for lang in [Lang.en, Lang.zh] {
            let fixtures = GalleryFixtures(lang: lang)
            let folder = fixtures.directory.appendingPathComponent("lib-\(lang.code)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let library = GameLibrary(file: folder.appendingPathComponent("library.json"), artwork: fixtures.artworkFolder)
            library.applicationFolders = []
            for (index, item) in fixtures.catalog.enumerated() {
                var game = LibraryGame(titleID: item.titleID, name: item.name)
                game.inputs["base"] = ["/Volumes/Games/\(item.name) [\(item.titleID)].nsp"]
                game.lastPlayed = Date(timeIntervalSince1970: 1_790_000_000 - Double(index) * 86_400)
                library.upsert(game)
            }
            let target = library.games[11]
            let stores = LauncherStores(localizer: Localizer(lang), defaults: testDefaults)
            let pad = PadFocus()
            let window = OffscreenWindow(size: NSSize(width: 1280, height: 800), styleMask: [.titled, .closable, .resizable, .fullSizeContentView])
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(LauncherPalette.background)
            let root = LauncherView(
                stores: stores,
                library: library,
                performStartupChecks: false,
                padFocus: pad,
                allGamesOpen: true
            )
            .frame(width: 1280, height: 800)
            .background(LauncherPalette.background)
            window.contentView = NSHostingView(rootView: root)
            window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            settle(0.6)

            pad.show(default: "card." + target.id.uuidString)
            settle(0.2)
            pad.activate()
            settle(0.8)

            let view = try XCTUnwrap(window.contentView)
            view.layoutSubtreeIfNeeded()
            let scale = window.backingScaleFactor
            let pxW = Int(view.bounds.width * scale)
            let pxH = Int(view.bounds.height * scale)
            let bgColor = NSColor(srgbRed: 0.055, green: 0.059, blue: 0.071, alpha: 1)
            func makeDarkRep(size: NSSize) -> NSBitmapImageRep? {
                let w = max(1, Int(size.width * scale)), h = max(1, Int(size.height * scale))
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
                rep.size = size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                bgColor.setFill()
                NSRect(origin: .zero, size: size).fill()
                NSGraphicsContext.restoreGraphicsState()
                return rep
            }

            let fullRep = try XCTUnwrap(makeDarkRep(size: view.bounds.size))
            view.cacheDisplay(in: view.bounds, to: fullRep)

            func collectScrollViews(_ root: NSView, into out: inout [NSScrollView]) {
                if let sv = root as? NSScrollView { out.append(sv) }
                for sub in root.subviews { collectScrollViews(sub, into: &out) }
            }
            var scrollViews: [NSScrollView] = []
            collectScrollViews(view, into: &scrollViews)

            let image = NSImage(size: view.bounds.size)
            image.lockFocus()
            bgColor.setFill()
            NSRect(origin: .zero, size: view.bounds.size).fill()
            for sv in scrollViews {
                guard let doc = sv.documentView, !sv.isHiddenOrHasHiddenAncestor,
                      let docRep = makeDarkRep(size: doc.visibleRect.size) else { continue }
                let vis = doc.visibleRect
                guard vis.width > 1, vis.height > 1 else { continue }
                doc.cacheDisplay(in: vis, to: docRep)
                let frameInRoot = view.convert(sv.contentView.bounds, from: sv.contentView)
                let unflippedY = view.isFlipped ? (view.bounds.height - frameInRoot.maxY) : frameInRoot.minY
                let drawRect = NSRect(x: frameInRoot.minX, y: unflippedY, width: frameInRoot.width, height: frameInRoot.height)
                docRep.draw(in: drawRect)
            }
            // Re-draw top bar (top 64pt) and bottom activity bar (bottom 84pt) from fullRep on top of the scroll view
            let topSlice = NSRect(x: 0, y: view.bounds.height - 65, width: view.bounds.width, height: 65)
            fullRep.draw(in: topSlice, from: topSlice, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            let bottomSlice = NSRect(x: 0, y: 0, width: view.bounds.width, height: 84)
            fullRep.draw(in: bottomSlice, from: bottomSlice, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            image.unlockFocus()
            _ = (pxW, pxH)
            guard let tiff = image.tiffRepresentation,
                  let outRep = NSBitmapImageRep(data: tiff),
                  let data = outRep.representation(using: .png, properties: [:]) else {
                XCTFail("Failed to encode composite PNG")
                continue
            }
            try data.write(to: output.appendingPathComponent("\(stage)-\(lang.code).png"))
        }
    }
}
