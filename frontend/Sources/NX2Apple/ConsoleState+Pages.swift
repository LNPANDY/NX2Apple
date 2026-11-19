import Foundation
import AppKit
import NXCore

// The structure of LNPANDY/NX2Apple#816 (Koshindai's console mode concept) in console mode's own look: the home screen's row, a
// game's page and its tabs, all games with their filters and order, the search, the builds, the quick menu and the screen after a
// crash. And the launcher's side of #952 (Haseenesss): a game paused in the background, and the question before it quits.

/// The home screen's one row (#1458), as a PlayStation 5 home: every game in one line, the paused game first (#952), then the
/// ones played most recently, then the rest by name, and All games as the last tile. What a game needs is its tile's chip
/// (Not built, Needs game data), not a row of its own.
enum ConsoleHome {
    /// The row's last tile, All games: its place in `move`, never a game.
    static let allGamesID = "console.home.allGames"

    /// The games' ids in the row's order. Ties keep their place in `games`.
    static func order(_ games: [ConsoleGame], pausedGameID: String? = nil) -> [String] {
        games.enumerated().sorted { l, r in
            let lp = l.element.id == pausedGameID, rp = r.element.id == pausedGameID
            if lp != rp { return lp }
            switch (l.element.lastPlayed, r.element.lastPlayed) {
            case let (a?, b?): return a == b ? l.offset < r.offset : a > b
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil):
                let order = l.element.title.localizedStandardCompare(r.element.title)
                return order == .orderedSame ? l.offset < r.offset : order == .orderedAscending
            }
        }.map(\.element.id)
    }

    /// Left and right through the row, stopping at its ends: All games is the tile after the last game. nil for an id that is not in
    /// the row.
    static func move(from id: String, by step: Int, in order: [String]) -> String? {
        let row = order + [allGamesID]
        guard let index = row.firstIndex(of: id) else { return nil }
        return row[min(max(index + step, 0), row.count - 1)]
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
        var nameKey: String? = nil
        var nameArgument: String? = nil
        var state: StepState
        /// The share of this stage, 0 to 1, when the stage reports one.
        var progress: Double?
    }
    enum ArtworkOutcome: Equatable { case success, warning, failure }
    struct QueueRow: Equatable, Identifiable {
        var id: UUID
        var name: String
        /// queue.status.<status>
        var statusKey: String
        var platformKey: String? = nil
        var icon: NSImage? = nil
        var outcome: ArtworkOutcome? = nil
        var artwork: NSImage? = nil
        var active = false
        var progress: Double? = nil
        var platformSymbol: String { platformKey == "library.chip.both" ? "laptopcomputer.and.iphone" : platformKey == "build.ios" ? "iphone" : "desktopcomputer" }
    }
    var running = false
    var stopping = false
    var title = ""
    var stages: [StageRow] = []
    var queue: [QueueRow] = []
    /// A completed game settles visibly at 100% before the next snapshot is presented.
    static func completionFrame(from old: Self, to next: Self) -> Self? {
        guard let index = old.queue.firstIndex(where: \.active),
              next.queue.first(where: \.active)?.id != old.queue[index].id,
              next.queue.first(where: { $0.id == old.queue[index].id })?.outcome == .success else { return nil }
        var frame = old
        frame.queue[index].progress = 1
        return frame
    }
    var completionOrder: [UUID] = []
    mutating func retainCompletionOrder(from previous: Self) {
        let completed = queue.filter { $0.outcome == .success }.map(\.id)
        completionOrder = previous.completionOrder.filter { completed.contains($0) }
        completionOrder += completed.filter { !completionOrder.contains($0) }
    }
    var indicatorRow: QueueRow? {
        if let active = queue.first(where: \.active) { return active }
        if running { return queue.first { $0.outcome == nil } }
        return queue.last { $0.outcome == .failure || $0.outcome == .warning }
            ?? orderedQueue.first { $0.outcome == .success }
    }
    var hasActivity: Bool { running || !queue.isEmpty }
    var orderedQueue: [QueueRow] {
        let completed = queue.filter { $0.outcome == .success }
        let order = completionOrder.isEmpty ? completed.map(\.id) : completionOrder
        return queue.filter { $0.outcome != .success } + order.reversed().compactMap { id in completed.first { $0.id == id } }
    }
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
    /// The home screen's row: the games' ids in their order (ConsoleHome.order).
    var homeOrder: [String] { ConsoleHome.order(games, pausedGameID: pausedGameID) }

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
            return SupportedGamesSheet.matchesSearch(game, needle: needle, ownedName: ownedTitle)
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
        case .search?: return false
        case .supportedGames?: return !state.supportedText.isEmpty
        default: return false
        }
    }
    /// The hint's words for B.
    static func labelKey(_ text: String) -> String { text.isEmpty ? "console.back" : "console.search.deleteLetter" }
}

extension ConsoleState {
    /// A game panel keeps its context through nested settings and save pages.
    var gameContextID: String? {
        for sheet in sheets.reversed() {
            switch sheet {
            case let .options(id), let .gamePad(id), let .advanced(id), let .manage(id), let .gamePage(id): return id
            case .mapping: if let mappingGameID { return mappingGameID }
            default: break
            }
        }
        return nil
    }
}


extension ConsoleState {
    /// Utility submenus retain the context they were opened from, including beneath a confirmation.
    func titleParent(of sheet: ConsoleSheet) -> ConsoleSheet? {
        switch sheet {
        case .mapping, .language, .cloudSaves, .supportedGames, .advanced, .manage, .gamePad:
            guard let index = sheets.lastIndex(of: sheet), index > 0 else { return nil }
            let parent = sheets[index - 1]
            return parent == .menu || parent == .quickMenu ? nil : parent
        default: return nil
        }
    }
}
