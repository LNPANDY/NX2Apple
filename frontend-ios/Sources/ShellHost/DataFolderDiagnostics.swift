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

    private struct ScopedSignals {
        var sawICloudPlaceholder = false
        var sawSplitParts = false
        var wrongGames: [String?] = []
    }

    /// Inspects `folder` up to `maxDepth` levels down (at most `maxEntries` directory entries total, symbolic links skipped)
    /// after `DataLocator` did not find `manifest`'s data at the root or `<folder>/<titleID>/`.
    /// Scans all allowed depths before choosing the highest-priority finding so a deeper exact match is never shadowed by a shallow sibling.
    /// When `folder` is a multi-game parent folder that already has `<folder>/<titleID>/`, findings inside `<folder>/<titleID>/`
    /// take precedence over sibling `<otherTitleID>/` folders so an incomplete target folder is never blamed on another game.
    static func diagnose(folder: URL, manifest: GameManifest, knownTitles: [String: String] = [:],
                         knownIdentities: [RomfsIdentity: String] = [:],
                         fileManager fm: FileManager = .default) -> DataFolderFinding {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { return .none }

        let expectedIdentity = RomfsIdentity.parse(manifest.romfsIdentity)
        let targetID = manifest.titleID.uppercased()
        let ownTitlePaths = Set(
            DataLocator.titleFolders(in: folder, titleID: manifest.titleID, fm)
                .map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        )
        let hasOwnTitleSubfolder = !ownTitlePaths.isEmpty

        var seenEntries = 0
        var nestedMatch: String?
        var ownSignals = ScopedSignals()
        var outerSignals = ScopedSignals()

        func record(_ body: (inout ScopedSignals) -> Void, inOwnSubtree: Bool) {
            if inOwnSubtree {
                body(&ownSignals)
            } else {
                body(&outerSignals)
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

        func visit(_ dir: URL, relativePrefix: String, depth: Int, inOwnSubtree: Bool) {
            guard seenEntries < maxEntries else { return }
            let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
            // Include hidden files so `.romfs.img.icloud` placeholders are visible, while skipping hidden directories below.
            guard let rawChildren = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(resourceKeys), options: []) else {
                return
            }
            let children = rawChildren.sorted { $0.lastPathComponent < $1.lastPathComponent }
            var subdirs: [(url: URL, rel: String, inOwn: Bool)] = []

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
                    let resolvedPath = url.standardizedFileURL.resolvingSymlinksInPath().path
                    let childInOwn = inOwnSubtree || (depth == 0 && ownTitlePaths.contains(resolvedPath))
                    // Check whether a deeper folder actually holds this game's own data.
                    let checkedByLocator = depth == 0 && name.caseInsensitiveCompare(manifest.titleID) == .orderedSame
                    if !checkedByLocator, nestedMatch == nil, matchesTargetData(in: url) {
                        nestedMatch = rel
                    } else if !childInOwn, isTitleID(name), name.uppercased() != targetID {
                        let upper = name.uppercased()
                        if dirHasValidOtherRomfsPayload(url, fm: fm) {
                            record({ $0.wrongGames.append(knownTitles[upper] ?? upper) }, inOwnSubtree: false)
                        }
                    }
                    if depth < maxDepth {
                        subdirs.append((url, rel, childInOwn))
                    }
                } else {
                    if lower.hasSuffix(".icloud") {
                        record({ $0.sawICloudPlaceholder = true }, inOwnSubtree: inOwnSubtree)
                        continue
                    }
                    if name.hasPrefix(".") { continue }
                    if DataParts.parse(name) != nil || lower.contains(".nxpart.") || lower.hasSuffix(".nxpart") {
                        record({ $0.sawSplitParts = true }, inOwnSubtree: inOwnSubtree)
                        continue
                    }
                    if RomfsImageName.isNonPartImage(name), let size = values?.fileSize, size > 0 {
                        let imageIdentity = RomfsIdentity.ofImage(at: url)
                        if let expectedIdentity, imageIdentity == expectedIdentity {
                            let isDirectOwnTitleFolder = depth == 1 && inOwnSubtree
                            if !relativePrefix.isEmpty, !isDirectOwnTitleFolder, nestedMatch == nil {
                                nestedMatch = relativePrefix
                            }
                        } else if let imageIdentity, dir.lastPathComponent.lowercased() != "aoc" {
                            let parentName = dir.lastPathComponent.uppercased()
                            let hint: String?
                            if let knownTitle = knownIdentities[imageIdentity], !knownTitle.isEmpty {
                                hint = knownTitle
                            } else if isTitleID(parentName), parentName != targetID {
                                hint = knownTitles[parentName] ?? parentName
                            } else {
                                hint = nil
                            }
                            record({ $0.wrongGames.append(hint) }, inOwnSubtree: inOwnSubtree)
                        }
                    }
                }
            }

            // Breadth-aware full traversal up to maxDepth before making a final decision.
            for sub in subdirs {
                if seenEntries >= maxEntries { break }
                visit(sub.url, relativePrefix: sub.rel, depth: depth + 1, inOwnSubtree: sub.inOwn)
            }
        }

        visit(folder, relativePrefix: "", depth: 0, inOwnSubtree: false)

        if let nestedMatch {
            return .nestedGameData(subfolder: nestedMatch)
        }
        let chosen = hasOwnTitleSubfolder ? ownSignals : outerSignals
        if chosen.sawICloudPlaceholder {
            return .icloudPlaceholder
        }
        if chosen.sawSplitParts {
            return .unjoinedSplitParts
        }
        if !chosen.wrongGames.isEmpty {
            return .wrongGame(otherTitleOrID: uniqueWrongGameLabel(chosen.wrongGames))
        }
        return .none
    }

    private static func uniqueWrongGameLabel(_ candidates: [String?]) -> String? {
        var distinct: [String] = []
        for item in candidates {
            guard let label = item, !label.isEmpty else { continue }
            if !distinct.contains(label) {
                distinct.append(label)
            }
        }
        return distinct.count == 1 ? distinct[0] : nil
    }

    private static func dirHasValidOtherRomfsPayload(_ dir: URL, fm: FileManager) -> Bool {
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
        for name in names {
            let lower = name.lowercased()
            if lower == "romfs" {
                var isSubDir: ObjCBool = false
                if fm.fileExists(atPath: dir.appendingPathComponent(name).path, isDirectory: &isSubDir), isSubDir.boolValue {
                    return true
                }
            }
            if RomfsImageName.isNonPartImage(name) {
                let child = dir.appendingPathComponent(name)
                if let attrs = try? fm.attributesOfItem(atPath: child.path),
                   attrs[.type] as? FileAttributeType == .typeRegular,
                   RomfsIdentity.ofImage(at: child) != nil {
                    return true
                }
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
