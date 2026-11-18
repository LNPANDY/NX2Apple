import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
@testable import NXLauncher

@MainActor final class LibraryEmptyStateTests: IsolatedDefaultsTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.4)) }

    private func host(_ games: [LibraryGame], scheme: ColorScheme = .dark, height: CGFloat = 974, search: String? = nil) throws -> (GameLibrary, PadFocus, LauncherStores, OffscreenWindow) {
        let root = try directory(), file = root.appendingPathComponent("library.json")
        try JSONEncoder().encode(games).write(to: file)
        let library = GameLibrary(file: file), stores = LauncherStores(defaults: testDefaults), pad = PadFocus()
        let window = OffscreenWindow(size: NSSize(width: 1257, height: height))
        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        window.contentView = NSHostingView(rootView: LauncherView(stores: stores, library: library,
            performStartupChecks: false, search: search, padFocus: pad).preferredColorScheme(scheme))
        window.orderFront(nil)
        addTeardownBlock { MainActor.assumeIsolated { window.orderOut(nil); window.contentView = nil; window.close() } }
        settle()
        return (library, pad, stores, window)
    }

    func testNoMatchSearchHasNoHiddenHeroActionAndKeepsSupportedGamesReachable() throws {
        let game = LibraryGame(titleID: "0100000000000000", name: "Example", inputs: ["base": ["/tmp/game.nsp"]])
        let (library, pad, stores, _) = try host([game], search: "no-such-game")
        let view = LauncherView(stores: stores, library: library, performStartupChecks: false, search: "no-such-game")
        XCTAssertNil(view.heroGame)
        XCTAssertTrue(view.filteredGames.isEmpty)
        XCTAssertFalse(pad.frames["main", default: []].contains { $0.id == "hero.play" || $0.id.hasPrefix("card.") })
        XCTAssertNotNil(pad.frame(of: "library.supported"))
    }

    func testEmptyPlatformFiltersKeepHeroAndCarouselGeometryAndRecover() throws {
        let prior = UserDefaults.standard.object(forKey: "libraryFilter")
        defer {
            if let prior { UserDefaults.standard.set(prior, forKey: "libraryFilter") }
            else { UserDefaults.standard.removeObject(forKey: "libraryFilter") }
        }
        UserDefaults.standard.removeObject(forKey: "libraryFilter")
        var game = LibraryGame(titleID: "0100000000000000", name: "Source-only game",
                               inputs: ["base": ["/tmp/game.nsp"]], sourceFolder: "/tmp")
        game.installedDevice = "previous-install-record"
        let (_, pad, stores, window) = try host([game], height: 680)
        func frame(_ id: String) throws -> CGRect { try XCTUnwrap(pad.frames["main"]?.first { $0.id == id }?.frame, id) }
        let filter = try frame("library.filter"), sort = try frame("library.sort")
        for _ in 0..<2 {
            pad.show(default: "library.filter"); pad.activate()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let early = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            _ = window.performKeyEquivalent(with: early)
            XCTAssertTrue(stores.build.gameDir.isEmpty)
            settle()
            XCTAssertEqual(try frame("library.filter").minY, filter.minY, accuracy: 1)
            XCTAssertEqual(try frame("library.sort"), sort)
            XCTAssertGreaterThan(try frame("library.filter").minY, try frame("tab.library").maxY + 200)
            XCTAssertFalse(pad.frames["main", default: []].contains { $0.id == "library.empty.primary" }, "The visible filter is the recovery control, not a duplicate hero action")
            XCTAssertFalse(pad.frames["main", default: []].contains { $0.id.hasPrefix("card.") })
            let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            _ = window.performKeyEquivalent(with: key)
            XCTAssertTrue(stores.build.gameDir.isEmpty, "An empty result must not activate the hidden game's shortcut")
        }
        pad.show(default: "library.filter"); pad.activate(); settle()
        XCTAssertEqual(try frame("library.filter").minY, filter.minY, accuracy: 1)
        XCTAssertTrue(pad.frames["main", default: []].contains { $0.id == "card." + game.id.uuidString })
    }

    func testTrulyEmptyLibraryUsesTheSameHeroBoundaryInBothAppearances() throws {
        for scheme in [ColorScheme.light, .dark] {
            let (_, emptyPad, _, emptyWindow) = try host([], scheme: scheme)
            let emptyFilter = try XCTUnwrap(emptyPad.frames["main"]?.first { $0.id == "library.filter" }?.frame)
            let primary = try XCTUnwrap(emptyPad.frames["main"]?.first { $0.id == "library.empty.primary" }?.frame)
            let folder = try XCTUnwrap(emptyPad.frames["main"]?.first { $0.id == "library.empty.folder" }?.frame)
            XCTAssertEqual(folder.size, CGSize(width: 44, height: 44))
            XCTAssertEqual(primary.midY, folder.midY, accuracy: 1)
            let game = LibraryGame(titleID: "0100000000000000", name: "Example")
            let (_, populatedPad, _, _) = try host([game], scheme: scheme)
            let populatedFilter = try XCTUnwrap(populatedPad.frames["main"]?.first { $0.id == "library.filter" }?.frame)
            XCTAssertEqual(emptyFilter.minY, populatedFilter.minY, accuracy: 1)
            XCTAssertFalse(emptyPad.frames["main", default: []].contains { $0.id.hasPrefix("card.") })
            if let path = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"], let view = emptyWindow.contentView {
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent(scheme == .light ? "library-first-use-light.png" : "library-first-use-dark.png")
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
            }
        }
    }

    func testBackdropMarkPreservesTransparentCornersBeforeBlur() throws {
        let image = try XCTUnwrap(LauncherBrandMark.backdropImage)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        XCTAssertTrue(bitmap.hasAlpha)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 0, accuracy: 0.01)
    }

    func testBlurredFallbackHasSoftVisibleEdgesInBothAppearances() throws {
        for scheme in [ColorScheme.light, .dark] {
            let host = NSHostingView(rootView: LibraryFallbackArtwork(size: CGSize(width: 1000, height: 400))
                .preferredColorScheme(scheme))
            host.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            let window = OffscreenWindow(size: NSSize(width: 1000, height: 400))
            window.contentView = host; window.orderFront(nil); settle()
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let y = bitmap.pixelsHigh / 3
            let values = (0..<bitmap.pixelsWide).compactMap { x -> Int? in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return nil }
                return Int((color.redComponent * 255).rounded())
            }
            XCTAssertGreaterThan((values.max() ?? 0) - (values.min() ?? 0), 5, "The NX mark remains visible")
            let jumps = zip(values, values.dropFirst()).map { abs($0 - $1) }
            XCTAssertLessThanOrEqual(jumps.max() ?? 255, 8, "A blurred mark must not expose a hard rectangular image edge")
            if let path = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent(scheme == .light ? "nx-fallback-light.png" : "nx-fallback-dark.png")
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
            }
        }
    }

    func testPlaceholderMatchesRealCardFootprintAtCarouselWidths() {
        let state = LibraryArtworkState(LibraryGame(titleID: "0100000000000000", name: "Example"))
        for scheme in [ColorScheme.light, .dark] {
            for available in [CGFloat(900), 1257, 1900] {
                let width = LibraryCardLayout.width(in: available), localizer = Localizer(.en)
                let card = NSHostingView(rootView: LibraryGameCard(title: "Example", image: nil, focus: .center,
                    state: state, width: width, selected: false, select: {}).environmentObject(localizer).preferredColorScheme(scheme))
                let placeholder = NSHostingView(rootView: LibraryCarouselPlaceholder(width: width)
                    .environmentObject(localizer).preferredColorScheme(scheme))
                XCTAssertEqual(card.fittingSize.width, placeholder.fittingSize.width, accuracy: 0.5)
                XCTAssertEqual(card.fittingSize.height, placeholder.fittingSize.height, accuracy: 0.5)
            }
        }
    }
}
