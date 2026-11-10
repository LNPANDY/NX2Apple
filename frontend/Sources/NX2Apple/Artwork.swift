import AppKit
import NXCore

/// Official key art for a game, by title ID: the eShop banner (1920×1080, Nintendo's image CDN) that the
/// community title database blawar/titledb lists for each title. The region list is large (about 90 MB), so
/// it is fetched only while a game in the library has no banner yet, reduced to title ID → banner URL and
/// kept beside the library; each banner is downloaded once into the same folder. The list also names a title's screenshots:
/// those are indexed for the titles asked for and downloaded one by one, on request.
///
/// The list can hold several shop products under one title ID (LNPANDY/NX2Apple#403): the game, its Nintendo Switch 2
/// Edition, a bundle with a membership or an expansion pass. They share the ID and differ in name, nsuId and banner.
/// `BannerPick` chooses the game's own product. `sources.json` beside the banners records which URL each one came from, so
/// a banner saved before the rule (no record) is checked once against it and replaced when the pick differs.
actor ArtworkStore {
    static let shared = ArtworkStore(directory: BannerCache.directory)

    static let titleListURL = URL(string: "https://raw.githubusercontent.com/blawar/titledb/master/US.en.json")!
    static let imageHosts: Set<String> = ["img-eshop.cdn.nintendo.net", "cdn2.steamgriddb.com", "www.nintendo.com"]
    /// The index format. An index written by an older launcher (no version: the first product per title ID won) is fetched
    /// again once, so its picks are made by `BannerPick`. Version 3 adds the language the index was read for.
    static let indexVersion = 3

    /// The launcher languages whose eShop has its own list in blawar/titledb: names, logos and banners in that language. Chinese
    /// reads Hong Kong's (17,418 titles with a banner, Chinese names; CN.zh has 89). Swedish has no Swedish list (SE.en is
    /// English), so it keeps the US list.
    static let regionalLists: [String: String] = ["it": "IT.it", "de": "DE.de", "fr": "FR.fr", "ja": "JP.ja", "zh": "HK.zh"]
    nonisolated static func titleListURL(for language: String) -> URL? {
        regionalLists[language].flatMap { URL(string: "https://raw.githubusercontent.com/blawar/titledb/master/\($0).json") }
    }
    /// sources.json records the language its banners were picked for under this key, which is not a title ID
    static let languageKey = "_language"

    let directory: URL
    private let titleList: URL
    private let allowsFileURLs: Bool   // tests serve the list and the images from disk
    private var index: Index?
    private var listFailed = false   // one attempt per launch
    private var running = false

    /// What the list knows of a title besides its banner: up to `maxScreenshots` gameplay screenshots (1920×1080).
    struct Media: Codable, Equatable {
        var screenshots: [String]
    }
    enum MediaLoad: Equatable {
        case loaded(Media)
        case offline   // the list could not be fetched and nothing is saved for the title
        case none
    }
    enum ArtworkError: LocalizedError {
        case refused, unreadable, unavailable
        var errorDescription: String? {
            switch self {
            case .refused: return "the link is not on Nintendo's image CDN"
            case .unreadable: return "the download is not a readable image"
            case .unavailable: return "the title has no such image"
            }
        }
    }
    static let maxScreenshots = 6

    /// Saved as index.json. `media` holds only the titles that were asked for, as the list for all of them would add some 10 MB.
    private struct Index: Codable {
        var version: Int?
        var language: String?   // nil: the US list alone (an index from before version 3, or English)
        var fetched: Date
        var banners: [String: String]
        var several: Set<String>?   // title IDs the list holds more than one product with a banner for
        var media: [String: Media]?
    }
    private var regional: [String: URL]   // language → its list; tests pass their own
    private let catalogue: CleanArt.Lookup
    private var clean: CleanArt.Cache?
    private var catalogueFailed = false   // one attempt per launch, as for the list
    private var language = "en"   // the language of the call being served: fetchMissing and media set it
    private var reading: Task<Void, Never>?   // the list being read, about 90 MB: once at a time
    private var seen: Set<String> = []   // the title IDs asked for since launch: the media to keep when the list is read again

    init(directory: URL, titleList: URL = ArtworkStore.titleListURL, allowsFileURLs: Bool = false, regional: [String: URL]? = nil,
         catalogue: CleanArt.Lookup? = nil) {
        self.directory = directory
        self.titleList = titleList
        self.allowsFileURLs = allowsFileURLs
        self.regional = regional ?? Dictionary(uniqueKeysWithValues: Self.regionalLists.keys.compactMap { code in Self.titleListURL(for: code).map { (code, $0) } })
        // Tests that serve their images from disk get no catalogue unless they pass one: it is on the network
        self.catalogue = catalogue ?? (allowsFileURLs ? { _, _ in [:] } : CleanArt.live)
    }

    /// The language whose list is read: the launcher's when it has one, else English (the US list)
    private func listLanguage(_ language: String) -> String { regional[language] == nil ? "en" : language }

    /// Where a title's banner is kept; nil while it has none.
    nonisolated static func cachedBanner(_ titleID: String, in directory: URL = ArtworkStore.shared.directory) -> URL? {
        BannerCache.cached(titleID, in: directory)
    }

    /// Where a title's downloaded screenshot is kept: `<TITLEID>/screenshot-<n>.jpg` (n from 0, as in `.screenshot(n)`). Nil for any other source.
    nonisolated private static func candidateFile(_ source: ArtworkChoice.Source, titleID: String, in directory: URL) -> URL? {
        guard isTitleID(titleID.uppercased()) else { return nil }
        let name: String
        switch source {
        case .screenshot(let n) where (0..<maxScreenshots).contains(n): name = "screenshot-\(n).jpg"
        default: return nil
        }
        return directory.appendingPathComponent(titleID.uppercased(), isDirectory: true).appendingPathComponent(name)
    }

    nonisolated static func cachedCandidate(_ source: ArtworkChoice.Source, titleID: String, in directory: URL = ArtworkStore.shared.directory) -> URL? {
        guard let url = candidateFile(source, titleID: titleID, in: directory) else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    nonisolated private static func isTitleID(_ id: String) -> Bool {
        id.range(of: "^[0-9A-F]{16}$", options: .regularExpression) != nil
    }

    /// Where a game's own images are kept: the copies of what the user chose. Keyed on the library's UUID, as a title ID is not
    /// unique to one entry and is not a safe folder name.
    nonisolated static func customDirectory(for gameID: UUID, in directory: URL = ArtworkStore.shared.directory) -> URL {
        directory.appendingPathComponent("custom/" + gameID.uuidString, isDirectory: true)
    }

    /// Download the banners the given titles lack, and replace one saved before `BannerPick` when the list holds another
    /// product for its title. Returns the title IDs whose banner is new.
    @discardableResult func fetchMissing(_ titleIDs: [String], language requested: String = "en") async -> [String] {
        let asked = Set(titleIDs.map { $0.uppercased() }.filter(Self.isTitleID))
        seen.formUnion(asked)
        language = listLanguage(requested)
        var sources = readSources()
        // Picked for another language (or before languages were recorded): every banner is picked again, once
        let sameLanguage = (sources[Self.languageKey] ?? "en") == language
        if !sameLanguage { sources = [Self.languageKey: language] }
        await lookUpClean(asked, language: requested)
        let wanted = asked.filter { id in
            Self.cachedBanner(id, in: directory) == nil || sources[id] == nil || clean(for: id).map { !Self.cleanIsCurrent($0, id: id, sources: sources) } == true
        }
        // A title added since the list was last read has its banner and no media: read the list now, in the background, rather than
        // when the panel opens. An index without media is left for `media(for:)`, as it is not rewritten at launch.
        loadIndex()
        let lacksMedia = index?.media.map { media in asked.contains { media[$0] == nil } } ?? false
        guard !wanted.isEmpty || (lacksMedia && !listFailed), !running else { return [] }
        running = true
        defer { running = false }
        if lacksMedia, !listFailed { await refresh() }
        guard !wanted.isEmpty else { writeSources(sources); return [] }
        // A title on the clean list needs no title list: the list is read only for the others
        let fromList = wanted.filter { clean(for: $0) == nil }
        let index = fromList.isEmpty ? nil : await index(for: fromList)
        guard fromList.isEmpty || index != nil else { writeSources(sources); return [] }
        let current = index.map { $0.version == Self.indexVersion && $0.language == language } ?? true
        var added: [String] = []
        for id in wanted.sorted() {
            let cached = Self.cachedBanner(id, in: directory) != nil
            if let link = clean(for: id) {
                if cached && Self.cleanIsCurrent(link, id: id, sources: sources) { continue }
                // The original first (2000 pixels), then the 1600 pixel size. A banner saved at 1600 before is replaced once; an
                // original that is missing is recorded, so it is not asked for at every launch.
                var saved = false
                for (attempt, file) in CleanArt.downloads(for: link).enumerated() {
                    let isOriginal = attempt == 0 && file != link
                    if !isOriginal && cached && sources[id] == link { saved = true; break }   // the 1600 copy is already the one there is
                    do {
                        try await download(file, to: directory.appendingPathComponent(id + ".jpg"))
                        sources[id] = file
                        added.append(id)
                        saved = true
                        break
                    } catch {
                        fputs("artwork: \(id): \(file): \(error.localizedDescription)\n", stderr)
                        if isOriginal && Self.isMissing(error) { sources[Self.missingOriginalKey(id)] = file }   // offline: asked again next time
                    }
                }
                // the catalogue's sizes are all missing: the list's banner next time
                if !saved { clean?.images[id] = nil; saveClean() }
                continue
            }
            guard let index else { continue }
            guard let link = index.banners[id] ?? fallbackBanner(for: id) else {
                if cached && current { sources[id] = "" }   // the list no longer has it: keep the banner, check it no more
                continue
            }
            if cached {
                guard current else { continue }   // an old index: its pick may be the wrong product
                if sources[id] == link { continue }
                // one product and no record from an older launcher, in the same language: the saved banner is it
                if sameLanguage, sources[id] == nil, !(index.several ?? []).contains(id) { sources[id] = link; continue }
            }
            do {
                try await download(link, to: directory.appendingPathComponent(id + ".jpg"))
                if current { sources[id] = link }
                added.append(id)
            } catch { fputs("artwork: \(id): \(error.localizedDescription)\n", stderr) }
        }
        writeSources(sources)
        return added
    }

    /// Where sources.json records that a title's catalogue original is not published (not a title ID, as the language key).
    nonisolated static func missingOriginalKey(_ id: String) -> String { "_noOriginal:" + id }

    /// The server has no such image (an HTTP error, not an image, no such file), as opposed to a network that is down.
    nonisolated static func isMissing(_ error: Error) -> Bool {
        if error is ArtworkError { return true }
        if let url = error as? URLError { return [.badServerResponse, .fileDoesNotExist].contains(url.code) }
        return (error as? CocoaError)?.code == .fileReadNoSuchFile
    }

    /// The saved banner is the catalogue image's best size: its original, or the 1600 pixel one when the original is known to be missing.
    nonisolated static func cleanIsCurrent(_ link: String, id: String, sources: [String: String]) -> Bool {
        guard let original = CleanArt.original(link) else { return sources[id] == link }
        return sources[id] == original || (sources[id] == link && sources[missingOriginalKey(id)] == original)
    }

    /// The screenshots of a title. They are in the saved index once it has been read again since they were added, so an index
    /// without them is read again, once, here and never at launch. `retrying` is the player asking again after `.offline`: the
    /// list gets another attempt, which the one-attempt-per-launch rule would refuse.
    func media(for titleID: String, retrying: Bool = false, language requested: String? = nil) async -> MediaLoad {
        if let requested { language = listLanguage(requested) }
        let id = titleID.uppercased()
        seen.insert(id)
        if retrying { listFailed = false }
        loadIndex()
        if index?.media?[id] == nil, !listFailed { await refresh() }
        guard let media = index?.media?[id] else { return .offline }
        return media.screenshots.isEmpty ? .none : .loaded(media)
    }

    func candidate(_ source: ArtworkChoice.Source, titleID: String) async throws -> URL {
        guard let file = Self.candidateFile(source, titleID: titleID, in: directory) else { throw ArtworkError.unavailable }
        if FileManager.default.fileExists(atPath: file.path) { return file }
        switch await media(for: titleID) {
        case .loaded(let media):
            if case .screenshot(let n) = source { try await download(media.screenshots.indices.contains(n) ? media.screenshots[n] : nil, to: file) }
            return file
        case .offline: throw URLError(.notConnectedToInternet)
        case .none: throw ArtworkError.unavailable
        }
    }

    /// Fetch an image into `file`: Nintendo's CDN only, at most 20 MB, and one that decodes.
    private func download(_ link: String?, to file: URL) async throws {
        guard let link, let url = URL(string: link), allowed(url) else { throw ArtworkError.refused }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
        guard data.count < 20 << 20, NSImage(data: data) != nil else { throw ArtworkError.unreadable }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    private func loadIndex() {
        guard index == nil, let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")) else { return }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        index = try? decoder.decode(Index.self, from: data)
    }

    /// The title ID → banner URL index: the saved one while it is current and fresh or knows every wanted title, else the list again.
    private func index(for wanted: Set<String>) async -> Index? {
        loadIndex()
        if let index, listFailed || index.version == Self.indexVersion && index.language == language
            && (wanted.isSubset(of: index.banners.keys) || Date().timeIntervalSince(index.fetched) < 7 * 86400) {
            return index
        }
        await refresh()
        return index
    }

    /// Read the title list again and save the index, with the media of the titles asked for so far and of those it had.
    private func refresh() async {
        // The actor runs other calls while this awaits: a second caller (the banners, the panel) waits for the same read
        if let reading { return await reading.value }
        let task = Task { await readList() }
        reading = task
        await task.value
        reading = nil
    }

    private func products(at list: URL) async throws -> [BannerPick.Product] {
        let (data, response) = try await URLSession.shared.data(from: list)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
        return Array(try JSONDecoder().decode([String: BannerPick.Product].self, from: data).values)
    }

    /// The products of the language's list, then of the US list for the titles asked for that it lacks (a game sold in the US
    /// shop only, a list that is behind): their banner stays English rather than missing. The US list is read only then.
    private func readProducts() async throws -> [BannerPick.Product] {
        guard let own = regional[language] else { return try await products(at: titleList) }
        let local = try await products(at: own)
        let known = Set(local.compactMap { $0.id?.uppercased() })
        guard !seen.subtracting(known).isEmpty, let us = try? await products(at: titleList) else { return local }
        return local + us.filter { product in product.id.map { !known.contains($0.uppercased()) } ?? false }
    }

    private func readList() async {
        do {
            let products = try await readProducts()
            let picked = BannerPick.banners(products)
            // The screenshots of the product whose banner the game gets, so both come from the game's own listing
            let kept = seen.union(index?.media?.keys.map { $0 } ?? [])
            var byID: [String: [BannerPick.Product]] = [:]
            for product in products { if let id = product.id?.uppercased(), kept.contains(id) { byID[id, default: []].append(product) } }
            var media: [String: Media] = [:]
            for id in kept {   // a title not in the list gets no screenshots, and no second look
                let list = byID[id] ?? []
                let product = BannerPick.pick(list) ?? list.first
                media[id] = Media(screenshots: Array((product?.screenshots ?? []).prefix(Self.maxScreenshots)))
            }
            let fresh = Index(version: Self.indexVersion, language: language, fetched: Date(), banners: picked.banners, several: picked.several, media: media)
            index = fresh
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(fresh).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
        } catch {
            listFailed = true
            fputs("artwork: title list \(titleList.absoluteString): \(error.localizedDescription)\n", stderr)
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
        self.regional = [:]
        self.catalogue = { _, _ in [:] }
        self.customFallbacks = fallbacks
    }

    /// The game's clean key art from Nintendo of Europe's catalogue (`CleanArt`), ahead of the title list's banner.
    private func clean(for id: String) -> String? { clean?.images[id] }

    /// Look up in the catalogue the titles it has not been asked about in this language, or all of them once a week. Saved as
    /// catalogue.json beside the banners. Offline, or when the catalogue fails, the banners come from the list as before.
    private func lookUpClean(_ asked: Set<String>, language requested: String) async {
        let language = CleanArt.language(for: requested)
        if clean == nil, let data = try? Data(contentsOf: directory.appendingPathComponent("catalogue.json")) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            clean = try? decoder.decode(CleanArt.Cache.self, from: data)
        }
        if clean?.language != language || Date().timeIntervalSince(clean?.fetched ?? .distantPast) > 7 * 86400 {
            clean = CleanArt.Cache(language: language, fetched: Date(), images: [:], checked: [])
        }
        let missing = asked.subtracting(clean?.checked ?? [])
        guard !missing.isEmpty, !catalogueFailed else { return }
        do {
            let found = try await catalogue(language, missing.sorted())
            clean?.images.merge(found.filter { missing.contains($0.key) }) { $1 }
            clean?.checked.formUnion(missing)
            saveClean()
        } catch {
            catalogueFailed = true
            fputs("artwork: catalogue \(language): \(error.localizedDescription)\n", stderr)
        }
    }

    private func saveClean() {
        guard let clean else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(clean).write(to: directory.appendingPathComponent("catalogue.json"), options: .atomic)
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
/// ("Demo Available", an award) cannot be told from the list: Nintendo of Europe's catalogue (`CleanArt`) comes first for the
/// games it has, and the player's own image (Manage > Change artwork) covers the rest.
enum BannerPick {
    struct Product: Decodable, Equatable {
        var id: String?
        var name: String?
        var nsuId: Int64?
        var isDemo: Bool?
        var bannerUrl: String?
        var screenshots: [String]?

        init(id: String?, name: String?, nsuId: Int64?, isDemo: Bool? = nil, bannerUrl: String?, screenshots: [String]? = nil) {
            self.id = id; self.name = name; self.nsuId = nsuId; self.isDemo = isDemo; self.bannerUrl = bannerUrl; self.screenshots = screenshots
        }

        private enum CodingKeys: String, CodingKey { case id, name, nsuId, isDemo, bannerUrl, screenshots }

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
            screenshots = try? c.decodeIfPresent([String].self, forKey: .screenshots)
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
