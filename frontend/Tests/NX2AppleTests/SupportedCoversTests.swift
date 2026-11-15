import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher
import NXModel

/// The covers of the Supported games list (SupportedCovers): the library's own files in the library's order of sources, fetched only
/// for the rows on screen, a few at a time, and never twice in a session. Images are served from disk, no network.
@MainActor final class SupportedCoversTests: IsolatedDefaultsTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nx-supported-covers-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temporary) }

    private static func jpeg(_ color: NSColor, _ label: String, size: NSSize = NSSize(width: 640, height: 360)) -> Data {
        let picture = NSImage(size: size, flipped: false) { rect in
            color.setFill(); rect.fill()
            let style = NSMutableParagraphStyle(); style.alignment = .center
            (label as NSString).draw(in: rect.insetBy(dx: 24, dy: size.height * 0.36), withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: size.height / 9), .foregroundColor: NSColor.white, .paragraphStyle: style])
            return true
        }
        return NSBitmapImageRep(data: picture.tiffRepresentation!)!.representation(using: .jpeg, properties: [:])!
    }

    private func write(_ color: NSColor, _ label: String, to name: String) throws -> URL {
        let url = temporary.appendingPathComponent("cdn/" + name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.jpeg(color, label).write(to: url)
        return url
    }

    private func bytes(_ url: URL?) -> Data? { url.flatMap { try? Data(contentsOf: $0) } }

    /// What the fake transport saw: the batches in order, and how many ran at once.
    private actor Calls {
        var batches: [[String]] = []
        var active = 0
        var most = 0
        func begin(_ ids: [String]) { batches.append(ids); active += 1; most = max(most, active) }
        func end() { active -= 1 }
    }

    /// A fake transport: it saves a cover for the title IDs in `has`, after a short wait, and nothing for the others (offline, not found).
    private func fakeFetch(_ calls: Calls, into directory: URL, has: Set<String>) -> SupportedCovers.Fetch {
        let image = Self.jpeg(.systemTeal, "cover", size: NSSize(width: 1920, height: 1080))
        return { ids, _ in
            await calls.begin(ids)
            try? await Task.sleep(nanoseconds: 20_000_000)
            for id in ids where has.contains(id) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? image.write(to: directory.appendingPathComponent(id + ".jpg"))
            }
            await calls.end()
        }
    }

    /// The order the library uses for an owned game: Nintendo of Europe's clean key art first, then the title list's banner, then
    /// the SteamGridDB override for a title the list lacks. The list's banner wins over an override. The files land where the
    /// library reads them, and the row's image is decoded at the slot's size.
    func testCoversComeFromTheLibrarysSourcesInItsOrder() async throws {
        let clean = try write(.systemGreen, "clean key art", to: "clean.jpg")
        let listed = try write(.systemOrange, "title list banner", to: "listed.jpg")
        let listedToo = try write(.systemPink, "title list banner (clean art exists)", to: "listed-too.jpg")
        let override = try write(.systemIndigo, "SteamGridDB override", to: "override.jpg")
        let unused = try write(.systemRed, "override the list beats", to: "unused.jpg")
        let (a, b, c, d) = ("0100000000000A00", "0100000000000B00", "0400000000000C00", "0100000000000D00")
        let list = temporary.appendingPathComponent("US.en.json")
        try """
        {"1": {"id": "\(a)", "name": "Game A", "nsuId": 1, "bannerUrl": "\(listedToo.absoluteString)"},
         "2": {"id": "\(b)", "name": "Game B", "nsuId": 2, "bannerUrl": "\(listed.absoluteString)"}}
        """.write(to: list, atomically: true, encoding: .utf8)
        let folder = temporary.appendingPathComponent("artwork")
        let cleanLink = clean.absoluteString
        let store = ArtworkStore(directory: folder, titleList: list, fallbacks: [b: unused.absoluteString, c: override.absoluteString],
                                 catalogue: { _, ids in ids.contains(a) ? [a: cleanLink] : [:] })
        let covers = SupportedCovers.live(store: store, directory: folder, language: "en", maxPixel: SupportedGamesSheet.coverPixels)
        for id in [a, b, c, d] { covers.appear(id) }
        await covers.idle()

        XCTAssertEqual(bytes(ArtworkStore.cachedBanner(a, in: folder)), bytes(clean), "clean key art first")
        XCTAssertEqual(bytes(ArtworkStore.cachedBanner(b, in: folder)), bytes(listed), "then the title list, ahead of an override")
        XCTAssertEqual(bytes(ArtworkStore.cachedBanner(c, in: folder)), bytes(override), "the override where the list has nothing")
        XCTAssertNil(ArtworkStore.cachedBanner(d, in: folder), "no source: no file")
        for id in [a, b, c] {
            let image = try XCTUnwrap(covers.image(id), id)
            XCTAssertLessThanOrEqual(image.representations.first?.pixelsWide ?? .max, SupportedGamesSheet.coverPixels, "decoded at the slot's size")
        }
        XCTAssertNil(covers.image(d), "the placeholder stays")
        let game = LibraryGame(titleID: a, name: "Game A")
        XCTAssertEqual(GameLibrary.artworkURLs(for: game, repo: temporary.path, banners: folder).first, ArtworkStore.cachedBanner(a, in: folder),
                       "the library shows the same file")
    }

    /// A fetch that waits is not turned away while another one runs: it runs after it.
    func testAWaitingFetchRunsAfterTheOneRunning() async throws {
        let first = try write(.systemTeal, "first", to: "first.jpg"), second = try write(.systemPink, "second", to: "second.jpg")
        let list = temporary.appendingPathComponent("US.en.json")
        try """
        {"1": {"id": "0100000000000100", "name": "One", "nsuId": 1, "bannerUrl": "\(first.absoluteString)"},
         "2": {"id": "0100000000000200", "name": "Two", "nsuId": 2, "bannerUrl": "\(second.absoluteString)"}}
        """.write(to: list, atomically: true, encoding: .utf8)
        let folder = temporary.appendingPathComponent("artwork")
        let store = ArtworkStore(directory: folder, titleList: list, fallbacks: [:])
        async let library = store.fetchMissing(["0100000000000100"])
        async let sheet = store.fetchMissing(["0100000000000200"], waits: true)
        let (_, two) = await (library, sheet)
        XCTAssertEqual(two, ["0100000000000200"], "the waiting call got its banner")
        XCTAssertNotNil(ArtworkStore.cachedBanner("0100000000000200", in: folder))
    }

    /// Only rows on screen ask, in batches, one fetch at a time. A row that leaves before its turn is not fetched, nor anything after
    /// the list closes. A saved cover shows without a fetch.
    func testTheLoaderFetchesOnlyVisibleRowsAFewAtATime() async throws {
        let folder = temporary.appendingPathComponent("artwork")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.jpeg(.systemBlue, "saved").write(to: folder.appendingPathComponent("0100000000000099.jpg"))
        let calls = Calls()
        let ids = (1...7).map { String(format: "01000000000000%02d", $0) }
        let covers = SupportedCovers(directory: folder, language: "de", maxPixel: 128, batch: 2, tried: SupportedCovers.Tried(),
                                     fetch: fakeFetch(calls, into: folder, has: Set(ids)))

        covers.appear("0100000000000099")
        XCTAssertNotNil(covers.image("0100000000000099"), "a saved cover at once")
        for id in ids.prefix(5) { covers.appear(id) }
        covers.disappear(ids[4])   // scrolled away before its turn
        await covers.idle()
        let batches = await calls.batches, most = await calls.most
        XCTAssertEqual(batches, [[ids[0], ids[1]], [ids[2], ids[3]]])
        XCTAssertEqual(most, 1, "one fetch at a time")
        for id in ids.prefix(4) { XCTAssertNotNil(covers.image(id), id) }
        XCTAssertNil(covers.image(ids[4]))

        covers.appear(ids[5]); covers.appear(ids[6])
        covers.stop()   // the list closed before the worker ran
        await covers.idle()
        let after = await calls.batches
        XCTAssertEqual(after.count, 2, "nothing fetched after the list closed")
    }

    /// A title whose fetch found nothing (offline, no image) is not asked again in the session, not even by a list opened again.
    func testAFailedFetchIsNotRetriedInTheSession() async throws {
        let folder = temporary.appendingPathComponent("artwork")
        let calls = Calls(), tried = SupportedCovers.Tried()
        let id = "0100000000000001"
        let covers = SupportedCovers(directory: folder, language: "en", maxPixel: 128, tried: tried, fetch: fakeFetch(calls, into: folder, has: []))
        covers.appear(id)
        await covers.idle()
        covers.disappear(id); covers.appear(id)
        await covers.idle()
        let reopened = SupportedCovers(directory: folder, language: "en", maxPixel: 128, tried: tried, fetch: fakeFetch(calls, into: folder, has: []))
        reopened.appear(id)
        await reopened.idle()
        let batches = await calls.batches
        XCTAssertEqual(batches, [[id]])
        XCTAssertNil(covers.image(id))
        XCTAssertNil(reopened.image(id))
    }

    func testStopWhileInFlightFetchWritesFilesDoesNotPublishStaleGenerationImages() async throws {
        let folder = temporary.appendingPathComponent("artwork-race")
        let id = "0100000000000077"
        let imageData = Self.jpeg(.systemGreen, "late-cover", size: NSSize(width: 640, height: 360))

        actor Gate {
            private var startedContinuation: CheckedContinuation<Void, Never>?
            private var releaseContinuation: CheckedContinuation<Void, Never>?
            private var started = false
            private var released = false

            func enterAndWait() async {
                started = true
                startedContinuation?.resume()
                startedContinuation = nil
                if !released {
                    await withCheckedContinuation { releaseContinuation = $0 }
                }
            }

            func waitUntilStarted() async {
                if !started {
                    await withCheckedContinuation { startedContinuation = $0 }
                }
            }

            func release() {
                released = true
                releaseContinuation?.resume()
                releaseContinuation = nil
            }
        }

        let gate = Gate()
        let covers = SupportedCovers(directory: folder, language: "en", maxPixel: 128, batch: 2, tried: SupportedCovers.Tried()) { ids, _ in
            await gate.enterAndWait()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for item in ids {
                try? imageData.write(to: folder.appendingPathComponent(item + ".jpg"))
            }
        }

        covers.appear(id)
        await gate.waitUntilStarted()
        covers.stop()
        await gate.release()
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(id + ".jpg").path))
        XCTAssertNil(covers.image(id), "an in-flight fetch from a stopped generation must never write decoded images back into covers")
    }

    // MARK: Visual QA (NX_LAUNCHER_CAPTURE_DIR=<dir> swift test --filter SupportedCoversTests/testRenderSupportedGamesCovers)

    /// The sheet and the console page before (no cover saved: the placeholder in every row) and after (a fake source saves each
    /// row's cover as it comes on screen).
    /// Synchronous, so the run loop below also runs the main actor's work (the loader's results).
    func testRenderSupportedGamesCovers() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        let colors: [NSColor] = [.systemRed, .systemOrange, .systemGreen, .systemTeal, .systemBlue, .systemIndigo, .systemPurple, .systemPink, .systemBrown]
        let names = ["Super Mario Odyssey", "The Legend of Zelda: Breath of the Wild", "Mario Kart 8 Deluxe", "Splatoon 3", "Hades",
                     "Celeste", "Hollow Knight", "Kirby and the Forgotten Land", "Donkey Kong Bananza", "Metroid Dread", "Pikmin 4", "Stardew Valley"]
        let games = names.enumerated().map { i, name in
            SupportedGame(titleID: String(format: "0100%012X", 0xA000 + i), name: name, edition: i == 8 ? .switch2 : .switch1,
                          version: i == 5 ? nil : "1.\(i).0", notes: "Plays to the end.")
        }
        let source = temporary.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for (i, game) in games.enumerated() {
            try Self.jpeg(colors[i % colors.count], game.name, size: NSSize(width: 1920, height: 1080)).write(to: source.appendingPathComponent(game.titleID + ".jpg"))
        }
        // The mock console's demo profiles carry its own title IDs
        for i in 0..<6 {
            try Self.jpeg(colors[i % colors.count], "Demo \(i + 1)", size: NSSize(width: 1920, height: 1080))
                .write(to: source.appendingPathComponent(String(format: "0100DEMO%08X", i) + ".jpg"))
        }
        func fake(_ folder: URL) -> SupportedCovers.Fetch {
            { ids, _ in
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for id in ids { try? FileManager.default.copyItem(at: source.appendingPathComponent(id + ".jpg"), to: folder.appendingPathComponent(id + ".jpg")) }
            }
        }
        let localizer = Localizer(.en)

        func shot<V: View>(_ name: String, _ view: V, size: NSSize, then: () -> Void = {}) throws {
            let root = view.environmentObject(PadFocus()).environmentObject(localizer).frame(width: size.width, height: size.height)
                .background(LauncherPalette.background)
            let host = NSHostingView(rootView: root)
            let window = OffscreenWindow(size: size, styleMask: [.titled, .closable, .fullSizeContentView])
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            then()
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
        }

        let none = temporary.appendingPathComponent("none")
        try shot("supported-covers-sheet-before", SupportedGamesSheet(games: games, owned: { _ in nil },
                 covers: .saved(in: none, maxPixel: SupportedGamesSheet.coverPixels), showInLibrary: { _ in }), size: NSSize(width: 680, height: 720))
        let sheetFolder = temporary.appendingPathComponent("sheet")
        try shot("supported-covers-sheet-after", SupportedGamesSheet(games: games, owned: { _ in nil },
                 covers: SupportedCovers(directory: sheetFolder, language: "en", maxPixel: SupportedGamesSheet.coverPixels, tried: .init(), fetch: fake(sheetFolder)),
                 showInLibrary: { _ in }), size: NSSize(width: 680, height: 720))

        for (name, folder, fetches) in [("before", none, false), ("after", temporary.appendingPathComponent("console"), true)] {
            let driver = MockConsoleDriver(scenario: .full, animated: false)
            driver.supportedCoverSource = { pixels in
                fetches ? SupportedCovers(directory: folder, language: "en", maxPixel: pixels, tried: .init(), fetch: fake(folder)) : .saved(in: folder, maxPixel: pixels)
            }
            driver.openSupportedGames()
            let pad = PadFocus()
            let first = driver.state.supportedGames.first?.titleID ?? ""
            // the first row focused: the page scrolls it to the middle, so several rows are on screen
            try shot("supported-covers-console-\(name)", ConsoleView(driver: driver, lang: Lang("en"), padFocus: pad), size: NSSize(width: 1280, height: 800)) {
                pad.focused = "console.supported.row." + first
            }
        }
    }
}
