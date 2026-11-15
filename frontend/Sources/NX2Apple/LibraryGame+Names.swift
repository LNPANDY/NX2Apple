import Foundation
import NXCore

/// The name the library shows for a game (LNPANDY/NX2Apple#895): the player's (Manage > Rename), else the game's own name in the
/// launcher's language or English from its control data (`titleNames`: the Mac app's `DMTitleNames`, or `TitleNameLookup`), else
/// the bundle name. `name` stays the bundle name, which the artwork lookup and the save discovery match on.
extension LibraryGame {
    /// The name to show in `lang`: the player's, else the game's own name in that language (or English), else `name`.
    func displayName(_ lang: Lang) -> String { customName.isEmpty ? ownName(lang) : customName }

    /// The game's own name in `lang`, ignoring the player's: what Rename offers to go back to.
    func ownName(_ lang: Lang) -> String { GameTitleNames.pick(titleNames, for: lang) ?? fallbackName }

    /// `name` as a name: without a package's decoration, and never a raw title ID while the game's package names it.
    var fallbackName: String {
        let cleaned = Self.cleanedName(name)
        guard Self.isRawName(cleaned, titleID: titleID) else { return cleaned }
        for path in (inputs["base"] ?? []) + (inputs[GameLibrary.folderInput] ?? []) + [sourceFolder] where !path.isEmpty {
            let fromFile = Self.cleanedName(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
            if !Self.isRawName(fromFile, titleID: titleID) { return fromFile }
        }
        return name
    }

    /// An entry without a Mac app whose kept name is a raw title ID or carries a package's decoration (a Mac app's name is its own).
    static func needsBetterName(_ game: LibraryGame) -> Bool {
        !game.isReady && (isRawName(game.name, titleID: game.titleID) || cleanedName(game.name) != game.name)
    }

    /// No name: empty, or a title ID (the game's own or any 16 hex digits).
    static func isRawName(_ name: String, titleID: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.caseInsensitiveCompare(titleID) == .orderedSame
            || trimmed.range(of: "^[0-9A-Fa-f]{16}$", options: .regularExpression) != nil
    }

    /// A package's or folder's name without what dump tools add to it: [title ID], bare 01/04 title ID tokens, [v0], [NSP] and a size such as (0.01 GB).
    static func cleanedName(_ raw: String) -> String {
        let name = raw
            .replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\(\\s*[0-9]+([.,][0-9]+)?\\s*(B|KB|MB|GB|TB|KiB|MiB|GiB|TiB)\\s*\\)", with: "",
                                  options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(
                of: "(?:^|[\\s_\\-]+)0[14][0-9A-Fa-f]{14}(?![0-9A-Fa-f])(?:[_ ]v\\d+)?(?:_[0-9A-Fa-f]{8,64})?(?:\\s*[\\-_]\\s*)?",
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        if let tid = TitleID.parse(raw) { return String(format: "%016llX", tid) }
        return raw
    }
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

    /// Names (when still empty) and source package version read off-thread by `TitleNameLookup`.
    func setPackageMetadata(names: [String: String]?, sourceVersion: String?, for id: UUID) {
        guard var game = games.first(where: { $0.id == id }) else { return }
        var changed = false
        if let names, !names.isEmpty, game.titleNames.isEmpty {
            game.titleNames = names
            changed = true
        }
        if let sourceVersion, game.sourceVersion != sourceVersion {
            game.sourceVersion = sourceVersion
            changed = true
        }
        if changed { upsert(game) }
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
