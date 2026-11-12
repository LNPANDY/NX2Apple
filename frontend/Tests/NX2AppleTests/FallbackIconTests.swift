import AppKit
import ImageIO
import XCTest
@testable import NX2Apple
@testable import NXCore

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
        XCTAssertEqual(FallbackIcon.arguments(titleID: "0100000000010000", banners: folder.appendingPathComponent("none"), folder: folder), [])
    }

    func testCachedBannerProducesFallbackIconArguments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fallback-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let banners = root.appendingPathComponent("banners", isDirectory: true)
        let out = root.appendingPathComponent("icons", isDirectory: true)
        try FileManager.default.createDirectory(at: banners, withIntermediateDirectories: true)
        let data = try XCTUnwrap(FallbackIcon.jpeg(from: try image(width: 1280, height: 720)))
        let tid = "0400c76024710000"
        try data.write(to: banners.appendingPathComponent("0400C76024710000.jpg"))
        let args = FallbackIcon.arguments(titleID: tid, banners: banners, folder: out)
        XCTAssertEqual(args, ["--fallback-icon", out.appendingPathComponent("fallback-icon-0400C76024710000.jpg").path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: args[1]))
    }

    func testSupportsFallbackIconMatchesTheSyncedEngineAndRejectsOlderScripts() throws {
        let checkout = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertTrue(RepoLayout.supportsFallbackIcon(checkout.path), "the synced engine at ccd834e06a39 accepts --fallback-icon")

        let older = FileManager.default.temporaryDirectory.appendingPathComponent("repo-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: older) }
        let script = older.appendingPathComponent(RepoLayout.buildScript)
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "ap.add_argument('--work-dir')\n".write(to: script, atomically: true, encoding: .utf8)
        XCTAssertFalse(RepoLayout.supportsFallbackIcon(older.path))
    }
}
