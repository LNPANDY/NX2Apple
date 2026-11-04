import Foundation

/// Keeps the game files out of the iCloud and device backup (#618). `Documents` is backed up unless a file or folder is marked, and a
/// game's data (`romfs.img`, add-on content, shader caches, scratch files) is many GB, so the backup passed 5 GB and the phone asked for
/// more iCloud space. The game data can always be sent again from the Mac, so it does not belong in the backup.
///
/// The saves stay in the backup. They are small (a few MB for a game), they cannot be made again, and a player who gets a new phone
/// from a backup wants them. Every entry of a game's folder whose name starts with `save` is left alone (`GameDeletion.isSave`, the same
/// rule that decides what deleting a game may remove), and so are small plain files (`env.txt`, `profile.tsv`, `log.txt`, settings
/// text). Everything else in `Documents/games/<title ID>/` is marked, and so are the old single-game names at the top of `Documents`
/// (`romfs*`, `aoc`, `temp`, which `dm/ios/Sources/main.m` marks for the one-game app). A framework is part of the app bundle, which
/// is never backed up, and the engine's own caches are in `Library/Caches`, which is not either, so nothing else needs a mark.
///
/// Marking a folder covers everything inside it, and marking is one `setResourceValues` call, so `apply` is cheap and safe to run on
/// every start: an entry that is marked already is not written again.
public enum BackupExclusion {
    /// A file in a game's folder up to this size counts as a setting, not as game data, and stays in the backup.
    public static let smallFileLimit = 1_000_000

    public static func isExcluded(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) ?? false
    }

    /// Marks one entry. Returns true when it changed (it was not marked before), false when it was marked already or could not be.
    @discardableResult
    public static func exclude(_ url: URL) -> Bool {
        guard !isExcluded(url) else { return false }
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        return (try? target.setResourceValues(values)) != nil
    }

    /// Whether `name` in a game's folder is game data (to mark) and not a save or a small setting file.
    static func isGameData(_ url: URL, fileManager fm: FileManager) -> Bool {
        if GameDeletion.isSave(url.lastPathComponent) { return false }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory == true { return true }
        return (values?.fileSize ?? Int.max) > smallFileLimit
    }

    /// The entries of one game's folder that are game data.
    public static func gameData(in folder: URL, fileManager fm: FileManager = .default) -> [URL] {
        let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { isGameData($0, fileManager: fm) }.sorted { $0.path < $1.path }
    }

    /// The old single-game names at the top of `Documents`: a RomFS image or tree in any letter case, `aoc` and `temp`.
    static func isLegacyTopLevelData(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("romfs") || lower == "aoc" || lower == "temp"
    }

    /// Marks the game data under `appDataRoot` (`Documents/games`) and the single-game names in `Documents`. Returns what was newly
    /// marked. Does nothing for a folder that does not exist, and never touches a save.
    @discardableResult
    public static func apply(appDataRoot: URL, fileManager fm: FileManager = .default) -> [URL] {
        var changed: [URL] = []
        let games = (try? fm.contentsOfDirectory(at: appDataRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for folder in games where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            for url in gameData(in: folder, fileManager: fm) where exclude(url) { changed.append(url) }
        }
        let documents = appDataRoot.deletingLastPathComponent()
        for url in (try? fm.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)) ?? []
        where isLegacyTopLevelData(url.lastPathComponent) && exclude(url) { changed.append(url) }
        return changed
    }
}
