import Foundation

/// Deleting a game in the shell (#559). The game's code is a framework inside the signed app, and an app cannot change its own
/// bundle: the code signature seals every file in it, and the bundle is read-only on the device. So the game's framework stays
/// until the app is installed again without it. What the shell can delete is the game's folder in `Documents/games/<title ID>/`
/// (game data, add-on content, temp files, its log), and it takes the game off the list.
///
/// The game stays off the list while the app holds the same build of it and its folder has no game data again. A new build of
/// the game in a later install, or game data sent again from the Mac, brings it back.
public enum GameDeletion {
    /// The per-game defaults key that marks the game as deleted. Its value is the build that was deleted (`stamp`).
    public static let deletedKey = "shell.deletedBuild"

    /// The save folders in the game's folder (dm/host/hle_fs.c: `save`, `save_device` for a game with device save data, and
    /// their `.work` and `.new` copies of a session). Every name that starts with `save` stays unless the player chose to delete
    /// the saves too, so no layout of the engine's can lose one.
    public static func isSave(_ name: String) -> Bool { name.hasPrefix("save") }

    /// Which build of the game the app holds: the manifest's build time, else what the manifest says about the build. A
    /// framework that could not be read is named by its folder.
    public static func stamp(_ entry: CatalogueEntry) -> String {
        guard let m = entry.manifest else { return "folder:" + entry.directory.lastPathComponent }
        if let built = m.builtAt, !built.isEmpty { return "built:" + built }
        return ["manifest", m.displayVersion, m.packageVersion, m.chain, m.romfsIdentity, String(m.bytes ?? 0)].joined(separator: ":")
    }

    /// What deleting removes from the game's folder: everything, or everything except the saves. Paths of the folder's
    /// top-level entries, sorted. Empty when the folder does not exist.
    public static func removals(in folder: URL, saves: Bool, fileManager fm: FileManager = .default) -> [URL] {
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { saves || !isSave($0) }.sorted().map { folder.appendingPathComponent($0) }
    }

    /// Deletes what `removals` names, and the folder itself when nothing is left in it. Returns the paths that could not be
    /// deleted.
    @discardableResult
    public static func delete(in folder: URL, saves: Bool, fileManager fm: FileManager = .default) -> [URL] {
        var failed: [URL] = []
        for url in removals(in: folder, saves: saves, fileManager: fm) {
            do { try fm.removeItem(at: url) } catch { failed.append(url) }
        }
        if ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? ["?"]).isEmpty { try? fm.removeItem(at: folder) }
        return failed
    }
}
