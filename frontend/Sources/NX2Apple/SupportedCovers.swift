import AppKit
import SwiftUI

/// The covers of the Supported games list: the desktop sheet (SupportedGamesSheet) and the console page (ConsoleSupportedGamesPage).
/// A cover is the file the library shows for an owned game: ArtworkStore's banner for the title ID, fetched in the same order (Nintendo
/// of Europe's clean key art, then blawar/titledb's banner in the launcher's language, then the SteamGridDB overrides) into the same
/// folder. So a cover fetched here is the library's later, and one the library has is shown here without a request.
///
/// Only the rows on screen ask (`appear`), a few title IDs per fetch and one fetch at a time. A row that scrolls away before its turn
/// leaves the queue (`disappear`), and closing the list empties it (`stop`). A fetch already running finishes, as cutting a download off
/// would make the store forget the title's key art. A title whose fetch found nothing (offline, no image) is not asked again until the
/// launcher starts again (`Tried`). The image is decoded at the row's size.
@MainActor final class SupportedCovers: ObservableObject {
    typealias Fetch = @Sendable (_ titleIDs: [String], _ language: String) async -> Void

    /// The title IDs fetched since launch, found or not: shared by every list, so reopening one does not ask again.
    @MainActor final class Tried {
        static let shared = Tried()
        var ids: Set<String> = []
    }

    @Published private(set) var images: [String: NSImage] = [:]
    let directory: URL
    let maxPixel: Int
    let batch: Int
    private let language: String
    private let fetch: Fetch
    private let tried: Tried
    private var queue: [String] = []   // on screen and not fetched yet, in the order they appeared
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

    /// No fetch: only the covers already saved in `directory` (the console demo, previews).
    static func saved(in directory: URL, maxPixel: Int) -> SupportedCovers {
        SupportedCovers(directory: directory, language: "en", maxPixel: maxPixel, tried: Tried()) { _, _ in }
    }

    func image(_ titleID: String) -> NSImage? { images[titleID.uppercased()] }

    /// A row came on screen: its saved cover at once, else a fetch in its turn.
    func appear(_ titleID: String) {
        let id = titleID.uppercased()
        guard images[id] == nil, !queue.contains(id) else { return }
        if let image = saved(id) { images[id] = image; return }
        guard !tried.ids.contains(id) else { return }
        queue.append(id)
        start()
    }

    /// A row left the screen: it leaves the queue if its fetch has not started.
    func disappear(_ titleID: String) {
        let id = titleID.uppercased()
        queue.removeAll { $0 == id }
    }

    /// The list closed: nothing more is fetched for it.
    func stop() {
        queue = []
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
            tried.ids.formUnion(ids)
            let fetch = fetch, language = language
            await Task { await fetch(ids, language) }.value   // not cancelled with the list: see the type's note
            guard !Task.isCancelled, run == generation else { break }
            for id in ids { if let image = saved(id) { images[id] = image } }
        }
        if run == generation { worker = nil }
    }
}
