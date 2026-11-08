import AppKit
import XCTest
@testable import NX2Apple
@testable import NXCore

final class ArtworkStoreMediaTests: XCTestCase {
    private var temporary: URL!
    private let titleID = "0100535012974000"
    private let otherID = "01007EF00011E000"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-media-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporary)
    }

    private func jpeg(_ name: String, width: Int = 64, height: Int = 36) throws -> URL {
        let url = temporary.appendingPathComponent(name)
        let picture = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in NSColor.orange.setFill(); rect.fill(); return true }
        try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(picture.tiffRepresentation))?.representation(using: .jpeg, properties: [:])).write(to: url)
        return url
    }

    /// A list in which the first title has eight screenshots, all served from disk.
    private func writeList(screenshots: Int = 8) throws -> URL {
        let shots = try (0..<screenshots).map { try jpeg("shot-\($0).jpg").absoluteString }
        let list = temporary.appendingPathComponent("US.en.json")
        let urls = shots.map { "\"\($0)\"" }.joined(separator: ",")
        try Data("""
        {"1": {"id": "\(titleID.lowercased())", "bannerUrl": "\(try jpeg("banner.jpg").absoluteString)", "screenshots": [\(urls)]},
         "2": {"id": "\(otherID)", "bannerUrl": null, "screenshots": []},
         "3": {"id": "0100000000010000", "screenshots": ["https://example.com/shot.jpg"]}}
        """.utf8).write(to: list)
        return list
    }

    private func store(_ list: URL) -> ArtworkStore {
        ArtworkStore(directory: temporary.appendingPathComponent("artwork"), titleList: list, allowsFileURLs: true)
    }

    func testScreenshotsAreIndexedUpToSix() async throws {
        let store = store(try writeList())
        guard case .loaded(let media) = await store.media(for: titleID) else { return XCTFail("no media") }
        XCTAssertEqual(media.screenshots.count, 6)
        XCTAssertEqual(media.screenshots.first, temporary.appendingPathComponent("shot-0.jpg").absoluteString)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: temporary.appendingPathComponent("artwork/index.json"))) as? [String: Any]
        XCTAssertEqual(saved?["version"] as? Int, 2)
        XCTAssertEqual(Set((saved?["media"] as? [String: Any])?.keys.map { $0 } ?? []), [titleID])   // only the title asked for
    }

    /// The screenshots come from the product whose banner the game gets (BannerPick, #403), not from a bundle listed first.
    func testScreenshotsComeFromTheGamesOwnProduct() async throws {
        let list = temporary.appendingPathComponent("products.json")
        try Data("""
        {"1": {"id": "\(titleID)", "name": "Hades II + Expansion Pass Bundle", "nsuId": 70010000000002, "bannerUrl": "https://img-eshop.cdn.nintendo.net/i/bundle.jpg", "screenshots": ["https://img-eshop.cdn.nintendo.net/i/bundle-shot.jpg"]},
         "2": {"id": "\(titleID)", "name": "Hades II", "nsuId": 70010000000001, "bannerUrl": "https://img-eshop.cdn.nintendo.net/i/game.jpg", "screenshots": ["https://img-eshop.cdn.nintendo.net/i/game-shot.jpg"]}}
        """.utf8).write(to: list)
        guard case .loaded(let media) = await store(list).media(for: titleID) else { return XCTFail("no media") }
        XCTAssertEqual(media.screenshots, ["https://img-eshop.cdn.nintendo.net/i/game-shot.jpg"])
    }

    func testATitleWithoutScreenshotsHasNone() async throws {
        let store = store(try writeList())
        let none = await store.media(for: otherID)
        XCTAssertEqual(none, .none)
        let unknown = await store.media(for: "0100AAAAAAAAA000")
        XCTAssertEqual(unknown, .none)   // not in the list at all
    }

    func testAMissingListIsOffline() async throws {
        let store = store(temporary.appendingPathComponent("absent.json"))
        let load = await store.media(for: titleID)
        XCTAssertEqual(load, .offline)
    }

    func testAVersionOneIndexIsReadAgainOnceAndKeepsItsBanners() async throws {
        let list = try writeList()
        let folder = temporary.appendingPathComponent("artwork")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("""
        {"fetched": "2026-10-30T10:00:00Z", "banners": {"\(otherID)": "https://img-eshop.cdn.nintendo.net/i/old.jpg"}}
        """.utf8).write(to: folder.appendingPathComponent("index.json"))
        let store = store(list)
        guard case .loaded(let first) = await store.media(for: titleID) else { return XCTFail("no media") }
        try Data("{}".utf8).write(to: list)   // a second read of the list would find nothing
        guard case .loaded(let second) = await store.media(for: titleID) else { return XCTFail("read again") }
        XCTAssertEqual(first, second)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("index.json"))) as? [String: Any]
        XCTAssertNotNil(saved?["media"])
        XCTAssertEqual((saved?["banners"] as? [String: String])?[titleID], temporary.appendingPathComponent("banner.jpg").absoluteString)   // the list's banners replace the old ones
    }

    func testATitleAddedSinceTheLastReadGetsItsMediaAtLaunchNotWhenThePanelOpens() async throws {
        let list = try writeList()
        let folder = temporary.appendingPathComponent("artwork")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try jpeg("banner-copy.jpg"), to: folder.appendingPathComponent(titleID + ".jpg"))   // the banner is cached
        try Data("""
        {"version": 2, "fetched": "\(ISO8601DateFormatter().string(from: Date()))", "banners": {}, "media": {"\(otherID)": {"screenshots": []}}}
        """.utf8).write(to: folder.appendingPathComponent("index.json"))   // fresh, and without media for the title
        let store = store(list)
        let added = await store.fetchMissing([titleID])
        XCTAssertEqual(added, [])   // no banner was missing
        try Data("{}".utf8).write(to: list)   // a second read of the list would find nothing
        guard case .loaded(let media) = await store.media(for: titleID) else { return XCTFail("the list was read again, or not at launch") }
        XCTAssertEqual(media.screenshots.count, 6)
    }

    func testACandidateIsDownloadedOnceAndRefusedOffTheCDN() async throws {
        let list = try writeList()
        let folder = temporary.appendingPathComponent("artwork")
        let store = store(list)
        XCTAssertNil(ArtworkStore.cachedCandidate(.screenshot(2), titleID: titleID, in: folder))
        let shot = try await store.candidate(.screenshot(2), titleID: titleID)
        XCTAssertEqual(shot, folder.appendingPathComponent(titleID + "/screenshot-2.jpg"))
        XCTAssertEqual(ArtworkStore.cachedCandidate(.screenshot(2), titleID: titleID, in: folder), shot)
        try FileManager.default.removeItem(at: temporary.appendingPathComponent("shot-2.jpg"))
        let again = try await store.candidate(.screenshot(2), titleID: titleID)   // cached: no second download
        XCTAssertEqual(again, shot)

        do { _ = try await store.candidate(.screenshot(6), titleID: titleID); XCTFail("only six screenshots") } catch {}
        do { _ = try await store.candidate(.banner, titleID: titleID); XCTFail("not a candidate") } catch {}
        do { _ = try await store.candidate(.screenshot(0), titleID: "0100000000010000"); XCTFail("off the CDN") } catch {
            XCTAssertNil(ArtworkStore.cachedCandidate(.screenshot(0), titleID: "0100000000010000", in: folder))
        }
        do { _ = try await store.candidate(.screenshot(0), titleID: "../etc"); XCTFail("not a title ID") } catch {}
    }

    func testTheResolverShowsACachedCandidateAndFallsBackWithout() async throws {
        let folder = temporary.appendingPathComponent("artwork")
        let banner = folder.appendingPathComponent(titleID + ".jpg")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try jpeg("banner-copy.jpg"), to: banner)
        var game = LibraryGame(titleID: titleID, name: "Hades")
        game.artwork.hero = ArtworkChoice(source: .screenshot(2))
        XCTAssertEqual(GameLibrary.artworkURLs(for: game, repo: temporary.path, banners: folder), [banner])   // not downloaded yet
        let shot = try await store(try writeList()).candidate(.screenshot(2), titleID: titleID)
        XCTAssertEqual(GameLibrary.artworkURLs(for: game, repo: temporary.path, banners: folder), [shot, banner])
        game.artwork.hero = ArtworkChoice(source: .screenshot(3))
        XCTAssertEqual(GameLibrary.artworkURLs(for: game, repo: temporary.path, banners: folder), [banner])
    }
}
