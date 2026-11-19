import Foundation
import AppKit
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
    func openQuickMenu() {
        if let id = (state.pausedGame ?? state.focusedGame)?.id,
           let game = libraryGame(id), let index = state.games.firstIndex(where: { $0.id == id }) {
            state.games[index].icon = GameLibrary.appIcon(for: game, banners: library.artworkDirectory)
        }
        state.openQuickMenu()
    }
    func openManage(_ gameID: String) { loadDetails(gameID); state.openManage(gameID) }

    /// Stop, once asked: the build store ends the running build (and only it, the queue waits), as the desktop's Stop does.
    func stopBuild() {
        if state.presentedSheet == .confirmStopBuild { state.back() }
        builds?.stop()
    }

    // MARK: The Builds page

    /// The Builds page follows the build store and the queue: the operation line, the stages, Stop, and the queue's rows.
    func bindBuilds(_ build: BuildStore, queue: BuildQueueStore) {
        builds = build
        buildQueue = queue
        var icons: [String: NSImage] = [:]
        var artwork: [String: NSImage] = [:]
        var missingIconCheck: [String: (appPath: String, at: Date)] = [:]
        var missingArtCheck: [String: (fingerprint: String, at: Date)] = [:]
        let missingRecheckInterval: TimeInterval = 5
        let standaloneID = UUID()
        var pendingSnapshot: ConsoleBuilds?
        var settling: Task<Void, Never>?
        let update: () -> Void = { [weak self, weak build, weak queue] in
            guard let self, let build else { return }
            let now = Date()
            let currentID = build.operation?.titleID ?? build.gameTitleID
            let titleIDs = Set((queue?.entries ?? []).map(\.titleID) + [currentID].compactMap { $0 })
            for id in titleIDs where icons[id] == nil || artwork[id] == nil {
                guard let game = self.library.games.first(where: { $0.titleID.caseInsensitiveCompare(id) == .orderedSame }) else { continue }
                if icons[id] == nil {
                    let prev = missingIconCheck[id]
                    let canCheck = prev == nil || prev!.appPath != game.appPath || now.timeIntervalSince(prev!.at) >= missingRecheckInterval
                    if canCheck {
                        if let icon = GameLibrary.appIcon(for: game, banners: self.library.artworkDirectory, maxPixel: ArtworkImages.iconPixels) {
                            icons[id] = icon
                            missingIconCheck.removeValue(forKey: id)
                        } else {
                            missingIconCheck[id] = (game.appPath, now)
                        }
                    }
                }
                if artwork[id] == nil {
                    let fp = "\(game.artwork)|\(game.artworkPath)|\(game.appPath)"
                    let prev = missingArtCheck[id]
                    let canCheck = prev == nil || prev!.fingerprint != fp || now.timeIntervalSince(prev!.at) >= missingRecheckInterval
                    if canCheck {
                        if let art = GameLibrary.artwork(for: game, slot: .thumbnail, repo: self.repo(), banners: self.library.artworkDirectory, maxPixel: ArtworkImages.cardPixels) {
                            artwork[id] = art
                            missingArtCheck.removeValue(forKey: id)
                        } else {
                            missingArtCheck[id] = (fp, now)
                        }
                    }
                }
            }
            let progress = build.buildingGame ? build.overallProgress : build.stages.first { $0.state == .running }?.percent.map { $0 / 100 }
            var snapshot = Self.builds(running: build.running, stopping: build.stopping,
                                      title: build.operationTitle ?? build.t("library.preparing"), stages: build.stages,
                                      queue: queue?.entries ?? [], icons: icons, artwork: artwork, progress: progress)
            if build.running && !snapshot.queue.contains(where: \.active) || !build.running && snapshot.queue.isEmpty && build.completionStatus != nil {
                snapshot.queue.insert(.init(id: standaloneID, name: build.gameName, statusKey: build.running ? "queue.status.running" : build.completionStatus == .needsData ? "result.dataNeeded" : "queue.status.done",
                    platformKey: build.runningTarget == BuildTarget.mac ? "library.section.mac" : "build.ios",
                    icon: currentID.flatMap { icons[$0] }, outcome: build.running ? nil : build.completionStatus == .needsData ? .warning : .success,
                    artwork: currentID.flatMap { artwork[$0] }, active: build.running,
                    progress: progress.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }), at: 0)
            }
            snapshot.retainCompletionOrder(from: pendingSnapshot ?? self.state.builds)
            if settling != nil { pendingSnapshot = snapshot; return }
            if let finishing = ConsoleBuilds.completionFrame(from: self.state.builds, to: snapshot) {
                pendingSnapshot = snapshot
                self.state.builds = finishing
                settling = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(220))
                    if let latest = pendingSnapshot { self?.state.builds = latest }
                    pendingSnapshot = nil; settling = nil
                }
            } else { self.state.builds = snapshot }
            if !build.running, self.state.presentedSheet == .confirmStopBuild { self.state.back() }   // it ended meanwhile: nothing to stop
        }
        build.objectWillChange.merge(with: queue.objectWillChange)
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated(update) }
            .store(in: &cancellables)
        update()
    }

    func buildGame(_ gameID: String, queueOnly: Bool) {
        guard let game = libraryGame(gameID), state.games.contains(where: { $0.id == gameID && $0.status == .needsBuild }),
              let queue = buildQueue, let builds else { return }
        let entry = QueueEntry(game: game, engineID: buildEngineID(), target: BuildTarget.mac)
        if let folder = entry.gameFolder, case .failure(let problem) = GameFolder.scan(GameFolder.resolve(folder)) {
            showToast(builds.gameFolderProblemText(problem)); return
        }
        let files = entry.gameFolder.map { [$0] } ?? entry.inputs.values.flatMap { $0 }
        guard !files.isEmpty, !(entry.inputs["base"] ?? []).isEmpty || entry.gameFolder != nil else {
            showToast(t("console.build.missingBase")); return
        }
        guard let missing = files.first(where: { !FileManager.default.fileExists(atPath: $0) }) else {
            if entry.gameFolder == nil && !(entry.inputs["keys"] ?? []).contains(where: { FileManager.default.fileExists(atPath: $0) }) && !builds.savedKeysExist {
                showToast(t("console.build.missingKeys")); return
            }
            queue.enqueue([entry])
            if !queueOnly && !builds.running {
                if let queued = queue.queued.first(where: { $0.titleID == entry.titleID }) {
                    while queue.canMoveUp(queued.id) { queue.moveUp(queued.id) }
                }
                queue.start()
            }
            state.openBuilds()
            return
        }
        showToast(String(format: t("console.build.missingFile"), (missing as NSString).lastPathComponent))
    }

    static func builds(running: Bool, stopping: Bool, title: String, stages: [Stage], queue: [QueueEntry], icons: [String: NSImage] = [:], artwork: [String: NSImage] = [:], progress: Double? = nil) -> ConsoleBuilds {
        ConsoleBuilds(running: running, stopping: stopping, title: title,
                      stages: running ? stages.map { ConsoleBuilds.StageRow(id: $0.id, name: $0.name, nameKey: $0.nameKey, nameArgument: $0.nameArgument,
                                                                            state: $0.state, progress: $0.percent.map { min(max($0 / 100, 0), 1) }) } : [],
                      queue: QueueGame.grouped(queue)
                          .map { game in
                              let current = game.entries.first { $0.status == .running || $0.packagePending == true }
                              let failed = game.entries.contains { $0.status == .failed }
                              let skipped = game.entries.contains { $0.status == .skipped }
                              let stopped = game.entries.contains { $0.status == .stopped }
                              let done = game.entries.allSatisfy { $0.status == .done && $0.packagePending == nil }
                              let status = failed ? "failed" : skipped ? "skipped" : stopped ? "stopped" : done ? "done" : current?.status.rawValue ?? "queued"
                              let active = running && current != nil
                              let reported = progress.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
                              let completed = game.entries.filter { $0.status == .done }.count
                              let units = game.entries.count + (game.entries.contains { $0.target == BuildTarget.ios && $0.packageAfter } ? 1 : 0)
                              let overall = reported.map { min((Double(completed) + $0) / Double(units), 1) }
                              return ConsoleBuilds.QueueRow(id: game.id, name: game.name,
                                  statusKey: current?.packagePending == true ? "queue.packaging" : game.entries.contains { $0.packagePending == false } && current == nil ? "queue.awaitingPackage" : "queue.status." + status,
                                  platformKey: game.both ? "library.chip.both" : game.entries[0].target == BuildTarget.mac ? "library.section.mac" : "build.ios",
                                  icon: icons[game.entries[0].titleID], outcome: (failed || stopped) ? .failure : skipped ? .warning : done ? .success : nil,
                                  artwork: artwork[game.entries[0].titleID], active: active, progress: active ? overall : nil)
                          })
    }
}
