import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import NXCore

final class BannerCachePipelineTests: XCTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxcore-banner-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    /// Generates a real 160×80 wide PNG with red sidebars and a green center square so square center-crop is verifiable.
    private func makeWidePNG(width: Int = 160, height: Int = 80) throws -> Data {
        let cs = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // Red background (left/right wings)
        ctx.setFillColor(CGColor(colorSpace: cs, components: [0.9, 0.1, 0.1, 1.0])!)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Green center square
        let side = min(width, height)
        ctx.setFillColor(CGColor(colorSpace: cs, components: [0.1, 0.85, 0.2, 1.0])!)
        ctx.fill(CGRect(x: (width - side) / 2, y: (height - side) / 2, width: side, height: side))

        let img = try XCTUnwrap(ctx.makeImage())
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    func testKnownGameBannersCatalogAndCandidatesAreValid() throws {
        XCTAssertGreaterThanOrEqual(KnownGameBanners.urls.count, 150)
        XCTAssertEqual(KnownGameBanners.switch2Fallbacks.count, 8)
        XCTAssertTrue(KnownGameBanners.imageHosts.contains("api.nlib.cc"))
        XCTAssertEqual(
            KnownGameBanners.nlibBannerURL(for: "0100deadbeef0000"),
            "https://api.nlib.cc/nx/0100DEADBEEF0000/banner/720p"
        )
        XCTAssertNil(KnownGameBanners.nlibBannerURL(for: "invalid"))
        for (tid, link) in KnownGameBanners.urls {
            XCTAssertTrue(KnownGameBanners.isValidTitleID(tid), tid)
            let url = try XCTUnwrap(URL(string: link), tid)
            XCTAssertTrue(KnownGameBanners.isAllowedURL(url), link)
        }
        let nintendo500 = "https://www.nintendo.com/eu/media/images/sample_image500w.jpg"
        XCTAssertEqual(
            KnownGameBanners.downloadCandidates(for: nintendo500, lightweight: false),
            ["https://www.nintendo.com/eu/media/images/sample_image1600w.jpg", nintendo500]
        )
        XCTAssertEqual(
            KnownGameBanners.downloadCandidates(for: nintendo500, lightweight: true),
            [nintendo500]
        )
    }

    func testEnsureCachedBannerFallsBackToNlibSingleEndpointForUnknownGame() throws {
        let unknownTID = "0100CAFE12340000"
        let banners = temporary.appendingPathComponent("banners")
        let validPNG = try makeWidePNG()
        final class Capture: @unchecked Sendable { var calls: [(String, TimeInterval)] = [] }
        let capture = Capture()

        let result = BannerCache.ensureCachedBanner(titleID: unknownTID, banners: banners, timeout: 12, fetcher: { url, timeout in
            capture.calls.append((url.absoluteString, timeout))
            return validPNG
        })
        let saved = try XCTUnwrap(result)
        XCTAssertEqual(capture.calls.count, 1)
        XCTAssertEqual(capture.calls[0].0, "https://api.nlib.cc/nx/\(unknownTID)/banner/720p")
        XCTAssertLessThanOrEqual(capture.calls[0].1, 8.0)
        XCTAssertEqual(try Data(contentsOf: saved), validPNG)
    }

    func testEnsureCachedBannerBackfillsKnownGameAndRejectsInvalidPayloads() throws {
        let tid = "01007EF00011E000"
        let banners = temporary.appendingPathComponent("banners")
        let validPNG = try makeWidePNG()
        final class Counter: @unchecked Sendable { var calls: [URL] = [] }
        let badCounter = Counter()

        // Non-image HTML payload must be rejected and never written to cache.
        let rejected = BannerCache.ensureCachedBanner(titleID: tid, banners: banners, fetcher: { url, _ in
            badCounter.calls.append(url)
            return Data("<html>error</html>".utf8)
        })
        XCTAssertNil(rejected)
        XCTAssertFalse(badCounter.calls.isEmpty)
        XCTAssertNil(BannerCache.cached(tid, in: banners))

        // Valid image payload is written atomically and reused on subsequent calls without hitting fetcher.
        let goodCounter = Counter()
        let cached = BannerCache.ensureCachedBanner(titleID: tid, banners: banners, fetcher: { url, _ in
            goodCounter.calls.append(url)
            return validPNG
        })
        let savedURL = try XCTUnwrap(cached)
        XCTAssertEqual(goodCounter.calls.count, 1)
        XCTAssertEqual(try Data(contentsOf: savedURL), validPNG)

        let second = BannerCache.ensureCachedBanner(titleID: tid, banners: banners, fetcher: { _, _ in
            XCTFail("cached banner must not trigger a second fetch")
            return nil
        })
        XCTAssertEqual(second, savedURL)
    }

    func testEnsureCachedBannerReadsLocalIndexBeforeKnownTable() throws {
        let tid = "0100DEADBEEF0000"
        let banners = temporary.appendingPathComponent("banners")
        try FileManager.default.createDirectory(at: banners, withIntermediateDirectories: true)
        let expected = "https://img-eshop.cdn.nintendo.net/i/custom-indexed-banner.jpg"
        try Data("""
        {"banners": {"\(tid)": "\(expected)"}}
        """.utf8).write(to: banners.appendingPathComponent("index.json"))

        let validPNG = try makeWidePNG()
        final class Capture: @unchecked Sendable { var url: String? }
        let capture = Capture()
        let result = BannerCache.ensureCachedBanner(titleID: tid, banners: banners, fetcher: { url, _ in
            capture.url = url.absoluteString
            return validPNG
        })
        XCTAssertNotNil(result)
        XCTAssertEqual(capture.url, expected)
    }

    func testPlaceBannerBackfillsCacheAndSynthesizes512SquareIconPNG() throws {
        let tid = "0400486024DEC000"
        let banners = temporary.appendingPathComponent("banners")
        let fw = temporary.appendingPathComponent("DmGame\(tid).framework")
        try FileManager.default.createDirectory(at: fw, withIntermediateDirectories: true)
        let validPNG = try makeWidePNG(width: 160, height: 80)

        let placed = ShellInstall.placeBanner(
            titleID: tid,
            framework: fw.path,
            banners: banners,
            picked: nil,
            ensureCached: { id, dir in
                BannerCache.ensureCachedBanner(titleID: id, banners: dir, fetcher: { _, _ in validPNG })
            }
        )
        XCTAssertNotNil(placed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: banners.appendingPathComponent("\(tid).jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fw.appendingPathComponent("banner.jpg").path))

        let iconURL = fw.appendingPathComponent("icon.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: iconURL.path), "missing icon.png must be synthesized from banner")
        let iconData = try Data(contentsOf: iconURL)
        XCTAssertEqual(Array(iconData.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(iconData as CFData, nil))
        let iconImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(iconImage.width, 512)
        XCTAssertEqual(iconImage.height, 512)

        // Verify corner pixel is green (from center square crop, not red sidebars).
        let cs = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var pixel = [UInt8](repeating: 0, count: 4)
        let ctx = try XCTUnwrap(CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.draw(iconImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertGreaterThan(pixel[1], pixel[0], "center-cropped icon should sample green center, not red wings")
    }

    func testPlaceBannerNeverOverwritesExistingNativeIconPNG() throws {
        let tid = "01007EF00011E000"
        let banners = temporary.appendingPathComponent("banners")
        try FileManager.default.createDirectory(at: banners, withIntermediateDirectories: true)
        try makeWidePNG().write(to: banners.appendingPathComponent("\(tid).jpg"))
        let fw = temporary.appendingPathComponent("DmGame\(tid).framework")
        try FileManager.default.createDirectory(at: fw, withIntermediateDirectories: true)
        let nativeIcon = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4])
        let iconURL = fw.appendingPathComponent("icon.png")
        try nativeIcon.write(to: iconURL)

        let placed = ShellInstall.placeBanner(titleID: tid, framework: fw.path, banners: banners, picked: nil)
        XCTAssertNotNil(placed)
        XCTAssertEqual(try Data(contentsOf: iconURL), nativeIcon)
    }
}
