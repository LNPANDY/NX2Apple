import Foundation
import NXCore

enum BuildInventoryFilter: String, CaseIterable {
    case owned, built, notBuilt
    var labelKey: String { self == .owned ? "builds.allGames" : "filter." + rawValue }
    func includes(_ entry: BuildInventoryEntry) -> Bool {
        let built = entry.mac || entry.mobile != .none
        return self == .owned || (self == .built ? built : !built)
    }
    func adjusted(_ direction: Int) -> Self {
        let values = Self.allCases, index = values.firstIndex(of: self) ?? 0
        return values[(index + direction % values.count + values.count) % values.count]
    }
}
