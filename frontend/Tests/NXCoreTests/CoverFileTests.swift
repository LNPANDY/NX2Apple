import XCTest
@testable import NXCore

final class CoverFileTests: XCTestCase {
    func testAMovieIsToldFromAStillByItsName() {
        XCTAssertTrue(CoverFile.isMovie("/covers/clip.MP4"))
        XCTAssertTrue(CoverFile.isMovie("/covers/clip.mov"))
        XCTAssertTrue(CoverFile.isMovie("/covers/clip.m4v"))
        XCTAssertFalse(CoverFile.isMovie("/covers/clip.gif"))
        XCTAssertFalse(CoverFile.isMovie(""))
        XCTAssertFalse(CoverFile.animates(""))
        XCTAssertFalse(CoverFile.animates("/missing/cover.jpg"))
        XCTAssertTrue(CoverFile.animates("/missing/cover.mp4"))
    }

    func testAPngIsOneFrame() throws {
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cover-still-\(UUID().uuidString).png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(CoverFile.frames(at: url.path).count, 1)
        XCTAssertFalse(CoverFile.animates(url.path))
    }

    func testTheShellKeepsAGifAndAMovieAsThemselves() {
        XCTAssertTrue(CoverFile.shellExtensions.contains("gif"))
        XCTAssertTrue(CoverFile.shellExtensions.contains("mp4"))
        XCTAssertFalse(CoverFile.shellExtensions.contains("tiff"))
    }
}
