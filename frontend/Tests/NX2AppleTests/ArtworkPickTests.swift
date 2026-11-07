import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
import NXModel
import NXLauncher

/// The library's cover pick (LNPANDY/NX2Apple#403): blawar/titledb lists several shop products under one title ID, the game
/// and its Switch 2 Edition or a bundle, and the game's own banner must win. The lists here copy the shape and the names of
/// the real US list (2026-11-04), with placeholder images served from disk.
@MainActor final class ArtworkPickTests: IsolatedDefaultsTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-artwork-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temporary) }

    private func product(_ id: String, _ name: String, _ nsuId: Int64, demo: Bool = false, banner: String? = nil) -> BannerPick.Product {
        BannerPick.Product(id: id, name: name, nsuId: nsuId, isDemo: demo, bannerUrl: banner ?? "https://img-eshop.cdn.nintendo.net/i/\(nsuId).jpg")
    }

    /// The pairs from the issue and the other kinds the real list holds: the game's product wins in either order.
    func testTheGameWinsOverItsEditionsBundlesAndPasses() {
        let cases: [(game: BannerPick.Product, other: BannerPick.Product)] = [
            (product("0100C2500FC20000", "Splatoon™ 3", 70010000046395),
             product("0100C2500FC20000", "Splatoon™ 3 + Nintendo Switch Online Individual Membership (3 Months)", 70010000066990)),
            (product("010015100B514000", "Super Mario Bros.™ Wonder", 70010000068688),
             product("010015100B514000", "Super Mario Bros.™ Wonder – Nintendo Switch™ 2 Edition + Meetup in Bellabel Park", 70010000115567)),
            (product("01004D300C5AE000", "Kirby™ and the Forgotten Land", 70010000046405),
             product("01004D300C5AE000", "Kirby™ and the Forgotten Land – Nintendo Switch™ 2 Edition + Star-Crossed World", 70010000096829)),
            (product("0100F2C0115B6000", "The Legend of Zelda™: Tears of the Kingdom", 70010000063714),
             product("0100F2C0115B6000", "The Legend of Zelda™: Tears of the Kingdom – Nintendo Switch™ 2 Edition", 70010000096821)),
            (product("0100633007D48000", "Hollow Knight", 70010000003208),
             product("0100633007D48000", "Hollow Knight – Nintendo Switch 2 Edition", 70010000117998)),
            // The game's own name says Definitive Edition: both products carry "edition", the Switch 2 one more
            (product("010027400CDC6000", "Divinity: Original Sin 2 - Definitive Edition", 70010000015971),
             product("010027400CDC6000", "Divinity: Original Sin 2 - Nintendo Switch™ 2 Edition", 70010000114263)),
            // The bundle came to the shop first here: the lowest nsuId alone would pick it
            (product("0100D680194B2000", "Pikmin™ 2", 70010000068673), product("0100D680194B2000", "Pikmin™ 1+2", 70010000059262)),
            (product("01008DB008C2C000", "Pokémon™ Shield", 70010000004492),
             product("01008DB008C2C000", "Pokémon Shield + Pokémon Shield Expansion Pass", 70010000035969)),
            (product("0100A2F00EEFC000", "Disney Classic Games: Aladdin and The Lion King", 70010000022309),
             product("0100A2F00EEFC000", "Disney Classic Games Collection", 70010000047661)),
            (product("0100E1E00CF1A000", "Power Rangers: Battle for the Grid", 70010000016742),
             product("0100E1E00CF1A000", "Power Rangers: Battle for the Grid - Retail Version", 70010000030832)),
            (product("0100ABC000000000", "A Game", 70010000099999), product("0100ABC000000000", "A Game", 70010000000001, demo: true)),
        ]
        for (game, other) in cases {
            XCTAssertEqual(BannerPick.pick([game, other]), game, game.name ?? "")
            XCTAssertEqual(BannerPick.pick([other, game]), game, game.name ?? "")
        }
    }

    /// Two products with the same marks: the data cannot tell them apart, so the one that came to the shop first wins, in any order.
    func testATieKeepsTheFirstProductInTheShop() {
        let first = product("01000B900D8B0000", "Cadence of Hyrule: Crypt of the NecroDancer Featuring The Legend of Zelda", 70010000021364)
        let retail = product("01000B900D8B0000", "Cadence of Hyrule: Crypt of the NecroDancer featuring The Legend of Zelda", 70010000036004)
        XCTAssertEqual(BannerPick.pick([first, retail]), first)
        XCTAssertEqual(BannerPick.pick([retail, first]), first)
        XCTAssertNil(BannerPick.pick([product("0100000000000000", "No banner", 1, banner: "")]))
        let index = BannerPick.banners([first, retail, product("0100633007D48000", "Hollow Knight", 70010000003208)])
        XCTAssertEqual(index.banners["01000B900D8B0000"], first.bannerUrl)
        XCTAssertEqual(index.several, ["01000B900D8B0000"])
    }

    // MARK: The store, with the list and the images on disk

    private func image(_ color: NSColor, _ label: String, to url: URL) throws {
        let picture = NSImage(size: NSSize(width: 640, height: 360), flipped: false) { rect in
            color.setFill(); rect.fill()
            let style = NSMutableParagraphStyle(); style.alignment = .center
            (label as NSString).draw(in: rect.insetBy(dx: 24, dy: 130), withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 34), .foregroundColor: NSColor.white, .paragraphStyle: style])
            return true
        }
        let tiff = try XCTUnwrap(picture.tiffRepresentation)
        try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [:])).write(to: url)
    }

    private struct Fixture {
        let list: URL, folder: URL
        let splatoon: URL, bundle: URL, wonder: URL, edition: URL, bananza: URL
    }

    /// A list shaped like the real one (keyed by nsuId, each product a full entry) with the issue's two pairs, a Switch 2 game
    /// it knows (Donkey Kong Bananza) and none for Splatoon Raiders, as in the US, GB, DE, FR and JP lists.
    private func fixture() throws -> Fixture {
        let cdn = temporary.appendingPathComponent("cdn")
        try FileManager.default.createDirectory(at: cdn, withIntermediateDirectories: true)
        let urls = ["splatoon", "bundle", "wonder", "edition", "bananza"].map { cdn.appendingPathComponent($0 + ".jpg") }
        try image(.systemTeal, "Splatoon 3\n(the game)", to: urls[0])
        try image(.systemPink, "Splatoon 3 + membership\n(a bundle)", to: urls[1])
        try image(.systemGreen, "Super Mario Bros. Wonder\n(the game)", to: urls[2])
        try image(.systemRed, "Wonder Switch 2 Edition\n(another product)", to: urls[3])
        try image(.systemOrange, "Donkey Kong Bananza\n(Switch 2 game)", to: urls[4])
        func entry(_ nsu: String, _ id: String, _ name: String, _ banner: URL, demo: Bool = false, nsuAsText: Bool = false) -> String {
            """
            "\(nsu)": {"id": "\(id)", "name": "\(name)", "nsuId": \(nsuAsText ? "\"\(nsu)\"" : nsu), "isDemo": \(demo), "bannerUrl": "\(banner.absoluteString)",
                       "category": ["Action"], "size": 1, "ids": null, "rightsId": null}
            """
        }
        let list = temporary.appendingPathComponent("US.en.json")
        try Data(("{" + [
            entry("70010000066990", "0100C2500FC20000", "Splatoon™ 3 + Nintendo Switch Online Individual Membership (3 Months)", urls[1]),
            entry("70010000046395", "0100C2500FC20000", "Splatoon™ 3", urls[0]),
            entry("70010000115567", "010015100B514000", "Super Mario Bros.™ Wonder – Nintendo Switch™ 2 Edition + Meetup in Bellabel Park", urls[3]),
            entry("70010000068688", "010015100B514000", "Super Mario Bros.™ Wonder", urls[2], nsuAsText: true),
            entry("70010000096809", "040074a01bf12000", "Donkey Kong™ Bananza", urls[4]),
            entry("70010000000001", "0100C2500FC20000", "Splatoon™ 3 Demo", urls[1], demo: true),   // first in the shop, but a demo
            #""1": {"id": null, "bannerUrl": null}"#,
        ].joined(separator: ",\n") + "}").utf8).write(to: list)
        return Fixture(list: list, folder: temporary.appendingPathComponent("artwork"),
                       splatoon: urls[0], bundle: urls[1], wonder: urls[2], edition: urls[3], bananza: urls[4])
    }

    private func bytes(_ url: URL?) -> Data? { url.flatMap { try? Data(contentsOf: $0) } }

    /// A new library: each title gets its game's banner, the demo product is skipped, and a title the list lacks gets none.
    func testTheStoreSavesTheGamesBannerForEachTitle() async throws {
        let f = try fixture()
        let store = ArtworkStore(directory: f.folder, titleList: f.list, allowsFileURLs: true)
        let added = await store.fetchMissing(["0100C2500FC20000", "010015100B514000", "040074A01BF12000", "0400380020056000"])
        XCTAssertEqual(added, ["010015100B514000", "0100C2500FC20000", "040074A01BF12000"])
        XCTAssertEqual(bytes(ArtworkStore.cachedBanner("0100C2500FC20000", in: f.folder)), bytes(f.splatoon))
        XCTAssertEqual(bytes(ArtworkStore.cachedBanner("010015100B514000", in: f.folder)), bytes(f.wonder))
        XCTAssertEqual(bytes(ArtworkStore.cachedBanner("040074A01BF12000", in: f.folder)), bytes(f.bananza))
        XCTAssertNil(ArtworkStore.cachedBanner("0400380020056000", in: f.folder))   // Splatoon Raiders: in no list
        let again = await store.fetchMissing(["0100C2500FC20000", "010015100B514000", "040074A01BF12000"])
        XCTAssertEqual(again, [])
    }

    /// An older launcher kept the first product per ID (here the bundle and the Switch 2 Edition) in an index with no version.
    /// The update fetches the list once, replaces those two banners, keeps the one of a title with a single product without
    /// downloading it, and after that needs the list no more.
    func testABannerSavedByAnOlderLauncherIsReplaced() async throws {
        let f = try fixture()
        try FileManager.default.createDirectory(at: f.folder, withIntermediateDirectories: true)
        try Data(contentsOf: f.bundle).write(to: f.folder.appendingPathComponent("0100C2500FC20000.jpg"))
        try Data(contentsOf: f.edition).write(to: f.folder.appendingPathComponent("010015100B514000.jpg"))
        let ownBananza = f.folder.appendingPathComponent("040074A01BF12000.jpg")
        try image(.systemBrown, "saved earlier", to: ownBananza)
        let saved = try Data(contentsOf: ownBananza)
        let fresh = ISO8601DateFormatter().string(from: Date())
        try Data("""
        {"fetched": "\(fresh)", "banners": {"0100C2500FC20000": "\(f.bundle.absoluteString)", "010015100B514000": "\(f.edition.absoluteString)",
         "040074A01BF12000": "\(f.bananza.absoluteString)"}}
        """.utf8).write(to: f.folder.appendingPathComponent("index.json"))

        let ids = ["0100C2500FC20000", "010015100B514000", "040074A01BF12000"]
        let store = ArtworkStore(directory: f.folder, titleList: f.list, allowsFileURLs: true)
        let replaced = await store.fetchMissing(ids)
        XCTAssertEqual(replaced, ["010015100B514000", "0100C2500FC20000"])
        XCTAssertEqual(bytes(ArtworkStore.cachedBanner("0100C2500FC20000", in: f.folder)), bytes(f.splatoon))
        XCTAssertEqual(bytes(ArtworkStore.cachedBanner("010015100B514000", in: f.folder)), bytes(f.wonder))
        XCTAssertEqual(bytes(ArtworkStore.cachedBanner("040074A01BF12000", in: f.folder)), saved)   // one product: not fetched again
        let index = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.folder.appendingPathComponent("index.json"))) as? [String: Any])
        XCTAssertEqual(index["version"] as? Int, ArtworkStore.indexVersion)

        // The next launch: the list is gone, and nothing asks for it
        try FileManager.default.removeItem(at: f.list)
        let next = ArtworkStore(directory: f.folder, titleList: f.list, allowsFileURLs: true)
        let nothing = await next.fetchMissing(ids)
        XCTAssertEqual(nothing, [])
        XCTAssertEqual(bytes(ArtworkStore.cachedBanner("0100C2500FC20000", in: f.folder)), bytes(f.splatoon))
    }

    /// With the list unreachable, an old index still gives a missing title its banner but leaves the saved ones alone: they are
    /// checked once the list comes.
    func testAnOldIndexWithoutTheListKeepsTheSavedBanners() async throws {
        let f = try fixture()
        try FileManager.default.createDirectory(at: f.folder, withIntermediateDirectories: true)
        try Data(contentsOf: f.bundle).write(to: f.folder.appendingPathComponent("0100C2500FC20000.jpg"))
        try Data("""
        {"fetched": "\(ISO8601DateFormatter().string(from: Date()))", "banners": {"0100C2500FC20000": "\(f.bundle.absoluteString)",
         "010015100B514000": "\(f.wonder.absoluteString)"}}
        """.utf8).write(to: f.folder.appendingPathComponent("index.json"))
        let store = ArtworkStore(directory: f.folder, titleList: temporary.appendingPathComponent("missing.json"), allowsFileURLs: true)
        let added = await store.fetchMissing(["0100C2500FC20000", "010015100B514000"])
        XCTAssertEqual(added, ["010015100B514000"])
        XCTAssertEqual(bytes(ArtworkStore.cachedBanner("0100C2500FC20000", in: f.folder)), bytes(f.bundle))

        let later = ArtworkStore(directory: f.folder, titleList: f.list, allowsFileURLs: true)
        let replaced = await later.fetchMissing(["0100C2500FC20000", "010015100B514000"])
        XCTAssertEqual(replaced, ["010015100B514000", "0100C2500FC20000"])   // both were saved without a record: fetched once more
        XCTAssertEqual(bytes(ArtworkStore.cachedBanner("0100C2500FC20000", in: f.folder)), bytes(f.splatoon))
    }

    /// A Switch 2 game the list lacks (Splatoon Raiders): no banner and no error. The library shows the engine's screenshot of
    /// the game when the repository has one, else the placeholder.
    func testATitleTheListLacksFallsBack() async throws {
        let f = try fixture()
        let store = ArtworkStore(directory: f.folder, titleList: f.list, allowsFileURLs: true)
        let added = await store.fetchMissing(["0400380020056000"])
        XCTAssertEqual(added, [])
        let game = LibraryGame(titleID: "0400380020056000", name: "Splatoon Raiders")
        let repo = temporary.appendingPathComponent("repo")
        XCTAssertNil(GameLibrary.artwork(for: game, repo: repo.path, banners: f.folder))
        let images = repo.appendingPathComponent("docs/images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try image(.systemBlue, "screenshot", to: images.appendingPathComponent("splatoon-raiders.jpg"))
        XCTAssertEqual(GameLibrary.artwork(for: game, repo: repo.path, banners: f.folder)?.size, NSSize(width: 640, height: 360))
    }

    /// Switch 2 titles absent from blawar/titledb (such as Ocarina of Time, 0400486024DEC000) use the verified fallback map,
    /// while a title present in the list (Donkey Kong Bananza) keeps the list's own banner.
    func testFallbackBannersCoverMissingSwitch2TitlesWithoutOverridingTheList() async throws {
        XCTAssertEqual(ArtworkStore.fallbackBanners.count, 8)
        XCTAssertNotNil(ArtworkStore.fallbackBanners["0400486024DEC000"])
        for (id, link) in ArtworkStore.fallbackBanners {
            XCTAssertNotNil(id.range(of: "^0400[0-9A-F]{12}$", options: .regularExpression), id)
            let url = try XCTUnwrap(URL(string: link), id)
            XCTAssertEqual(url.scheme, "https")
            XCTAssertTrue(ArtworkStore.imageHosts.contains(url.host ?? ""), link)
        }

        let f = try fixture()
        let ocarina = temporary.appendingPathComponent("cdn/ocarina.jpg")
        try image(.systemIndigo, "Ocarina of Time\n(fallback banner)", to: ocarina)
        let store = ArtworkStore(directory: f.folder, titleList: f.list, fallbacks: [
            "0400486024DEC000": ocarina.absoluteString,
            "040074A01BF12000": ocarina.absoluteString,
        ])
        let added = await store.fetchMissing(["0400486024DEC000", "040074A01BF12000"])
        XCTAssertEqual(added, ["0400486024DEC000", "040074A01BF12000"])
        XCTAssertEqual(bytes(ArtworkStore.cachedBanner("0400486024DEC000", in: f.folder)), bytes(ocarina))
        XCTAssertEqual(bytes(ArtworkStore.cachedBanner("040074A01BF12000", in: f.folder)), bytes(f.bananza))
        let again = await store.fetchMissing(["0400486024DEC000", "040074A01BF12000"])
        XCTAssertEqual(again, [])
    }

    // MARK: Visual QA (matched by --filter testRenderLauncherForVisualQA)

    /// The library before and after the update: covers an older launcher saved (the bundle, the Switch 2 Edition), then the
    /// game's own after the store ran. Donkey Kong Bananza (Switch 2, in the list) has its cover, Splatoon Raiders (Switch 2,
    /// in no list) the placeholder. The capture's banner folder is its own, so each card shows its saved banner through the
    /// game's artwork path.
    @MainActor func testRenderLauncherForVisualQACovers() async throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let f = try fixture()
        try FileManager.default.createDirectory(at: f.folder, withIntermediateDirectories: true)
        try Data(contentsOf: f.bundle).write(to: f.folder.appendingPathComponent("0100C2500FC20000.jpg"))
        try Data(contentsOf: f.edition).write(to: f.folder.appendingPathComponent("010015100B514000.jpg"))
        try Data(contentsOf: f.bananza).write(to: f.folder.appendingPathComponent("040074A01BF12000.jpg"))
        try Data("""
        {"fetched": "\(ISO8601DateFormatter().string(from: Date()))", "banners": {}}
        """.utf8).write(to: f.folder.appendingPathComponent("index.json"))

        // A stand-in engine: the marker and the two Switch 2 profiles' first lines, so their cards carry the badge
        let repo = temporary.appendingPathComponent("repo")
        func write(_ path: String, _ text: String) throws {
            let url = repo.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write("engine/" + EngineLayout.marker, "")
        try write("engine/dm/games/040074A01BF12000/game.tsv", "# Donkey Kong Bananza (Switch 2, update v458752)\nname\tDonkey Kong Bananza\n")
        try write("engine/dm/games/0400380020056000/game.tsv", "# Splatoon Raiders (Switch 2, update v65536)\nname\tSplatoon Raiders\n")

        NSApplication.shared.setActivationPolicy(.accessory)
        let stores = LauncherStores(defaults: testDefaults); let model = stores.build
        stores.repo.path = repo.path
        model.lang = CaptureLanguage.current(.en)
        stores.dependencies.checked = true
        stores.dependencies.deps = [Dep(id: "test", name: "Xcode", hint: "", present: true, installCmd: [])]
        let library = GameLibrary(file: temporary.appendingPathComponent("preview.json"), artwork: f.folder)   // the banners saved above
        let games = [("0100C2500FC20000", "Splatoon 3"), ("010015100B514000", "Super Mario Bros. Wonder"),
                     ("040074A01BF12000", "Donkey Kong Bananza"), ("0400380020056000", "Splatoon Raiders")]
        var ids: [String: UUID] = [:]
        for (titleID, name) in games { ids[titleID] = try library.addApp(makeApp(titleID, name: name)) }
        func showSaved() {
            for (titleID, _) in games {
                guard let id = ids[titleID] else { continue }
                library.setArtwork(GameArtwork(), for: id)   // no choice: the saved banner, read again
            }
            library.selectedID = ids["0100C2500FC20000"]
        }
        func capture(_ name: String) throws {
            let host = NSHostingView(rootView: LauncherView(stores: stores, library: library, initialPage: .library, performStartupChecks: false))
            let window = OffscreenWindow(size: NSSize(width: 1440, height: 1024), styleMask: [.titled, .closable, .resizable])
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
            window.orderOut(nil)
        }
        showSaved()
        try capture("library-covers-before")
        let store = ArtworkStore(directory: f.folder, titleList: f.list, allowsFileURLs: true)
        _ = await store.fetchMissing(games.map(\.0))
        showSaved()
        try capture("library-covers-after")
    }

    private func makeApp(_ titleID: String, name: String) throws -> URL {
        let app = temporary.appendingPathComponent(name + ".app")
        let executables = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
        for tool in ["nxnative", "dmhost"] {
            try FileManager.default.createSymbolicLink(at: executables.appendingPathComponent(tool), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        }
        let info: [String: Any] = ["DMTitleID": titleID, "CFBundleDisplayName": name, "CFBundleExecutable": "nxnative",
                                   "CFBundleIdentifier": TestPreferences.domain(in: temporary, "artwork")]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }
}
