import SwiftUI
import NXCore

enum LauncherPage: String, CaseIterable {
    case library, builds, settings
    var symbol: String {
        switch self {
        case .library: return "gamecontroller"
        case .builds: return "shippingbox"
        case .settings: return "slider.horizontal.3"
        }
    }
}

/// The library's filter: every game in the games folder, or only those with a build. Remembered between launches.
enum LibraryFilter: String, CaseIterable, Identifiable {
    case owned, built, mac, ios
    var id: String { rawValue }
    static let libraryOptions: [LibraryFilter] = [.owned, .mac, .ios]
    var labelKey: String {
        switch self {
        case .owned: return "builds.allGames"
        case .built: return "filter.built"
        case .mac: return "library.section.mac"
        case .ios: return "library.section.mobile"
        }
    }
    func adjusted(_ direction: Int) -> Self {
        let index = Self.libraryOptions.firstIndex(of: self) ?? 0
        return Self.libraryOptions[min(max(index + direction, 0), Self.libraryOptions.count - 1)]
    }

    /// Owned shows every game without reading its build, so the default filter costs nothing per card.
    func includes(_ game: LibraryGame) -> Bool {
        switch self {
        case .owned: return true
        case .built: return game.isReady || game.hasIOSBuild
        case .mac: return game.isReady
        case .ios: return game.hasIOSBuild
        }
    }

    func includes(_ game: LibraryGame, state: LibraryArtworkState?) -> Bool {
        guard let state else { return includes(game) }
        switch self {
        case .owned: return true
        case .built: return state.mac || state.ios
        case .mac: return state.mac
        case .ios: return state.ios
        }
    }

    /// The games this filter shows that match `search` (any name the game answers to), in `sort` order.
    func visibleGames(
        _ games: [LibraryGame],
        matching search: String = "",
        lang: Lang = Lang.initial(),
        sort: LibrarySort = .name,
        builtFirst: Bool = true,
        buildingID: UUID? = nil,
        states: [UUID: LibraryArtworkState]? = nil
    ) -> [LibraryGame] {
        let matched = games.filter { $0.matches(search: search, lang: lang) && includes($0, state: states?[$0.id]) }
        return sort.ordered(matched, lang: lang, builtFirst: builtFirst, buildingID: buildingID, states: states)
    }

    static func load(_ defaults: UserDefaults = .standard) -> LibraryFilter {
        LibraryFilter(rawValue: defaults.string(forKey: "libraryFilter") ?? "") ?? .owned
    }
    func save(_ defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: "libraryFilter") }

    /// Desktop filter persistence isolated from Console Mode's `.onlyBuilt` ("libraryFilter" == .built) flag.
    static func loadDesktop(_ defaults: UserDefaults = .standard) -> LibraryFilter {
        if let raw = defaults.string(forKey: "desktopLibraryFilter"),
           let filter = LibraryFilter(rawValue: raw), libraryOptions.contains(filter) {
            return filter
        }
        if let legacy = defaults.string(forKey: "libraryFilter"),
           let filter = LibraryFilter(rawValue: legacy), libraryOptions.contains(filter) {
            return filter
        }
        return .owned
    }
    func saveDesktop(_ defaults: UserDefaults = .standard) {
        let normalized = Self.libraryOptions.contains(self) ? self : .owned
        defaults.set(normalized.rawValue, forKey: "desktopLibraryFilter")
    }

    /// The selection and the controller's focus after a switch to this filter. A selected game the filter hides gives way to the
    /// first one it shows, and a focus on a hidden card is dropped, so neither the hero nor the A button reaches a game that is not
    /// on screen.
    func reconcile(
        games: [LibraryGame],
        selectedID: UUID?,
        focused: String?,
        sort: LibrarySort = .name,
        search: String = "",
        lang: Lang = Lang.initial(),
        builtFirst: Bool = true,
        buildingID: UUID? = nil,
        states: [UUID: LibraryArtworkState]? = nil
    ) -> (selectedID: UUID?, focused: String?) {
        let shown = visibleGames(games, matching: search, lang: lang, sort: sort, builtFirst: builtFirst, buildingID: buildingID, states: states)
        let selection = shown.contains { $0.id == selectedID } ? selectedID : shown.first?.id
        guard let focused, focused.hasPrefix("card.") else { return (selection, focused) }
        return (selection, shown.contains { "card." + $0.id.uuidString == focused } ? focused : nil)
    }
}

/// The library's order: built games lead by tier when `builtFirst` is enabled (Mac ready -> iOS built -> building/needs repair -> unbuilt),
/// then by recently played or name. Ties fall to the name shown, then to the title ID, so the order is stable.
enum LibrarySort: String, CaseIterable, Identifiable {
    case recent, name
    var id: String { rawValue }
    var labelKey: String { "sort." + rawValue }

    /// O(N) build tier snapshot: 0 = Mac ready, 1 = iOS built, 2 = building or existing bundle needing repair, 3 = unbuilt source ROM.
    static func buildTier(for game: LibraryGame, state: LibraryArtworkState? = nil, building: Bool = false) -> Int {
        if let state {
            if state.mac { return 0 }
            if state.ios { return 1 }
            if building || state.attention == .building || !game.appPath.isEmpty { return 2 }
            return 3
        }
        if !game.appPath.isEmpty && game.isReady { return 0 }
        if game.hasIOSBuild { return 1 }
        if building || !game.appPath.isEmpty { return 2 }
        return 3
    }

    func ordered(
        _ games: [LibraryGame],
        lang: Lang,
        builtFirst: Bool = true,
        buildingID: UUID? = nil,
        states: [UUID: LibraryArtworkState]? = nil
    ) -> [LibraryGame] {
        // Precompute build tier and cleaned display name once per game (O(N)), never inside the sort comparator.
        games.map { game in
            let tier = builtFirst ? Self.buildTier(for: game, state: states?[game.id], building: buildingID == game.id) : 0
            return (game: game, tier: tier, name: game.displayName(lang))
        }.sorted { left, right in
            if builtFirst && left.tier != right.tier { return left.tier < right.tier }
            if self == .recent, left.game.lastPlayed != right.game.lastPlayed {
                switch (left.game.lastPlayed, right.game.lastPlayed) {
                case let (l?, r?): return l > r
                case (_?, nil): return true
                default: return false
                }
            }
            let order = left.name.localizedStandardCompare(right.name)
            return order == .orderedSame ? left.game.titleID < right.game.titleID : order == .orderedAscending
        }.map(\.game)
    }

    static func load(_ defaults: UserDefaults = .standard) -> LibrarySort {
        LibrarySort(rawValue: defaults.string(forKey: "librarySort") ?? "") ?? .recent
    }
    func save(_ defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: "librarySort") }
}
