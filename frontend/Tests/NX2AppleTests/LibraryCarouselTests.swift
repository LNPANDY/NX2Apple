import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
@testable import NXLauncher

/// The library's Recently played row and the All games grid behind Show all (LNPANDY/NX2Apple#1458).
@MainActor final class LibraryCarouselTests: IsolatedDefaultsTestCase {
    private func settle(_ seconds: Double = 0.4) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func host(
        games count: Int,
        allGames: Bool = false,
        search: String? = nil,
        stores: LauncherStores? = nil
    ) throws -> (GameLibrary, LauncherStores, PadFocus, [LibraryGame], OffscreenWindow) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var games = (0..<count).map { LibraryGame(titleID: String(format: "%016llX", UInt64(0x0100000000000000) + UInt64($0) * 0x2000), name: String(format: "Game %02d", $0)) }
        for index in games.indices { games[index].lastPlayed = Date(timeIntervalSince1970: 1_800_000_000 - Double(index) * 60) }
        let file = root.appendingPathComponent("library.json")
        try JSONEncoder().encode(games).write(to: file)
        let library = GameLibrary(file: file), resolvedStores = stores ?? LauncherStores(defaults: testDefaults), pad = PadFocus()
        let window = OffscreenWindow(size: NSSize(width: 1280, height: 800))
        window.contentView = NSHostingView(rootView: LauncherView(stores: resolvedStores, library: library, performStartupChecks: false, search: search, padFocus: pad,
                                                                  allGamesOpen: allGames))
        window.orderFront(nil)
        addTeardownBlock { MainActor.assumeIsolated { window.orderOut(nil); window.contentView = nil; window.close() } }
        settle()
        return (library, resolvedStores, pad, games, window)
    }

    private func ids(_ pad: PadFocus) -> Set<String> { Set(pad.frames["main", default: []].map(\.id)) }

    private func orderedRowCardIDs(_ pad: PadFocus) -> [UUID] {
        pad.frames["main", default: []]
            .filter { $0.id.hasPrefix("card.") }
            .sorted { $0.frame.minX < $1.frame.minX }
            .compactMap { UUID(uuidString: String($0.id.dropFirst(5))) }
    }

    func testAShortLibraryFitsTheRowWithoutShowAll() throws {
        let (_, _, pad, games, _) = try host(games: 6)
        let ids = ids(pad)
        XCTAssertEqual(ids.filter { $0.hasPrefix("card.") }.count, games.count, "every game is in the row")
        XCTAssertFalse(ids.contains("library.showAll"))
        XCTAssertFalse(ids.contains("library.showAllCard"))
        XCTAssertFalse(ids.contains("library.filter"), "the filter belongs to All games")
    }

    func testALongLibraryShowsTheMostRecentAndOffersShowAll() throws {
        let (_, _, pad, games, _) = try host(games: 14)
        let ids = ids(pad)
        let cards = ids.filter { $0.hasPrefix("card.") }
        XCTAssertEqual(cards.count, LauncherView.recentLimit)
        XCTAssertTrue(cards.contains("card." + games[0].id.uuidString), "the most recently played game is in the row")
        XCTAssertFalse(cards.contains("card." + games[13].id.uuidString), "the least recent one waits in All games")
        XCTAssertTrue(ids.contains("library.showAll"))
        XCTAssertTrue(ids.contains("library.showAllCard"))
    }

    func testShowAllOpensTheGridAndChoosingAGameReturnsWithItAsTheHero() throws {
        let (library, stores, pad, games, _) = try host(games: 14)
        pad.show(default: "library.showAll"); pad.activate(); settle()
        var ids = ids(pad)
        XCTAssertTrue(ids.contains("allGames.back"))
        XCTAssertTrue(ids.contains("library.filter"))
        XCTAssertGreaterThanOrEqual(ids.filter { $0.hasPrefix("card.") }.count, 8, "the grid shows the library in rows")
        pad.focused = "card." + games[7].id.uuidString; settle(0.1)
        pad.activate(); settle()
        XCTAssertEqual(library.selectedID, games[7].id)
        XCTAssertEqual(stores.librarySelection.pinnedID, games[7].id)
        ids = self.ids(pad)
        XCTAssertFalse(ids.contains("allGames.back"), "back in the library")
        XCTAssertTrue(ids.contains("hero.play"))
        XCTAssertEqual(orderedRowCardIDs(pad).first, games[7].id, "chosen game is pinned first in the Recently played row")
    }

    /// Notices share one slot under the top bar: the skipped files notice keeps its Details and its dismiss.
    func testSkippedFilesShowAsANoticeUnderTheTopBar() throws {
        let (library, _, pad, _, _) = try host(games: 3)
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

    func testBackLeavesAllGames() throws {
        let (_, _, pad, _, _) = try host(games: 14, allGames: true)
        XCTAssertTrue(ids(pad).contains("allGames.back"))
        pad.show(default: "allGames.back"); pad.activate(); settle()
        XCTAssertFalse(ids(pad).contains("allGames.back"))
        XCTAssertTrue(ids(pad).contains("library.showAll"))
    }

    func testPinSelectionFromAllGamesReplacingInRowSelectionAndLaunchClearsPin() throws {
        let (library, stores, pad, games, _) = try host(games: 14)
        let originalPlayed10 = games[10].lastPlayed
        let originalPlayed11 = games[11].lastPlayed

        // 1. Choose game 10 (outside top-10) from All games: pinned first without mutating persistent lastPlayed
        pad.show(default: "library.showAll"); pad.activate(); settle()
        pad.focused = "card." + games[10].id.uuidString; settle(0.1)
        pad.activate(); settle()
        XCTAssertEqual(stores.librarySelection.pinnedID, games[10].id)
        XCTAssertEqual(library.selectedID, games[10].id)
        var rowOrder = orderedRowCardIDs(pad)
        XCTAssertEqual(rowOrder.count, LauncherView.recentLimit)
        XCTAssertEqual(rowOrder.first, games[10].id)
        XCTAssertEqual(rowOrder[1], games[0].id)
        XCTAssertEqual(library.games.first(where: { $0.id == games[10].id })?.lastPlayed, originalPlayed10)

        // 2. Selecting another card directly inside the row only changes Hero/selection without reordering cards
        pad.focused = "card." + games[1].id.uuidString; settle(0.2)
        XCTAssertEqual(library.selectedID, games[1].id)
        XCTAssertEqual(stores.librarySelection.pinnedID, games[10].id)
        XCTAssertEqual(orderedRowCardIDs(pad), rowOrder)

        // 3. Choose game 11 from All games: replaces pin; game 10 disappears back to its persistent rank
        pad.focused = "library.showAll"; settle(0.1)
        pad.activate(); settle()
        pad.focused = "card." + games[11].id.uuidString; settle(0.1)
        pad.activate(); settle()
        XCTAssertEqual(stores.librarySelection.pinnedID, games[11].id)
        rowOrder = orderedRowCardIDs(pad)
        XCTAssertEqual(rowOrder.first, games[11].id)
        XCTAssertFalse(rowOrder.contains(games[10].id))
        XCTAssertEqual(library.games.first(where: { $0.id == games[11].id })?.lastPlayed, originalPlayed11)

        // 4. Actually playing a game clears the temporary pin and falls back to persistent play order
        library.recordPlayed(games[5].id, at: Date(timeIntervalSince1970: 1_900_000_000))
        settle()
        XCTAssertNil(stores.librarySelection.pinnedID)
        rowOrder = orderedRowCardIDs(pad)
        XCTAssertEqual(rowOrder.first, games[5].id)
        XCTAssertFalse(rowOrder.contains(games[11].id))
    }

    func testChoosingFromSearchPinsSelectionAndRemovingOrFilteringClearsStalePin() throws {
        let (library, stores, pad, games, _) = try host(games: 14, search: "Game 13")
        pad.focused = "card." + games[13].id.uuidString; settle(0.1)
        pad.activate(); settle()
        XCTAssertEqual(stores.librarySelection.pinnedID, games[13].id)
        XCTAssertEqual(orderedRowCardIDs(pad).first, games[13].id)

        // Removing the pinned game revalidates and clears the stale pin
        library.remove(games[13].id); settle()
        XCTAssertNil(stores.librarySelection.pinnedID)
        XCTAssertEqual(orderedRowCardIDs(pad).first, games[0].id)

        // Pinning an unbuilt game then switching platform filter to Mac in All games clears the incompatible pin
        pad.show(default: "library.showAll")
        pad.focused = "library.showAll"; settle(0.1)
        pad.activate(); settle()
        pad.focused = "card." + games[11].id.uuidString; settle(0.1)
        pad.activate(); settle()
        XCTAssertEqual(stores.librarySelection.pinnedID, games[11].id)

        pad.focused = "library.showAll"; settle(0.1)
        pad.activate(); settle()
        pad.focused = "library.filter"; settle(0.1)
        pad.activate(); settle()   // .owned -> .mac
        XCTAssertNil(stores.librarySelection.pinnedID, "switching platform filter clears an incompatible temporary pin")
    }

    func testRowScrollerScrollToStartResetsOffsetWhenAttached() {
        let row = RowScroller()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 200))
        scroll.documentView = doc
        row.attach(scroll)
        scroll.contentView.setBoundsOrigin(NSPoint(x: 320, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle(0.05)
        XCTAssertTrue(row.canBack)

        row.scrollToStart()
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.5)
        XCTAssertFalse(row.canBack)
    }
}
