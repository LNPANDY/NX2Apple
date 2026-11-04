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
        XCTAssertFalse(CoverFile.animates("/missing/cover.mp4"))
    }

    func testAMovieOnDiskAnimatesAndAMissingOneDoesNot() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).mp4")
        try Data("not a movie".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(CoverFile.animates(url.path))
        XCTAssertFalse(CoverFile.animates(url.path + ".gone"))
    }

    func testAPngIsOneFrame() throws {
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cover-still-\(UUID().uuidString).png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(CoverFile.frames(at: url.path).count, 1)
        XCTAssertNotNil(CoverFile.poster(at: url.path))
        XCTAssertFalse(CoverFile.animates(url.path))
    }

    func testTheShellKeepsAGifAndAMovieAsThemselves() {
        XCTAssertTrue(CoverFile.shellExtensions.contains("gif"))
        XCTAssertTrue(CoverFile.shellExtensions.contains("mp4"))
        XCTAssertFalse(CoverFile.shellExtensions.contains("tiff"))
    }
}

final class CoverSealTests: XCTestCase {
    func testTheCertificateNameIsTheFirstAuthority() {
        let text = "Authority=Apple Development: Ada Lovelace (ABCDE12345)\nAuthority=Apple Worldwide Developer Relations Certification Authority\n"
        XCTAssertEqual(CoverSeal.identity(in: text), "Apple Development: Ada Lovelace (ABCDE12345)")
    }

    func testAnAdHocSignatureSealsAsAdHoc() {
        XCTAssertEqual(CoverSeal.identity(in: "Signature=adhoc\n"), "-")
        XCTAssertEqual(CoverSeal.identity(in: "flags=0x2(adhoc)\n"), "-")
    }

    func testADisplayWithNoIdentitySealsNothing() {
        XCTAssertNil(CoverSeal.identity(in: "code object is not signed at all\n"))
        XCTAssertNil(CoverSeal.identity(in: "Authority=-\n"))
    }
}
