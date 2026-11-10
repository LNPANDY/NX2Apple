import Foundation
import NXCore

/// What the library's search and order read of a game (LNPANDY/NX2Apple#895, #937).
extension LibraryGame {
    /// Every name the game answers to: the one shown in `lang`, the player's, the game's own in each language its control data
    /// has, the bundle name and the title ID. Searching "Zelda" finds a game shown in Japanese, and a rename does not hide the
    /// original name.
    func searchTerms(_ lang: Lang) -> [String] {
        [displayName(lang), customName, name, titleID] + titleNames.values.sorted()
    }

    /// True for an empty search. Case and accents are ignored ("pokemon" finds "Pokémon").
    func matches(search: String, lang: Lang) -> Bool {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty || searchTerms(lang).contains {
            !$0.isEmpty && $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

extension GameLibrary {
    /// Play started the Mac app: the game goes to the front of the Recently played order.
    func recordPlayed(_ id: UUID, at date: Date = Date()) {
        guard var game = games.first(where: { $0.id == id }) else { return }
        game.lastPlayed = date
        upsert(game)
    }
}
