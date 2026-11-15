import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import NX2Apple
@testable import NXCore

final class ArtworkImageTests: XCTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-artwork-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporary)
    }

    /// A JPEG of `width` × `height` pixels with the EXIF orientation set, as a camera writes it.
    private func jpeg(_ name: String, width: Int, height: Int, orientation: Int = 1) throws -> URL {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = temporary.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testCropFractionIsWhatTheBandCutsOff() {
        let wide = CGSize(width: 1920, height: 1080)
        XCTAssertEqual(ArtworkFraming.cropFraction(image: wide, band: CGSize(width: 1020, height: 498)), 0.132, accuracy: 0.001)
        XCTAssertEqual(ArtworkFraming.cropFraction(image: wide, band: CGSize(width: 1.8, height: 1)), 0.012, accuracy: 0.001)
        XCTAssertEqual(ArtworkFraming.cropFraction(image: wide, band: CGSize(width: 16, height: 9)), 0, accuracy: 0.0001)
        XCTAssertEqual(ArtworkFraming.cropFraction(image: CGSize(width: 1000, height: 1000), band: CGSize(width: 2, height: 1)), 0.5, accuracy: 0.0001)   // a tall cut
        XCTAssertEqual(ArtworkFraming.cropFraction(image: wide, band: .zero), 0)
    }

    func testFramingIsOfferedFromFivePercent() {
        let wide = CGSize(width: 1920, height: 1080)
        XCTAssertTrue(ArtworkFraming.needsFraming(image: wide, band: CGSize(width: 1020, height: 498)))
        XCTAssertFalse(ArtworkFraming.needsFraming(image: wide, band: CGSize(width: 1.8, height: 1)))
    }

    func testFocusPutsTheEdgeOnTheBandEdge() {
        let image = CGSize(width: 1920, height: 1080), band = CGSize(width: 1020, height: 498)
        let scale = max(band.width / image.width, band.height / image.height), cut = image.height * scale - band.height
        XCTAssertGreaterThan(cut, 0)   // a wide band: the image is cut at the top and bottom
        // Focus 0: the image's top edge on the band's top. Centred it sits cut / 2 above the band, so it moves down by that much.
        XCTAssertEqual(ArtworkFraming.offset(image: image, band: band, focus: UnitPoint(x: 0.5, y: 0)).height, cut / 2, accuracy: 0.0001)
        XCTAssertEqual(ArtworkFraming.offset(image: image, band: band, focus: UnitPoint(x: 0.5, y: 1)).height, -cut / 2, accuracy: 0.0001)
        XCTAssertEqual(ArtworkFraming.offset(image: image, band: band, focus: .center), .zero)
        XCTAssertEqual(ArtworkFraming.offset(image: image, band: band, focus: UnitPoint(x: 0, y: 0.5)).width, 0)   // nothing is cut across
        let tall = CGSize(width: 1000, height: 1000), narrow = CGSize(width: 600, height: 300)
        XCTAssertEqual(ArtworkFraming.offset(image: tall, band: narrow, focus: UnitPoint(x: 0.5, y: 0)).height, 150, accuracy: 0.0001)
        let sideways = CGSize(width: 2000, height: 500), square = CGSize(width: 100, height: 100)
        XCTAssertEqual(ArtworkFraming.offset(image: sideways, band: square, focus: UnitPoint(x: 0, y: 0.5)).width, 150, accuracy: 0.0001)
        XCTAssertEqual(ArtworkFraming.offset(image: sideways, band: square, focus: UnitPoint(x: 1, y: 0.5)).width, -150, accuracy: 0.0001)
    }

    func testNothingCutMeansNoOffset() {
        let image = CGSize(width: 1920, height: 1080)
        for focus in [UnitPoint.topLeading, .bottomTrailing, UnitPoint(x: 0.2, y: 0.9), .center] {
            XCTAssertEqual(ArtworkFraming.offset(image: image, band: CGSize(width: 960, height: 540), focus: focus), .zero)
        }
    }

    func testAFocusOutsideTheImageStopsAtTheEdge() {
        let image = CGSize(width: 1920, height: 1080), band = CGSize(width: 1020, height: 498)
        let edge = ArtworkFraming.offset(image: image, band: band, focus: UnitPoint(x: 0, y: 1))
        XCTAssertEqual(ArtworkFraming.offset(image: image, band: band, focus: UnitPoint(x: -3, y: 7)), edge)
        XCTAssertEqual(ArtworkFraming.offset(image: image, band: band, focus: UnitPoint(x: 3, y: -7)),
                       ArtworkFraming.offset(image: image, band: band, focus: UnitPoint(x: 1, y: 0)))
    }

    func testDecodeKeepsTheLongerSideWithinMaxPixel() throws {
        let url = try jpeg("big.jpg", width: 1600, height: 900)
        let image = try XCTUnwrap(ArtworkImages().image(at: url, maxPixel: 640))
        XCTAssertEqual(image.size, NSSize(width: 640, height: 360))
        let rep = try XCTUnwrap(image.representations.first)
        XCTAssertTrue(rep is NSBitmapImageRep)
        XCTAssertEqual(rep.pixelsWide, 640)
        XCTAssertEqual(rep.pixelsHigh, 360)
    }

    func testDecodeNeverEnlargesASmallImage() throws {
        let url = try jpeg("small.jpg", width: 64, height: 36)
        XCTAssertEqual(try XCTUnwrap(ArtworkImages().image(at: url, maxPixel: 3840)).size, NSSize(width: 64, height: 36))
    }

    func testDecodeStandsAnEXIFRotatedPhotoUpright() throws {
        let url = try jpeg("rotated.jpg", width: 400, height: 200, orientation: 6)   // stored sideways, shown rotated by 90 degrees
        XCTAssertEqual(try XCTUnwrap(ArtworkImages().image(at: url, maxPixel: 3840)).size, NSSize(width: 200, height: 400))
        XCTAssertEqual(try XCTUnwrap(ArtworkImages().image(at: url, maxPixel: 100)).size, NSSize(width: 50, height: 100))
    }

    func testTheSameImageComesBackUntilTheFileChanges() throws {
        let url = try jpeg("cached.jpg", width: 800, height: 450)
        var clock = Date()
        let images = ArtworkImages(now: { clock })
        let first = try XCTUnwrap(images.image(at: url, maxPixel: 640))
        XCTAssertTrue(images.image(at: url, maxPixel: 640) === first)
        XCTAssertFalse(images.image(at: url, maxPixel: 320) === first)   // another size is another entry
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
        XCTAssertTrue(images.image(at: url, maxPixel: 640) === first)   // not looked at again within the window
        clock.addTimeInterval(ArtworkImages.recheckInterval + 0.1)
        XCTAssertFalse(images.image(at: url, maxPixel: 640) === first)   // a changed file decodes again
    }

    func testTheModificationDateIsReadOnceWithinTheWindow() throws {
        let url = try jpeg("stat.jpg", width: 800, height: 450)
        var clock = Date(), stats = 0
        let images = ArtworkImages(now: { clock }, stat: { _ in stats += 1; return Date(timeIntervalSinceReferenceDate: 1) })
        _ = images.image(at: url, maxPixel: 640)
        clock.addTimeInterval(1)
        _ = images.image(at: url, maxPixel: 640)
        _ = images.image(at: url, maxPixel: 320)   // the date is by path, not by size
        XCTAssertEqual(stats, 1)
        clock.addTimeInterval(1.5)
        _ = images.image(at: url, maxPixel: 640)
        XCTAssertEqual(stats, 2)
    }

    func testAnUnreadableFileIsNil() throws {
        let url = temporary.appendingPathComponent("broken.jpg")
        try Data("not an image".utf8).write(to: url)
        XCTAssertNil(ArtworkImages().image(at: url, maxPixel: 640))
        XCTAssertNil(ArtworkImages().image(at: temporary.appendingPathComponent("missing.jpg"), maxPixel: 640))
    }

    func testTheArtworkLookupDecodesAtTheSizeAskedFor() throws {
        let url = try jpeg("own.jpg", width: 1600, height: 900)
        var game = LibraryGame(titleID: "0100535012974000", name: "Hades")
        game.artworkPath = url.path
        XCTAssertEqual(GameLibrary.artworkURLs(for: game, repo: temporary.path, banners: temporary), [url])
        XCTAssertEqual(GameLibrary.artwork(for: game, repo: temporary.path, banners: temporary, maxPixel: ArtworkImages.cardPixels)?.size, NSSize(width: 640, height: 360))
        XCTAssertEqual(GameLibrary.artwork(for: game, repo: temporary.path, banners: temporary)?.size, NSSize(width: 1600, height: 900))
        game.artworkPath = temporary.appendingPathComponent("gone.png").path
        XCTAssertEqual(GameLibrary.artworkURLs(for: game, repo: temporary.path, banners: temporary), [])   // nothing else to fall back to
    }

    func testAnImageThatDoesNotDecodeGivesWayToTheBanner() throws {
        let banner = try jpeg("0100535012974000.jpg", width: 1280, height: 720)
        let broken = temporary.appendingPathComponent("own.png")
        try Data("not an image".utf8).write(to: broken)
        var game = LibraryGame(titleID: "0100535012974000", name: "Hades")
        game.artworkPath = broken.path
        XCTAssertEqual(GameLibrary.artworkURLs(for: game, repo: temporary.path, banners: temporary), [broken, banner])
        XCTAssertEqual(GameLibrary.artwork(for: game, repo: temporary.path, banners: temporary)?.size, NSSize(width: 1280, height: 720))
    }
}
