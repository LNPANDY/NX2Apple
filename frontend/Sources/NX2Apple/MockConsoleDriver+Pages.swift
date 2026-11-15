import Foundation
import NXCore

/// The preview's side of #816 and #952: the same state changes as the live driver, over the demo games. Nothing starts, stops or quits.
extension MockConsoleDriver {
    func openGamePage(_ gameID: String) { loadDemoDetails(gameID); state.openGamePage(gameID) }
    func stepGameTab(_ step: Int) { state.stepGameTab(step) }
    func openAllGames() { sortDemo(); state.openAllGames() }
    func stepLibraryFilter(_ step: Int) { state.stepLibraryFilter(step) }
    func toggleLibrarySort() {
        guard state.presentedSheet == .allGames else { return }
        state.librarySort = state.librarySort == .recent ? .name : .recent
        sortDemo()
    }
    /// Recently played, else by name, as LibrarySort orders the desktop's games.
    private func sortDemo() {
        state.libraryOrder = state.games.sorted { l, r in
            if state.librarySort == .recent, l.lastPlayed != r.lastPlayed { return (l.lastPlayed ?? .distantPast) > (r.lastPlayed ?? .distantPast) }
            return l.title.localizedStandardCompare(r.title) == .orderedAscending
        }.map(\.id)
    }
    func openSearch() { state.openSearch() }
    /// A few demo profiles, the first one owned (the first demo game), as the live driver reads the engine's.
    func openSupportedGames() {
        let list = (0..<6).map { i in
            SupportedGame(titleID: String(format: "0100DEMO%08X", i), name: i < state.games.count ? state.games[i].title : "Demo game \(i + 1)",
                          edition: i == 2 ? .switch2 : .switch1, version: i == 4 ? nil : "1.0.\(i)",
                          notes: i == 1 ? "" : "Runs to the end credits. Online play is not supported.")
        }
        state.openSupportedGames(list, owned: state.games.first.map { [list[0].titleID: $0.id] } ?? [:])
    }
    func typeSupported(_ text: String) { state.typeSupported(text) }
    func deleteSupported() { state.deleteSupported() }
    /// The demo's covers: none, unless a capture or a test hands its own (`supportedCoverSource`).
    func supportedCovers(maxPixel: Int) -> SupportedCovers {
        supportedCoverSource?(maxPixel) ?? .saved(in: FileManager.default.temporaryDirectory.appendingPathComponent("console-demo-no-banners"), maxPixel: maxPixel)
    }
    func typeSearch(_ text: String) {
        guard state.presentedSheet == .search else { return }
        state.searchText += text
        searchDemo()
    }
    func deleteSearch() {
        guard state.presentedSheet == .search, !state.searchText.isEmpty else { return }
        state.searchText.removeLast()
        searchDemo()
    }
    private func searchDemo() {
        let query = state.searchText.trimmingCharacters(in: .whitespaces)
        state.searchResults = query.isEmpty ? [] : state.games.filter { $0.title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }.map(\.id)
    }
    func openBuilds() { state.openBuilds() }
    func askStopBuild() { state.askStopBuild() }
    func stopBuild() { if state.presentedSheet == .confirmStopBuild { state.back() }; state.builds.stopping = true }
    func openQuickMenu() { state.openQuickMenu() }
    func openManage(_ gameID: String) { state.openManage(gameID) }
    func resume(_ gameID: String) { if state.pausedGameID == gameID { state.gameResumed() } }
    func quitPausedGame() {
        state.beginQuitPaused()
        switch state.pausedGameEnded() {
        case let .play(id)?: play(id)
        case .leave?: exitToDesktop()
        default: break
        }
    }
}
