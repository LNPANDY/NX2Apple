import Foundation

/// Clean key art from Nintendo of Europe's game catalogue (the search index behind nintendo.com/<country>), by title ID
/// (LNPANDY/NX2Apple#403).
///
/// The eShop banners of blawar/titledb carry promotions painted into the picture in every regional list: "Demo Available" and
/// award ribbons in the US one, "Demo gratuita" and voucher badges in the Italian one. The list has no field for them, so
/// `BannerPick` cannot leave them out. The catalogue's 2:1 game-page image (`image_url_h2x1_s`) is the game's key art and
/// logo only: of 34 games checked by eye on 2026-11-08 in Italian, none carried a badge. Where Nintendo made a version for the
/// language the catalogue names it (`…_itIT_…`, `…_deDE_…`), so the logo is the language's own: Kirby and the Forgotten Land,
/// Hyrule Warriors: Age of Calamity and Dragon Quest XI S in German, French, Italian and Spanish, one in Dutch.
///
/// The catalogue has English, German, French, Italian, Spanish, Dutch and Portuguese. A launcher language without one (Swedish,
/// Chinese, Japanese, Korean) asks the English catalogue: an English logo without a badge rather than the list's banner. A title the
/// catalogue lacks (Switch 2 games, games not sold in Europe, the newest releases) keeps the list's banner.
enum CleanArt {
    typealias Lookup = @Sendable (_ language: String, _ titleIDs: [String]) async throws -> [String: String]

    static let languages: Set<String> = ["en", "de", "fr", "it", "es", "nl", "pt"]
    static func language(for launcher: String) -> String {
        let base = String(launcher.prefix { $0 != "-" })
        return languages.contains(launcher) ? launcher : (languages.contains(base) ? base : "en")
    }

    struct Cache: Codable {
        var language: String
        var fetched: Date
        var images: [String: String]   // title ID → image URL
        var checked: Set<String>   // the title IDs asked about, found or not: not asked again until the week is over
    }

    /// The catalogue's image at 1600 pixels wide: it names the 500-pixel one, and every size is published under the same name.
    static func large(_ url: String) -> String {
        url.replacingOccurrences(of: #"_image\d+w\."#, with: "_image1600w.", options: .regularExpression)
    }

    /// The catalogue's compact image at 500 pixels wide (~35 KB): used when browsing list covers (`SupportedCovers`).
    static func compact(_ url: String) -> String {
        url.replacingOccurrences(of: #"_image\d+w\."#, with: "_image500w.", options: .regularExpression)
    }

    /// The catalogue's original of an image: its name without a size (`…_image1600w.jpg` → `….jpg`), 2000 x 1000 for the
    /// games checked on 2026-11-09 (`_image2500w` and `_image3200w` are not published). A 1440 to 1920 pt hero on a Retina
    /// screen needs 2880 to 3840 pixels, so 1600 was half of it. Nil for a name without a size.
    static func original(_ url: String) -> String? {
        guard url.range(of: #"_image\d+w\."#, options: .regularExpression) != nil else { return nil }
        return url.replacingOccurrences(of: #"_image\d+w\."#, with: ".", options: .regularExpression)
    }

    /// What to download for a catalogue image, best first: the original, then the 1600 pixel size when the original is missing.
    static func downloads(for link: String) -> [String] { [original(link), link].compactMap { $0 } }

    /// One request per 40 titles: `application_id_s` is the title ID in lower case.
    static func query(language: String, titleIDs: [String]) -> URL? {
        var parts = URLComponents(string: "https://searching.nintendo-europe.com/\(language)/select")
        parts?.queryItems = [
            URLQueryItem(name: "q", value: "*"),
            URLQueryItem(name: "fq", value: "application_id_s:(" + titleIDs.map { $0.lowercased() }.joined(separator: " OR ") + ")"),
            URLQueryItem(name: "fl", value: "application_id_s,image_url_h2x1_s,title,type,playable_on_txt,nsuid_txt"),
            URLQueryItem(name: "rows", value: String(titleIDs.count * 10)),   // a game, its editions and its add-on content
            URLQueryItem(name: "wt", value: "json"),
        ]
        return parts?.url
    }

    struct Doc: Decodable, Equatable {
        var application_id_s: String?
        var image_url_h2x1_s: String?
        var title: String?
        var type: String?
        var playable_on_txt: [String]?
        var nsuid_txt: [String]?
    }

    /// Which of the products the catalogue holds under one title ID gives the game's image. As in the title list (`BannerPick`),
    /// one ID can carry the game, its Nintendo Switch 2 Edition (Kirby and the Forgotten Land: "– Nintendo Switch 2 Edition + Il
    /// mondo astrale", Tears of the Kingdom, Super Mario Bros. Wonder) and its add-on content (Splatoon 3's expansion passes). So:
    /// a game, not add-on content; the Nintendo Switch product (`HAC`) before the Switch 2 one (`BEE`) when both are there; then
    /// the name with the fewest edition or bundle marks (`BannerPick.marks`); then the lowest nsuId, the first in the shop.
    static func pick(_ docs: [Doc]) -> Doc? {
        let games = docs.filter { $0.type == "GAME" && !($0.image_url_h2x1_s ?? "").isEmpty }
        func switch1(_ doc: Doc) -> Bool { (doc.playable_on_txt ?? []).contains("HAC") }
        let pool = games.contains(where: switch1) ? games.filter(switch1) : games
        return pool.min { a, b in
            let (sa, sb) = (BannerPick.score(.init(id: nil, name: a.title, nsuId: nil, bannerUrl: nil)),
                            BannerPick.score(.init(id: nil, name: b.title, nsuId: nil, bannerUrl: nil)))
            if sa != sb { return sa < sb }
            return (a.nsuid_txt?.compactMap { Int64($0) }.min() ?? .max) < (b.nsuid_txt?.compactMap { Int64($0) }.min() ?? .max)
        }
    }

    /// Title ID → the large image of the game's own product, from a catalogue answer. An image off Nintendo's site is left out.
    static func images(from data: Data) throws -> [String: String] {
        struct Answer: Decodable {
            struct Response: Decodable { var docs: [Doc] }
            var response: Response
        }
        var byID: [String: [Doc]] = [:]
        for doc in try JSONDecoder().decode(Answer.self, from: data).response.docs {
            guard let id = doc.application_id_s?.uppercased(), let image = doc.image_url_h2x1_s,
                  URL(string: image)?.host == "www.nintendo.com" else { continue }
            byID[id, default: []].append(doc)
        }
        return byID.compactMapValues { pick($0)?.image_url_h2x1_s.map(large) }
    }

    static let live: Lookup = { language, titleIDs in
        var found: [String: String] = [:]
        for start in stride(from: 0, to: titleIDs.count, by: 40) {
            let chunk = Array(titleIDs[start..<min(start + 40, titleIDs.count)])
            guard let url = query(language: language, titleIDs: chunk) else { continue }
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
            found.merge(try images(from: data)) { first, _ in first }
        }
        return found
    }
}
