import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

@MainActor final class ConsoleArtworkChipTests: IsolatedDefaultsTestCase {
    func testNeutralMetadataAndArtworkChipsShareBorderPixels() throws {
        func border(indicator: Bool, fontSize: CGFloat) throws -> NSColor {
            let view = NSHostingView(rootView: ArtworkStatusChip(title: "Example", color: ArtworkStatusChip.neutralColor,
                fontSize: fontSize, showsIndicator: indicator).fixedSize())
            view.setFrameSize(view.fittingSize); view.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            return try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: 0)?.usingColorSpace(.sRGB))
        }
        for size in [CGFloat(11), 15] {
            let artwork = try border(indicator: true, fontSize: size)
            let metadata = try border(indicator: false, fontSize: size)
            XCTAssertGreaterThan(metadata.redComponent, 0.7)
            XCTAssertEqual(metadata.redComponent, artwork.redComponent, accuracy: 0.02)
        }
    }

    func testAdvisoryChipKeepsWhiteTextAndBlueAccentInBothAppearances() throws {
        for dark in [false, true] {
            let host = NSHostingView(rootView: ArtworkStatusChip(title: "Older iOS build", color: LauncherPalette.advisory, textColor: .white)
                .fixedSize().environment(\.colorScheme, dark ? .dark : .light))
            let window = OffscreenWindow(size: .init(width: 180, height: 40))
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host; window.orderBack(nil)
            defer { window.contentView = nil; window.orderOut(nil); window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            var white = 0, blue = 0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if c.blueComponent > 0.6 && c.blueComponent > c.redComponent + 0.2 { blue += 1 }
                    if x > rep.pixelsWide / 5 && x < rep.pixelsWide * 4 / 5 && y > rep.pixelsHigh / 3 && y < rep.pixelsHigh * 2 / 3,
                       c.redComponent > 0.85 && c.greenComponent > 0.85 && c.blueComponent > 0.85 { white += 1 }
                }
            }
            XCTAssertGreaterThan(blue, 10)
            XCTAssertGreaterThan(white, 10)
            if let path = ProcessInfo.processInfo.environment["NX_CHIP_CAPTURE_DIR"] {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(dark ? "older-ios-dark.png" : "older-ios-light.png"))
            }
        }
    }

    func testLoadingPillFillsFromLeftToRight() throws {
        let view = NSHostingView(rootView: ConsoleLaunchProgress(progress: 0.5, label: "Loading").frame(width: 200, height: 60).environment(\.colorScheme, .dark))
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 60)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let left = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 4, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        let right = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide * 3 / 4, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(left.redComponent, 0.9)
        XCTAssertLessThan(right.redComponent, 0.3)
    }

    func testIndeterminatePillFillRestartsAtLeftAndRespectsReducedMotion() {
        XCTAssertEqual(ConsoleLaunchProgress.phase(at: Date(timeIntervalSinceReferenceDate: 0), reducedMotion: false), 0)
        XCTAssertEqual(ConsoleLaunchProgress.phase(at: Date(timeIntervalSinceReferenceDate: 1), reducedMotion: false), 0.5)
        XCTAssertEqual(ConsoleLaunchProgress.phase(at: Date(timeIntervalSinceReferenceDate: 2), reducedMotion: false), 0)
        XCTAssertEqual(ConsoleLaunchProgress.phase(at: Date(timeIntervalSinceReferenceDate: 0), reducedMotion: true), 0.5)
    }

    func testConsoleUsesSharedStatusKeysWithoutFilesystemChecks() {
        var game = MockConsoleDriver(scenario: .full, animated: false).state.games[0]
        game.status = .ready
        game.platforms = [.mac]
        XCTAssertNil(LibraryArtworkState(game).chipKey)
        game.platforms = [.mac, .iphone]
        XCTAssertEqual(LibraryArtworkState(game).chipKey, "library.chip.both")
        XCTAssertEqual(LibraryArtworkState(game).symbol, "laptopcomputer.and.iphone")
        game.status = .iphoneOnly
        game.platforms = [.iphone]
        XCTAssertEqual(LibraryArtworkState(game).chipKey, "library.chip.iosOnly")
        XCTAssertEqual(LibraryArtworkState(game).symbol, "iphone")
        game.platforms = []
        XCTAssertEqual(LibraryArtworkState(game).chipKey, "library.chip.iosOnly", "Explicit iOS-only status remains authoritative")
        for (status, key) in [(ConsoleGame.Status.needsBuild, "library.chip.notBuilt"), (.needsData, "ios.ui.missingDataChip"), (.broken("Incomplete"), "ios.ui.fixGameFilesChip")] {
            game.status = status
            XCTAssertEqual(LibraryArtworkState(game).chipKey, key)
        }
    }

    func testUnavailableSelectedArtworkIsMonochromeWithoutInactiveDimming() throws {
        var game = MockConsoleDriver(scenario: .full, animated: false).state.games[0]
        game.olderTools = false
        game.artwork = NSImage(size: NSSize(width: 360, height: 200), flipped: false) { bounds in
            NSColor.red.setFill(); bounds.fill(); return true
        }
        func pixel(status: ConsoleGame.Status, selected: Bool) throws -> NSColor {
            game.status = status
            let view = NSHostingView(rootView: ConsoleGameTile(game: game, selected: selected, compact: false, lang: .en)
                .frame(width: 360, height: 250).transaction { $0.disablesAnimations = true })
            let window = OffscreenWindow(size: NSSize(width: 360, height: 250), styleMask: [.borderless])
            window.contentView = view; window.orderBack(nil)
            defer { window.contentView = nil; window.orderOut(nil); window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            view.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            return try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 3)?.usingColorSpace(.deviceRGB))
        }
        let active = try pixel(status: .needsBuild, selected: true)
        let inactive = try pixel(status: .needsBuild, selected: false)
        XCTAssertGreaterThan(active.redComponent, active.greenComponent + 0.5, "selected unbuilt tile restores full color")
        XCTAssertGreaterThan(inactive.redComponent, inactive.greenComponent + 0.12, "inactive unbuilt tile uses soft muted color, not grayscale")
        XCTAssertGreaterThan(active.redComponent, inactive.redComponent + 0.02)
        let ready = try pixel(status: .ready, selected: true)
        XCTAssertGreaterThan(ready.redComponent, ready.greenComponent + 0.5)
    }
}
