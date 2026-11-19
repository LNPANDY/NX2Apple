import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

final class ArtworkPipelineFixTests: IsolatedDefaultsTestCase {
    private var temporary: URL!
    private let titleID = "0100535012974000"
    private let titleIDU64: UInt64 = 0x0100_5350_1297_4000

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nx-art-fix-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeJPEGData(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cg = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    private func writeJPEG(_ name: String, width: Int, height: Int, red: CGFloat = 0.9, green: CGFloat = 0.3, blue: CGFloat = 0.1) throws -> URL {
        let url = temporary.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeJPEGData(width: width, height: height, red: red, green: green, blue: blue).write(to: url)
        return url
    }

    /// Builds a Control NCA RomFS with arbitrary root files (such as `icon_SimplifiedChinese.dat`, `icon_AmericanEnglish.dat`, `control.nacp`).
    private func makeControlNCA(programID: UInt64, files: [(name: String, bytes: [UInt8])], rightsID: [UInt8]? = nil) -> [UInt8] {
        typealias F = ControlPackageFixture
        func fileEntry(sibling: UInt64, offset: UInt64, size: Int, name: String) -> [UInt8] {
            F.pad(
                F.le(0, 4)
                    + F.le(sibling, 4)
                    + F.le(offset, 8)
                    + F.le(UInt64(size), 8)
                    + F.le(0xFFFF_FFFF, 4)
                    + F.le(UInt64(name.utf8.count), 4)
                    + Array(name.utf8),
                4
            )
        }
        var dataOffset: UInt64 = 0
        var rawEntries: [(offset: UInt64, size: Int, name: String)] = []
        var filePayload: [UInt8] = []
        for item in files {
            rawEntries.append((dataOffset, item.bytes.count, item.name))
            filePayload += item.bytes
            dataOffset += UInt64(item.bytes.count)
        }
        var encodedEntries: [[UInt8]] = []
        for item in rawEntries {
            encodedEntries.append(fileEntry(sibling: 0, offset: item.offset, size: item.size, name: item.name))
        }
        var fileMeta: [UInt8] = []
        var cursor: UInt64 = 0
        for i in 0..<rawEntries.count {
            let sibling: UInt64 = (i + 1 < rawEntries.count) ? (cursor + UInt64(encodedEntries[i].count)) : 0xFFFF_FFFF
            let entry = fileEntry(sibling: sibling, offset: rawEntries[i].offset, size: rawEntries[i].size, name: rawEntries[i].name)
            fileMeta += entry
            cursor += UInt64(entry.count)
        }
        let dir = F.le(0, 4) + F.le(0xFFFF_FFFF, 4) + F.le(0xFFFF_FFFF, 4) + F.le(0, 4) + F.le(0xFFFF_FFFF, 4) + F.le(0, 4)
        let dirHash = 0x50
        let dirMeta = dirHash + 4
        let fileHash = dirMeta + dir.count
        let fileMetaOff = fileHash + 4
        let dataOff = (fileMetaOff + fileMeta.count + 0xF) & ~0xF
        var head = F.le(0x50, 8) + F.le(UInt64(dirHash), 8) + F.le(4, 8) + F.le(UInt64(dirMeta), 8) + F.le(UInt64(dir.count), 8)
        head += F.le(UInt64(fileHash), 8) + F.le(4, 8) + F.le(UInt64(fileMetaOff), 8) + F.le(UInt64(fileMeta.count), 8) + F.le(UInt64(dataOff), 8)
        let romfs = F.pad(head + F.le(0xFFFF_FFFF, 4) + dir + F.le(0xFFFF_FFFF, 4) + fileMeta, 0x10) + filePayload

        let section = F.pad([UInt8](repeating: 0, count: 0x200) + romfs, 0x200)
        var h = [UInt8](repeating: 0, count: 0xC00)
        h.replaceSubrange(0x200..<0x204, with: Array("NCA3".utf8))
        h[0x205] = 2
        h[0x220] = F.generation
        h.replaceSubrange(0x210..<0x218, with: F.le(programID, 8))
        h.replaceSubrange(0x240..<0x248, with: F.le(6, 4) + F.le(UInt64(6 + section.count / 0x200), 4))
        let key: [UInt8]
        if let rightsID {
            h.replaceSubrange(0x230..<0x240, with: rightsID)
            key = F.titleKey
        } else {
            let area = [UInt8](repeating: 0x11, count: 32) + F.titleKey.reversed() + [UInt8](repeating: 0x22, count: 16)
            h.replaceSubrange(0x300..<0x340, with: KeyCheck.ecb(area, key: F.keyAreaKey, encrypt: true)!)
            key = Array(F.titleKey.reversed())
        }
        let fs = 0x400
        let counter: [UInt8] = [1, 0, 0, 0, 2, 0, 0, 0]
        h[fs] = 2; h[fs + 2] = 0; h[fs + 3] = 3; h[fs + 4] = 3
        h.replaceSubrange((fs + 8)..<(fs + 12), with: Array("IVFC".utf8))
        h.replaceSubrange((fs + 0x18 + 5 * 0x18)..<(fs + 0x18 + 5 * 0x18 + 16), with: F.le(0x200, 8) + F.le(UInt64(section.count - 0x200), 8))
        h.replaceSubrange((fs + 0x140)..<(fs + 0x148), with: counter)
        var blocks: [UInt8] = []
        for i in 0..<UInt64(section.count / 16) {
            blocks += counter.reversed() + PackageControl.be((0xC00 >> 4) + i)
        }
        let body = zip(section, KeyCheck.ecb(blocks, key: key, encrypt: true)!).map { $0 ^ $1 }
        return KeyCheck.xts(h, key: F.headerKey, encrypt: true)! + body
    }

    private func centerRGB(of image: NSImage) throws -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let rep = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        let color = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        return (color.redComponent, color.greenComponent, color.blueComponent)
    }

    // MARK: - 1. ArtworkImages Cache Key & No Negative Cache

    func testArtworkImagesNeverNegativeCachesMissingFilesAndRefreshesOnSizeChange() throws {
        let url = temporary.appendingPathComponent("late.jpg")
        var clock = Date(timeIntervalSinceReferenceDate: 1_000)
        let images = ArtworkImages(now: { clock })

        // Missing file returns nil and must not be cached for 2s.
        XCTAssertNil(images.image(at: url, maxPixel: ArtworkImages.iconPixels))
        let fixedMTime = Date(timeIntervalSinceReferenceDate: 500)
        let smallData = try makeJPEGData(width: 120, height: 120, red: 0.9, green: 0.1, blue: 0.1)
        try smallData.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: fixedMTime], ofItemAtPath: url.path)

        // Immediately visible at the exact same clock timestamp (fails if stat==nil was negative-cached).
        let first = try XCTUnwrap(images.image(at: url, maxPixel: ArtworkImages.iconPixels))
        XCTAssertEqual(first.size, NSSize(width: 120, height: 120))

        // Replace with a different-sized file keeping the exact same mtime.
        let biggerData = try makeJPEGData(width: 320, height: 320, red: 0.1, green: 0.8, blue: 0.2)
        XCTAssertNotEqual(smallData.count, biggerData.count)
        try biggerData.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: fixedMTime], ofItemAtPath: url.path)

        clock.addTimeInterval(ArtworkImages.recheckInterval + 0.1)
        let second = try XCTUnwrap(images.image(at: url, maxPixel: ArtworkImages.iconPixels))
        XCTAssertFalse(second === first, "cache key must include file size so same-mtime replacements refresh")
        XCTAssertEqual(second.size, NSSize(width: ArtworkImages.iconPixels, height: ArtworkImages.iconPixels))
    }

    func testArtworkImagesSquareCropAndStandardTiersDoNotCollideWithLandscapeCache() async throws {
        XCTAssertEqual(ArtworkImages.iconPixels, 192)
        XCTAssertEqual(ArtworkImages.listThumbPixels, 224)
        XCTAssertEqual(ArtworkImages.cardPixels, 640)

        let banner = try writeJPEG("banner.jpg", width: 1280, height: 720, red: 0.2, green: 0.4, blue: 0.9)
        let images = ArtworkImages()
        let wideLoaded = await images.loadImage(at: banner, maxPixel: ArtworkImages.iconPixels, squareCrop: false)
        let squareLoaded = await images.loadImage(at: banner, maxPixel: ArtworkImages.iconPixels, squareCrop: true)
        let wide = try XCTUnwrap(wideLoaded)
        let square = try XCTUnwrap(squareLoaded)
        XCTAssertGreaterThan(wide.size.width, wide.size.height)
        XCTAssertEqual(square.size, NSSize(width: ArtworkImages.iconPixels, height: ArtworkImages.iconPixels))
    }

    // MARK: - 2. Offline NACP Icon Extraction & Icon Fallback Chain

    func testOfflineControlIconExtractionPrefersLanguageFallsBackAndProtectsOnlineIcon() async throws {
        let zhJPEG = try makeJPEGData(width: 256, height: 256, red: 0.95, green: 0.1, blue: 0.1)   // red = zh
        let enJPEG = try makeJPEGData(width: 256, height: 256, red: 0.1, green: 0.2, blue: 0.95)   // blue = en
        let nca = makeControlNCA(programID: titleIDU64, files: [
            ("icon_AmericanEnglish.dat", [UInt8](enJPEG)),
            ("icon_SimplifiedChinese.dat", [UInt8](zhJPEG)),
            ("control.nacp", ControlPackageFixture.nacp([0: "Sample", 14: "样例"])),
        ])
        let xciURL = temporary.appendingPathComponent("Game.xci")
        try Data(ControlPackageFixture.xci([("ctrl.nca", nca)])).write(to: xciURL)
        let keysURL = temporary.appendingPathComponent("prod.keys")
        try Data(ControlPackageFixture.keysFile().utf8).write(to: keysURL)

        let artworkDir = temporary.appendingPathComponent("artwork")
        let extracted = try XCTUnwrap(PackageControl.extractControlIcon(
            from: xciURL.path,
            keysFile: keysURL.path,
            titleID: titleID,
            preferredLanguage: "zh",
            artworkDirectory: artworkDir
        ))
        XCTAssertEqual(extracted.lastPathComponent, "nacp-icon.jpg")
        let zhImage = try XCTUnwrap(ArtworkImages.shared.image(at: extracted, maxPixel: ArtworkImages.iconPixels))
        let zhColor = try centerRGB(of: zhImage)
        XCTAssertGreaterThan(zhColor.r, 0.7, "zh language must pick icon_SimplifiedChinese.dat")
        XCTAssertLessThan(zhColor.b, 0.3)

        // Language without exact icon falls back to first valid icon_*.dat instead of nil.
        let fallbackDir = temporary.appendingPathComponent("artwork-fallback")
        let fallbackURL = try XCTUnwrap(PackageControl.extractControlIcon(
            from: xciURL.path,
            keys: ControlPackageFixture.keys,
            titleID: titleID,
            preferredLanguage: "ko",
            artworkDirectory: fallbackDir
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fallbackURL.path))

        // Corrupt / non-JPEG icon bytes are rejected and never written to disk.
        let badNCA = makeControlNCA(programID: titleIDU64, files: [
            ("icon_AmericanEnglish.dat", [UInt8](repeating: 0xEE, count: 64)),
            ("control.nacp", ControlPackageFixture.nacp([0: "BadIcon"])),
        ])
        let badXCI = temporary.appendingPathComponent("BadIcon.xci")
        try Data(ControlPackageFixture.xci([("ctrl.nca", badNCA)])).write(to: badXCI)
        let badDir = temporary.appendingPathComponent("artwork-bad")
        XCTAssertNil(PackageControl.extractControlIcon(from: badXCI.path, keys: ControlPackageFixture.keys, titleID: titleID, artworkDirectory: badDir))
        XCTAssertNil(BannerCache.cachedNacpIcon(titleID, in: badDir))

        // Unbuilt game (empty appPath, no online icon.jpg) resolves icon offline through GameLibrary.loadAppIcon.
        let unbuiltDir = temporary.appendingPathComponent("artwork-unbuilt")
        var unbuilt = LibraryGame(titleID: titleID, name: "Unbuilt")
        unbuilt.inputs = ["base": [xciURL.path]]
        let loadedOfflineIcon = await GameLibrary.loadAppIcon(
            for: unbuilt,
            banners: unbuiltDir,
            language: "zh",
            fallbackKeys: keysURL.path
        )
        let offlineIcon = try XCTUnwrap(loadedOfflineIcon)
        XCTAssertEqual(offlineIcon.size, NSSize(width: ArtworkImages.iconPixels, height: ArtworkImages.iconPixels))
        XCTAssertNotNil(BannerCache.cachedNacpIcon(titleID, in: unbuiltDir))

        // Online icon.jpg takes precedence over nacp-icon.jpg and is never overwritten.
        let onlineFile = try XCTUnwrap(BannerCache.iconFile(titleID, in: unbuiltDir))
        try makeJPEGData(width: 200, height: 200, red: 0.1, green: 0.9, blue: 0.1).write(to: onlineFile)
        let preferred = try XCTUnwrap(GameLibrary.appIcon(for: unbuilt, banners: unbuiltDir))
        let green = try centerRGB(of: preferred)
        XCTAssertGreaterThan(green.g, 0.7)

        // Banner fallback: when no dedicated icon exists, GameLibrary.appIcon center-crops the landscape banner to a square.
        let bannerOnlyDir = temporary.appendingPathComponent("artwork-banner-only")
        try FileManager.default.createDirectory(at: bannerOnlyDir, withIntermediateDirectories: true)
        try makeJPEGData(width: 1280, height: 720, red: 0.4, green: 0.6, blue: 0.2)
            .write(to: bannerOnlyDir.appendingPathComponent(titleID + ".jpg"))
        let bannerOnlyGame = LibraryGame(titleID: titleID, name: "BannerOnly")
        let cropped = try XCTUnwrap(GameLibrary.appIcon(for: bannerOnlyGame, banners: bannerOnlyDir))
        XCTAssertEqual(cropped.size, NSSize(width: ArtworkImages.iconPixels, height: ArtworkImages.iconPixels))
    }

    // MARK: - 3. ArtworkStore Cross-Language Query, Failure Cooldown & Normalized Language Generation

    func testArtworkStoreCrossLanguageMediaIsNotLockedByEnglishEmptyShell() async throws {
        let zhIcon = try writeJPEG("zh-icon.jpg", width: 256, height: 256, red: 0.9, green: 0.2, blue: 0.2)
        let zhShot = try writeJPEG("zh-shot.jpg", width: 1280, height: 720, red: 0.2, green: 0.7, blue: 0.3)
        let usList = temporary.appendingPathComponent("US.en.json")
        let zhList = temporary.appendingPathComponent("HK.zh.json")
        // US list lacks `titleID`; HK.zh list has it with iconUrl and screenshot.
        try Data("{\"1\": {\"id\": \"0100000000000999\", \"name\": \"Other\", \"screenshots\": []}}".utf8).write(to: usList)
        try Data("""
        {"1": {"id": "\(titleID)", "name": "中文标题", "iconUrl": "\(zhIcon.absoluteString)", "screenshots": ["\(zhShot.absoluteString)"]}}
        """.utf8).write(to: zhList)

        let artDir = temporary.appendingPathComponent("art-lang")
        let store = ArtworkStore(directory: artDir, titleList: usList, allowsFileURLs: true, regional: ["zh": zhList])

        let enMedia = await store.media(for: titleID, language: "en")
        XCTAssertEqual(enMedia, .none)
        let enIcon = await store.fetchIcon(titleID, language: "en")
        XCTAssertNil(enIcon)

        // Switching to zh must re-query HK.zh.json rather than returning the English empty shell.
        let zhMedia = await store.media(for: titleID, language: "zh")
        guard case .loaded(let media) = zhMedia else {
            return XCTFail("expected zh media to load after English miss, got \(zhMedia)")
        }
        XCTAssertEqual(media.screenshots, [zhShot.absoluteString])
        XCTAssertEqual(media.iconURL, zhIcon.absoluteString)

        let fetchedIcon = await store.fetchIcon(titleID, language: "zh")
        XCTAssertEqual(fetchedIcon?.lastPathComponent, "icon.jpg")
    }

    func testArtworkStoreListFailureRecoversAfterCooldown() async throws {
        let icon = try writeJPEG("recover-icon.jpg", width: 128, height: 128, red: 0.3, green: 0.8, blue: 0.4)
        let listURL = temporary.appendingPathComponent("US.en.json")
        var clock = Date(timeIntervalSinceReferenceDate: 2_000)
        let artDir = temporary.appendingPathComponent("art-cooldown")
        let store = ArtworkStore(
            directory: artDir,
            titleList: listURL,
            allowsFileURLs: true,
            regional: [:],
            now: { clock },
            retryCooldown: 30
        )

        // List missing -> failure recorded.
        let firstAttempt = await store.fetchIcon(titleID, language: "en")
        XCTAssertNil(firstAttempt)

        // Network/list recovers. Within cooldown still skipped, after cooldown succeeds automatically.
        try Data("""
        {"1": {"id": "\(titleID)", "name": "Recovered", "iconUrl": "\(icon.absoluteString)", "screenshots": []}}
        """.utf8).write(to: listURL)
        clock.addTimeInterval(10)
        let cooldownAttempt = await store.fetchIcon(titleID, language: "en")
        XCTAssertNil(cooldownAttempt)

        clock.addTimeInterval(25)
        let recovered = await store.fetchIcon(titleID, language: "en")
        XCTAssertEqual(recovered?.lastPathComponent, "icon.jpg")
    }

    func testArtworkStoreEquivalentLanguageCodesDoNotCancelConcurrentFetch() async throws {
        let cleanBanner = try writeJPEG("clean-en.jpg", width: 800, height: 450, red: 0.5, green: 0.5, blue: 0.9)
        let usList = temporary.appendingPathComponent("US.en.json")
        try Data("{}".utf8).write(to: usList)
        let artDir = temporary.appendingPathComponent("art-concurrent")

        actor Gate {
            private var started = false
            private var released = false
            private var startWaiter: CheckedContinuation<Void, Never>?
            private var releaseWaiter: CheckedContinuation<Void, Never>?

            func enterAndWait() async {
                started = true
                startWaiter?.resume()
                startWaiter = nil
                if !released {
                    await withCheckedContinuation { releaseWaiter = $0 }
                }
            }

            func waitStarted() async {
                if !started {
                    await withCheckedContinuation { startWaiter = $0 }
                }
            }

            func release() {
                released = true
                releaseWaiter?.resume()
                releaseWaiter = nil
            }
        }

        let gate = Gate()
        let link = cleanBanner.absoluteString
        let targetID = titleID
        let otherID = "0100000000000888"
        let store = ArtworkStore(directory: artDir, titleList: usList, allowsFileURLs: true, regional: [:]) { _, ids in
            guard ids.contains(targetID) else { return [:] }
            await gate.enterAndWait()
            return [targetID: link]
        }

        async let firstFetch = store.fetchMissing([targetID], language: "en")
        await gate.waitStarted()
        // Equivalent language codes (`en-US`, `sv`) resolve to the exact same sources and must not bump generation.
        _ = await store.fetchMissing([otherID], language: "en-US")
        _ = await store.fetchMissing([otherID], language: "sv")
        await gate.release()

        let added = await firstFetch
        XCTAssertEqual(added, [targetID], "equivalent normalized language codes must not cancel an in-flight fetch")
    }

    // MARK: - 4. SupportedCovers Cooldown Recovery & 224px List Thumbnail

    @MainActor func testSupportedCoversRecoversAfterCooldownAndExplicitRetry() async throws {
        let folder = temporary.appendingPathComponent("supported-recover")
        var clock = Date(timeIntervalSinceReferenceDate: 5_000)
        let tried = SupportedCovers.Tried(retryInterval: 60, now: { clock })
        let bannerData = try makeJPEGData(width: 1280, height: 720, red: 0.2, green: 0.7, blue: 0.9)

        final class State: @unchecked Sendable {
            var online = false
            var attempts = 0
        }
        let state = State()
        let fetch: SupportedCovers.Fetch = { ids, _ in
            state.attempts += 1
            guard state.online else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for id in ids {
                try? bannerData.write(to: folder.appendingPathComponent(id + ".jpg"))
            }
        }

        let covers = SupportedCovers(directory: folder, language: "en", maxPixel: SupportedCovers.listThumbnailPixels, tried: tried, fetch: fetch)
        covers.appear(titleID)
        await covers.idle()
        XCTAssertNil(covers.image(titleID))
        XCTAssertEqual(state.attempts, 1)

        // Comes back online; after cooldown a reopened list retries and loads the cover.
        state.online = true
        clock.addTimeInterval(65)
        let reopened = SupportedCovers(directory: folder, language: "en", maxPixel: SupportedCovers.listThumbnailPixels, tried: tried, fetch: fetch)
        reopened.appear(titleID)
        await reopened.idle()
        XCTAssertEqual(state.attempts, 2)
        let loaded = try XCTUnwrap(reopened.image(titleID))
        XCTAssertLessThanOrEqual(loaded.representations.first?.pixelsWide ?? .max, SupportedCovers.listThumbnailPixels)

        // Reusable async 224px thumbnail helper also decodes cleanly.
        let loadedThumb = await SupportedCovers.loadListThumbnail(for: titleID, in: folder)
        let thumb = try XCTUnwrap(loadedThumb)
        XCTAssertLessThanOrEqual(thumb.representations.first?.pixelsWide ?? .max, SupportedCovers.listThumbnailPixels)
    }

    // MARK: - 5. LiveConsoleDriver Never Caches Nil Covers

    @MainActor func testLiveConsoleDriverDoesNotCacheNilCoversWhenArtworkLandsLater() throws {
        let libFile = temporary.appendingPathComponent("library.json")
        let artDir = temporary.appendingPathComponent("artwork")
        try FileManager.default.createDirectory(at: artDir, withIntermediateDirectories: true)
        let library = GameLibrary(file: libFile, artwork: artDir)
        let game = LibraryGame(titleID: titleID, name: "LateCover")
        library.games = [game]

        let driver = LiveConsoleDriver(
            launchGracePeriod: 0,
            library: library,
            controls: ControlLayout(defaults: testDefaults),
            repo: { "" },
            lang: { .en },
            labels: { L10n.string($0, .en) },
            observeSystem: false
        )
        XCTAssertNil(driver.state.games.first?.artwork)

        // Write the banner onto disk after the first refresh and refresh again.
        try makeJPEGData(width: 1280, height: 720, red: 0.8, green: 0.5, blue: 0.1)
            .write(to: artDir.appendingPathComponent(titleID + ".jpg"))
        driver.refresh()
        XCTAssertNotNil(driver.state.games.first?.artwork, "LiveConsoleDriver must not cache nil covers once artwork appears on disk")
    }
}
