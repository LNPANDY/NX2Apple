import Foundation
import NXCore

/// The name the library shows for a game (LNPANDY/NX2Apple#895): the player's (Manage > Rename), else the game's own name in the
/// launcher's language or English from its control data (`titleNames`: the Mac app's `DMTitleNames`, or `TitleNameLookup`), else
/// the bundle name. `name` stays the bundle name, which the artwork lookup and the save discovery match on.
extension LibraryGame {
    /// The name to show in `lang`: the player's, else the game's own name in that language (or English), else `name`.
    func displayName(_ lang: Lang) -> String { customName.isEmpty ? ownName(lang) : customName }

    /// The game's own name in `lang`, ignoring the player's: what Rename offers to go back to.
    func ownName(_ lang: Lang) -> String { GameTitleNames.pick(titleNames, for: lang) ?? name }
}

extension GameLibrary {
    /// The player's name for a game, trimmed. Empty goes back to the game's own names.
    func rename(_ id: UUID, to name: String) {
        guard var game = games.first(where: { $0.id == id }) else { return }
        game.customName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        upsert(game)
    }

    /// The names `TitleNameLookup` read for a game that had none (an app packed with them meanwhile wins).
    func setTitleNames(_ names: [String: String], for id: UUID) {
        guard var game = games.first(where: { $0.id == id }), game.titleNames.isEmpty else { return }
        game.titleNames = names
        upsert(game)
    }

    /// A ready entry the folder scan finds again learns the names of its app: one from before the names were kept, or rebuilt since.
    /// An app without names (packed before the key) leaves what TitleNameLookup read.
    func learnTitleNames(_ game: LibraryGame, from app: MacGameBundle, at url: URL) {
        guard game.appPath == url.standardizedFileURL.path, !app.titleNames.isEmpty, game.titleNames != app.titleNames else { return }
        var game = game
        game.titleNames = app.titleNames
        upsert(game)
    }
}
