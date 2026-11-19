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
}
