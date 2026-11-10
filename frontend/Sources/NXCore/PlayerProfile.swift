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

    /// What Play adds to the game's environment for this player, given the game's usual save folder (SaveTransfer.macSave):
    /// - `DM_SAVE`: the player's folder.
    /// - `DM_PSO_USER`: the game's shared `pso_user.tsv` (nvn_mtl.m puts it beside `DM_SAVE` otherwise), so what the game learned
    ///   about its shaders is not learned again for each player.
    /// - `DM_SAVE_SYNC=0`: cloud saves keep one save per game (dm/host/save_sync.c), which is the default player's. Another player
    ///   syncing to it would overwrite that save, the very thing players are for.
    /// A key already in `existing` (a launch option, an env file read by the launcher) is left to it, except `DM_SAVE`.
    package func environment(base: URL, existing: [String: String] = [:]) -> [String: String] {
        guard !isDefault else { return [:] }
        var env = ["DM_SAVE": saveFolder(base: base).path]
        if existing["DM_PSO_USER"] == nil {
            env["DM_PSO_USER"] = base.deletingLastPathComponent().appendingPathComponent("pso_user.tsv").path
        }
        env["DM_SAVE_SYNC"] = "0"
        return env
    }
}
