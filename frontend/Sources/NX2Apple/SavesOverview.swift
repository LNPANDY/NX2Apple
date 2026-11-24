import Foundation
import NXCore
import NXModel

/// The Saves page's data (#1079): every built Mac game with where its save is and why, when it was last written, its size,
/// whether it syncs to the cloud, and a save of the game found in another place while its own folder is empty (#1041: an app
/// moved into a subfolder left its save behind). It reads what the launcher already reads (SaveLocations, SaveTransfer,
/// GameCloudSaves) and writes only what Launch options › Cloud saves writes, so games built before the page need no rebuild.
struct SaveOverviewRow: Identifiable, Equatable {
    let id: UUID
    let titleID: String
    let name: String
    /// The folder the game reads for the active player (DM_SAVE).
    let folder: URL
    let source: SaveLocations.Source
    let volumeHoldsSaves: Bool
    let cloud: SaveLocations.EffectiveCloud
    /// An env.txt line decides the cloud: the switch still works (GameCloudSaves rewrites the player's env.txt), the row says so.
    let cloudFromEnv: Bool
    /// The newest save file, its folder's size and file count; nil and 0 while there is no save.
    var newest: Date?
    var bytes: Int64 = 0
    var files = 0
    /// A folder of another place that holds this game's save while `folder` holds none.
    var elsewhere: URL?

    var hasSave: Bool { files > 0 }
}

enum SavesOverview {
    /// The games the page lists: those with a Mac build, by name.
    static func games(_ games: [LibraryGame], lang: Lang) -> [LibraryGame] {
        LibrarySort.name.ordered(games.filter(\.isReady), lang: lang)
    }

    /// One row per game, without the folder statistics (`measured` fills them, off the main thread).
    static func rows(_ games: [LibraryGame], lang: Lang, global: SaveGlobalSettings, game override: (String) -> SaveGameOverride,
                     player: PlayerProfile?, cloudSetting: (LibraryGame) -> CloudSaveSync.Setting,
                     support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                     volumeHolds: (String) -> Bool? = { VolumeSaves.holdsSaves(at: $0) }) -> [SaveOverviewRow] {
        Self.games(games, lang: lang).map { game in
            let own = override(game.titleID)
            let save = SaveLocations.effectiveSave(titleID: game.titleID, appPath: game.appPath, global: global, game: own,
                                                   support: support, volumeHolds: volumeHolds)
            let setting = cloudSetting(game)
            let cloud = SaveLocations.effectiveCloud(global: global, game: own, own: setting)
            return SaveOverviewRow(id: game.id, titleID: game.titleID, name: game.displayName(lang),
                                   folder: player?.saveFolder(base: save.path) ?? save.path, source: save.source,
                                   volumeHoldsSaves: save.volumeHoldsSaves, cloud: cloud,
                                   cloudFromEnv: own.cloud == nil && [.playerEnv, .appEnv].contains(setting.source))
        }
    }

    /// The row with its folder measured and, while that folder holds no save, the first other place that does.
    static func measured(_ row: SaveOverviewRow, appPath: String, player: PlayerProfile?,
                         support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                         fm: FileManager = .default) -> SaveOverviewRow {
        var row = row
        let stats = folderStats(row.folder, fm: fm)
        row.newest = stats.newest; row.bytes = stats.bytes; row.files = stats.files
        if !row.hasSave {
            row.elsewhere = otherPlaces(titleID: row.titleID, appPath: appPath, support: support)
                .map { player?.saveFolder(base: $0) ?? $0 }
                .first { $0.standardizedFileURL != row.folder.standardizedFileURL && folderStats($0, fm: fm).files > 0 }
        }
        return row
    }

    /// The places the launcher has put this game's save before, the default player's: the usual folder in ~/Library, beside
    /// the app in a library folder, and beside the folder the app sits in (an app moved one folder down, #1041).
    static func otherPlaces(titleID: String, appPath: String, support: URL) -> [URL] {
        var places = [support.appendingPathComponent("nxnative").appendingPathComponent(titleID).appendingPathComponent("save")]
        if !appPath.isEmpty {
            let folder = URL(fileURLWithPath: appPath).deletingLastPathComponent()
            places.append(folder.appendingPathComponent("save").appendingPathComponent(titleID))
            places.append(folder.deletingLastPathComponent().appendingPathComponent("save").appendingPathComponent(titleID))
        }
        return places
    }

    /// The newest regular file, the bytes and the count of a save folder. Finder's `._` files do not count.
    static func folderStats(_ folder: URL, fm: FileManager = .default) -> (newest: Date?, bytes: Int64, files: Int) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let walk = fm.enumerator(at: folder, includingPropertiesForKeys: keys) else { return (nil, 0, 0) }
        var newest: Date?, bytes: Int64 = 0, files = 0
        for case let url as URL in walk where !url.lastPathComponent.hasPrefix("._") {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            files += 1
            bytes += Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
            if let date = v.contentModificationDate { newest = max(newest ?? date, date) }
        }
        return (newest, bytes, files)
    }

    /// The value the switch turns a game's cloud saves on with: the folder of the setup for every game, else iCloud Drive.
    static func cloudValue(global: SaveGlobalSettings) -> String {
        if let folder = global.cloudFolder, !folder.isEmpty { return folder }
        return "icloud"
    }

    /// The switch: the same change as Launch options › Cloud saves (CloudSavesCard), this game's own choice. On syncs through
    /// `cloudValue`, off keeps the game off even while the setup for every game is on.
    @MainActor static func setCloud(_ on: Bool, titleID: String, saves: GameCloudSaves, settings: SaveSettingsStore) throws {
        var value = settings.game(titleID)
        if on {
            let folder = cloudValue(global: settings.global)
            try saves.choose(folder)
            value.cloud = .folder(folder)
        } else {
            try saves.turnOff()
            value.cloud = .off
        }
        settings.setGame(titleID, value)
    }

    /// The l10n key for where a save folder comes from.
    static func sourceKey(_ source: SaveLocations.Source) -> String {
        switch source {
        case .standard: return "savespage.from.standard"
        case .libraryFolder: return "savespage.from.library"
        case .global: return "savespage.from.global"
        case .game: return "savespage.from.game"
        case .fallback: return "savespage.from.fallback"
        }
    }
}
