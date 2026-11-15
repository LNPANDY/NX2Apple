import Foundation

/// Claims loose `DMROMFS1` images placed under `Documents/` (for example via Files or Finder file sharing) into their matching
/// `Documents/games/<titleID>/romfs.img` folder by zero-copy rename (#1229-style sideloading without modifying signed app bundles).
public enum LooseRomfsClaimer {
    /// Scans `documents` (top-level `.img` files and one-level subdirectories outside `Documents/games/`) for complete
    /// `DMROMFS1` images whose identity uniquely matches an entry in `entries`, moving them into `appDataRoot/<titleID>/romfs.img`.
    /// Also moves sibling `aoc/` and `msl/` folders when claiming a single-game subdirectory and the destination does not have them.
    /// Returns the destination `romfs.img` URLs that were claimed.
    @discardableResult
    public static func claimAll(documents: URL, appDataRoot: URL, entries: [CatalogueEntry],
                                fileManager fm: FileManager = .default) -> [URL] {
        let map = identityMap(from: entries)
        guard !map.isEmpty,
              let topItems = contents(of: documents, fileManager: fm) else { return [] }

        let gamesPath = appDataRoot.standardizedFileURL.path
        let topNames = topItems.map(\.lastPathComponent)
        var claimed: [URL] = []

        for item in topItems {
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isSymbolicLink != true else { continue }

            if values?.isRegularFile == true {
                guard item.pathExtension.lowercased() == "img",
                      !hasPartFiles(for: item.lastPathComponent, inNames: topNames),
                      let match = matchEntry(for: item, map: map),
                      let dest = claimImageFile(item, titleID: match.titleID, identity: match.identity,
                                                appDataRoot: appDataRoot, fileManager: fm) else { continue }
                claimed.append(dest)
            } else if values?.isDirectory == true {
                let nameLower = item.lastPathComponent.lowercased()
                guard nameLower != "games",
                      item.standardizedFileURL.path != gamesPath else { continue }
                claimed.append(contentsOf: claimSubdirectory(item, map: map, appDataRoot: appDataRoot, fileManager: fm))
            }
        }
        if !claimed.isEmpty {
            for dest in claimed { BackupExclusion.exclude(dest) }
            BackupExclusion.apply(appDataRoot: appDataRoot, fileManager: fm)
        }
        return claimed
    }

    private static func identityMap(from entries: [CatalogueEntry]) -> [RomfsIdentity: String] {
        var map: [RomfsIdentity: String] = [:]
        var ambiguous = Set<RomfsIdentity>()
        for entry in entries {
            let id = entry.id
            guard !id.isEmpty, !id.contains("/"), id != ".", id != "..",
                  let raw = entry.manifest?.romfsIdentity,
                  let identity = RomfsIdentity.parse(raw),
                  !ambiguous.contains(identity) else { continue }
            if let existing = map[identity] {
                if existing != id {
                    map.removeValue(forKey: identity)
                    ambiguous.insert(identity)
                }
            } else {
                map[identity] = id
            }
        }
        return map
    }

    private static func matchEntry(for fileURL: URL, map: [RomfsIdentity: String]) -> (titleID: String, identity: RomfsIdentity)? {
        guard let identity = RomfsIdentity.ofImage(at: fileURL),
              let titleID = map[identity] else { return nil }
        return (titleID, identity)
    }

    private static func claimSubdirectory(_ dir: URL, map: [RomfsIdentity: String], appDataRoot: URL,
                                          fileManager fm: FileManager) -> [URL] {
        guard let children = contents(of: dir, fileManager: fm) else { return [] }
        let names = children.map(\.lastPathComponent)
        // Skip directories holding in-progress split transfers or joins.
        guard !names.contains(where: { DataParts.parse($0) != nil || $0.lowercased().hasSuffix(DataParts.joinSuffix) }) else {
            return []
        }

        var matched: [(url: URL, titleID: String, identity: RomfsIdentity)] = []
        var extraDirs: [(url: URL, canonicalName: String)] = []
        for child in children {
            let values = try? child.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isSymbolicLink != true else { continue }
            if values?.isRegularFile == true, child.pathExtension.lowercased() == "img",
               let hit = matchEntry(for: child, map: map) {
                matched.append((child, hit.titleID, hit.identity))
            } else if values?.isDirectory == true {
                let lower = child.lastPathComponent.lowercased()
                if lower == "aoc" || lower == "msl" {
                    extraDirs.append((child, lower))
                }
            }
        }
        guard !matched.isEmpty else { return [] }

        var claimed: [URL] = []
        for entry in matched {
            if let dest = claimImageFile(entry.url, titleID: entry.titleID, identity: entry.identity,
                                         appDataRoot: appDataRoot, fileManager: fm) {
                claimed.append(dest)
            }
        }
        // Only migrate sibling aoc/ and msl/ when every claimed image in the folder targets the exact same game.
        let targetTitles = Set(matched.map(\.titleID))
        if matched.count == 1, claimed.count == 1, let soleTitleID = targetTitles.first {
            let targetDir = appDataRoot.appendingPathComponent(soleTitleID, isDirectory: true)
            for extra in extraDirs {
                let dest = targetDir.appendingPathComponent(extra.canonicalName, isDirectory: true)
                if !fm.fileExists(atPath: dest.path) {
                    try? fm.moveItem(at: extra.url, to: dest)
                }
            }
        }
        removeDirectoryIfEmpty(dir, fileManager: fm)
        return claimed
    }

    private static func claimImageFile(_ source: URL, titleID: String, identity: RomfsIdentity,
                                       appDataRoot: URL, fileManager fm: FileManager) -> URL? {
        let targetDir = appDataRoot.appendingPathComponent(titleID, isDirectory: true)
        let targetImg = targetDir.appendingPathComponent("romfs.img")

        if fm.fileExists(atPath: targetDir.path) {
            if fm.fileExists(atPath: targetImg.path) { return nil }
            if let existing = contents(of: targetDir, fileManager: fm) {
                for item in existing {
                    let name = item.lastPathComponent
                    if DataParts.parse(name) != nil || name.lowercased().hasSuffix(DataParts.joinSuffix) {
                        return nil
                    }
                    let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    if values?.isSymbolicLink != true,
                       values?.isRegularFile == true,
                       item.pathExtension.lowercased() == "img",
                       RomfsIdentity.ofImage(at: item) == identity {
                        return nil
                    }
                }
            }
        } else {
            do {
                try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
            } catch {
                return nil
            }
        }

        do {
            try fm.moveItem(at: source, to: targetImg)
            return targetImg
        } catch {
            return nil
        }
    }

    private static func contents(of dir: URL, fileManager fm: FileManager) -> [URL]? {
        try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
    }

    private static func hasPartFiles(for fileName: String, inNames names: [String]) -> Bool {
        let lower = fileName.lowercased()
        let joinLower = lower + DataParts.joinSuffix
        return names.contains { candidate in
            let candLower = candidate.lowercased()
            if candLower == joinLower { return true }
            return DataParts.parse(candidate)?.file.lowercased() == lower
        }
    }

    private static func removeDirectoryIfEmpty(_ dir: URL, fileManager fm: FileManager) {
        guard let remaining = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        if remaining == [".DS_Store"] {
            try? fm.removeItem(at: dir.appendingPathComponent(".DS_Store"))
        }
        guard let after = try? fm.contentsOfDirectory(atPath: dir.path), after.isEmpty else { return }
        try? fm.removeItem(at: dir)
    }
}
