import Foundation
import NXCore

// The structure of LNPANDY/NX2Apple#816 (Koshindai's console mode concept) in console mode's own look: the home screen's rows, a
// game's page and its tabs, all games with their filters and order, the search, the builds, the quick menu and the screen after a
// crash. And the launcher's side of #952 (Haseenesss): a game paused in the background, and the question before it quits.

/// The home screen's rows, in their order. A game is in one row only, so each tile is one focus target.
enum ConsoleHomeRow: String, CaseIterable, Equatable {
    /// Ready on this Mac and played before, the one played last first.
    case continuePlaying
    /// Ready on this Mac, never played, built with the engine's current tools.
    case ready
    /// Not playable as it is: not built, built for iPhone only, an incomplete app, no game data, or built with older tools.
    case attention
    var titleKey: String { "console.rows." + rawValue }
}

struct ConsoleHomeSection: Equatable, Identifiable {
    var row: ConsoleHomeRow
    var gameIDs: [String]
    var id: String { row.rawValue }
}

enum ConsoleHome {
    /// The rows with their games, an empty row left out. `games` keeps its order inside a row, except Continue playing, which goes by
    /// when the game was last played (ties by its place in `games`). A paused game (#952) is played, so it leads Continue playing.
    static func sections(_ games: [ConsoleGame], pausedGameID: String? = nil) -> [ConsoleHomeSection] {
        var continuing: [(game: ConsoleGame, index: Int)] = []
        var ready: [String] = [], attention: [String] = []
        for (index, game) in games.enumerated() {
            if game.status == .ready, game.lastPlayed != nil || game.id == pausedGameID { continuing.append((game, index)) }
            else if game.status == .ready, !game.olderTools { ready.append(game.id) }
            else { attention.append(game.id) }
        }
        continuing.sort { l, r in
            if (l.game.id == pausedGameID) != (r.game.id == pausedGameID) { return l.game.id == pausedGameID }
            let a = l.game.lastPlayed ?? .distantFuture, b = r.game.lastPlayed ?? .distantFuture
            return a == b ? l.index < r.index : a > b
        }
        return [ConsoleHomeSection(row: .continuePlaying, gameIDs: continuing.map(\.game.id)),
                ConsoleHomeSection(row: .ready, gameIDs: ready),
                ConsoleHomeSection(row: .attention, gameIDs: attention)].filter { !$0.gameIDs.isEmpty }
    }

    /// Where a move from a game's tile goes: left and right inside its row (stopping at the ends), up and down to the row above or
    /// below at the same place, or its last tile when that row is shorter. nil: up from the first row (the top bar), down from the
    /// last, or a game that is in no row. The same game when left or right is at the end of the row.
    static func move(from id: String, dx: Int, dy: Int, in sections: [ConsoleHomeSection]) -> String? {
        guard let rowIndex = sections.firstIndex(where: { $0.gameIDs.contains(id) }),
              let column = sections[rowIndex].gameIDs.firstIndex(of: id) else { return nil }
        if dy != 0 {
            let target = rowIndex + (dy < 0 ? -1 : 1)
            guard sections.indices.contains(target) else { return nil }
            let ids = sections[target].gameIDs
            return ids[min(column, ids.count - 1)]
        }
        let ids = sections[rowIndex].gameIDs
        return ids[min(max(column + dx, 0), ids.count - 1)]
    }
}

/// All games' filters (L and R), in their order.
enum ConsoleLibraryFilter: String, CaseIterable, Equatable {
    case all, readyOnMac, notBuilt, needsData
    var titleKey: String { "console.filter." + rawValue }
    func includes(_ game: ConsoleGame) -> Bool {
        switch self {
        case .all: return true
        case .readyOnMac: return game.status == .ready
        case .notBuilt:
            switch game.status { case .needsBuild, .iphoneOnly, .broken: return true; default: return false }
        case .needsData: return game.status == .needsData
        }
    }
    /// The next filter to the left or right, stopping at the ends.
    func stepped(_ step: Int) -> ConsoleLibraryFilter {
        let all = Self.allCases, index = all.firstIndex(of: self) ?? 0
        return all[min(max(index + step, 0), all.count - 1)]
    }
}

/// A game page's tabs (L and R), in their order.
enum ConsoleGameTab: String, CaseIterable, Equatable {
    case overview, saves, build, cheats
    var titleKey: String { "console.tab." + rawValue }
    func stepped(_ step: Int) -> ConsoleGameTab {
        let all = Self.allCases, index = all.firstIndex(of: self) ?? 0
        return all[min(max(index + step, 0), all.count - 1)]
    }
}

/// The desktop's build as the Builds page shows it: its operation line, its stages (the Builds page's), Stop, and the queue (read only).
struct ConsoleBuilds: Equatable {
    struct StageRow: Equatable, Identifiable {
        var id: Int
        var name: String
        var state: StepState
        /// The share of this stage, 0 to 1, when the stage reports one.
        var progress: Double?
    }
    struct QueueRow: Equatable, Identifiable {
        var id: UUID
        var name: String
        /// queue.status.<status>
        var statusKey: String
    }
    var running = false
    var stopping = false
    var title = ""
    var stages: [StageRow] = []
    var queue: [QueueRow] = []
}

/// What happens once the paused game has quit: another game starts, console mode is left (for the desktop, with a game to select),
/// or the launcher quits.
enum ConsoleAfterQuit: Equatable {
    case play(String), leave(selecting: String?), terminate
}

struct ConsoleStopped: Equatable {
    var gameID: String
    /// The newest file of the save the session used, nil when it has none.
    var lastSave: Date?
}

extension ConsoleState {
    var pausedGame: ConsoleGame? { games.first { $0.id == pausedGameID } }
    var homeSections: [ConsoleHomeSection] { ConsoleHome.sections(games, pausedGameID: pausedGameID) }

    /// All games in the chosen order and filter. A game the order does not know yet (just added) goes at the end.
    var libraryGames: [ConsoleGame] {
        let byID = Dictionary(games.map { ($0.id, $0) }) { a, _ in a }
        let ordered = libraryOrder.compactMap { byID[$0] }
        let known = Set(ordered.map(\.id))
        return (ordered + games.filter { !known.contains($0.id) }).filter(libraryFilter.includes)
    }
    var searchGames: [ConsoleGame] {
        let byID = Dictionary(games.map { ($0.id, $0) }) { a, _ in a }
        return searchResults.compactMap { byID[$0] }
    }

    private var canOpen: Bool { !exited && startingGameID == nil }

    /// A game's page, on its Overview.
    mutating func openGamePage(_ id: String) {
        guard canOpen, games.contains(where: { $0.id == id }), presentedSheet != .gamePage(id) else { return }
        gameTab = .overview
        sheets.append(.gamePage(id))
    }
    mutating func stepGameTab(_ step: Int) {
        guard case .gamePage = presentedSheet else { return }
        gameTab = gameTab.stepped(step)
    }
    mutating func openAllGames() {
        guard canOpen, presentedSheet != .allGames else { return }
        sheets.append(.allGames)
    }
    mutating func stepLibraryFilter(_ step: Int) {
        guard presentedSheet == .allGames else { return }
        libraryFilter = libraryFilter.stepped(step)
    }
    /// The search starts empty each time it opens.
    mutating func openSearch() {
        guard canOpen, presentedSheet != .search else { return }
        searchText = ""; searchResults = []
        sheets.append(.search)
    }
    /// The supported games, with an empty search each time the page opens.
    mutating func openSupportedGames(_ list: [SupportedGame], owned: [String: String]) {
        guard canOpen, presentedSheet != .supportedGames else { return }
        supportedGames = list; supportedOwned = owned; supportedText = ""
        sheets.append(.supportedGames)
    }
    mutating func typeSupported(_ text: String) {
        guard presentedSheet == .supportedGames, supportedText.count < 60 else { return }
        supportedText += text
    }
    mutating func deleteSupported() {
        guard presentedSheet == .supportedGames, !supportedText.isEmpty else { return }
        supportedText.removeLast()
    }
    /// The profiles that answer to the search, by name, title ID or the owned game's name in the library, as the desktop's Supported
    /// games sheet finds them. All of them for an empty search.
    var supportedShown: [SupportedGame] {
        let needle = supportedText.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return supportedGames }
        return supportedGames.filter { game in
            let ownedTitle = ownedGameID(game).flatMap { id in games.first { $0.id == id }?.title } ?? ""
            return [game.name, game.titleID, ownedTitle].contains { $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
    /// The library's game for a supported game the player owns.
    func ownedGameID(_ game: SupportedGame) -> String? {
        supportedOwned[game.titleID.uppercased()].flatMap { id in games.contains { $0.id == id } ? id : nil }
    }

    mutating func openBuilds() {
        guard canOpen, presentedSheet != .builds else { return }
        sheets.append(.builds)
    }
    mutating func openQuickMenu() {
        guard canOpen, presentedSheet != .quickMenu else { return }
        sheets.append(.quickMenu)
    }
    mutating func openManage(_ id: String) {
        guard canOpen, games.contains(where: { $0.id == id }), presentedSheet != .manage(id) else { return }
        sheets.append(.manage(id))
    }
    /// "Stop the build?", asked while one runs.
    mutating func askStopBuild() {
        guard canOpen, builds.running, presentedSheet != .confirmStopBuild else { return }
        sheets.append(.confirmStopBuild)
    }

    // MARK: A game paused in the background (#952)

    /// The game paused from its Home menu: console mode is back, with its tile focused on the home screen.
    mutating func gamePaused(_ id: String) {
        guard games.contains(where: { $0.id == id }) else { return }
        pausedGameID = id
        exited = false
        startingGameID = nil
        if sheets.isEmpty { focusedGameID = id }
    }
    /// The game is playing again (the launcher's Resume, the Dock, ⌘Tab).
    mutating func gameResumed() {
        pausedGameID = nil
        if !quittingPaused { afterQuit = nil; if presentedSheet == .confirmQuitPaused { sheets.removeLast() } }
    }
    /// "Quit <game>?" before another game starts, console mode is left or the launcher quits. Cancel keeps the game paused.
    mutating func askQuitPaused(then action: ConsoleAfterQuit) {
        guard pausedGameID != nil, !quittingPaused else { return }
        afterQuit = action
        if presentedSheet != .confirmQuitPaused { sheets.append(.confirmQuitPaused) }
    }
    /// The answer was Quit: the driver asked the game to quit and waits for it.
    mutating func beginQuitPaused() {
        guard pausedGameID != nil, presentedSheet == .confirmQuitPaused else { return }
        quittingPaused = true
    }
    /// The paused game has quit (or quit by itself): what was waiting for it, which the driver then carries out.
    mutating func pausedGameEnded() -> ConsoleAfterQuit? {
        let next = quittingPaused ? afterQuit : nil
        pausedGameID = nil; quittingPaused = false; afterQuit = nil
        if presentedSheet == .confirmQuitPaused { sheets.removeLast() }
        return next
    }

    // MARK: After a crash

    /// "<game> stopped unexpectedly", over the home screen.
    mutating func showStopped(_ id: String, lastSave: Date?) {
        guard games.contains(where: { $0.id == id }), !exited else { return }
        focusedGameID = id
        stopped = ConsoleStopped(gameID: id, lastSave: lastSave)
        sheets = [.stopped]
    }
}

/// B in the search and in the supported games: a letter goes while the field has one, then B leaves (#1129).
enum ConsoleSearchBack {
    static func deletes(_ state: ConsoleState) -> Bool {
        switch state.presentedSheet {
        case .search?: return !state.searchText.isEmpty
        case .supportedGames?: return !state.supportedText.isEmpty
        default: return false
        }
    }
    /// The hint's words for B.
    static func labelKey(_ text: String) -> String { text.isEmpty ? "console.back" : "console.search.deleteLetter" }
}
