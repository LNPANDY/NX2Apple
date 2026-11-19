import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import NXCore
@testable import NXModel

final class FrameworkExportBannerTests: XCTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxmodel-fw-banner-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    private func makeWidePNG() throws -> Data {
        let cs = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: 120, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(CGColor(colorSpace: cs, components: [0.1, 0.7, 0.3, 1.0])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
        let img = try XCTUnwrap(ctx.makeImage())
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    func testStandaloneFrameworkExportBackfillsBannerAndCreates512SquareIcon() throws {
        let tid = "0400486024DEC000"
        let workDir = temporary.appendingPathComponent("work")
        let fw = workDir.appendingPathComponent("shell-framework/DmGame\(tid).framework")
        let outDir = temporary.appendingPathComponent("out")
        let banners = temporary.appendingPathComponent("banners")
        try FileManager.default.createDirectory(at: fw, withIntermediateDirectories: true)
        try Data("bin".utf8).write(to: fw.appendingPathComponent("DmGame\(tid)"))
        let plist: [String: Any] = ["CFBundleExecutable": "DmGame\(tid)", "DMTitleID": tid]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: fw.appendingPathComponent("Info.plist"))

        let validPNG = try makeWidePNG()
        let outcome = BuildStore.stageAndReplaceFramework(
            framework: fw.path,
            titleID: tid,
            outFolder: outDir.path,
            team: "",
            runner: SystemProcessRunner(),
            banners: banners,
            pickedBanner: nil,
            workDir: workDir.path,
            ensureBanner: { id, dir in
                BannerCache.ensureCachedBanner(titleID: id, banners: dir, fetcher: { _, _ in validPNG })
            }
        )
        XCTAssertNil(outcome.error)
        let exported = try XCTUnwrap(outcome.destPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported + "/banner.jpg"))
        let iconURL = URL(fileURLWithPath: exported + "/icon.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: iconURL.path))
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(iconURL as CFURL, nil))
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertEqual(img.width, 512)
        XCTAssertEqual(img.height, 512)
    }
}
