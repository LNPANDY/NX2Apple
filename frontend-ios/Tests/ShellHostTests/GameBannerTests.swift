import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ShellHost
@testable import ShellUI

@Suite struct GameBannerTests {
    private actor FetchRecorder {
        var requestedURLs: [URL] = []
        private let responder: @Sendable (URL) -> Data?

        init(payload: Data?) {
            self.responder = { _ in payload }
        }

        init(responder: @escaping @Sendable (URL) -> Data?) {
            self.responder = responder
        }

        func fetch(_ url: URL) -> Data? {
            requestedURLs.append(url)
            return responder(url)
        }
    }

    private func solidJPEG(width: Int, height: Int, r: CGFloat, g: CGFloat, b: CGFloat) throws -> Data {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(ctx.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    @Test func bannerPriorityAndCustomSaveResetFlow() async throws {
        let sandbox = try Sandbox()
        let gameDir = sandbox.games.appendingPathComponent(Fixtures.orbit, isDirectory: true)
        let bundledBannerURL = gameDir.appendingPathComponent("banner.png")
        try pngData(width: 64, height: 36).write(to: bundledBannerURL)

        let model = await MainActor.run { ShellHostModel(config: sandbox.config()) }
        await model.waitForStartupTasks()

        // Step 1: Bundled banner is used by default and hasCustomCover is false.
        let initial = try #require(await MainActor.run { model.details.first(where: { $0.id == Fixtures.orbit }) })
        #expect(initial.game.banner?.id == bundledBannerURL.path)
        #expect(!initial.game.hasCustomCover)

        // Step 2: Saving a custom cover writes custom.jpg, marks BackupExclusion, and immediately swaps Artwork.
        let custom1 = try solidJPEG(width: 320, height: 180, r: 0.9, g: 0.1, b: 0.1)
        await MainActor.run { model.saveCustomCover(for: Fixtures.orbit, jpegData: custom1) }

        let customURL = try #require(GameBannerStore.customBannerURL(for: Fixtures.orbit, bannersRoot: sandbox.banners))
        #expect(FileManager.default.fileExists(atPath: customURL.path))
        #expect(BackupExclusion.isExcluded(sandbox.banners))

        let afterFirstSave = try #require(await MainActor.run { model.details.first(where: { $0.id == Fixtures.orbit }) })
        #expect(afterFirstSave.game.hasCustomCover)
        #expect(afterFirstSave.game.banner?.id == customURL.path)

        // Step 3: Saving a second custom cover invalidates the in-memory Artwork cache immediately.
        let custom2 = try solidJPEG(width: 640, height: 360, r: 0.1, g: 0.8, b: 0.2)
        await MainActor.run { model.saveCustomCover(for: Fixtures.orbit, jpegData: custom2) }
        let afterSecondSave = try #require(await MainActor.run { model.details.first(where: { $0.id == Fixtures.orbit }) })
        #expect(afterSecondSave.game.hasCustomCover)
        #expect(afterSecondSave.game.banner != afterFirstSave.game.banner)

        // Step 4: Resetting deletes custom.jpg and restores the bundled banner immediately.
        await MainActor.run { model.resetCustomCover(for: Fixtures.orbit) }
        #expect(!FileManager.default.fileExists(atPath: customURL.path))
        let afterReset = try #require(await MainActor.run { model.details.first(where: { $0.id == Fixtures.orbit }) })
        #expect(!afterReset.game.hasCustomCover)
        #expect(afterReset.game.banner?.id == bundledBannerURL.path)
    }

    @Test func missingBannerBackfillsAutoJpgFromKnownGameBanners() async throws {
        let sandbox = try Sandbox()
        // Fixtures.orbit is 0100000000010000 (Super Mario Odyssey) in KnownGameBanners and has no bundled banner.
        let expectedRemoteURL = try #require(KnownGameBanners.url(for: Fixtures.orbit))
        let fetchedBytes = try solidJPEG(width: 500, height: 250, r: 0.2, g: 0.5, b: 0.9)
        let recorder = FetchRecorder(payload: fetchedBytes)

        let config = sandbox.config(fetchBannerData: { url in
            await recorder.fetch(url)
        })
        let model = await MainActor.run { ShellHostModel(config: config) }
        await model.waitForStartupTasks()

        let requested = await recorder.requestedURLs
        // Orbit hits KnownGameBanners first and stops without querying nlib.cc; unknown fixtures fall back to nlib.cc.
        #expect(requested.contains(expectedRemoteURL))
        let orbitNlibURL = try #require(GameBannerStore.nlibBannerURL(for: Fixtures.orbit))
        #expect(!requested.contains(orbitNlibURL))
        let chainNlibURL = try #require(GameBannerStore.nlibBannerURL(for: Fixtures.chain))
        #expect(requested.contains(chainNlibURL))

        let autoURL = try #require(GameBannerStore.autoBannerURL(for: Fixtures.orbit, bannersRoot: sandbox.banners))
        #expect(FileManager.default.fileExists(atPath: autoURL.path))
        #expect(BackupExclusion.isExcluded(sandbox.banners))
        let chainAutoURL = try #require(GameBannerStore.autoBannerURL(for: Fixtures.chain, bannersRoot: sandbox.banners))
        #expect(FileManager.default.fileExists(atPath: chainAutoURL.path))

        let detail = try #require(await MainActor.run { model.details.first(where: { $0.id == Fixtures.orbit }) })
        #expect(detail.game.banner?.id == autoURL.path)
        #expect(!detail.game.hasCustomCover)
        let chainDetail = try #require(await MainActor.run { model.details.first(where: { $0.id == Fixtures.chain }) })
        #expect(chainDetail.game.banner?.id == chainAutoURL.path)
        #expect(!chainDetail.game.hasCustomCover)

        // Subsequent reload uses persisted auto.jpg without re-fetching over the network.
        let secondRecorder = FetchRecorder(payload: fetchedBytes)
        let model2 = await MainActor.run {
            ShellHostModel(config: sandbox.config(fetchBannerData: { url in
                await secondRecorder.fetch(url)
            }))
        }
        await model2.waitForStartupTasks()
        #expect(await secondRecorder.requestedURLs.isEmpty)
        let detail2 = try #require(await MainActor.run { model2.details.first(where: { $0.id == Fixtures.orbit }) })
        #expect(detail2.game.banner?.id == autoURL.path)
    }

    @Test func bundledBannerOrCustomCoverSkipsRemoteBackfill() async throws {
        let sandbox = try Sandbox()
        let gameDir = sandbox.games.appendingPathComponent(Fixtures.orbit, isDirectory: true)
        try pngData(width: 64, height: 36).write(to: gameDir.appendingPathComponent("banner.png"))

        let recorder = FetchRecorder(payload: try solidJPEG(width: 160, height: 90, r: 1, g: 0, b: 0))
        let model = await MainActor.run {
            ShellHostModel(config: sandbox.config(fetchBannerData: { url in
                await recorder.fetch(url)
            }))
        }
        await model.waitForStartupTasks()
        let requested = await recorder.requestedURLs
        let orbitKnown = try #require(KnownGameBanners.url(for: Fixtures.orbit))
        let orbitNlib = try #require(GameBannerStore.nlibBannerURL(for: Fixtures.orbit))
        #expect(!requested.contains(orbitKnown))
        #expect(!requested.contains(orbitNlib))
    }

    @Test func knownBannerFailureFallsBackToNlibSinglePointEndpoint() async throws {
        let sandbox = try Sandbox()
        let orbitKnown = try #require(KnownGameBanners.url(for: Fixtures.orbit))
        let orbitNlib = try #require(GameBannerStore.nlibBannerURL(for: Fixtures.orbit))
        #expect(orbitNlib.absoluteString == "https://api.nlib.cc/nx/0100000000010000/banner/720p")
        #expect(GameBannerStore.nlibBannerURL(for: "0100abcd00010000")?.absoluteString == "https://api.nlib.cc/nx/0100ABCD00010000/banner/720p")
        #expect(GameBannerStore.nlibBannerURL(for: "not-a-title-id") == nil)
        #expect(GameBannerStore.nlibBannerURL(for: "../0100000000010000") == nil)

        let fallbackBytes = try solidJPEG(width: 640, height: 360, r: 0.3, g: 0.7, b: 0.4)
        let recorder = FetchRecorder { url in
            if url == orbitKnown { return nil } // simulate primary CDN outage
            if url == orbitNlib { return fallbackBytes }
            return nil
        }

        let model = await MainActor.run {
            ShellHostModel(config: sandbox.config(fetchBannerData: { url in
                await recorder.fetch(url)
            }))
        }
        await model.waitForStartupTasks()

        let requested = await recorder.requestedURLs
        let knownIdx = try #require(requested.firstIndex(of: orbitKnown))
        let nlibIdx = try #require(requested.firstIndex(of: orbitNlib))
        #expect(knownIdx < nlibIdx)

        let autoURL = try #require(GameBannerStore.autoBannerURL(for: Fixtures.orbit, bannersRoot: sandbox.banners))
        #expect(FileManager.default.fileExists(atPath: autoURL.path))
        let detail = try #require(await MainActor.run { model.details.first(where: { $0.id == Fixtures.orbit }) })
        #expect(detail.game.banner?.id == autoURL.path)
        #expect(!detail.game.hasCustomCover)
    }

    @Test func invalidPayloadsAndTraversalIDsAreRejectedSafely() async throws {
        let sandbox = try Sandbox()
        // Traversal IDs are rejected by GameBannerStore.
        #expect(GameBannerStore.sanitizedTitleID("../evil") == nil)
        #expect(GameBannerStore.sanitizedTitleID("a/b") == nil)
        #expect(GameBannerStore.sanitizedTitleID("a:b") == nil)
        #expect(throws: GameBannerStore.StoreError.invalidTitleID) {
            try GameBannerStore.saveCustomBanner(try solidJPEG(width: 32, height: 18, r: 1, g: 0, b: 0),
                                                 for: "../evil", bannersRoot: sandbox.banners)
        }

        // Corrupt remote data is never persisted as auto.jpg.
        let corruptRecorder = FetchRecorder(payload: Data("not-an-image".utf8))
        let model = await MainActor.run {
            ShellHostModel(config: sandbox.config(fetchBannerData: { url in
                await corruptRecorder.fetch(url)
            }))
        }
        await model.waitForStartupTasks()
        let autoURL = try #require(GameBannerStore.autoBannerURL(for: Fixtures.orbit, bannersRoot: sandbox.banners))
        #expect(!FileManager.default.fileExists(atPath: autoURL.path))
        let detail = try #require(await MainActor.run { model.details.first(where: { $0.id == Fixtures.orbit }) })
        #expect(detail.game.banner == nil)

        // Corrupt custom cover save shows notice and leaves disk clean.
        await MainActor.run { model.saveCustomCover(for: Fixtures.orbit, jpegData: Data("corrupt".utf8)) }
        let customURL = try #require(GameBannerStore.customBannerURL(for: Fixtures.orbit, bannersRoot: sandbox.banners))
        #expect(!FileManager.default.fileExists(atPath: customURL.path))
        let notice = await MainActor.run { model.notice }
        #expect(notice != nil)
    }

    @Test func nintendoStoreUSNextDataAndHKOpenGraphFallbacksAndSecurityChecks() async throws {
        #expect(KnownGameBanners.imageHosts.contains("assets.nintendo.com"))
        #expect(KnownGameBanners.url(for: "04008E001F098000") != nil)
        #expect(KnownGameBanners.isSwitch2TitleID("04008E001F098000"))

        let sw2TID = "0400FACE12340000"
        let assetURL = "https://assets.nintendo.com/image/upload/q_auto/f_auto/store/software/switch2/70010000125145/60f801a1"
        let usHTML = """
        <html><head><script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"linkedData":[{"@type":"VideoGame","image":"\(assetURL)"}]}}}</script></head></html>
        """
        let widePNG = pngData(width: 1920, height: 1080)
        let portraitPNG = pngData(width: 400, height: 600)

        // 1. US __NEXT_DATA__ hits 1920x1080 PNG and normalizes to JPEG bytes.
        let usOutcome = await GameBannerStore.fetchNintendoStoreBanner(titleID: sw2TID) { req, _ in
            let u = req.url!.absoluteString
            if u == "https://ec.nintendo.com/apps/\(sw2TID)/US" {
                return GameBannerStore.RemoteResponse(
                    statusCode: 200,
                    finalURL: URL(string: "https://www.nintendo.com/us/store/products/demo-switch-2/")!,
                    data: Data(usHTML.utf8)
                )
            }
            if u == assetURL {
                return GameBannerStore.RemoteResponse(statusCode: 200, finalURL: URL(string: assetURL)!, data: widePNG)
            }
            return GameBannerStore.RemoteResponse(statusCode: 404, finalURL: req.url!, data: Data())
        }
        guard case .image(let jpegBytes, let resolvedSource) = usOutcome else {
            Issue.record("expected US __NEXT_DATA__ hit, got \(usOutcome)")
            return
        }
        #expect(resolvedSource.absoluteString == assetURL)
        #expect(Array(jpegBytes.prefix(3)) == [0xFF, 0xD8, 0xFF])
        let size = try #require(GameBannerStore.imagePixelSize(jpegBytes))
        #expect(size.width == 1920 && size.height == 1080)

        // 2. US 404 falls back to HK og:image with reversed attribute order.
        let hkTID = "0100AA11BB220000"
        let hkImg = "https://img-eshop.cdn.nintendo.net/i/0123456789abcdef0123456789abcdef.jpg"
        let hkHTML = """
        <html><head><meta content="\(hkImg)" property="og:image"></head></html>
        """
        let hkOutcome = await GameBannerStore.fetchNintendoStoreBanner(titleID: hkTID) { req, _ in
            let u = req.url!.absoluteString
            if u.hasSuffix("/US") {
                return GameBannerStore.RemoteResponse(statusCode: 404, finalURL: req.url!, data: Data())
            }
            if u.hasSuffix("/HK") {
                return GameBannerStore.RemoteResponse(
                    statusCode: 200,
                    finalURL: URL(string: "https://ec.nintendo.com/HK/zh/titles/70010000000001")!,
                    data: Data(hkHTML.utf8)
                )
            }
            if u == hkImg {
                return GameBannerStore.RemoteResponse(statusCode: 200, finalURL: URL(string: hkImg)!, data: widePNG)
            }
            return GameBannerStore.RemoteResponse(statusCode: 404, finalURL: req.url!, data: Data())
        }
        guard case .image(_, let hkSource) = hkOutcome else {
            Issue.record("expected HK og:image hit, got \(hkOutcome)")
            return
        }
        #expect(hkSource.absoluteString == hkImg)

        // 3. Disallowed store redirect host is rejected.
        let badStoreRedirect = await GameBannerStore.fetchNintendoStoreBanner(titleID: sw2TID) { req, _ in
            if req.url!.absoluteString.contains("ec.nintendo.com") {
                return GameBannerStore.RemoteResponse(
                    statusCode: 200,
                    finalURL: URL(string: "https://evil.example/store")!,
                    data: Data(usHTML.utf8)
                )
            }
            Issue.record("must not fetch image after disallowed store redirect")
            return GameBannerStore.RemoteResponse(statusCode: 404, finalURL: req.url!, data: Data())
        }
        #expect(badStoreRedirect == .notFound)

        // 4. Disallowed image redirect host is rejected.
        let badImgRedirect = await GameBannerStore.fetchNintendoStoreBanner(titleID: sw2TID) { req, _ in
            if req.url!.absoluteString.hasSuffix("/US") {
                return GameBannerStore.RemoteResponse(
                    statusCode: 200,
                    finalURL: URL(string: "https://www.nintendo.com/us/store/products/demo-switch-2/")!,
                    data: Data(usHTML.utf8)
                )
            }
            if req.url!.absoluteString == assetURL {
                return GameBannerStore.RemoteResponse(
                    statusCode: 200,
                    finalURL: URL(string: "https://evil-cdn.example/banner.jpg")!,
                    data: widePNG
                )
            }
            return GameBannerStore.RemoteResponse(statusCode: 404, finalURL: req.url!, data: Data())
        }
        #expect(badImgRedirect == .notFound)

        // 5. Portrait image (width <= height) is rejected.
        let portraitRejected = await GameBannerStore.fetchNintendoStoreBanner(titleID: sw2TID) { req, _ in
            if req.url!.absoluteString.hasSuffix("/US") {
                return GameBannerStore.RemoteResponse(
                    statusCode: 200,
                    finalURL: URL(string: "https://www.nintendo.com/us/store/products/demo-switch-2/")!,
                    data: Data(usHTML.utf8)
                )
            }
            if req.url!.absoluteString == assetURL {
                return GameBannerStore.RemoteResponse(statusCode: 200, finalURL: URL(string: assetURL)!, data: portraitPNG)
            }
            return GameBannerStore.RemoteResponse(statusCode: 404, finalURL: req.url!, data: Data())
        }
        #expect(portraitRejected == .notFound)

        // 6. 5xx returns .transientFailure (must not permanently poison ShellHostModel backfill).
        let serverError = await GameBannerStore.fetchNintendoStoreBanner(titleID: sw2TID) { req, _ in
            GameBannerStore.RemoteResponse(statusCode: 503, finalURL: req.url!, data: Data())
        }
        #expect(serverError == .transientFailure)
    }

    @Test func shellHostModelTransientStoreErrorRetriesOnReloadWithoutNegativeCache() async throws {
        let sandbox = try Sandbox()
        // Fixtures.chain (0100000000020000) is not in KnownGameBanners and has no bundled banner.
        let hkImg = "https://img-eshop.cdn.nintendo.net/i/abcdef0123456789abcdef0123456789.jpg"
        let hkHTML = #"<html><head><meta content="\#(hkImg)" property="og:image"></head></html>"#
        let wideJPEG = try solidJPEG(width: 1920, height: 1080, r: 0.2, g: 0.6, b: 0.8)

        actor Toggle {
            var failWith503 = true
            func setFail(_ v: Bool) { failWith503 = v }
        }
        let toggle = Toggle()

        let config = sandbox.config(
            fetchBannerData: { _ in nil }, // simulate nlib.cc 404 so ec.nintendo.com runs
            fetchStoreResponse: { req, _ in
                let u = req.url!.absoluteString
                if await toggle.failWith503 {
                    return GameBannerStore.RemoteResponse(statusCode: 503, finalURL: req.url!, data: Data())
                }
                if u == "https://ec.nintendo.com/apps/\(Fixtures.chain)/US" {
                    return GameBannerStore.RemoteResponse(statusCode: 404, finalURL: req.url!, data: Data())
                }
                if u == "https://ec.nintendo.com/apps/\(Fixtures.chain)/HK" {
                    return GameBannerStore.RemoteResponse(
                        statusCode: 200,
                        finalURL: URL(string: "https://ec.nintendo.com/HK/zh/titles/70010000000002")!,
                        data: Data(hkHTML.utf8)
                    )
                }
                if u == hkImg {
                    return GameBannerStore.RemoteResponse(statusCode: 200, finalURL: URL(string: hkImg)!, data: wideJPEG)
                }
                return GameBannerStore.RemoteResponse(statusCode: 404, finalURL: req.url!, data: Data())
            }
        )

        let model = await MainActor.run { ShellHostModel(config: config) }
        await model.waitForStartupTasks()
        let autoURL = try #require(GameBannerStore.autoBannerURL(for: Fixtures.chain, bannersRoot: sandbox.banners))
        #expect(!FileManager.default.fileExists(atPath: autoURL.path))

        // Recover from transient 503: next reload retries and persists auto.jpg.
        await toggle.setFail(false)
        await MainActor.run { model.reload() }
        await model.waitForStartupTasks()
        #expect(FileManager.default.fileExists(atPath: autoURL.path))
        let detail = try #require(await MainActor.run { model.details.first(where: { $0.id == Fixtures.chain }) })
        #expect(detail.game.banner?.id == autoURL.path)
    }
}
