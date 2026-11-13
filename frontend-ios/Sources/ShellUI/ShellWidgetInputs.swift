import Foundation

/// Supported WidgetKit size families rendered by `ShellWidgetView`.
public enum ShellWidgetFamily: String, CaseIterable, Equatable, Sendable {
    case small
    case medium
    case large
    case extraLarge
    case accessoryRectangular
    case accessoryCircular
    case accessoryInline
}

/// Which subset of the library a widget highlights.
public enum ShellWidgetFilter: String, CaseIterable, Codable, Equatable, Sendable {
    case all
    case switch2
    case pinned
}

/// What happens when the player taps a game card in the widget.
public enum ShellWidgetTapBehavior: String, CaseIterable, Codable, Equatable, Sendable {
    case launch
    case inspect
}

/// Display model for one game inside a Home Screen or Lock Screen widget.
public struct ShellWidgetGame: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var version: String
    public var state: GameState
    public var recentlyPlayed: String?
    public var isSwitch2: Bool
    public var banner: Artwork?
    public var icon: Artwork?

    public init(
        id: String,
        title: String,
        version: String = "",
        state: GameState = .playable,
        recentlyPlayed: String? = nil,
        isSwitch2: Bool = false,
        banner: Artwork? = nil,
        icon: Artwork? = nil
    ) {
        self.id = id
        self.title = title
        self.version = version
        self.state = state
        self.recentlyPlayed = recentlyPlayed
        self.isSwitch2 = isSwitch2
        self.banner = banner
        self.icon = icon
    }

    public init(tile: GameTile) {
        self.init(
            id: tile.id,
            title: tile.title,
            version: tile.version,
            state: tile.state,
            recentlyPlayed: tile.recentlyPlayed,
            isSwitch2: tile.isSwitch2,
            banner: tile.banner,
            icon: tile.icon
        )
    }

    public var isPlayable: Bool { state == .playable }

    public var playURL: URL {
        (isPlayable ? ShellDeepLink.play(id: id) : ShellDeepLink.game(id: id)).url
    }

    public var inspectURL: URL {
        ShellDeepLink.game(id: id).url
    }

    public var settingsURL: URL {
        ShellDeepLink.settings(id: id).url
    }

    public func primaryURL(behavior: ShellWidgetTapBehavior) -> URL {
        switch behavior {
        case .launch: return playURL
        case .inspect: return inspectURL
        }
    }

    var tile: GameTile {
        GameTile(
            id: id,
            title: title,
            subtitle: ShellFormat.version(version),
            banner: banner,
            icon: icon,
            state: state,
            recentlyPlayed: recentlyPlayed,
            version: version,
            isSwitch2: isSwitch2
        )
    }

    var metaLine: String {
        if let recentlyPlayed, !recentlyPlayed.isEmpty {
            return ShellFormat.metaLine(ShellFormat.version(version), recentlyPlayed)
        }
        return ShellFormat.metaLine(ShellFormat.version(version), state.title)
    }

    var compactSubtitle: String {
        if let recentlyPlayed, !recentlyPlayed.isEmpty {
            return recentlyPlayed
        }
        if isSwitch2, !version.isEmpty {
            return ShellFormat.metaLine(ShellStrings.text("Switch 2"), "v\(version)")
        }
        if !version.isEmpty {
            return ShellFormat.version(version)
        }
        return state.title
    }
}

/// Complete display data for any widget family, already ordered by library priority.
public struct ShellWidgetSnapshot: Equatable, Sendable {
    public var games: [ShellWidgetGame]
    public var readyCount: Int
    public var totalCount: Int

    public init(games: [ShellWidgetGame] = [], readyCount: Int? = nil, totalCount: Int? = nil) {
        self.games = games
        self.readyCount = readyCount ?? games.filter(\.isPlayable).count
        self.totalCount = totalCount ?? games.count
    }

    /// Applies the user's Edit Widget filter and optional pinned hero selection while preserving library order.
    public func resolved(filter: ShellWidgetFilter, pinnedGameID: String? = nil) -> ShellWidgetSnapshot {
        let prioritized = Self.prioritizePlayable(games)
        switch filter {
        case .all:
            return ShellWidgetSnapshot(games: prioritized, readyCount: readyCount, totalCount: totalCount)
        case .switch2:
            let s2 = prioritized.filter(\.isSwitch2)
            let s2Ready = s2.filter(\.isPlayable).count
            return ShellWidgetSnapshot(games: s2, readyCount: s2Ready, totalCount: s2.count)
        case .pinned:
            guard let pinnedGameID, !pinnedGameID.isEmpty,
                  let index = prioritized.firstIndex(where: { $0.id.caseInsensitiveCompare(pinnedGameID) == .orderedSame }) else {
                return ShellWidgetSnapshot(games: prioritized, readyCount: readyCount, totalCount: totalCount)
            }
            var reordered = prioritized
            let hero = reordered.remove(at: index)
            reordered.insert(hero, at: 0)
            return ShellWidgetSnapshot(games: reordered, readyCount: readyCount, totalCount: totalCount)
        }
    }

    private static func prioritizePlayable(_ list: [ShellWidgetGame]) -> [ShellWidgetGame] {
        let ready = list.filter(\.isPlayable)
        let others = list.filter { !$0.isPlayable }
        return ready + others
    }

    /// Sample snapshot used by WidgetKit gallery previews before a library snapshot has been loaded.
    public static let sample = ShellWidgetSnapshot(
        games: [
            ShellWidgetGame(id: "0400001000000000", title: "Mario Kart World", version: "1.8.0",
                            recentlyPlayed: "Played today", isSwitch2: true),
            ShellWidgetGame(id: "0400002000000000", title: "Donkey Kong Bananza", version: "1.2.0",
                            recentlyPlayed: "Played yesterday", isSwitch2: true),
            ShellWidgetGame(id: "0100F2C0115B6000", title: "The Legend of Zelda: Tears of the Kingdom", version: "1.2.1",
                            isSwitch2: false),
            ShellWidgetGame(id: "0400003000000000", title: "Splatoon Raiders", version: "1.1.0",
                            isSwitch2: true),
            ShellWidgetGame(id: "0100000000010000", title: "Super Mario Odyssey", version: "1.3.0",
                            isSwitch2: false),
            ShellWidgetGame(id: "0400004000000000", title: "Mario Tennis Fever", version: "1.0.2",
                            isSwitch2: true),
            ShellWidgetGame(id: "0400005000000000", title: "Pokémon Pokopia", version: "1.1.0",
                            isSwitch2: true),
        ],
        readyCount: 7,
        totalCount: 7
    )
}

/// Localized strings shared with `ShellWidget` so every text comes from `ShellUI`'s 10-language catalog.
public enum ShellWidgetStrings {
    public static var bundle: Bundle { ShellStrings.bundle }
    public static var continueTitle: String { ShellStrings.text("Continue Playing") }
    public static var continueDescription: String {
        ShellStrings.text("Jump back into your recent and ready games from the Home Screen or Lock Screen.")
    }
    public static var switch2Title: String { ShellStrings.text("Switch 2 Deck") }
    public static var switch2Description: String {
        ShellStrings.text("Spotlight your Switch 2 collection with instant one-tap launch.")
    }
    public static var filterLabel: String { ShellStrings.text("Collection") }
    public static var filterAll: String { ShellStrings.text("Recent & Ready") }
    public static var filterSwitch2: String { ShellStrings.text("Switch 2 Only") }
    public static var filterPinned: String { ShellStrings.text("Pinned Game") }
    public static var pinnedGameLabel: String { ShellStrings.text("Featured Game") }
    public static var tapLabel: String { ShellStrings.text("When Tapped") }
    public static var tapLaunch: String { ShellStrings.text("Launch Game") }
    public static var tapInspect: String { ShellStrings.text("Show in Library") }
    public static var upNext: String { ShellStrings.text("Up next") }
    public static var emptyTitle: String { ShellStrings.text("No games ready yet") }
    public static var emptyNote: String {
        ShellStrings.text("Open NX2Apple to load your library or add game data.")
    }
    public static func readyCount(_ count: Int) -> String {
        ShellStrings.text("\(Int64(max(0, count))) ready")
    }
    public static func playAccessibility(_ title: String) -> String {
        ShellStrings.text("Play \(title)")
    }
}
