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
    case owned, built
    var id: String { rawValue }
    var labelKey: String { "filter." + rawValue }

    /// Owned shows every game without reading its build, so the default filter costs nothing per card.
    func includes(_ game: LibraryGame) -> Bool { self == .owned || game.isReady || game.hasIOSBuild }

    /// Use Finder-style ordering on the display title. Different games can have the same title.
    /// The search finds a game by the name shown in `lang` or by its bundle name.
    func visibleGames(_ games: [LibraryGame], matching search: String = "", lang: Lang = Lang.initial()) -> [LibraryGame] {
        games.filter { (search.isEmpty || $0.displayName(lang).localizedCaseInsensitiveContains(search) || $0.name.localizedCaseInsensitiveContains(search)) && includes($0) }
            .sorted { left, right in
                let order = left.displayName(lang).localizedStandardCompare(right.displayName(lang))
                return order == .orderedSame ? left.titleID < right.titleID : order == .orderedAscending
            }
    }

    static func load(_ defaults: UserDefaults = .standard) -> LibraryFilter {
        LibraryFilter(rawValue: defaults.string(forKey: "libraryFilter") ?? "") ?? .owned
    }
    func save(_ defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: "libraryFilter") }

    /// The selection and the controller's focus after a switch to this filter. A selected game the filter hides gives way to the
    /// first one it shows, and a focus on a hidden card is dropped, so neither the hero nor the A button reaches a game that is not
    /// on screen.
    func reconcile(games: [LibraryGame], selectedID: UUID?, focused: String?) -> (selectedID: UUID?, focused: String?) {
        let shown = visibleGames(games)
        let selection = shown.contains { $0.id == selectedID } ? selectedID : shown.first?.id
        guard let focused, focused.hasPrefix("card.") else { return (selection, focused) }
        return (selection, shown.contains { "card." + $0.id.uuidString == focused } ? focused : nil)
    }
}
