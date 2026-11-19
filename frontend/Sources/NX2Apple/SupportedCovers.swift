import AppKit
import NXCore
import SwiftUI

/// The covers of the Supported games list and compact 16:9 game lists: the desktop sheet (SupportedGamesSheet), console page
/// (ConsoleSupportedGamesPage) and reusable 224px list thumbnail loaders. A cover is the file the library shows for an owned game:
/// ArtworkStore's banner for the title ID, fetched in the same order (Nintendo of Europe's clean key art, then blawar/titledb's
/// banner in the launcher's language, then the SteamGridDB overrides) into the same folder.
///
/// Only the rows on screen ask (`appear`), a few title IDs per fetch and one fetch at a time. A row that scrolls away before its turn
/// leaves the queue (`disappear`), and closing the list empties it (`stop`). A fetch already running finishes, as cutting a download off
/// would make the store forget the title's key art. A failed or timed-out title cools down briefly (`Tried.defaultRetryInterval`) rather
/// than staying blacklisted for the entire session, and `retryFailed()` retries visible rows immediately after reconnect.
@MainActor final class SupportedCovers: ObservableObject {
    typealias Fetch = @Sendable (_ titleIDs: [String], _ language: String) async -> Void

    /// Reusable 224px compact list thumbnail tier (112×63 pt at 2x Retina).
    nonisolated static let listThumbnailPixels = ArtworkImages.listThumbPixels

    /// Tracks recently failed title IDs with a cooldown so scrolling doesn't hammer the CDN while transient offline failures recover
    /// once the cooldown elapses or when explicitly reset.
    @MainActor final class Tried {
        static let shared = Tried()
        static let defaultRetryInterval: TimeInterval = 60

        private var attempts: [String: Date] = [:]
        private let retryInterval: TimeInterval
        private let now: () -> Date

        init(retryInterval: TimeInterval = Tried.defaultRetryInterval, now: @escaping () -> Date = Date.init) {
            self.retryInterval = max(0, retryInterval)
            self.now = now
        }

        /// Active cooled-down IDs; writable for tests (`Tried.shared.ids = []`).
        var ids: Set<String> {
            get {
                let current = now()
                return Set(attempts.compactMap { id, at in
                    let elapsed = current.timeIntervalSince(at)
                    return (elapsed >= 0 && elapsed < retryInterval) ? id : nil
                })
            }
            set {
                let current = now()
                attempts = Dictionary(uniqueKeysWithValues: newValue.map { ($0.uppercased(), current) })
            }
        }

        func shouldSkip(_ id: String) -> Bool {
            let key = id.uppercased()
            guard let at = attempts[key] else { return false }
            let elapsed = now().timeIntervalSince(at)
            if elapsed >= 0 && elapsed < retryInterval { return true }
            attempts.removeValue(forKey: key)
            return false
        }

        func record(_ ids: some Sequence<String>) {
            let current = now()
            for id in ids { attempts[id.uppercased()] = current }
        }

        func clear(_ id: String) { attempts.removeValue(forKey: id.uppercased()) }
        func clearAll() { attempts.removeAll() }
    }

    @Published private(set) var images: [String: NSImage] = [:]
    let directory: URL
    let maxPixel: Int
    let batch: Int
    private let language: String
    private let fetch: Fetch
    private let tried: Tried
    private var queue: [String] = []   // on screen and not fetched yet, in the order they appeared
    private var visible: [String] = []   // currently visible rows, in appearance order, for retryFailed()
    private var worker: Task<Void, Never>?
    private var generation = 0

    /// `maxPixel`: the longer side of the decoded image, the slot's width at 2x. `batch`: the title IDs per fetch.
    init(directory: URL, language: String, maxPixel: Int, batch: Int = 4, tried: Tried? = nil, fetch: @escaping Fetch) {
        self.directory = directory
        self.language = language
        self.maxPixel = maxPixel
        self.batch = max(1, batch)
        self.tried = tried ?? .shared
        self.fetch = fetch
    }

    /// Through the launcher's store, into the library's artwork folder.
    static func live(store: ArtworkStore = .shared, directory: URL, language: String, maxPixel: Int) -> SupportedCovers {
        SupportedCovers(directory: directory, language: language, maxPixel: maxPixel) { ids, language in
            _ = await store.fetchMissing(ids, language: language, waits: true, lightweight: true)
        }
    }

    /// Reusable 224px list thumbnail loader backed by `ArtworkStore`.
    static func listThumbnails(store: ArtworkStore = .shared, directory: URL, language: String, tried: Tried? = nil) -> SupportedCovers {
        SupportedCovers(directory: directory, language: language, maxPixel: listThumbnailPixels, tried: tried) { ids, language in
            _ = await store.fetchMissing(ids, language: language, waits: true, lightweight: true)
        }
    }

    /// Off-main-thread loader for a single cached 224px list thumbnail (banner first, falling back to cached icon).
    nonisolated static func loadListThumbnail(for titleID: String, in directory: URL, maxPixel: Int = listThumbnailPixels) async -> NSImage? {
        if let banner = ArtworkStore.cachedBanner(titleID, in: directory),
           let image = await ArtworkImages.shared.loadImage(at: banner, maxPixel: maxPixel) {
            return image
        }
        if let icon = BannerCache.cachedIcon(titleID, in: directory),
           let image = await ArtworkImages.shared.loadImage(at: icon, maxPixel: maxPixel) {
            return image
        }
        return nil
    }

    /// No fetch: only the covers already saved in `directory` (the console demo, previews).
    static func saved(in directory: URL, maxPixel: Int) -> SupportedCovers {
        SupportedCovers(directory: directory, language: "en", maxPixel: maxPixel, tried: Tried()) { _, _ in }
    }

    func image(_ titleID: String) -> NSImage? { images[titleID.uppercased()] }

    /// A row came on screen: its saved cover at once, else a fetch in its turn.
    func appear(_ titleID: String) {
        let id = titleID.uppercased()
        if !visible.contains(id) { visible.append(id) }
        guard images[id] == nil, !queue.contains(id) else { return }
        if let image = saved(id) { images[id] = image; tried.clear(id); return }
        guard !tried.shouldSkip(id) else { return }
        queue.append(id)
        start()
    }

    /// A row left the screen: it leaves the queue if its fetch has not started.
    func disappear(_ titleID: String) {
        let id = titleID.uppercased()
        visible.removeAll { $0 == id }
        queue.removeAll { $0 == id }
    }

    /// Clears cooldown entries and retries currently visible rows that still have no cover (e.g. after reconnecting or reopening).
    func retryFailed() {
        tried.clearAll()
        for id in visible where images[id] == nil && !queue.contains(id) {
            if let image = saved(id) { images[id] = image; continue }
            queue.append(id)
        }
        start()
    }

    /// The list closed: nothing more is fetched for it.
    func stop() {
        queue = []
        visible = []
        worker?.cancel()
        worker = nil
        generation += 1
    }

    /// The fetches in flight have ended (tests).
    func idle() async { while let worker { await worker.value } }

    private func saved(_ id: String) -> NSImage? {
        ArtworkStore.cachedBanner(id, in: directory).flatMap { ArtworkImages.shared.image(at: $0, maxPixel: maxPixel) }
    }

    private func start() {
        guard worker == nil, !queue.isEmpty else { return }
        let run = generation
        worker = Task { [weak self] in await self?.work(run) }
    }

    private func work(_ run: Int) async {
        while !Task.isCancelled, run == generation, !queue.isEmpty {
            let ids = Array(queue.prefix(batch))
            queue.removeFirst(ids.count)
            tried.record(ids)
            let fetch = fetch, language = language, directory = directory, maxPixel = maxPixel
            await Task { await fetch(ids, language) }.value   // not cancelled with the list: see the type's note
            guard !Task.isCancelled, run == generation else { break }
            let decoded: [(String, NSImage)] = await Task.detached(priority: .userInitiated) {
                ids.compactMap { id in
                    guard let url = ArtworkStore.cachedBanner(id, in: directory),
                          let image = ArtworkImages.shared.image(at: url, maxPixel: maxPixel) else { return nil }
                    return (id, image)
                }
            }.value
            guard !Task.isCancelled, run == generation else { break }
            for (id, image) in decoded {
                images[id] = image
                tried.clear(id)
            }
        }
        if run == generation { worker = nil }
    }
}
