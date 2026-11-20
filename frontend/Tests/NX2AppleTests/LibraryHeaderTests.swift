import SwiftUI
import XCTest
import NXCore
@testable import NX2Apple
@testable import NXLauncher

@MainActor final class LibraryHeaderTests: IsolatedDefaultsTestCase {
    func testLongHeroTitleKeepsActionsVisibleAcrossWindowSizes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("library.json")
        let ipa = directory.appendingPathComponent("example.ipa")
        try Data().write(to: ipa)
        var game = LibraryGame(titleID: "0100000000000000",
            name: "The Legend of a Very Long Game Title and a Journey Across the Entire Kingdom",
            inputs: ["base": ["/tmp/example.nsp"]])
        game.ipaPath = ipa.path
        XCTAssertTrue(game.isOlderIOSBuild, "Exercise both the platform and older-iOS chips")
        try JSONEncoder().encode([game]).write(to: file)
        for scheme in [ColorScheme.light, .dark] {
        for size in [NSSize(width: 900, height: 680), NSSize(width: 1000, height: 720), NSSize(width: 1500, height: 900)] {
            let stores = LauncherStores(defaults: testDefaults), pad = PadFocus()
            let host = NSHostingView(rootView: LauncherView(stores: stores, library: GameLibrary(file: file),
                performStartupChecks: false, padFocus: pad).environment(\.colorScheme, scheme))
            let window = OffscreenWindow(size: size)
            window.contentView = host; window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            XCTAssertEqual(host.bounds.width, size.width, accuracy: 1)
            let play = try XCTUnwrap(pad.frames["main"]?.first { $0.id == "hero.play" }?.frame)
            let menu = try XCTUnwrap(pad.frames["main"]?.first { $0.id == "hero.manage" }?.frame)
            XCTAssertEqual(play.height, 44, accuracy: 1)
            XCTAssertEqual(menu.height, play.height, accuracy: 1)
            XCTAssertEqual(menu.midY, play.midY, accuracy: 1)
            XCTAssertEqual(menu.minX - play.maxX, 12, accuracy: 1)
            XCTAssertGreaterThanOrEqual(play.minX, 130)
            XCTAssertGreaterThan(play.minY, 80)
            XCTAssertLessThan(menu.maxX, size.width)
            XCTAssertLessThan(play.maxY, size.height)
            if let path = ProcessInfo.processInfo.environment["NX_HERO_TITLE_CAPTURE_DIR"] {
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let output = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("hero-\(Int(size.width))-\(scheme).png"))
            }
        }
        }
    }

    func testHeroElementsShareAvailableSpaceAndPreserveTheirProportions() {
        for size in [CGSize(width: 900, height: 300), CGSize(width: 1208, height: 300),
                     CGSize(width: 1500, height: 420), CGSize(width: 1920, height: 300)] {
            let layout = LibraryHeroLayout.content(width: size.width, height: size.height, headerHeight: 64)
            XCTAssertGreaterThanOrEqual(layout.titleSize, 30)
            XCTAssertLessThanOrEqual(layout.titleSize, 48)
            XCTAssertEqual(layout.iconSize / layout.titleSize, 4, accuracy: 0.001)
            XCTAssertEqual(layout.columnGap / layout.titleSize, 2 / 3, accuracy: 0.001)
            XCTAssertEqual(layout.titleActionGap / layout.titleSize, 14 / 36, accuracy: 0.001)
            XCTAssertGreaterThan(size.width - 68 - layout.iconSize - layout.columnGap, layout.iconSize * 4)
        }
        XCTAssertLessThan(LibraryHeroLayout.content(width: 1920, height: 260, headerHeight: 64).iconSize,
                          LibraryHeroLayout.content(width: 1920, height: 420, headerHeight: 64).iconSize)
        let before = LibraryHeroLayout.content(width: 1099, height: 300, headerHeight: 64)
        let after = LibraryHeroLayout.content(width: 1101, height: 300, headerHeight: 64)
        XCTAssertLessThan(after.titleSize - before.titleSize, 0.1, "No breakpoint jump")
    }

    func testCrowdedHeroKeepsAllBadgesAndActionsBelowTheHeader() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let known = root.appendingPathComponent("dm/games/known/game.tsv")
        try FileManager.default.createDirectory(at: known.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("title_id\t0100000000001000\n".utf8).write(to: known)
        _ = VerifiedProfiles.titleIDs(engineRoot: root.path)
        let ipa = root.appendingPathComponent("example.ipa")
        try Data().write(to: ipa)
        let games = (0..<2).map { index in
            var game = LibraryGame(titleID: "010000000000000\(index)",
                name: "A long game title with many words and additional details for a responsive layout")
            game.ipaPath = ipa.path
            return game
        }
        let file = root.appendingPathComponent("library.json")
        try JSONEncoder().encode(games).write(to: file)
        for size in [NSSize(width: 900, height: 680), NSSize(width: 1440, height: 722)] {
            let stores = LauncherStores(defaults: testDefaults), focus = PadFocus()
            stores.repo.path = root.path
            stores.localizer.lang = Lang("fr")
            let library = GameLibrary(file: file)
            let skipped = root.appendingPathComponent("example.zip")
            library.applySkippedItems([SkippedLibraryItem(path: skipped.path, name: skipped.lastPathComponent,
                rootPath: root.path, reason: .unextractedArchiveOrSplit)])
            let host = NSHostingView(rootView: LauncherView(stores: stores, library: library,
                performStartupChecks: false, olderTools: Set(games.map(\.id)), padFocus: focus))
            let window = OffscreenWindow(size: size)
            window.contentView = host; window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            let frames = focus.frames["main", default: []]
            let header = try XCTUnwrap(frames.first { $0.id == "tab.library" }?.frame)
            let play = try XCTUnwrap(frames.first { $0.id == "hero.play" }?.frame)
            let profile = try XCTUnwrap(frames.first { $0.id == "hero.profile" }?.frame)
            XCTAssertGreaterThan(profile.minY, header.maxY)
            XCTAssertLessThan(profile.maxY, play.minY)
            let refresh = try XCTUnwrap(frames.first { $0.id == "hero.rebuild" }?.frame)
            XCTAssertGreaterThan(refresh.minY, header.maxY)
            XCTAssertLessThan(refresh.maxY, size.height)
            XCTAssertLessThanOrEqual(refresh.maxX, size.width)
            XCTAssertLessThan(play.maxY, size.height)
            let banner = try XCTUnwrap(frames.first { $0.id == "library.skippedBanner" }?.frame)
            XCTAssertGreaterThan(banner.minY, play.maxY)
            library.dismissSkippedBanner()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let afterDismissal = focus.frames["main", default: []]
            XCTAssertFalse(afterDismissal.contains { $0.id == "library.skippedBanner" })
            let refreshAfterDismissal = try XCTUnwrap(afterDismissal.first { $0.id == "hero.rebuild" }?.frame)
            XCTAssertGreaterThan(refreshAfterDismissal.minY, header.maxY)
            let profileAfterDismissal = try XCTUnwrap(afterDismissal.first { $0.id == "hero.profile" }?.frame)
            XCTAssertGreaterThan(profileAfterDismissal.minY, header.maxY)
        }
    }

    func testCollectionHeaderUsesTheRoomBesideTheArtworkPanel() throws {
        let fixture = try ArtworkFixture()
        defer { fixture.cleanup() }
        let lang = Lang("fr")
        var environment = fixture.environment()
        environment.media = { _, _ in .none }
        let editor = ArtworkEditor(game: fixture.game, slot: .hero, artworkDirectory: fixture.artwork,
                                   env: environment, labels: { L10n.string($0, lang) })
        for width: CGFloat in [1408, 900] {
            let stores = LauncherStores(defaults: testDefaults)
            stores.localizer.lang = lang
            let focus = PadFocus()
            let host = NSHostingView(rootView: LauncherView(stores: stores, library: fixture.library,
                performStartupChecks: false, padFocus: focus, artworkEditor: editor))
            let window = OffscreenWindow(size: NSSize(width: width, height: 760))
            window.contentView = host; window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let frames = focus.frames["main", default: []]
            let supported = try XCTUnwrap(frames.first { $0.id == "library.supported" }?.frame)
            let sort = try XCTUnwrap(frames.first { $0.id == "library.sort" }?.frame)
            let filter = try XCTUnwrap(frames.first { $0.id == "library.filter" }?.frame)
            let libraryRight = width - ArtworkPanel.width - 1 - 34
            for frame in [supported, sort, filter] {
                XCTAssertGreaterThanOrEqual(frame.minX, 33, "Width: \(width)")
                XCTAssertLessThanOrEqual(frame.maxX, libraryRight + 1, "Width: \(width)")
            }
            if width == 1408 {
                XCTAssertEqual(supported.midY, sort.midY, accuracy: 1)
                XCTAssertEqual(sort.midY, filter.midY, accuracy: 1)
                XCTAssertLessThan(supported.maxX, sort.minX)
            } else {
                XCTAssertLessThan(supported.maxY, sort.minY)
                if filter.midY > sort.midY { XCTAssertEqual(filter.minX, 34, accuracy: 1) }
            }
        }
    }

    func testCollectionHeaderStaysOnOneRowWhenFullLabelsAppear() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("library.json")
        try JSONEncoder().encode([LibraryGame(titleID: "0100000000000000", name: "Example")]).write(to: file)
        for lang in Lang.all {
            let stores = LauncherStores(defaults: testDefaults)
            stores.localizer.lang = lang
            let focus = PadFocus()
            let host = NSHostingView(rootView: LauncherView(stores: stores, library: GameLibrary(file: file),
                performStartupChecks: false, padFocus: focus))
            let window = OffscreenWindow(size: NSSize(width: 1199, height: 760))
            window.contentView = host; window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            for width: CGFloat in [1099, 1100, 1199, 1200] {
                window.setContentSize(NSSize(width: width, height: 760))
                RunLoop.main.run(until: Date().addingTimeInterval(0.25))
                let frames = focus.frames["main", default: []]
                let supported = try XCTUnwrap(frames.first { $0.id == "library.supported" }?.frame)
                let sort = try XCTUnwrap(frames.first { $0.id == "library.sort" }?.frame)
                XCTAssertEqual(supported.midY, sort.midY, accuracy: 1, "\(lang.code) at \(width) pt")
                XCTAssertLessThan(supported.maxX, sort.minX, "\(lang.code) at \(width) pt")
            }
        }
    }

    func testOnlyLibraryScrollsUnderTheHeaderAndKeepsItsViewport() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Native scroll-edge bars require macOS 26") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("library.json")
        try JSONEncoder().encode([LibraryGame(titleID: "0100000000000000", name: "Example")]).write(to: file)
        for page in LauncherPage.allCases {
            let stores = LauncherStores(defaults: testDefaults)
            let pad = PadFocus()
            let host = NSHostingView(rootView: LauncherView(stores: stores, library: GameLibrary(file: file), initialPage: page,
                                                          performStartupChecks: false, padFocus: pad))
            let window = OffscreenWindow(size: NSSize(width: 1000, height: 720))
            window.contentView = host
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let size = host.bounds.size
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            XCTAssertEqual(host.bounds.size, size, "Layout must not resize the window")
            func scrolls(_ view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
            }
            let scroll = try XCTUnwrap(scrolls(host).max { $0.bounds.height < $1.bounds.height })
            let top = host.convert(scroll.bounds, from: scroll).minY
            let header = try XCTUnwrap(pad.frames["main"]?.first { $0.id == "tab.library" }?.frame)
            if page == .library {
                XCTAssertLessThan(top, header.maxY, "Artwork must actually occupy the area behind the controls")
            } else {
                XCTAssertGreaterThanOrEqual(top, header.maxY, "Other pages retain their separate opaque header")
            }
        }
    }
}
