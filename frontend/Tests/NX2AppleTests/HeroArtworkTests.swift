import AppKit
import XCTest
@testable import NX2Apple
@testable import NXCore

/// The hero draws the largest image there is for it, decoded at the hero's size: never the 640 pixel card thumbnail.
final class HeroArtworkTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("nx-hero-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func banner(_ id: String, width: Int) throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: width / 2, bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(rep.representation(using: .jpeg, properties: [:])).write(to: folder.appendingPathComponent(id + ".jpg"))
    }

    private func pixels(_ image: NSImage?) -> Int { Int(image?.size.width ?? 0) }   // ArtworkImages sizes an image in its pixels

    func testTheHeroDecodesTheBannerAtItsFullSize() throws {
        try banner("0100535012974000", width: 2000)
        let game = LibraryGame(titleID: "0100535012974000", name: "Hades")
        XCTAssertEqual(pixels(GameLibrary.artwork(for: game, repo: "", banners: folder)), min(2000, ArtworkImages.heroPixels), "the hero: all the pixels the file has")
        XCTAssertEqual(pixels(GameLibrary.artwork(for: game, slot: .thumbnail, repo: "", banners: folder, maxPixel: ArtworkImages.cardPixels)), 640)
    }

    func testTheHeroNeverFallsBackToTheCardThumbnail() throws {
        try banner("0100535012974000", width: 2000)
        let game = LibraryGame(titleID: "0100535012974000", name: "Hades")
        let other = (id: UUID(), image: NSImage(size: NSSize(width: 10, height: 10)))
        let image = GameLibrary.heroImage(for: game.id, decoded: other) { GameLibrary.artwork(for: game, repo: "", banners: self.folder) }
        XCTAssertEqual(pixels(image), min(2000, ArtworkImages.heroPixels), "another game's decode is not used, and the hero decodes its own at full size")
        let own = (id: game.id, image: NSImage(size: NSSize(width: 20, height: 20)))
        XCTAssertTrue(GameLibrary.heroImage(for: game.id, decoded: own) { nil } === own.image)
    }
}
