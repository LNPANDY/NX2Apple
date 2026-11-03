import Foundation

/// A game's mods (#557): folders in `Documents/games/<title ID>/mods/`, each holding RomFS files that replace the game's own
/// (`DM_ROMFS_OVERLAY`, `hle_fs.c`). The layout is the Mac launcher's `GameMod` (`mods/<title ID>/<mod>`): the files are in
/// `<mod>/romfs`, in an Atmosphere layout (`<mod>/atmosphere/contents/<title ID>/romfs`, `<mod>/contents/<title ID>/romfs`)
/// or in the folder itself. A mod with only `exefs/` changes the game's code, which the rewriter does not take, so it is
/// skipped. A name that starts with a dot is skipped too. The folder belongs to one game, so a mod never reaches another one.
public enum GameMods {
    /// The RomFS folder of each usable mod, in name order (Finder order).
    public static func romfsFolders(in mods: URL, titleID: String, _ fm: FileManager = .default) -> [String] {
        let names = ((try? fm.contentsOfDirectory(atPath: mods.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        return names.compactMap { name in
            var dir: ObjCBool = false
            let mod = mods.appendingPathComponent(name)
            guard fm.fileExists(atPath: mod.path, isDirectory: &dir), dir.boolValue else { return nil }
            let candidates = ["romfs", "atmosphere/contents/\(titleID)/romfs", "contents/\(titleID)/romfs"].map { mod.appendingPathComponent($0).path }
            if let found = candidates.first(where: { fm.fileExists(atPath: $0) }) { return found }
            let top = ((try? fm.contentsOfDirectory(atPath: mod.path)) ?? []).filter { !$0.hasPrefix(".") }
            let codeOnly = !top.isEmpty && top.allSatisfy { ["exefs", "atmosphere", "contents"].contains($0.lowercased()) }
            return codeOnly || top.isEmpty ? nil : mod.path
        }
    }

    /// The `DM_ROMFS_OVERLAY` value for the usable mods, or nil when the folder is missing or holds none. Where two mods
    /// replace one file, the one first in name order wins (the host looks in the folders in order), as on the Mac.
    public static func overlay(in mods: URL, titleID: String, _ fm: FileManager = .default) -> String? {
        let folders = romfsFolders(in: mods, titleID: titleID, fm)
        return folders.isEmpty ? nil : folders.joined(separator: ":")
    }
}
