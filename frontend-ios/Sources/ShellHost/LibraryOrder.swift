import Foundation
import ShellUI

/// When a game was last played, in the game's own defaults suite. A separate key from the `launcher.<VAR>` choices,
/// so Reset to tested defaults keeps it.
public struct LastPlayedStore {
    public static let key = "shell.lastPlayed"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults) { self.defaults = defaults }
    public var date: Date? { defaults.object(forKey: Self.key) as? Date }
    public func record(_ date: Date) { defaults.set(date, forKey: Self.key) }
}

/// The library's order: recently played first (the latest first), then playable, then needs game data, then needs an
/// app update, then broken. Alphabetical by title within each group. Applied when the library loads or reloads, never
/// on a single game's change of state, so nothing moves under the player's finger.
public enum LibraryOrder {
    static func group(_ game: GameTile, lastPlayed: Date?) -> Int {
        if lastPlayed != nil { return 0 }
        switch game.state {
        case .playable: return 1
        case .needsGameData: return 2
        case .needsAppUpdate: return 3
        case .broken: return 4
        }
    }

    /// The ids in library order.
    public static func ids(of games: [GameTile], lastPlayed: [String: Date]) -> [String] {
        games.sorted { a, b in
            let (da, db) = (lastPlayed[a.id], lastPlayed[b.id])
            let (ga, gb) = (group(a, lastPlayed: da), group(b, lastPlayed: db))
            if ga != gb { return ga < gb }
            if let da, let db, da != db { return da > db }
            let byTitle = a.title.localizedCaseInsensitiveCompare(b.title)
            return byTitle == .orderedSame ? a.id < b.id : byTitle == .orderedAscending
        }.map(\.id)
    }
}
