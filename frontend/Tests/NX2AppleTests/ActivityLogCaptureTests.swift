import AppKit
import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher
import NXModel

/// Opt-in visual QA captures for the Activity Log and hero playtime (#1161).
/// Run with `NX_LAUNCHER_CAPTURE_DIR=<dir> NX_CAPTURE_LANG=en|zh swift test --filter ActivityLogCaptureTests`.
@MainActor final class ActivityLogCaptureTests: IsolatedDefaultsTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nx-activity-capture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    private func makeApp(_ id: String, name: String, zhName: String, version: String) throws -> URL {
        let app = temporary.appendingPathComponent(id + ".app")
        let executables = app.appendingPathComponent("Contents/MacOS")
        let dm = app.appendingPathComponent("Contents/Resources/dm")
        try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dm, withIntermediateDirectories: true)
        for exe in ["nxnative", "dmhost"] {
            try FileManager.default.createSymbolicLink(
                at: executables.appendingPathComponent(exe),
                withDestinationURL: URL(fileURLWithPath: "/usr/bin/true")
            )
        }
        let info: [String: Any] = [
            "DMTitleID": id,
            "CFBundleDisplayName": name,
            "CFBundleExecutable": "nxnative",
            "CFBundleShortVersionString": version,
            "CFBundleIdentifier": TestPreferences.domain(in: temporary, "act-" + id),
            "DMTitleNames": ["en": name, "zh": zhName]
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let fps = #"{"env": "DM_FPS_TARGET", "kind": "choice", "label": "Frame rate", "note": "", "default": "60", "section": "Game", "level": "basic", "options": [["30", "30"], ["60", "60"]]}"#
        try #"{"game": "\#(id)", "settings": [\#(fps)]}"#
            .write(to: dm.appendingPathComponent("launcher.json"), atomically: true, encoding: .utf8)
        return app
    }

    private func makeGradientPNG(name: String, c0: (CGFloat, CGFloat, CGFloat), c1: (CGFloat, CGFloat, CGFloat)) throws -> URL {
        let width = 1280, height = 720
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("Failed to allocate CGContext")
            return temporary
        }
        let colors = [
            CGColor(srgbRed: c0.0, green: c0.1, blue: c0.2, alpha: 1),
            CGColor(srgbRed: c1.0, green: c1.1, blue: c1.2, alpha: 1)
        ] as CFArray
        let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: CGFloat(height)),
            end: CGPoint(x: CGFloat(width), y: 0),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14))
        ctx.fillEllipse(in: CGRect(x: CGFloat(width) * 0.66, y: CGFloat(height) * 0.42, width: 460, height: 460))
        let url = temporary.appendingPathComponent(name + ".png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func renderToPNG<V: View>(
        _ view: V,
        size: NSSize,
        styleMask: NSWindow.StyleMask,
        wait: TimeInterval,
        to file: URL
    ) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let window = OffscreenWindow(size: size, styleMask: styleMask)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        RunLoop.main.run(until: Date().addingTimeInterval(wait))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            XCTFail("Missing bitmapImageRepForCachingDisplay")
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            XCTFail("Missing PNG representation")
            return
        }
        try data.write(to: file)
    }

    func testRenderActivityLogForVisualQA() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else {
            throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views")
        }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)

        let lang = CaptureLanguage.current(.en)
        let artworkDir = temporary.appendingPathComponent("artwork", isDirectory: true)
        try FileManager.default.createDirectory(at: artworkDir, withIntermediateDirectories: true)
        let artworkStore = ArtworkStore(directory: artworkDir)
        let library = GameLibrary(file: temporary.appendingPathComponent("library.json"), artwork: artworkDir)
        library.applicationFolders = []

        let specs: [(id: String, en: String, zh: String, ver: String, c0: (CGFloat, CGFloat, CGFloat), c1: (CGFloat, CGFloat, CGFloat))] = [
            ("0100AA0000010000", "Starlight Odyssey", "星光奥德赛", "1.2.0", (0.20, 0.30, 0.80), (0.48, 0.22, 0.78)),
            ("0100AA0000020000", "Chrono Horizon", "时空地平线", "1.0.4", (0.16, 0.50, 0.54), (0.22, 0.32, 0.62)),
            ("0100AA0000030000", "Aether Drift", "苍穹漂移", "2.1.0", (0.76, 0.34, 0.30), (0.44, 0.20, 0.48))
        ]

        var coverImages: [UUID: NSImage] = [:]
        var starlightUUID: UUID?
        for (idx, spec) in specs.enumerated() {
            let appURL = try makeApp(spec.id, name: spec.en, zhName: spec.zh, version: spec.ver)
            let gameID = try library.addApp(appURL)
            if idx == 0 { starlightUUID = gameID }
            let png = try makeGradientPNG(name: spec.id, c0: spec.c0, c1: spec.c1)
            let copy = try ArtworkImport.prepare(png, kind: .hero, into: ArtworkStore.customDirectory(for: gameID, in: artworkDir))
            let choice = ArtworkChoice(source: .imported(copy.url.lastPathComponent))
            library.setArtwork(GameArtwork(hero: choice, thumbnail: choice), for: gameID)
            coverImages[gameID] = NSImage(contentsOf: copy.url)
        }
        library.selectedID = starlightUUID

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 18, minute: 0))!

        let stores = LauncherStores(defaults: testDefaults)
        stores.dependencies.checked = true
        stores.localizer.lang = lang
        let playStore = stores.playSessions

        func addSession(_ id: String, title: String, daysAgo: Int, minutes: Double) {
            let start = cal.date(byAdding: .day, value: -daysAgo, to: now) ?? now
            playStore.started(titleID: id, title: title, at: start)
            playStore.ended(titleID: id, at: start.addingTimeInterval(minutes * 60))
        }
        let starTitle = lang == .zh ? "星光奥德赛" : "Starlight Odyssey"
        let chronoTitle = lang == .zh ? "时空地平线" : "Chrono Horizon"
        let aetherTitle = lang == .zh ? "苍穹漂移" : "Aether Drift"
        let removedTitle = lang == .zh ? "曜星纪元" : "Solaris Prime"

        for (d, m) in [(13, 65.0), (12, 80.0), (10, 95.0), (9, 50.0), (7, 110.0), (6, 75.0), (4, 120.0), (3, 60.0), (1, 105.0), (0, 100.0)] {
            addSession("0100AA0000010000", title: starTitle, daysAgo: d, minutes: m)
        }
        for (d, m) in [(11, 55.0), (8, 70.0), (5, 85.0), (2, 65.0), (1, 45.0)] {
            addSession("0100AA0000020000", title: chronoTitle, daysAgo: d, minutes: m)
        }
        for (d, m) in [(9, 40.0), (4, 35.0), (0, 50.0)] {
            addSession("0100AA0000030000", title: aetherTitle, daysAgo: d, minutes: m)
        }
        for (d, m) in [(13, 45.0), (6, 50.0)] {
            addSession("0100AA0000090000", title: removedTitle, daysAgo: d, minutes: m)
        }

        let launcher = LauncherView(
            stores: stores,
            library: library,
            initialPage: .library,
            performStartupChecks: false,
            artworkStore: artworkStore
        )
        try renderToPNG(
            launcher,
            size: NSSize(width: 1400, height: 920),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            wait: 0.8,
            to: output.appendingPathComponent("mac-library-after-\(lang.code).png")
        )

        let sheet = ActivityLogSheet(
            store: playStore,
            owned: { id in library.games.first { $0.titleID.uppercased() == id } },
            cover: { game in coverImages[game.id] },
            showInLibrary: { _ in },
            now: now,
            initialExpandedID: "0100AA0000010000"
        )
        .environmentObject(stores.localizer)
        .environmentObject(PadFocus())
        try renderToPNG(
            sheet,
            size: NSSize(width: ActivityLogSheet.width, height: 860),
            styleMask: [.borderless],
            wait: 0.5,
            to: output.appendingPathComponent("mac-activity-log-after-\(lang.code).png")
        )
    }
}
