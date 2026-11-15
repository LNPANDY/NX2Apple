import AppKit
import XCTest
@testable import NX2Apple
@testable import NXCore

/// The banner in the launcher's language, and Nintendo of Europe's clean key art ahead of both lists (#403). Each image has its
/// own width, so the saved banner tells which source it came from.
final class ArtworkLanguageTests: XCTestCase {
    private var temporary: URL!
    private let game = "0100535012974000", usOnly = "01007EF00011E000", cleanOne = "010093801237C000"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-lang-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    private func jpeg(_ name: String, width: Int) throws -> URL {
        let url = temporary.appendingPathComponent(name)
        let picture = NSImage(size: NSSize(width: width, height: 36), flipped: false) { rect in NSColor.orange.setFill(); rect.fill(); return true }
        try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(picture.tiffRepresentation))?.representation(using: .jpeg, properties: [:])).write(to: url)
        return url
    }

    private func list(_ name: String, _ entries: [(String, URL)]) throws -> URL {
        let url = temporary.appendingPathComponent(name)
        let body = entries.enumerated().map { "\"\($0.offset)\": {\"id\": \"\($0.element.0)\", \"bannerUrl\": \"\($0.element.1.absoluteString)\"}" }
        try Data(("{" + body.joined(separator: ",") + "}").utf8).write(to: url)
        return url
    }

    private func width(_ id: String, in folder: URL) -> Int? {
        ArtworkStore.cachedBanner(id, in: folder).flatMap { NSBitmapImageRep(data: (try? Data(contentsOf: $0)) ?? Data())?.pixelsWide }
    }

    private var folder: URL { temporary.appendingPathComponent("artwork") }

    /// A catalogue that answers from a table by catalogue language, and records what it was asked.
    private final class Catalogue: @unchecked Sendable {
        var table: [String: [String: String]]; var asked: [(String, [String])] = []; var fails = false
        init(_ table: [String: [String: String]]) { self.table = table }
        var lookup: CleanArt.Lookup { { language, ids in
            self.asked.append((language, ids))
            if self.fails { throw URLError(.notConnectedToInternet) }
            return (self.table[language] ?? [:]).filter { ids.contains($0.key) }
        } }
    }

    private func store(catalogue: Catalogue = Catalogue([:])) throws -> ArtworkStore {
        let us = try list("US.en.json", [(game, jpeg("us.jpg", width: 10)), (usOnly, jpeg("us-only.jpg", width: 11)), (cleanOne, jpeg("us-promo.jpg", width: 12))])
        let it = try list("IT.it.json", [(game, jpeg("it.jpg", width: 20)), (cleanOne, jpeg("it-promo.jpg", width: 22))])
        return ArtworkStore(directory: folder, titleList: us, allowsFileURLs: true, regional: ["it": it], catalogue: catalogue.lookup)
    }

    func testTheLaunchersLanguagePicksItsOwnListAndTheUSListFillsWhatItLacks() async throws {
        let store = try store()
        let added = await store.fetchMissing([game, usOnly], language: "it")
        XCTAssertEqual(Set(added), [game, usOnly])
        XCTAssertEqual(width(game, in: folder), 20, "the Italian banner")
        XCTAssertEqual(width(usOnly, in: folder), 11, "not in the Italian list: the US banner rather than none")
    }

    func testALanguageWithoutItsOwnListReadsTheUSList() async throws {
        let store = try store()
        _ = await store.fetchMissing([game], language: "sv")
        XCTAssertEqual(width(game, in: folder), 10)
    }

    func testChangingTheLanguagePicksEveryBannerAgainOnce() async throws {
        let store = try store()
        _ = await store.fetchMissing([game], language: "en")
        XCTAssertEqual(width(game, in: folder), 10)
        let italian = await store.fetchMissing([game], language: "it")
        XCTAssertEqual(italian, [game])
        XCTAssertEqual(width(game, in: folder), 20)
        let again = await store.fetchMissing([game], language: "it")
        XCTAssertEqual(again, [], "the same language: nothing to download")
        _ = await store.fetchMissing([game], language: "en")
        XCTAssertEqual(width(game, in: folder), 10, "and back")
    }

    func testTheCatalogueComesFirstInTheLanguagesItHas() async throws {
        let italian = try jpeg("clean-it.jpg", width: 30).absoluteString, english = try jpeg("clean-en.jpg", width: 31).absoluteString
        let catalogue = Catalogue(["it": [cleanOne: italian], "en": [cleanOne: english]])
        let store = try store(catalogue: catalogue)
        _ = await store.fetchMissing([cleanOne, game], language: "it")
        XCTAssertEqual(width(cleanOne, in: folder), 30, "the Italian catalogue's image, not the list's promotional banner")
        XCTAssertEqual(width(game, in: folder), 20, "not in the catalogue: the Italian list's banner")
        _ = await store.fetchMissing([cleanOne], language: "ja")
        XCTAssertEqual(width(cleanOne, in: folder), 31, "Japanese has no catalogue: the English one")
        XCTAssertEqual(catalogue.asked.map(\.0), ["it", "en"])
    }

    func testTheCatalogueIsAskedOnceAWeekPerLanguageAndAnOfflineCatalogueLeavesTheList() async throws {
        let catalogue = Catalogue([:]); catalogue.fails = true
        let first = try store(catalogue: catalogue)
        _ = await first.fetchMissing([cleanOne], language: "it")
        XCTAssertEqual(width(cleanOne, in: folder), 22, "offline catalogue: the list's banner")
        catalogue.fails = false
        _ = await first.fetchMissing([cleanOne], language: "it")
        XCTAssertEqual(catalogue.asked.count, 1, "one attempt per launch")
        let again = try store(catalogue: catalogue)
        _ = await again.fetchMissing([cleanOne], language: "it")
        _ = await again.fetchMissing([cleanOne], language: "it")
        XCTAssertEqual(catalogue.asked.count, 2, "the next launch asks again, and then not before the week is over")
    }

    func testACleanImageReplacesASavedBannerAndNeedsNoTitleList() async throws {
        let first = try store()
        _ = await first.fetchMissing([cleanOne], language: "it")
        XCTAssertEqual(width(cleanOne, in: folder), 22, "the list's banner, saved before the catalogue had the game")
        try FileManager.default.removeItem(at: temporary.appendingPathComponent("IT.it.json"))
        try FileManager.default.removeItem(at: temporary.appendingPathComponent("US.en.json"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("catalogue.json"))
        let clean = try jpeg("clean-it.jpg", width: 30).absoluteString
        let offline = ArtworkStore(directory: folder, titleList: temporary.appendingPathComponent("US.en.json"), allowsFileURLs: true,
                                   regional: ["it": temporary.appendingPathComponent("IT.it.json")], catalogue: Catalogue(["it": [cleanOne: clean]]).lookup)
        let added = await offline.fetchMissing([cleanOne], language: "it")
        XCTAssertEqual(added, [cleanOne])
        XCTAssertEqual(width(cleanOne, in: folder), 30, "replaced although neither list can be read")
    }

    // The catalogue itself

    func testTheCatalogueQueryAsksForTheTitleIDsInLowerCase() throws {
        let url = try XCTUnwrap(CleanArt.query(language: "it", titleIDs: ["01004D300C5AE000", "010093801237C000"]))
        XCTAssertEqual(url.host, "searching.nintendo-europe.com")
        XCTAssertEqual(url.path, "/it/select")
        let fq = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "fq" }?.value
        XCTAssertEqual(fq, "application_id_s:(01004d300c5ae000 OR 010093801237c000)")
    }

    func testTheAnswerGivesTheLargeImageOnNintendosSiteOnly() throws {
        let answer = Data("""
        {"response": {"docs": [
          {"application_id_s": "01004d300c5ae000", "type": "GAME", "image_url_h2x1_s": "https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_KirbyAndTheForgottenLand_onlylogo_itIT_image500w.jpg"},
          {"application_id_s": "010093801237c000", "type": "GAME", "image_url_h2x1_s": "https://example.com/H2x1_image500w.jpg"},
          {"application_id_s": "0100000000010000"}
        ]}}
        """.utf8)
        XCTAssertEqual(try CleanArt.images(from: answer), [
            "01004D300C5AE000": "https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_KirbyAndTheForgottenLand_onlylogo_itIT_image1600w.jpg",
        ])
    }

    /// The catalogue's answer for Kirby and Splatoon 3 on 2026-11-08 (Italian), trimmed: the Switch 2 Edition bundle comes first.
    func testTheGamesOwnProductWinsOverItsSwitch2EditionAndItsAddOns() throws {
        let answer = Data("""
        {"response": {"docs": [
          {"application_id_s": "01004d300c5ae000", "type": "GAME", "playable_on_txt": ["BEE"], "nsuid_txt": ["70050000056804", "70010000096830"],
           "title": "Kirby e la terra perduta – Nintendo Switch 2 Edition + Il mondo astrale",
           "image_url_h2x1_s": "https://www.nintendo.com/eu/media/images/assets/nintendo_switch_2_games/NSwitch2_KirbyForgottenLandNS2EdSCW_IT_it_image500w.jpg"},
          {"application_id_s": "01004d300c5ae000", "type": "GAME", "playable_on_txt": ["HAC"], "nsuid_txt": ["70010000046406"], "title": "Kirby e la terra perduta",
           "image_url_h2x1_s": "https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_KirbyAndTheForgottenLand_onlylogo_itIT_image500w.jpg"},
          {"application_id_s": "0100c2500fc20000", "type": "DLC", "title": "Pass di espansione di Splatoon 3 – Coloropoli",
           "image_url_h2x1_s": "https://www.nintendo.com/eu/media/images/dlc_image500w.jpg"},
          {"application_id_s": "0100c2500fc20000", "type": "GAME", "playable_on_txt": ["HAC"], "nsuid_txt": ["70010000046396"], "title": "Splatoon 3",
           "image_url_h2x1_s": "https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/2x1_nswitch_splatoon3/2x1_NSwitch_Splatoon3_image500w.jpg"},
          {"application_id_s": "0400486024dec000", "type": "GAME", "playable_on_txt": ["BEE"], "title": "A Switch 2 game",
           "image_url_h2x1_s": "https://www.nintendo.com/eu/media/images/switch2_game_image500w.jpg"}
        ]}}
        """.utf8)
        let images = try CleanArt.images(from: answer)
        XCTAssertEqual(images["01004D300C5AE000"]?.hasSuffix("H2x1_NSwitch_KirbyAndTheForgottenLand_onlylogo_itIT_image1600w.jpg"), true)
        XCTAssertEqual(images["0100C2500FC20000"]?.hasSuffix("2x1_NSwitch_Splatoon3_image1600w.jpg"), true, "the game, not its expansion pass")
        XCTAssertEqual(images["0400486024DEC000"]?.hasSuffix("switch2_game_image1600w.jpg"), true, "a Switch 2 game keeps its own image")
    }

    func testLanguagesWithoutACatalogueAskTheEnglishOne() {
        XCTAssertEqual(["en", "de", "fr", "it", "es", "pt-br", "sv", "zh", "ja", "ko"].map(CleanArt.language(for:)),
                       ["en", "de", "fr", "it", "es", "pt", "en", "en", "en", "en"])
        XCTAssertEqual(ArtworkStore.titleListURL(for: "es")?.lastPathComponent, "ES.es.json")
        XCTAssertEqual(ArtworkStore.titleListURL(for: "pt-br")?.lastPathComponent, "BR.pt.json")
        XCTAssertEqual(ArtworkStore.titleListURL(for: "ko")?.lastPathComponent, "KR.ko.json")
        XCTAssertNil(ArtworkStore.titleListURL(for: "sv"))
    }

    // The catalogue's original size (the hero at 1440 to 1920 pt on a Retina screen needs about 3000 pixels)

    func testTheOriginalComesBeforeThe1600PixelSize() {
        let link = "https://www.nintendo.com/eu/media/images/10_share_images/games_15/wiiu_14/SI_WiiU_TheLegendOfZeldaBreathOfTheWild_image1600w.jpg"
        XCTAssertEqual(CleanArt.original(link), "https://www.nintendo.com/eu/media/images/10_share_images/games_15/wiiu_14/SI_WiiU_TheLegendOfZeldaBreathOfTheWild.jpg")
        XCTAssertEqual(CleanArt.downloads(for: link), [CleanArt.original(link)!, link])
        XCTAssertEqual(CleanArt.original("https://www.nintendo.com/eu/media/images/2x1_NSwitch2_TLoZTBotWNSwitch2Edition_image1600w.jpg"),
                       "https://www.nintendo.com/eu/media/images/2x1_NSwitch2_TLoZTBotWNSwitch2Edition.jpg")
        XCTAssertNil(CleanArt.original("https://www.nintendo.com/eu/media/images/plain.jpg"))
        XCTAssertEqual(CleanArt.downloads(for: "https://www.nintendo.com/eu/media/images/plain.jpg"), ["https://www.nintendo.com/eu/media/images/plain.jpg"])
    }

    func testTheCataloguesOriginalIsSavedWhenItIsPublished() async throws {
        let sized = try jpeg("key_image1600w.jpg", width: 40).absoluteString
        _ = try jpeg("key.jpg", width: 50)
        let store = try store(catalogue: Catalogue(["it": [cleanOne: sized]]))
        let added = await store.fetchMissing([cleanOne], language: "it")
        XCTAssertEqual(added, [cleanOne])
        XCTAssertEqual(width(cleanOne, in: folder), 50, "the original, not the 1600 pixel size")
        let again = await store.fetchMissing([cleanOne], language: "it")
        XCTAssertEqual(again, [], "kept: not fetched again")
    }

    func testAMissingOriginalFallsBackTo1600AndIsNotAskedForAgain() async throws {
        let sized = try jpeg("only_image1600w.jpg", width: 40).absoluteString   // no only.jpg: the original is missing
        let store = try store(catalogue: Catalogue(["it": [cleanOne: sized]]))
        let added = await store.fetchMissing([cleanOne], language: "it")
        XCTAssertEqual(added, [cleanOne])
        XCTAssertEqual(width(cleanOne, in: folder), 40, "the 1600 pixel size when the original is not published")
        _ = try jpeg("only.jpg", width: 50)   // it appears later: the record says it was missing, so nothing is fetched every launch
        let again = await store.fetchMissing([cleanOne], language: "it")
        XCTAssertEqual(again, [])
        XCTAssertEqual(width(cleanOne, in: folder), 40)
    }

    func testABannerSavedAt1600IsReplacedOnceByTheOriginal() async throws {
        let sized = try jpeg("old_image1600w.jpg", width: 40).absoluteString
        // a launcher from before kept the 1600 size and recorded it as the banner's source
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(string: sized)!, to: folder.appendingPathComponent(cleanOne + ".jpg"))
        try JSONEncoder().encode([cleanOne: sized, ArtworkStore.languageKey: "it"]).write(to: folder.appendingPathComponent("sources.json"))
        _ = try jpeg("old.jpg", width: 50)
        let store = try store(catalogue: Catalogue(["it": [cleanOne: sized]]))
        let added = await store.fetchMissing([cleanOne], language: "it")
        XCTAssertEqual(added, [cleanOne])
        XCTAssertEqual(width(cleanOne, in: folder), 50, "replaced by the larger original")
        let again = await store.fetchMissing([cleanOne], language: "it")
        XCTAssertEqual(again, [], "once")
    }

    func testConcurrentLanguageSwitchDropsStaleCatalogueFetchAndKeepsLatestLanguage() async throws {
        let italianClean = try jpeg("race-clean-it.jpg", width: 30).absoluteString
        let englishClean = try jpeg("race-clean-en.jpg", width: 31).absoluteString
        let us = try list("US.en.json", [(game, jpeg("us.jpg", width: 10)), (cleanOne, jpeg("us-promo.jpg", width: 12))])
        let it = try list("IT.it.json", [(game, jpeg("it.jpg", width: 20)), (cleanOne, jpeg("it-promo.jpg", width: 22))])

        actor Gate {
            private var startedContinuation: CheckedContinuation<Void, Never>?
            private var releaseContinuation: CheckedContinuation<Void, Never>?
            private var started = false
            private var released = false

            func notifyStartedAndWait() async {
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
        let store = ArtworkStore(directory: folder, titleList: us, allowsFileURLs: true, regional: ["it": it]) { lang, ids in
            if lang == "en" {
                await gate.notifyStartedAndWait()
                return [self.cleanOne: englishClean].filter { ids.contains($0.key) }
            }
            return [self.cleanOne: italianClean].filter { ids.contains($0.key) }
        }

        async let staleEnglish = store.fetchMissing([cleanOne, game], language: "en")
        await gate.waitUntilStarted()
        let italianTask = Task { await store.fetchMissing([cleanOne, game], language: "it") }
        try? await Task.sleep(nanoseconds: 20_000_000)
        await gate.release()

        let englishAdded = await staleEnglish
        let italianAdded = await italianTask.value
        XCTAssertEqual(englishAdded, [], "stale English fetch must abort once Italian incremented the language generation")
        XCTAssertEqual(Set(italianAdded), [cleanOne, game])
        XCTAssertEqual(width(cleanOne, in: folder), 30, "Italian clean art must stay on disk without being overwritten by stale English fetch")
        XCTAssertEqual(width(game, in: folder), 20, "Italian regional list banner must stay on disk")
        let sourcesData = try Data(contentsOf: folder.appendingPathComponent("sources.json"))
        let sources = try JSONDecoder().decode([String: String].self, from: sourcesData)
        XCTAssertEqual(sources[ArtworkStore.languageKey], "it")
    }
}
