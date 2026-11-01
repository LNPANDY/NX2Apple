import AppKit

/// Official key art for a game, by title ID: the eShop banner (1920×1080, Nintendo's image CDN) that the
/// community title database blawar/titledb lists for each title. The region list is large (about 90 MB), so
/// it is fetched only while a game in the library has no banner yet, reduced to title ID → banner URL and
/// kept beside the library; each banner is downloaded once into the same folder.
actor ArtworkStore {
    static let shared = ArtworkStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NS Port Builder/artwork"))

    static let titleListURL = URL(string: "https://raw.githubusercontent.com/blawar/titledb/master/US.en.json")!
    static let imageHosts: Set<String> = ["img-eshop.cdn.nintendo.net"]

    let directory: URL
    private let titleList: URL
    private let allowsFileURLs: Bool   // tests serve the list and the images from disk
    private var index: Index?
    private var listFailed = false   // one attempt per launch
    private var running = false

    private struct Index: Codable {
        var fetched: Date
        var banners: [String: String]
    }
    private struct Entry: Decodable {
        let id: String?
        let bannerUrl: String?
    }

    init(directory: URL, titleList: URL = ArtworkStore.titleListURL, allowsFileURLs: Bool = false) {
        self.directory = directory
        self.titleList = titleList
        self.allowsFileURLs = allowsFileURLs
    }

    /// Where a title's banner is kept; nil while it has none.
    nonisolated static func cachedBanner(_ titleID: String, in directory: URL = ArtworkStore.shared.directory) -> URL? {
        let url = directory.appendingPathComponent(titleID.uppercased() + ".jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Download the banners the given titles lack. Returns the title IDs that got one.
    @discardableResult func fetchMissing(_ titleIDs: [String]) async -> [String] {
        let wanted = Set(titleIDs.map { $0.uppercased() }.filter { $0.range(of: "^[0-9A-F]{16}$", options: .regularExpression) != nil })
            .filter { Self.cachedBanner($0, in: directory) == nil }
        guard !wanted.isEmpty, !running else { return [] }
        running = true
        defer { running = false }
        guard let banners = await banners(for: wanted) else { return [] }
        var added: [String] = []
        for id in wanted.sorted() {
            guard let link = banners[id], let url = URL(string: link), allowed(url) else { continue }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 { continue }
                guard data.count < 20 << 20, NSImage(data: data) != nil else { continue }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent(id + ".jpg"), options: .atomic)
                added.append(id)
            } catch { fputs("artwork: \(id): \(error.localizedDescription)\n", stderr) }
        }
        return added
    }

    /// The title ID → banner URL index: the saved one while it is fresh or knows every wanted title, else the list again.
    private func banners(for wanted: Set<String>) async -> [String: String]? {
        let file = directory.appendingPathComponent("index.json")
        if index == nil, let data = try? Data(contentsOf: file) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            index = try? decoder.decode(Index.self, from: data)
        }
        if let index, wanted.isSubset(of: index.banners.keys) || Date().timeIntervalSince(index.fetched) < 7 * 86400 || listFailed {
            return index.banners
        }
        guard !listFailed else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: titleList)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
            let entries = try JSONDecoder().decode([String: Entry].self, from: data)
            var banners: [String: String] = [:]
            for entry in entries.values {
                guard let id = entry.id?.uppercased(), let banner = entry.bannerUrl, !banner.isEmpty, banners[id] == nil else { continue }
                banners[id] = banner
            }
            let fresh = Index(fetched: Date(), banners: banners)
            index = fresh
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(fresh).write(to: file, options: .atomic)
            return banners
        } catch {
            listFailed = true
            fputs("artwork: title list \(titleList.absoluteString): \(error.localizedDescription)\n", stderr)
            return index?.banners
        }
    }

    /// Only Nintendo's image CDN over HTTPS: the list is third-party data.
    private func allowed(_ url: URL) -> Bool {
        if allowsFileURLs && url.isFileURL { return true }
        return url.scheme == "https" && Self.imageHosts.contains(url.host ?? "")
    }
}
