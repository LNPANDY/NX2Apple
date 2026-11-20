import XCTest
import CryptoKit
@testable import NX2Apple
@testable import NXCore

/// The gallery's copy of the player's covers (#1459): the source library and artwork stay byte for byte as they were, and games
/// without art fall back to the generated ones.
@MainActor final class GalleryRealCoversTests: IsolatedDefaultsTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nx-covers-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// Every file under `folder` with its contents' hash and modification date.
    private func fingerprint(_ folder: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])?.compactMap { $0 as? URL } ?? []
        for file in files where !file.hasDirectoryPath {
            let data = try Data(contentsOf: file)
            let date = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            result[String(file.path.dropFirst(folder.path.count))] = SHA256.hash(data: data).description + "@\(date.timeIntervalSince1970)"
        }
        return result
    }

    func testTheSnapshotCopiesWithoutTouchingTheSourceAndLeavesGamesWithoutArtOut() throws {
        let source = root.appendingPathComponent("source"), artwork = source.appendingPathComponent("artwork")
        let withBanner = LibraryGame(titleID: "0100AAAA00010000", name: "Real Banner Game")
        var withCustom = LibraryGame(titleID: "0100AAAA00020000", name: "Real Custom Game")
        withCustom.customName = "My Own Name"
        let withoutArt = LibraryGame(titleID: "0100AAAA00030000", name: "No Art Game")
        try FileManager.default.createDirectory(at: artwork.appendingPathComponent("0100AAAA00010000"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artwork.appendingPathComponent("custom/" + withCustom.id.uuidString), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: artwork.appendingPathComponent("0100AAAA00010000.jpg"))
        try Data([4, 5]).write(to: artwork.appendingPathComponent("0100AAAA00010000/icon.jpg"))
        try Data([6]).write(to: artwork.appendingPathComponent("custom/\(withCustom.id.uuidString)/picked.png"))
        let file = source.appendingPathComponent("library.json")
        struct Snapshot: Encodable { let games: [LibraryGame]; let folder: String }
        try JSONEncoder().encode(Snapshot(games: [withBanner, withCustom, withoutArt], folder: "")).write(to: file)
        let before = try fingerprint(source)

        let copies = root.appendingPathComponent("copies")
        let covers = GalleryRealCovers.snapshot(libraryFile: file, artwork: artwork, into: copies)

        XCTAssertEqual(try fingerprint(source), before, "the player's library and artwork stay byte for byte as they were")
        XCTAssertEqual(covers.map(\.titleID), ["0100AAAA00010000", "0100AAAA00020000"], "a game without art is left out")
        XCTAssertEqual(covers.last?.customName, "My Own Name")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copies.appendingPathComponent("0100AAAA00010000.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copies.appendingPathComponent("0100AAAA00010000/icon.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copies.appendingPathComponent("custom/\(withCustom.id.uuidString)/picked.png").path))

        // The scenes take the real games first and fill the rest with the fictional ones.
        let fixtures = GalleryFixtures(covers: covers, coverFolder: copies)
        XCTAssertEqual(fixtures.catalog.count, GalleryFixtures.games.count)
        XCTAssertEqual(fixtures.catalog.prefix(2).map(\.titleID), ["0100AAAA00010000", "0100AAAA00020000"])
        XCTAssertNil(fixtures.catalog[2].cover, "the rest is generated")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copies.appendingPathComponent(fixtures.catalog[2].titleID + ".jpg").path),
                      "the generated games have their art beside the copies")
        XCTAssertEqual(try fingerprint(source), before)
    }

    func testNoLibraryMeansGeneratedArt() {
        let covers = GalleryRealCovers.snapshot(libraryFile: root.appendingPathComponent("missing.json"), artwork: root, into: root.appendingPathComponent("copies"))
        XCTAssertTrue(covers.isEmpty)
        let fixtures = GalleryFixtures(covers: covers, coverFolder: nil)
        XCTAssertTrue(fixtures.catalog.allSatisfy { $0.cover == nil })
    }
}
