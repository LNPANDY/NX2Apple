import Foundation

/// Specific reasons why a folder picked for a game's data did not satisfy `DataLocator`.
/// Runs off the main actor with strict depth and entry bounds so a large external drive or iCloud folder never stalls the UI.
enum DataFolderFinding: Equatable, Sendable {
    /// A valid image or tree for this game sits deeper inside `subfolder` (relative to the picked folder).
    case nestedGameData(subfolder: String)
    /// An undownloaded `.icloud` placeholder file was found.
    case icloudPlaceholder
    /// Unjoined `.nxpart` split files were found outside `Documents/games/<titleID>`.
    case unjoinedSplitParts
    /// Game data belonging to another game (`otherTitleOrID` when known, nil when unknown) was found.
    case wrongGame(otherTitleOrID: String?)
    /// Nothing recognizable was found in the folder.
    case none
}

enum DataFolderDiagnostics {
    static let maxDepth = 3
    static let maxEntries = 2000

    /// Inspects `folder` up to `maxDepth` levels down (at most `maxEntries` directory entries total, symbolic links skipped)
    /// after `DataLocator` did not find `manifest`'s data at the root or `<folder>/<titleID>/`.
    /// Scans all allowed depths before choosing the highest-priority finding so a deeper exact match is never shadowed by a shallow sibling.
    static func diagnose(folder: URL, manifest: GameManifest, knownTitles: [String: String] = [:],
                         fileManager fm: FileManager = .default) -> DataFolderFinding {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { return .none }

        let expectedIdentity = RomfsIdentity.parse(manifest.romfsIdentity)
        let targetID = manifest.titleID.uppercased()

        var seenEntries = 0
        var nestedMatch: String?
        var sawICloudPlaceholder = false
        var sawSplitParts = false
        var sawWrongGame = false
        var wrongGameLabel: String?

        func recordWrongGame(_ candidateLabel: String?) {
            sawWrongGame = true
            if wrongGameLabel == nil, let candidateLabel, !candidateLabel.isEmpty {
                wrongGameLabel = candidateLabel
            }
        }

        func isTitleID(_ name: String) -> Bool {
            name.count == 16 && name.utf8.allSatisfy {
                ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
                    || ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "f"))
                    || ($0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "F"))
            }
        }

        func matchesTargetData(in dir: URL) -> Bool {
            DataLocator.romfs(in: dir, manifest: manifest, fm, allowPickedFile: false, acceptsImage: { image in
                guard let expectedIdentity else { return true }
                return RomfsIdentity.ofImage(at: image) == expectedIdentity
            }) != nil
        }

        func visit(_ dir: URL, relativePrefix: String, depth: Int) {
            guard seenEntries < maxEntries else { return }
            let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
            // Include hidden files so `.romfs.img.icloud` placeholders are visible, while skipping hidden directories below.
            guard let rawChildren = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(resourceKeys), options: []) else {
                return
            }
            let children = rawChildren.sorted { $0.lastPathComponent < $1.lastPathComponent }
            var subdirs: [(url: URL, rel: String, name: String)] = []

            for url in children {
                if seenEntries >= maxEntries { break }
                seenEntries += 1
                let name = url.lastPathComponent
                if name == "." || name == ".." || name == ".DS_Store" { continue }
                let values = try? url.resourceValues(forKeys: resourceKeys)
                if values?.isSymbolicLink == true { continue }

                let lower = name.lowercased()
                if values?.isDirectory == true {
                    if name.hasPrefix(".") { continue }
                    let rel = relativePrefix.isEmpty ? name : "\(relativePrefix)/\(name)"
                    // Check whether a deeper folder actually holds this game's own data.
                    let checkedByLocator = depth == 0 && name.caseInsensitiveCompare(manifest.titleID) == .orderedSame
                    if !checkedByLocator, nestedMatch == nil, matchesTargetData(in: url) {
                        nestedMatch = rel
                    } else if isTitleID(name), name.uppercased() != targetID {
                        let upper = name.uppercased()
                        if dirHasAnyRomfsPayload(url, fm: fm) {
                            recordWrongGame(knownTitles[upper] ?? upper)
                        }
                    }
                    if depth < maxDepth {
                        subdirs.append((url, rel, name))
                    }
                } else {
                    if lower.hasSuffix(".icloud") {
                        sawICloudPlaceholder = true
                        continue
                    }
                    if name.hasPrefix(".") { continue }
                    if DataParts.parse(name) != nil || lower.contains(".nxpart.") || lower.hasSuffix(".nxpart") {
                        sawSplitParts = true
                        continue
                    }
                    if lower == "romfs.img", let size = values?.fileSize, size > 0 {
                        // If this directory's romfs.img belonged to the target game at a nested level, `matchesTargetData` on parent handled it.
                        if let expectedIdentity, RomfsIdentity.ofImage(at: url) == expectedIdentity {
                            if !relativePrefix.isEmpty, nestedMatch == nil {
                                nestedMatch = relativePrefix
                            }
                        } else {
                            let parentName = dir.lastPathComponent.uppercased()
                            let hint = (isTitleID(parentName) && parentName != targetID) ? (knownTitles[parentName] ?? parentName) : nil
                            recordWrongGame(hint)
                        }
                    }
                }
            }

            // Breadth-aware full traversal up to maxDepth before making a final decision.
            for sub in subdirs {
                if seenEntries >= maxEntries { break }
                visit(sub.url, relativePrefix: sub.rel, depth: depth + 1)
            }
        }

        visit(folder, relativePrefix: "", depth: 0)

        if let nestedMatch {
            return .nestedGameData(subfolder: nestedMatch)
        }
        if sawICloudPlaceholder {
            return .icloudPlaceholder
        }
        if sawSplitParts {
            return .unjoinedSplitParts
        }
        if sawWrongGame {
            return .wrongGame(otherTitleOrID: wrongGameLabel)
        }
        return .none
    }

    private static func dirHasAnyRomfsPayload(_ dir: URL, fm: FileManager) -> Bool {
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
        for name in names {
            let lower = name.lowercased()
            if lower == "romfs.img" || lower == "romfs" {
                return true
            }
        }
        return false
    }

    /// Player-facing explanation for a wrong-folder finding.
    static func message(for finding: DataFolderFinding, gameTitle: String, gameID: String, folderName: String) -> String {
        let shownFolder = folderName.isEmpty ? "Files" : folderName
        switch finding {
        case .nestedGameData(let subfolder):
            return hostText("Game data for \(gameTitle) is inside the subfolder “\(subfolder)”. Choose that inner folder directly so the game can read its files.")
        case .icloudPlaceholder:
            return hostText("Game data for \(gameTitle) in “\(shownFolder)” has not been downloaded from iCloud Drive yet. Download it in Files first, then try again.")
        case .unjoinedSplitParts:
            return hostText("“\(shownFolder)” holds unjoined .nxpart split files. External folders cannot read split parts directly. Copy them to games/\(gameID) in this app's folder in Files to join automatically, or use a whole romfs.img.")
        case .wrongGame(let other):
            if let other, !other.isEmpty {
                return hostText("That folder holds game data for \(other), not \(gameTitle).")
            }
            return hostText("That folder holds game data for another game, not \(gameTitle).")
        case .none:
            return hostText("No game data for \(gameTitle) was found in that folder.")
        }
    }
}
