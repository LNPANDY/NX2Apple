import Foundation
import Combine
import NXCore
import NXModel

/// #816 (Koshindai's concept) over the launcher's real data: a game's page with its details, all games in the desktop's order
/// (LibrarySort, its saved choice), the search with the desktop's matching (LibraryGame.matches), the desktop's build and queue for the
/// Builds page, Stop through the build store, and the quick menu.
extension LiveConsoleDriver {
    // MARK: Order and search

    /// After the games were read: all games' order and the search's results follow the library, and the tools are checked once per change.
    func refreshPages(_ shown: [LibraryGame]) {
        state.librarySort = LibrarySort.load(tracking.sortDefaults)
        state.libraryOrder = state.librarySort.ordered(shown, lang: lang()).map(\.id.uuidString)
        state.searchResults = Self.searchResults(shown, query: state.searchText, sort: state.librarySort, lang: lang())
        checkTools(shown)
    }

    /// The games that answer to the query (any name, LibraryGame.matches), in the chosen order. Nothing for an empty query.
    static func searchResults(_ games: [LibraryGame], query: String, sort: LibrarySort, lang: Lang) -> [String] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return sort.ordered(games.filter { $0.matches(search: query, lang: lang) }, lang: lang).map(\.id.uuidString)
    }

    private var shownGames: [LibraryGame] {
        let ids = Set(state.games.map(\.id))
        return library.games.filter { ids.contains($0.id.uuidString) }
    }

    func toggleLibrarySort() {
        guard state.presentedSheet == .allGames else { return }
        (state.librarySort == .recent ? LibrarySort.name : .recent).save(tracking.sortDefaults)
        refreshPages(shownGames)
    }

    func openSearch() { state.openSearch() }

    /// The Library page's Supported games (#301): the engine's profiles, read off the main thread as the desktop's sheet reads them,
    /// with the library's games by title ID so an owned row opens that game's page.
    func openSupportedGames() {
        let root = EngineLayout.root(repo())
        let owned = Dictionary(library.games.filter { game in state.games.contains { $0.id == game.id.uuidString } }
            .map { ($0.titleID.uppercased(), $0.id.uuidString) }) { a, _ in a }
        DispatchQueue.global(qos: .userInitiated).async {
            let list = SupportedGames.list(engineRoot: root)
            DispatchQueue.main.async { [weak self] in self?.state.openSupportedGames(list, owned: owned) }
        }
    }
    func typeSupported(_ text: String) { state.typeSupported(text) }
    func deleteSupported() { state.deleteSupported() }
    /// The library's covers, fetched by the launcher's store as the desktop sheet does.
    func supportedCovers(maxPixel: Int) -> SupportedCovers {
        .live(directory: library.artworkDirectory, language: lang().code, maxPixel: maxPixel)
    }

    func typeSearch(_ text: String) {
        guard state.presentedSheet == .search, state.searchText.count < 60 else { return }
        state.searchText += text
        state.searchResults = Self.searchResults(shownGames, query: state.searchText, sort: state.librarySort, lang: lang())
    }

    func deleteSearch() {
        guard state.presentedSheet == .search, !state.searchText.isEmpty else { return }
        state.searchText.removeLast()
        state.searchResults = Self.searchResults(shownGames, query: state.searchText, sort: state.librarySort, lang: lang())
    }

    // MARK: Pages

    /// A game's page with its mods, cheats and cloud save (as its options load them) and its newest save on this Mac.
    func openGamePage(_ gameID: String) {
        loadDetails(gameID)
        if let game = libraryGame(gameID), let i = state.games.firstIndex(where: { $0.id == gameID }) {
            state.games[i].lastSave = game.isReady ? SaveTransfer.newest(in: SaveTransfer.macSave(titleID: game.titleID, appPath: game.appPath).save) : nil
        }
        state.openGamePage(gameID)
    }

    func stepGameTab(_ step: Int) { state.stepGameTab(step) }
    func openAllGames() { refreshPages(shownGames); state.openAllGames() }
    func stepLibraryFilter(_ step: Int) { state.stepLibraryFilter(step) }
    func openBuilds() { state.openBuilds() }
    func askStopBuild() { state.askStopBuild() }
    func openQuickMenu() { state.openQuickMenu() }
    func openManage(_ gameID: String) { loadDetails(gameID); state.openManage(gameID) }

    /// Stop, once asked: the build store ends the running build (and only it, the queue waits), as the desktop's Stop does.
    func stopBuild() {
        if state.presentedSheet == .confirmStopBuild { state.back() }
        builds?.stop()
    }

    // MARK: The Builds page

    /// The Builds page follows the build store and the queue: the operation line, the stages, Stop, and the queue's rows.
    func bindBuilds(_ build: BuildStore, queue: BuildQueueStore) {
        let update: () -> Void = { [weak self, weak build, weak queue] in
            guard let self, let build else { return }
            self.state.builds = Self.builds(running: build.running, stopping: build.stopping,
                                            title: build.operationTitle ?? build.t("library.preparing"), stages: build.stages, queue: queue?.entries ?? [])
            if !build.running, self.state.presentedSheet == .confirmStopBuild { self.state.back() }   // it ended meanwhile: nothing to stop
        }
        build.objectWillChange.merge(with: queue.objectWillChange)
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated(update) }
            .store(in: &cancellables)
        update()
    }

    static func builds(running: Bool, stopping: Bool, title: String, stages: [Stage], queue: [QueueEntry]) -> ConsoleBuilds {
        ConsoleBuilds(running: running, stopping: stopping, title: title,
                      stages: running ? stages.map { ConsoleBuilds.StageRow(id: $0.id, name: $0.name, state: $0.state, progress: $0.percent.map { min(max($0 / 100, 0), 1) }) } : [],
                      queue: queue.filter { $0.status == .queued || $0.status == .running }
                          .map { ConsoleBuilds.QueueRow(id: $0.id, name: $0.name, statusKey: "queue.status." + $0.status.rawValue) })
    }
}
