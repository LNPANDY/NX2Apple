import Foundation

/// A player of this Mac: each one keeps their own saves, so one player's progress never overwrites another's.
///
/// The engine has a single Switch user (dm/host/hle_account.c), so a player is not a Switch account: it is a save folder.
/// The launcher's Play hands the game a `DM_SAVE` of the player's own (dm/mac/launcher.c keeps a `DM_SAVE` that is already set).
/// The default player has no environment at all: its saves stay where they always were, so nothing moves for anyone who never
/// adds a second player.
package struct PlayerProfile: Codable, Equatable, Identifiable, Sendable {
    package static let defaultID = "default"

    package var id: String     // the folder name, fixed when the player is created: renaming keeps the saves
    package var name: String

    package init(id: String, name: String) { self.id = id; self.name = name }

    package var isDefault: Bool { id == Self.defaultID }

    /// A folder name for a new player: lowercase letters, digits and dashes from the name, made unique among `taken`.
    package static func slug(for name: String, taken: Set<String>) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        var base = ""
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII { base.unicodeScalars.append(scalar) }
            else if !base.isEmpty && !base.hasSuffix("-") { base += "-" }
        }
        while base.hasSuffix("-") { base.removeLast() }
        if base.isEmpty || base == defaultID { base = "player" }
        var candidate = base, n = 2
        while taken.contains(candidate) { candidate = "\(base)-\(n)"; n += 1 }
        return candidate
    }

    /// The player's save folder beside the game's usual one: `<parent>/profiles/<id>/<name>`. For `~/Library/Application
    /// Support/nxnative/<title ID>/save` that is `…/<title ID>/profiles/<id>/save`, for a library folder's `save/<title ID>` it is
    /// `save/profiles/<id>/<title ID>`. The host puts `.work`, `.new` and `_device` beside it (dm/host/hle_fs.c), all inside the
    /// player's folder. The default player keeps `base`.
    package func saveFolder(base: URL) -> URL {
        guard !isDefault else { return base }
        return base.deletingLastPathComponent().appendingPathComponent("profiles").appendingPathComponent(id)
            .appendingPathComponent(base.lastPathComponent)
    }

    /// The most the engine keeps of a nickname: `nn::account::Nickname` holds 32 bytes of UTF-8 and a terminator
    /// (dm/host/hle_account.c copies at most 32 bytes of `DM_NICK`).
    package static let nicknameBytes = 32

    /// The name the game shows for its user (`nn::account::GetNickname`), from the player's name: control characters and line
    /// breaks become spaces, and it is cut to `nicknameBytes` on a character boundary, so the engine never cuts a character in
    /// half. nil for the default player not yet renamed: the game keeps the engine's "Player".
    package var nickname: String? {
        // Only control characters (Cc) and line breaks become spaces. A lone format character (Cf, such as a direction override)
        // is dropped, but one inside a character stays: a zero width joiner holds a family emoji together.
        var cleaned = ""
        for character in name {
            let scalars = character.unicodeScalars
            if scalars.contains(where: { $0.properties.generalCategory == .control || CharacterSet.newlines.contains($0) }) {
                cleaned.append(" ")
            } else if !scalars.allSatisfy({ $0.properties.generalCategory == .format }) {
                cleaned.append(character)
            }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        var cut = ""
        for character in cleaned {
            guard cut.utf8.count + String(character).utf8.count <= Self.nicknameBytes else { break }
            cut.append(character)
        }
        cut = cut.trimmingCharacters(in: .whitespaces)
        return cut.isEmpty ? nil : cut
    }

    /// `DM_NICK` for Play: the player's `nickname` (#1128), also for the default player once renamed. A `DM_NICK` already in
    /// `existing` (a launch option) is left to it, and a player without a nickname adds nothing.
    package func nicknameEnvironment(existing: [String: String] = [:]) -> [String: String] {
        guard existing["DM_NICK"] == nil, let nickname else { return [:] }
        return ["DM_NICK": nickname]
    }

    /// What Play adds to the game's environment for this player, given the game's usual save folder (SaveTransfer.macSave):
    /// - `DM_SAVE`: the player's folder.
    /// - `DM_PSO_USER`: the game's shared `pso_user.tsv` (nvn_mtl.m puts it beside `DM_SAVE` otherwise), so what the game learned
    ///   about its shaders is not learned again for each player.
    /// - `DM_SAVE_SYNC=0`: cloud saves keep one save per game (dm/host/save_sync.c), which is the default player's. Another player
    ///   syncing to it would overwrite that save, the very thing players are for.
    /// A key already in `existing` (a launch option, an env file read by the launcher) is left to it, except `DM_SAVE`.
    /// `engine` names the keys (SaveEngine): an app nxkit built gets `NXKIT_SAVE`, `NXKIT_SAVE_SYNC=0`, and plays as the game's
    /// user 1 under the player's name (`NXKIT_USER`, `NXKIT_NICK`), the default player too once renamed.
    package func environment(base: URL, existing: [String: String] = [:], engine: any SaveEngine = DmSaveEngine()) -> [String: String] {
        guard engine.managesSavesInLauncher else { return [:] }
        var env = engine.playerEnvironment(name: name)
        guard !isDefault else { return name.isEmpty ? [:] : env }
        env[engine.saveKey] = saveFolder(base: base).path
        if let key = engine.psoUserKey, existing[key] == nil {
            env[key] = base.deletingLastPathComponent().appendingPathComponent("pso_user.tsv").path
        }
        env[engine.syncKey] = "0"
        return env
    }
}
