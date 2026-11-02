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

    static func load(_ defaults: UserDefaults = .standard) -> LibraryFilter {
        LibraryFilter(rawValue: defaults.string(forKey: "libraryFilter") ?? "") ?? .owned
    }
    func save(_ defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: "libraryFilter") }

    /// The selection and the controller's focus after a switch to this filter. A selected game the filter hides gives way to the
    /// first one it shows, and a focus on a hidden card is dropped, so neither the hero nor the A button reaches a game that is not
    /// on screen.
    func reconcile(games: [LibraryGame], selectedID: UUID?, focused: String?) -> (selectedID: UUID?, focused: String?) {
        let shown = games.filter(includes)
        let selection = shown.contains { $0.id == selectedID } ? selectedID : shown.first?.id
        guard let focused, focused.hasPrefix("card.") else { return (selection, focused) }
        return (selection, shown.contains { "card." + $0.id.uuidString == focused } ? focused : nil)
    }
}
