import AppKit
import ImageIO
import XCTest
@testable import NX2Apple

final class FallbackIconTests: XCTestCase {
    private func image(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    func testAWideBannerBecomesASquareIconOfTheEngineSize() throws {
        let data = try XCTUnwrap(FallbackIcon.jpeg(from: try image(width: 1920, height: 1080)))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 256)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 256)
    }

    func testWithoutACachedBannerThereIsNoStandIn() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fallback-" + UUID().uuidString)
        XCTAssertEqual(FallbackIcon.environment(titleID: "0100000000010000", banners: folder.appendingPathComponent("none"), folder: folder), [:])
    }
}
