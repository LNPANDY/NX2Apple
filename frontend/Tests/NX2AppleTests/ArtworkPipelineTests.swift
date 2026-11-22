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

    /// Switch 2 titles prefer Nintendo store fallback ahead of nlib.cc; Switch 1 tries nlib.cc first then falls back to Nintendo store.
    /// Transient 5xx/timeouts never write a permanent negative cache and stop once the per-batch error budget is reached.
    func testNintendoStoreFallbackPriorityTransientRecoveryAndBatchBudget() async throws {
        XCTAssertTrue(ArtworkStore.imageHosts.contains("assets.nintendo.com"))
        XCTAssertNotNil(SupportedBanners.urls["04008E001F098000"])

        let sw2TID = "0400CAFE11110000"
        let sw1TID = "0100CAFE22220000"
        let folder = temporary.appendingPathComponent("artwork-store-fallback")
        let missingList = temporary.appendingPathComponent("missing-list.json")
        let missingDirect = temporary.appendingPathComponent("404.jpg")
        let bannerURL = try writeJPEG("store-hit.jpg", color: .systemIndigo, width: 1920, height: 1080)
        let bannerBytes = try Data(contentsOf: bannerURL)

        actor EventLog {
            var events: [String] = []
            func append(_ e: String) { events.append(e) }
        }
        let log = EventLog()

        // 1. Switch 2 hits storeBannerFetcher first without calling directBannerURL or titledb.
        let sw2Store = ArtworkStore(
            directory: folder,
            titleList: missingList,
            allowsFileURLs: true,
            directBannerURL: { id in
                Task { await log.append("direct:\(id)") }
                return missingDirect.absoluteString
            },
            storeBannerFetcher: { id in
                await log.append("store:\(id)")
                return .image(bannerBytes, sourceURL: URL(string: "https://assets.nintendo.com/image/upload/q_auto/f_auto/store/software/switch2/1/a")!)
            }
        )
        let sw2Added = await sw2Store.fetchMissing([sw2TID], language: "en")
        XCTAssertEqual(sw2Added, [sw2TID])
        let sw2Events = await log.events
        XCTAssertEqual(sw2Events, ["store:\(sw2TID)"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("index.json").path))

        // 2. Switch 1 tries directBannerURL first (fails 404), then succeeds via storeBannerFetcher.
        let sw1Log = EventLog()
        let sw1Store = ArtworkStore(
            directory: folder,
            titleList: missingList,
            allowsFileURLs: true,
            directBannerURL: { id in
                Task { await sw1Log.append("direct:\(id)") }
                return missingDirect.absoluteString
            },
            storeBannerFetcher: { id in
                await sw1Log.append("store:\(id)")
                return .image(bannerBytes, sourceURL: URL(string: "https://img-eshop.cdn.nintendo.net/i/abcdef123456.jpg")!)
            }
        )
        let sw1Added = await sw1Store.fetchMissing([sw1TID], language: "en")
        XCTAssertEqual(sw1Added, [sw1TID])
        let sw1Events = await sw1Log.events
        XCTAssertTrue(sw1Events.contains("store:\(sw1TID)"))

        // 3. Transient error does not poison long-term cache; next fetch recovers cleanly.
        let retryTID = "0400BEEF33330000"
        final class Toggle: @unchecked Sendable { var fail = true }
        let toggle = Toggle()
        let retryStore = ArtworkStore(
            directory: folder,
            titleList: missingList,
            allowsFileURLs: true,
            storeBannerFetcher: { _ in
                if toggle.fail { return .transientError }
                return .image(bannerBytes, sourceURL: URL(string: "https://assets.nintendo.com/image/upload/q_auto/f_auto/store/software/switch2/2/b")!)
            }
        )
        let firstTry = await retryStore.fetchMissing([retryTID], language: "en")
        XCTAssertEqual(firstTry, [])
        XCTAssertNil(ArtworkStore.cachedBanner(retryTID, in: folder))

        toggle.fail = false
        let secondTry = await retryStore.fetchMissing([retryTID], language: "en")
        XCTAssertEqual(secondTry, [retryTID])

        // 4. Batch budget stops probing remaining titles once cumulative transient error time reaches 24s.
        final class ClockBox: @unchecked Sendable {
            var now = Date(timeIntervalSinceReferenceDate: 10_000)
            var probed: [String] = []
        }
        let clockBox = ClockBox()
        let budgetStore = ArtworkStore(
            directory: folder,
            titleList: missingList,
            allowsFileURLs: true,
            storeBannerFetcher: { id in
                clockBox.probed.append(id)
                clockBox.now.addTimeInterval(13)
                return .transientError
            },
            now: { clockBox.now }
        )
        let budgetAdded = await budgetStore.fetchMissing(
            ["0400000000010000", "0400000000020000", "0400000000030000", "0400000000040000"],
            language: "en"
        )
        XCTAssertEqual(budgetAdded, [])
        XCTAssertEqual(clockBox.probed.count, 2, "must stop probing after cumulative transient failures exhaust the 24s budget")
    }
}
