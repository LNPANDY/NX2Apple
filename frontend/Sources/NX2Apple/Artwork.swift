import AppKit
import NXCore

/// Official key art for a game, by title ID: the eShop banner (1920×1080, Nintendo's image CDN) that the
/// community title database blawar/titledb lists for each title. The region list is large (about 90 MB), so
/// it is fetched only while a game in the library has no banner yet, reduced to title ID → banner URL and
/// kept beside the library; each banner is downloaded once into the same folder.
///
/// The list can hold several shop products under one title ID (LNPANDY/NX2Apple#403): the game, its Nintendo Switch 2
/// Edition, a bundle with a membership or an expansion pass. They share the ID and differ in name, nsuId and banner.
/// `BannerPick` chooses the game's own product. `sources.json` beside the banners records which URL each one came from, so
/// a banner saved before the rule (no record) is checked once against it and replaced when the pick differs.
actor ArtworkStore {
    static let shared = ArtworkStore(directory: BannerCache.directory)

    static let titleListURL = URL(string: "https://raw.githubusercontent.com/blawar/titledb/master/US.en.json")!
    static let imageHosts: Set<String> = ["img-eshop.cdn.nintendo.net", "cdn2.steamgriddb.com"]
    /// The index format. An index written by an older launcher (no version: the first product per title ID won) is fetched
    /// again once, so its picks are made by `BannerPick`.
    static let indexVersion = 2

    let directory: URL
    private let titleList: URL
    private let allowsFileURLs: Bool   // tests serve the list and the images from disk
    private var index: Index?
    private var listFailed = false   // one attempt per launch
    private var running = false

    private struct Index: Codable {
        var version: Int?
        var fetched: Date
        var banners: [String: String]
        var several: Set<String>?   // title IDs the list holds more than one product with a banner for
    }

    init(directory: URL, titleList: URL = ArtworkStore.titleListURL, allowsFileURLs: Bool = false) {
        self.directory = directory
        self.titleList = titleList
        self.allowsFileURLs = allowsFileURLs
    }

    /// Where a title's banner is kept; nil while it has none.
    nonisolated static func cachedBanner(_ titleID: String, in directory: URL = ArtworkStore.shared.directory) -> URL? {
        BannerCache.cached(titleID, in: directory)
    }

    /// Download the banners the given titles lack, and replace one saved before `BannerPick` when the list holds another
    /// product for its title. Returns the title IDs whose banner is new.
    @discardableResult func fetchMissing(_ titleIDs: [String]) async -> [String] {
        var sources = readSources()
        let wanted = Set(titleIDs.map { $0.uppercased() }.filter { $0.range(of: "^[0-9A-F]{16}$", options: .regularExpression) != nil })
            .filter { Self.cachedBanner($0, in: directory) == nil || sources[$0] == nil }
        guard !wanted.isEmpty, !running else { return [] }
        running = true
        defer { running = false }
        guard let index = await index(for: wanted) else { return [] }
        let current = index.version == Self.indexVersion
        var added: [String] = []
        for id in wanted.sorted() {
            let cached = Self.cachedBanner(id, in: directory) != nil
            guard let link = index.banners[id] ?? fallbackBanner(for: id) else {
                if cached && current { sources[id] = "" }   // the list no longer has it: keep the banner, check it no more
                continue
            }
            if cached {
                guard current else { continue }   // an old index: its pick may be the wrong product
                if !(index.several ?? []).contains(id) { sources[id] = link; continue }   // one product: the saved banner is it
            }
            guard let url = URL(string: link), allowed(url) else { continue }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 { continue }
                guard data.count < 20 << 20, NSImage(data: data) != nil else { continue }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent(id + ".jpg"), options: .atomic)
                if current { sources[id] = link }
                added.append(id)
            } catch { fputs("artwork: \(id): \(error.localizedDescription)\n", stderr) }
        }
        writeSources(sources)
        return added
    }

    /// The title ID → banner URL index: the saved one while it is current and fresh or knows every wanted title, else the list again.
    private func index(for wanted: Set<String>) async -> Index? {
        let file = directory.appendingPathComponent("index.json")
        if index == nil, let data = try? Data(contentsOf: file) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            index = try? decoder.decode(Index.self, from: data)
        }
        if let index, listFailed || index.version == Self.indexVersion
            && (wanted.isSubset(of: index.banners.keys) || Date().timeIntervalSince(index.fetched) < 7 * 86400) {
            return index
        }
        guard !listFailed else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: titleList)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
            let entries = try JSONDecoder().decode([String: BannerPick.Product].self, from: data)
            let picked = BannerPick.banners(Array(entries.values))
            let fresh = Index(version: Self.indexVersion, fetched: Date(), banners: picked.banners, several: picked.several)
            index = fresh
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(fresh).write(to: file, options: .atomic)
            return fresh
        } catch {
            listFailed = true
            fputs("artwork: title list \(titleList.absoluteString): \(error.localizedDescription)\n", stderr)
            return index
        }
    }

    /// Title ID → the URL its saved banner came from ("" when the list no longer names one). A banner without a record was
    /// saved by an older launcher.
    private func readSources() -> [String: String] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("sources.json")) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func writeSources(_ sources: [String: String]) {
        guard sources != readSources(), FileManager.default.fileExists(atPath: directory.path) else { return }
        try? JSONEncoder().encode(sources).write(to: directory.appendingPathComponent("sources.json"), options: .atomic)
    }

    /// Switch 2 and Nintendo Classics titles that blawar/titledb's regional lists do not carry yet: verified 16:9 key art
    /// with the official logo on SteamGridDB's CDN, used only while the title list has no entry for the ID.
    static let fallbackBanners: [String: String] = [
        "0400245021D2C000": "https://cdn2.steamgriddb.com/grid/4019460f699df3ca57bb36a6cc8b1ce5.png",   // Yoshi and the Mysterious Book
        "0400380020056000": "https://cdn2.steamgriddb.com/grid/220a08c045f283231e519ed83cd21466.png",   // Splatoon Raiders
        "04003F40232DE000": "https://cdn2.steamgriddb.com/grid/30430599d3640690ebddef63609c5f31.png",   // Hyrule Warriors: Age of Imprisonment
        "0400486024DEC000": "https://cdn2.steamgriddb.com/grid/925526bdfb5910517494acb4db2537d5.png",   // The Legend of Zelda: Ocarina of Time
        "04007EF01F8AE000": "https://cdn2.steamgriddb.com/grid/f73cc1e0813d90b30a22ca9af2e9c8b0.png",   // Fire Emblem: Fortune's Weave
        "0400A3A01EE4C000": "https://cdn2.steamgriddb.com/grid/00b97e285bef52b2826cfbeecd4d30f7.png",   // Pokémon Pokopia
        "0400D4201C6EA000": "https://cdn2.steamgriddb.com/grid/eb3353d1afeb0b6b1c6507bb5d39c757.png",   // Mario Tennis Fever
        "0400E88025B1A000": "https://cdn2.steamgriddb.com/grid/a82908cc940793dc1d63acfc0218b2f9.jpg",   // Star Fox
    ]
    private var customFallbacks: [String: String]?

    init(directory: URL, titleList: URL, fallbacks: [String: String]) {
        self.directory = directory
        self.titleList = titleList
        self.allowsFileURLs = true
        self.customFallbacks = fallbacks
    }

    private func fallbackBanner(for id: String) -> String? {
        if let customFallbacks { return customFallbacks[id] }
        return allowsFileURLs ? nil : Self.fallbackBanners[id]
    }

    /// Only Nintendo's image CDN or the verified fallback host over HTTPS: the list is third-party data.
    private func allowed(_ url: URL) -> Bool {
        if allowsFileURLs && url.isFileURL { return true }
        return url.scheme == "https" && Self.imageHosts.contains(url.host ?? "")
    }
}

/// Which of the products the title list holds under one title ID gives the game's banner (LNPANDY/NX2Apple#403).
///
/// In blawar/titledb's US list (checked 2026-11-04) 167 of the 19,416 base title IDs with a banner have more than one
/// product with different banners. The ID, the category and the size are the same or close for all of them. What tells
/// them apart is the name: the other products add "Nintendo Switch 2 Edition", "+ Nintendo Switch Online Membership",
/// "Expansion Pass", "Bundle", "Collection", "Deluxe", "Complete Edition" or "Retail Version" to the game's name. So each
/// product scores one point per such mark in its name (a demo many more), the lowest score wins, and on a tie the
/// lowest nsuId, the product that came to the shop first. That leaves 3 IDs where two products have the same marks and
/// the tie decides (Cadence of Hyrule, Dragon Marked for Death, Police Simulator). Banners with a promotion painted in
/// ("Demo Available", an award) cannot be told from the list: the player's own image (Manage > Change artwork) covers them.
enum BannerPick {
    struct Product: Decodable, Equatable {
        var id: String?
        var name: String?
        var nsuId: Int64?
        var isDemo: Bool?
        var bannerUrl: String?

        init(id: String?, name: String?, nsuId: Int64?, isDemo: Bool? = nil, bannerUrl: String?) {
            self.id = id; self.name = name; self.nsuId = nsuId; self.isDemo = isDemo; self.bannerUrl = bannerUrl
        }

        private enum CodingKeys: String, CodingKey { case id, name, nsuId, isDemo, bannerUrl }

        /// Third-party data: a field of an unexpected type is left out instead of failing the whole list.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try? c.decodeIfPresent(String.self, forKey: .id)
            name = try? c.decodeIfPresent(String.self, forKey: .name)
            if let number = try? c.decodeIfPresent(Int64.self, forKey: .nsuId) { nsuId = number }
            else if let text = try? c.decodeIfPresent(String.self, forKey: .nsuId) { nsuId = Int64(text) }
            else { nsuId = nil }
            isDemo = try? c.decodeIfPresent(Bool.self, forKey: .isDemo)
            bannerUrl = try? c.decodeIfPresent(String.self, forKey: .bannerUrl)
        }
    }

    /// Words in a product's name that mark another product than the game alone: an edition, a bundle, a pass, a demo.
    static let marks: [String] = [
        "switch\\W*2\\b", "edition", "\\+", "membership", "\\bpass\\b", "bundle", "\\bpacks?\\b", "collection", "ultimate",
        "deluxe", "\\bplus\\b", "\\blite\\b", "\\bset\\b", "retail", "upgrade", "\\bdemo\\b", "\\btrial\\b",
    ]

    static func score(_ product: Product) -> Int {
        let name = product.name ?? ""
        let words = marks.filter { name.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }.count
        return words + (product.isDemo == true ? 100 : 0)
    }

    /// The product whose banner the game gets, among those with a banner; nil when none has one.
    static func pick(_ products: [Product]) -> Product? {
        products.filter { !($0.bannerUrl ?? "").isEmpty }.min { a, b in
            let (sa, sb) = (score(a), score(b))
            if sa != sb { return sa < sb }
            if a.nsuId != b.nsuId { return (a.nsuId ?? .max) < (b.nsuId ?? .max) }
            return (a.bannerUrl ?? "") < (b.bannerUrl ?? "")   // the same product twice: any order gives the same answer
        }
    }

    /// Title ID → the picked banner URL, and the IDs that had more than one banner to choose from.
    static func banners(_ products: [Product]) -> (banners: [String: String], several: Set<String>) {
        var byID: [String: [Product]] = [:]
        for product in products {
            guard let id = product.id?.uppercased(), !(product.bannerUrl ?? "").isEmpty else { continue }
            byID[id, default: []].append(product)
        }
        var banners: [String: String] = [:]
        var several: Set<String> = []
        for (id, list) in byID {
            if let banner = pick(list)?.bannerUrl { banners[id] = banner }
            if Set(list.compactMap(\.bannerUrl)).count > 1 { several.insert(id) }
        }
        return (banners, several)
    }
}
