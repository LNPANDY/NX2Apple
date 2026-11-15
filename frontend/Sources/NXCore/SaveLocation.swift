import Darwin
import Foundation

/// Where a game's save and its cloud copy are, once the one global setup and the game's own choices are put together (#864, #1041).
///
/// Two layers, the game's own choice always winning:
/// - `SaveGlobalSettings`: set up once for every game. A cloud folder (or iCloud Drive) and an optional folder that holds every game's
///   save as `<root>/<TITLE ID>/save`.
/// - `SaveGameOverride`: this game only. A cloud choice (off, or a folder) and a save folder of its own.
/// A cloud setting the game already has in its env.txt or preferences (CloudSaveSync) stands between the two: it is the game's own,
/// so the global setup does not replace it, a per-game override made here does.
package struct SaveGlobalSettings: Codable, Equatable, Sendable {
    /// `icloud`, a folder path, or nil when cloud saves were never set up for every game.
    package var cloudFolder: String?
    package var cloudOn: Bool
    /// Every game's save under `<root>/<TITLE ID>/save`, nil for each game's usual place.
    package var saveRoot: String?
    package init(cloudFolder: String? = nil, cloudOn: Bool = false, saveRoot: String? = nil) {
        self.cloudFolder = cloudFolder; self.cloudOn = cloudOn; self.saveRoot = saveRoot
    }
}

package enum SaveCloudChoice: Codable, Equatable, Sendable {
    case off
    case folder(String)   // `icloud` or a path
}

package struct SaveGameOverride: Codable, Equatable, Sendable {
    package var cloud: SaveCloudChoice?
    /// The folder that holds this game's `save` (DM_SAVE itself), nil for the global or usual place.
    package var saveFolder: String?
    package init(cloud: SaveCloudChoice? = nil, saveFolder: String? = nil) { self.cloud = cloud; self.saveFolder = saveFolder }
    package var isEmpty: Bool { cloud == nil && saveFolder == nil }
}

package enum SaveLocations {
    /// Where an effective value comes from, so the UI can tell the game's own choice from the global default.
    package enum Source: Equatable, Sendable { case standard, libraryFolder, global, game, fallback }

    package struct EffectiveSave: Equatable, Sendable {
        /// DM_SAVE for the default player.
        package var path: URL
        package var source: Source
        /// False when the volume cannot hold a save (no clone or no folder swap): the launcher keeps the save in ~/Library then.
        package var volumeHoldsSaves: Bool
    }

    package struct EffectiveCloud: Equatable, Sendable {
        package var folder: String?   // the value as written: `icloud` or a path, nil for off
        package var source: Source    // .game (override or the game's own env/preferences), .global, .standard (nothing sets it)
        package var isOn: Bool { folder != nil }
    }

    /// The save folder the game reads. `volumeHolds` answers for a path (VolumeSaves.holdsSaves, a fake in tests); nil means unknown and counts as yes.
    package static func effectiveSave(titleID: String, appPath: String, global: SaveGlobalSettings, game: SaveGameOverride,
                                      support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                                      volumeHolds: (String) -> Bool? = { VolumeSaves.holdsSaves(at: $0) }) -> EffectiveSave {
        let usual = support.appendingPathComponent("nxnative").appendingPathComponent(titleID).appendingPathComponent("save")
        func result(_ url: URL, _ source: Source) -> EffectiveSave {
            // A chosen folder on a volume that cannot hold a save is not used: the usual place is, and the UI says why.
            if source == .game || source == .global, volumeHolds(url.path) == false {
                return EffectiveSave(path: usual, source: .fallback, volumeHoldsSaves: false)
            }
            return EffectiveSave(path: url, source: source, volumeHoldsSaves: volumeHolds(url.path) != false)
        }
        if let folder = game.saveFolder, !folder.isEmpty { return result(URL(fileURLWithPath: folder, isDirectory: true), .game) }
        if let root = global.saveRoot, !root.isEmpty {
            return result(URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(titleID.uppercased()).appendingPathComponent("save"), .global)
        }
        if !appPath.isEmpty {
            let folder = URL(fileURLWithPath: appPath).deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".nx2apple-library").path) {
                let library = folder.appendingPathComponent("save").appendingPathComponent(titleID)
                return volumeHolds(library.path) == false
                    ? EffectiveSave(path: usual, source: .fallback, volumeHoldsSaves: false)
                    : EffectiveSave(path: library, source: .libraryFolder, volumeHoldsSaves: true)
            }
        }
        return EffectiveSave(path: usual, source: .standard, volumeHoldsSaves: true)
    }

    /// The cloud setting that counts: this game's override, else what the game already has (`own`, from CloudSaveSync.resolve), else the global setup.
    package static func effectiveCloud(global: SaveGlobalSettings, game: SaveGameOverride, own: CloudSaveSync.Setting) -> EffectiveCloud {
        switch game.cloud {
        case .off?: return EffectiveCloud(folder: nil, source: .game)
        case .folder(let folder)?: return EffectiveCloud(folder: folder, source: .game)
        case nil: break
        }
        if own.source != .none { return EffectiveCloud(folder: own.value.flatMap { CloudSaveSync.folder(for: $0) == nil ? nil : $0 }, source: .game) }
        if global.cloudOn, let folder = global.cloudFolder, !folder.isEmpty { return EffectiveCloud(folder: folder, source: .global) }
        return EffectiveCloud(folder: nil, source: .standard)
    }

    /// The launch environment these settings add. Nothing for a game with nothing set, so a usual start is unchanged.
    /// `DM_SAVE_SYNC` is only written when the global setup or an override decides, never over a setting the game made for itself.
    package static func environment(save: EffectiveSave, cloud: EffectiveCloud) -> [String: String] {
        var env: [String: String] = [:]
        if [.game, .global, .libraryFolder, .fallback].contains(save.source) { env["DM_SAVE"] = save.path.path }
        if cloud.source == .global { env[CloudSaveSync.key] = cloud.folder ?? "0" }
        else if cloud.source == .game { env[CloudSaveSync.key] = cloud.folder ?? "0" }
        return env
    }
}

/// What a volume can do for a save: the host commits a save by cloning the folder and swapping two folders (dm/host/hle_fs.c),
/// which only APFS answers (the same test as dm/mac/launcher.c volume_holds_saves, patch 0105).
package enum VolumeSaves {
    /// true, false, or nil when the volume does not say (or the path is not there yet and no parent answers).
    package static func holdsSaves(at path: String) -> Bool? {
        var probe = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_CAPABILITIES)
        struct Buffer { var length: UInt32 = 0; var caps = vol_capabilities_attr_t() }
        var buffer = Buffer()
        guard getattrlist(probe.path, &list, &buffer, MemoryLayout<Buffer>.size, 0) == 0 else { return nil }
        let need = UInt32(VOL_CAP_INT_CLONE | VOL_CAP_INT_RENAME_SWAP)
        let index = Int(VOL_CAPABILITIES_INTERFACES)
        let valid = withUnsafeBytes(of: buffer.caps.valid) { $0.load(fromByteOffset: index * 4, as: UInt32.self) }
        let have = withUnsafeBytes(of: buffer.caps.capabilities) { $0.load(fromByteOffset: index * 4, as: UInt32.self) }
        guard valid & need == need else { return nil }
        return have & need == need
    }
}

/// Moving a save to another folder, by copy: the old folder stays until the player removes it, nothing is overwritten, and nothing
/// moves while the game runs (the caller refuses then, SaveMigration.Failure.gameRunning).
package enum SaveMigration {
    package enum Failure: Error, Equatable {
        case gameRunning
        case destinationNotEmpty(String)
        case sourceMissing
        case volumeCannotHoldSaves
    }

    /// The names under a save folder that belong to the save: both committed folders (hle_fs.c), never the uncommitted `.work` and `.new`.
    package static let folders = ["save", "save_device"]

    /// Copies the save at `from` (DM_SAVE) and its `_device` sibling to `to`. Fails without touching anything when the game runs, the
    /// destination already holds files, or its volume cannot hold a save. Returns the number of files copied.
    @discardableResult
    package static func copy(from: URL, to: URL, gameRunning: Bool, volumeHolds: (String) -> Bool? = { VolumeSaves.holdsSaves(at: $0) },
                             fm: FileManager = .default) throws -> Int {
        if gameRunning { throw Failure.gameRunning }
        if volumeHolds(to.path) == false { throw Failure.volumeCannotHoldSaves }
        let pairs = [(from, to), (URL(fileURLWithPath: from.path + "_device"), URL(fileURLWithPath: to.path + "_device"))]
        guard pairs.contains(where: { files(in: $0.0) > 0 }) else { throw Failure.sourceMissing }
        for (_, dest) in pairs where files(in: dest) > 0 { throw Failure.destinationNotEmpty(dest.path) }
        var copied = 0
        for (source, dest) in pairs where files(in: source) > 0 { copied += try copyTree(source, dest, fm: fm) }
        return copied
    }

    /// Number of regular files under a folder, AppleDouble files not counted.
    package static func files(in folder: URL, fm: FileManager = .default) -> Int {
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
        var count = 0
        for case let url as URL in walker where !url.lastPathComponent.hasPrefix("._") {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { count += 1 }
        }
        return count
    }

    /// Recursive copy that skips AppleDouble files and never replaces a file.
    @discardableResult
    package static func copyTree(_ from: URL, _ to: URL, fm: FileManager = .default) throws -> Int {
        try fm.createDirectory(at: to, withIntermediateDirectories: true)
        var copied = 0
        for name in try fm.contentsOfDirectory(atPath: from.path) where !name.hasPrefix("._") {
            let source = from.appendingPathComponent(name), dest = to.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            fm.fileExists(atPath: source.path, isDirectory: &isDirectory)
            if isDirectory.boolValue { copied += try copyTree(source, dest, fm: fm) }
            else if !fm.fileExists(atPath: dest.path) { try fm.copyItem(at: source, to: dest); copied += 1 }
        }
        return copied
    }
}
