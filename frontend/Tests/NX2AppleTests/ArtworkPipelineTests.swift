import AppKit
import XCTest
@testable import NX2Apple
@testable import NXCore

@MainActor final class ArtworkPipelineTests: IsolatedDefaultsTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nx2apple-artwork-pipeline-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    private func writeJPEG(_ name: String, color: NSColor = .systemGreen, width: Int = 160, height: Int = 80) throws -> URL {
        let url = temporary.appendingPathComponent(name)
        let img = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            color.setFill()
            rect.fill()
            return true
        }
        let tiff = try XCTUnwrap(img.tiffRepresentation)
        let data = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [:]))
        try data.write(to: url)
        return url
    }

    /// A known game downloads its single banner directly without waiting for or needing the 90 MB title database.
    func testKnownBannerDownloadsImmediatelyWithoutTitleList() async throws {
        let tid = "01007EF00011E000"
        let folder = temporary.appendingPathComponent("artwork")
        let missingList = temporary.appendingPathComponent("missing-titledb.json")
        let bannerFile = try writeJPEG("botw.jpg")

        let store = ArtworkStore(
            directory: folder,
            titleList: missingList,
            allowsFileURLs: true,
            knownBanners: [tid: bannerFile.absoluteString]
        )
        let added = await store.fetchMissing([tid], language: "en", lightweight: false)
        XCTAssertEqual(added, [tid])
        let cached = try XCTUnwrap(ArtworkStore.cachedBanner(tid, in: folder))
        XCTAssertEqual(try Data(contentsOf: cached), try Data(contentsOf: bannerFile))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("index.json").path))
    }

    /// A transient failure to fetch the title list must not permanently block retries on the same ArtworkStore instance.
    func testTransientTitleListFailureRetriesOnNextFetchWithoutLanguageSwitch() async throws {
        let tid = "0100CAFEBABE0000"
        let folder = temporary.appendingPathComponent("artwork")
        let listURL = temporary.appendingPathComponent("US.en.json")
        let bannerFile = try writeJPEG("retry.jpg", color: .systemBlue)

        let store = ArtworkStore(directory: folder, titleList: listURL, allowsFileURLs: true)
        // First attempt fails because listURL does not exist yet.
        let first = await store.fetchMissing([tid], language: "en")
        XCTAssertEqual(first, [])
        XCTAssertNil(ArtworkStore.cachedBanner(tid, in: folder))

        // List becomes available; next fetch on the SAME store and SAME language must recover.
        try Data("""
        {"1": {"id": "\(tid)", "name": "Recovered Game", "nsuId": 1, "bannerUrl": "\(bannerFile.absoluteString)"}}
        """.utf8).write(to: listURL)

        let second = await store.fetchMissing([tid], language: "en")
        XCTAssertEqual(second, [tid])
        let cached = try XCTUnwrap(ArtworkStore.cachedBanner(tid, in: folder))
        XCTAssertEqual(try Data(contentsOf: cached), try Data(contentsOf: bannerFile))
    }

    /// Default ArtworkStore skips the dead searching.nintendo-europe.com lookup so fetchMissing returns immediately.
    func testDefaultStoreDoesNotBlockOnDeadEuropeCatalogue() async throws {
        let tid = "01007EF00011E000"
        let folder = temporary.appendingPathComponent("artwork")
        let bannerFile = try writeJPEG("fast.jpg", color: .systemTeal)
        let missingList = temporary.appendingPathComponent("absent.json")
        // Notice: catalogue is intentionally omitted (uses default initializer behavior).
        let store = ArtworkStore(
            directory: folder,
            titleList: missingList,
            allowsFileURLs: true,
            knownBanners: [tid: bannerFile.absoluteString]
        )
        let start = Date()
        let added = await store.fetchMissing([tid], language: "en")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(added, [tid])
        XCTAssertLessThan(elapsed, 2.0, "default store must not block waiting on dead searching.nintendo-europe.com")
    }

    /// Tier-2 direct single-title lookup (nlib.cc) skips the 90 MB title database on hit, and falls back to titledb on 404/miss.
    func testTier2DirectLookupSkipsTitleListOnHitAndFallsBackOnMiss() async throws {
        XCTAssertTrue(ArtworkStore.imageHosts.contains("api.nlib.cc"))
        let hitTID = "0100AAAA11110000"
        let missTID = "0100BBBB22220000"
        let folder = temporary.appendingPathComponent("artwork")
        let directImg = try writeJPEG("direct.jpg", color: .systemPurple)
        let fallbackImg = try writeJPEG("titledb.jpg", color: .systemOrange)
        let missingImg = temporary.appendingPathComponent("404-direct.jpg")
        let missingList = temporary.appendingPathComponent("missing-list.json")

        // Hit: downloads via Tier-2 direct endpoint even when titleList does not exist.
        let hitStore = ArtworkStore(
            directory: folder,
            titleList: missingList,
            allowsFileURLs: true,
            directBannerURL: { id in id == hitTID ? directImg.absoluteString : nil }
        )
        let hitAdded = await hitStore.fetchMissing([hitTID], language: "en")
        XCTAssertEqual(hitAdded, [hitTID])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(ArtworkStore.cachedBanner(hitTID, in: folder))), try Data(contentsOf: directImg))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("index.json").path))

        // Miss (404): falls back cleanly to Tier-3 titledb.
        let listURL = temporary.appendingPathComponent("US.en.json")
        try Data("""
        {"1": {"id": "\(missTID)", "name": "New Switch 2 Title", "nsuId": 99, "bannerUrl": "\(fallbackImg.absoluteString)"}}
        """.utf8).write(to: listURL)
        let missStore = ArtworkStore(
            directory: folder,
            titleList: listURL,
            allowsFileURLs: true,
            directBannerURL: { _ in missingImg.absoluteString }
        )
        let missAdded = await missStore.fetchMissing([missTID], language: "en")
        XCTAssertEqual(missAdded, [missTID])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(ArtworkStore.cachedBanner(missTID, in: folder))), try Data(contentsOf: fallbackImg))
    }
}
