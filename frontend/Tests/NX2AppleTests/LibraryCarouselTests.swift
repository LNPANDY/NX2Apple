import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
@testable import NXLauncher

/// The library's Recently played row and the All games grid behind Show all (LNPANDY/NX2Apple#1458).
@MainActor final class LibraryCarouselTests: IsolatedDefaultsTestCase {
    private func settle(_ seconds: Double = 0.4) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func host(games count: Int, allGames: Bool = false) throws -> (GameLibrary, PadFocus, [LibraryGame], OffscreenWindow) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var games = (0..<count).map { LibraryGame(titleID: String(format: "%016llX", UInt64(0x0100000000000000) + UInt64($0) * 0x2000), name: String(format: "Game %02d", $0)) }
        for index in games.indices { games[index].lastPlayed = Date(timeIntervalSince1970: 1_800_000_000 - Double(index) * 60) }
        let file = root.appendingPathComponent("library.json")
        try JSONEncoder().encode(games).write(to: file)
        let library = GameLibrary(file: file), stores = LauncherStores(defaults: testDefaults), pad = PadFocus()
        let window = OffscreenWindow(size: NSSize(width: 1280, height: 800))
        window.contentView = NSHostingView(rootView: LauncherView(stores: stores, library: library, performStartupChecks: false, padFocus: pad,
                                                                  allGamesOpen: allGames))
        window.orderFront(nil)
        addTeardownBlock { MainActor.assumeIsolated { window.orderOut(nil); window.contentView = nil; window.close() } }
        settle()
        return (library, pad, games, window)
    }

    private func ids(_ pad: PadFocus) -> Set<String> { Set(pad.frames["main", default: []].map(\.id)) }

    func testAShortLibraryFitsTheRowWithoutShowAll() throws {
        let (_, pad, games, _) = try host(games: 6)
        let ids = ids(pad)
        XCTAssertEqual(ids.filter { $0.hasPrefix("card.") }.count, games.count, "every game is in the row")
        XCTAssertFalse(ids.contains("library.showAll"))
        XCTAssertFalse(ids.contains("library.showAllCard"))
        XCTAssertFalse(ids.contains("library.filter"), "the filter belongs to All games")
    }

    func testALongLibraryShowsTheMostRecentAndOffersShowAll() throws {
        let (_, pad, games, _) = try host(games: 14)
        let ids = ids(pad)
        let cards = ids.filter { $0.hasPrefix("card.") }
        XCTAssertEqual(cards.count, LauncherView.recentLimit)
        XCTAssertTrue(cards.contains("card." + games[0].id.uuidString), "the most recently played game is in the row")
        XCTAssertFalse(cards.contains("card." + games[13].id.uuidString), "the least recent one waits in All games")
        XCTAssertTrue(ids.contains("library.showAll"))
        XCTAssertTrue(ids.contains("library.showAllCard"))
    }

    func testShowAllOpensTheGridAndChoosingAGameReturnsWithItAsTheHero() throws {
        let (library, pad, games, _) = try host(games: 14)
        pad.show(default: "library.showAll"); pad.activate(); settle()
        var ids = ids(pad)
        XCTAssertTrue(ids.contains("allGames.back"))
        XCTAssertTrue(ids.contains("library.filter"))
        XCTAssertGreaterThanOrEqual(ids.filter { $0.hasPrefix("card.") }.count, 8, "the grid shows the library in rows")
        pad.focused = "card." + games[7].id.uuidString; settle(0.1)
        pad.activate(); settle()
        XCTAssertEqual(library.selectedID, games[7].id)
        ids = self.ids(pad)
        XCTAssertFalse(ids.contains("allGames.back"), "back in the library")
        XCTAssertTrue(ids.contains("hero.play"))
    }

    /// Notices share one slot under the top bar: the skipped files notice keeps its Details and its dismiss.
    func testSkippedFilesShowAsANoticeUnderTheTopBar() throws {
        let (library, pad, _, _) = try host(games: 3)
        library.skippedItems = [SkippedLibraryItem(path: "/Volumes/G/a.rar", name: "a.rar", rootPath: "/Volumes/G", reason: .unextractedArchiveOrSplit)]
        settle()
        let details = try XCTUnwrap(pad.frame(of: "library.skippedBanner"))
        let dismiss = try XCTUnwrap(pad.frame(of: "notice.library.skippedBanner.dismiss"))
        let tabs = try XCTUnwrap(pad.frame(of: "tab.library"))
        XCTAssertGreaterThan(details.minY, tabs.maxY, "under the top bar")
        XCTAssertLessThan(details.maxY, tabs.maxY + 120, "at the top of the content, not under the hero")
        XCTAssertEqual(details.midY, dismiss.midY, accuracy: 2, "one row")
        pad.show(default: "notice.library.skippedBanner.dismiss"); pad.activate(); settle()
        XCTAssertNil(pad.frame(of: "library.skippedBanner"))
    }

    /// A game that is not built keeps its cover in colour, only dimmed a little (#1458): the chip tells the state.
    func testAnUnbuiltCardStaysInColour() throws {
        let image = NSImage(size: NSSize(width: 360, height: 200), flipped: false) { rect in
            NSColor(srgbRed: 0.1, green: 0.4, blue: 0.95, alpha: 1).setFill(); rect.fill(); return true
        }
        let state = LibraryArtworkState(LibraryGame(titleID: "0100000000000000", name: "Example"))
        XCTAssertTrue(state.monochrome, "an unbuilt game needs attention")
        let card = LibraryGameCard(title: "Example", image: image, focus: .center, state: state, width: 300, selected: false, select: {})
            .environmentObject(Localizer(.en)).launcherAppearance()
        let host = NSHostingView(rootView: card)
        let window = OffscreenWindow(size: host.fittingSize)
        window.contentView = host; window.orderFront(nil); settle()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let pixel = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 3)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(Double(pixel.blueComponent - pixel.redComponent), 0.3, "the cover keeps its colour, not grey")
    }

    /// A widescreen game says so as a quiet line under its title, not as a status chip (#1458).
    func testWidescreenIsAQuietLineInTheHero() throws {
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")   // SwiftUI builds its accessibility tree
        let previous = NSApplication.shared.accessibilityAttributeValue(enhanced)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApplication.shared.accessibilitySetValue(previous ?? false, forAttribute: enhanced) }
        let fixtures = GalleryFixtures()
        let host = NSHostingView(rootView: fixtures.view(.libraryWidescreen))
        let window = OffscreenWindow(size: NSSize(width: GalleryScene.size.width, height: GalleryScene.size.height))
        window.contentView = host; window.orderFront(nil); settle(0.8)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        let labels = Self.texts(in: host)
        XCTAssertTrue(labels.contains(L10n.string("widescreen.badge", .en)), "the hero shows Widescreen: \(labels)")
    }

    private static func texts(in view: NSView) -> [String] {
        var out: [String] = []
        func visit(_ node: NSObject) {
            for selector in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                let sel = NSSelectorFromString(selector)
                if node.responds(to: sel), let value = node.perform(sel)?.takeUnretainedValue() as? String, !value.isEmpty { out.append(value) }
            }
            let children = NSSelectorFromString("accessibilityChildren")
            if node.responds(to: children), let list = node.perform(children)?.takeUnretainedValue() as? [NSObject] { list.forEach(visit) }
        }
        visit(view)
        return out
    }

    func testBackLeavesAllGames() throws {
        let (_, pad, _, _) = try host(games: 14, allGames: true)
        XCTAssertTrue(ids(pad).contains("allGames.back"))
        pad.show(default: "allGames.back"); pad.activate(); settle()
        XCTAssertFalse(ids(pad).contains("allGames.back"))
        XCTAssertTrue(ids(pad).contains("library.showAll"))
    }
}
