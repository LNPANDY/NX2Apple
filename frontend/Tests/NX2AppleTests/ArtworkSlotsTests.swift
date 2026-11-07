import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import NX2Apple
@testable import NXCore

final class ArtworkSlotsTests: XCTestCase {
    private var temporary: URL!
    private let titleID = "0100535012974000"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-slots-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporary)
    }


    private func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    func testEverySourceRoundTrips() throws {
        let sources: [ArtworkChoice.Source] = [.banner, .screenshot(3), .imported("abc.jpg")]
        for source in sources {
            let choice = ArtworkChoice(source: source, focus: ArtworkFocus(x: 0.25, y: 1))
            XCTAssertEqual(try JSONDecoder().decode(ArtworkChoice.self, from: JSONEncoder().encode(choice)), choice)
        }
        let artwork = GameArtwork(hero: ArtworkChoice(source: .banner), thumbnail: ArtworkChoice(source: .screenshot(0)))
        XCTAssertEqual(try JSONDecoder().decode(GameArtwork.self, from: JSONEncoder().encode(artwork)), artwork)
    }

    func testTheFileFormatIsFixed() throws {
        let artwork = GameArtwork(hero: ArtworkChoice(source: .imported("a.jpg")),
                                  thumbnail: ArtworkChoice(source: .screenshot(2), focus: ArtworkFocus(x: 0.25, y: 0.75)))
        XCTAssertEqual(try json(artwork), #"{"hero":{"focus":{"x":0.5,"y":0.5},"source":{"file":"a.jpg","kind":"imported"}},"thumbnail":{"focus":{"x":0.25,"y":0.75},"source":{"index":2,"kind":"screenshot"}}}"#)
        XCTAssertEqual(try json(GameArtwork()), "{}")
        let read = try JSONDecoder().decode(GameArtwork.self, from: Data(#"{"hero":{"source":{"kind":"banner"}}}"#.utf8))   // focus is optional
        XCTAssertEqual(read, GameArtwork(hero: ArtworkChoice(source: .banner)))
        XCTAssertThrowsError(try JSONDecoder().decode(ArtworkChoice.self, from: Data(#"{"source":{"kind":"hologram"}}"#.utf8)))
        // A library an earlier build wrote, with an app icon slot: it still loads, and the slot is ignored
        let withIcon = try JSONDecoder().decode(GameArtwork.self, from: Data(#"{"hero":{"source":{"kind":"banner"}},"icon":{"source":{"kind":"eshopIcon"}}}"#.utf8))
        XCTAssertEqual(withIcon, GameArtwork(hero: ArtworkChoice(source: .banner)))
        let iconHero = try JSONDecoder().decode(GameArtwork.self, from: Data(#"{"hero":{"source":{"kind":"gameIcon"}},"thumbnail":{"source":{"kind":"banner"}}}"#.utf8))
        XCTAssertEqual(iconHero, GameArtwork(thumbnail: ArtworkChoice(source: .banner)), "a source this version does not know is the default")
    }

    func testAFocusIsAUnitPoint() {
        XCTAssertEqual(ArtworkFocus(x: 0.2, y: 0.9).point, UnitPoint(x: 0.2, y: 0.9))
        XCTAssertEqual(GameArtwork().focus(for: .hero), .center)
        XCTAssertEqual(GameArtwork(hero: ArtworkChoice(source: .banner, focus: ArtworkFocus(x: 0, y: 1))).focus(for: .thumbnail), UnitPoint(x: 0, y: 1))   // follows the hero
    }


    private func library(_ game: String, artwork: URL? = nil) throws -> GameLibrary {
        let file = temporary.appendingPathComponent("state/library.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let id = "6E1D2B64-0000-4000-8000-000000000001"
        try Data(#"{"games":[{"id":"\#(id)","titleID":"\#(titleID)","name":"Hades"\#(game)}],"folder":""}"#.utf8).write(to: file)
        return GameLibrary(file: file, artwork: artwork ?? temporary.appendingPathComponent("artwork"))
    }

    func testALibraryWithOnlyTheOldPathAndOneWithNeitherKeyLoad() throws {
        let old = try library(#","artworkPath":"/Users/me/art.png""#)
        XCTAssertEqual(old.games[0].artworkPath, "/Users/me/art.png")
        XCTAssertEqual(old.games[0].artwork, GameArtwork())
        let none = try library("")
        XCTAssertEqual(none.games[0].artworkPath, "")
        XCTAssertEqual(none.games[0].artwork, GameArtwork())
    }

    func testASlotANewerVersionWroteIsTheDefaultAndTheLibraryStillLoads() throws {
        let newer = try library(#","artwork":{"hero":{"source":{"kind":"hologram"}},"thumbnail":{"source":{"kind":"screenshot","index":3}}}"#)
        XCTAssertEqual(newer.games.count, 1)
        XCTAssertEqual(newer.games[0].artwork, GameArtwork(thumbnail: ArtworkChoice(source: .screenshot(3))))
    }

    func testChoosingAThumbnailKeepsAHeroPathNotCopiedYet() throws {
        let library = try library(#","artworkPath":"/Volumes/Away/art.png""#)
        var artwork = library.games[0].artwork
        artwork.thumbnail = ArtworkChoice(source: .banner)
        library.setArtwork(artwork, for: library.games[0].id)
        XCTAssertEqual(library.games[0].artworkPath, "/Volumes/Away/art.png")
        artwork.hero = ArtworkChoice(source: .banner)
        library.setArtwork(artwork, for: library.games[0].id)
        XCTAssertEqual(library.games[0].artworkPath, "")
    }

    func testMigrationTurnsACopyOfThePreviousVersionIntoTheHero() throws {
        let folder = temporary.appendingPathComponent("artwork")
        let id = try XCTUnwrap(UUID(uuidString: "6E1D2B64-0000-4000-8000-000000000001"))
        let directory = ArtworkStore.customDirectory(for: id, in: folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent("abc.jpg")
        try Data("x".utf8).write(to: copy)
        let library = try library(#","artworkPath":"\#(copy.path)""#, artwork: folder)
        let done = expectation(description: "migrated")
        library.migrateArtwork { done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(library.games[0].artwork.hero, ArtworkChoice(source: .imported("abc.jpg")))
        XCTAssertEqual(library.games[0].artworkPath, "")
        let saved = GameLibrary(file: temporary.appendingPathComponent("state/library.json"), artwork: folder)
        XCTAssertEqual(saved.games[0].artwork.hero, ArtworkChoice(source: .imported("abc.jpg")))
        XCTAssertEqual(saved.games[0].artworkPath, "")
    }


    private func jpeg(_ url: URL, width: Int = 64, height: Int = 36) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func urls(_ game: LibraryGame, _ slot: ArtworkSlot) -> [URL] {
        GameLibrary.artworkURLs(for: game, slot: slot, repo: temporary.path, banners: temporary)
    }

    func testHeroAndThumbnailKeepTheDefaultChain() throws {
        let banner = temporary.appendingPathComponent(titleID + ".jpg")
        try jpeg(banner)
        let game = LibraryGame(titleID: titleID, name: "Hades")
        XCTAssertEqual(urls(game, .hero), [banner])
        XCTAssertEqual(GameLibrary.artworkURLs(for: game, repo: temporary.path, banners: temporary), [banner])   // no slot: the hero
        XCTAssertEqual(urls(game, .thumbnail), [banner])
    }

    func testAChoiceComesFirstAndAMissingOneFallsBackToTheDefault() throws {
        let banner = temporary.appendingPathComponent(titleID + ".jpg")
        try jpeg(banner)
        var game = LibraryGame(titleID: titleID, name: "Hades")
        let own = ArtworkStore.customDirectory(for: game.id, in: temporary).appendingPathComponent("own.jpg")
        try jpeg(own, width: 8, height: 8)
        game.artwork.hero = ArtworkChoice(source: .imported("own.jpg"))
        XCTAssertEqual(urls(game, .hero), [own, banner])
        game.artwork.hero = ArtworkChoice(source: .imported("gone.jpg"))   // the file is gone: the default, not nothing
        XCTAssertEqual(urls(game, .hero), [banner])
        game.artwork.hero = ArtworkChoice(source: .imported("../../" + titleID + ".jpg"))   // a name, never a path
        XCTAssertEqual(urls(game, .hero), [banner])
        game.artwork.hero = ArtworkChoice(source: .screenshot(1))   // nothing cached for it yet
        XCTAssertEqual(urls(game, .hero), [banner])
        game.artwork.hero = ArtworkChoice(source: .banner)
        XCTAssertEqual(urls(game, .hero), [banner, banner])
    }

    func testTheThumbnailFollowsTheHeroUnlessItHasItsOwnChoice() throws {
        let banner = temporary.appendingPathComponent(titleID + ".jpg")
        try jpeg(banner)
        var game = LibraryGame(titleID: titleID, name: "Hades")
        let directory = ArtworkStore.customDirectory(for: game.id, in: temporary)
        let hero = directory.appendingPathComponent("hero.jpg"), thumbnail = directory.appendingPathComponent("thumbnail.jpg")
        try jpeg(hero, width: 8, height: 8)
        try jpeg(thumbnail, width: 16, height: 16)
        game.artwork.hero = ArtworkChoice(source: .imported("hero.jpg"))
        XCTAssertEqual(urls(game, .thumbnail), urls(game, .hero))   // the hero's imported file
        XCTAssertEqual(urls(game, .thumbnail).first, hero)
        XCTAssertEqual(GameLibrary.artwork(for: game, slot: .thumbnail, repo: temporary.path, banners: temporary)?.size, NSSize(width: 8, height: 8))
        game.artwork.thumbnail = ArtworkChoice(source: .imported("thumbnail.jpg"))
        XCTAssertEqual(urls(game, .thumbnail), [thumbnail, hero, banner])
        XCTAssertEqual(urls(game, .hero), [hero, banner])
        XCTAssertEqual(GameLibrary.artwork(for: game, slot: .thumbnail, repo: temporary.path, banners: temporary)?.size, NSSize(width: 16, height: 16))
        game.artwork.thumbnail = ArtworkChoice(source: .imported("gone.jpg"))   // unresolvable: the hero's, as a thumbnail with no choice
        XCTAssertEqual(urls(game, .thumbnail), urls(game, .hero))
    }


    @MainActor func testTheConsoleCoverIsDrawnAgainWhenTheThumbnailChanges() throws {
        let library = try library("")
        var asked: [ArtworkSlot] = []
        let driver = LiveConsoleDriver(library: library, controls: ControlLayout(defaults: TestDefaults.make("ArtworkSlotsTests")),
                                       repo: { "" }, lang: { .en }, labels: { $0 }, pads: { [] },
                                       artwork: { game, _ in asked.append(game.artwork.thumbnail == nil ? .hero : .thumbnail); return nil }, observeSystem: false)
        driver.refresh()
        let before = asked.count
        driver.refresh()
        XCTAssertEqual(asked.count, before)   // unchanged: the cover is kept
        var artwork = library.games[0].artwork
        artwork.thumbnail = ArtworkChoice(source: .screenshot(1))
        library.setArtwork(artwork, for: library.games[0].id)
        driver.refresh()
        XCTAssertEqual(asked.count, before + 1)
        XCTAssertEqual(asked.last, .thumbnail)
    }
}
