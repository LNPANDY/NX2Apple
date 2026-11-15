import Foundation
import NXCore

/// A folder in the game's mods folder: RomFS files that replace the game's own (DM_ROMFS_OVERLAY, hle_fs.c). The files are
/// found in <mod>/romfs, in an Atmosphere layout (<mod>/atmosphere/contents/<title ID>/romfs, <mod>/contents/<title ID>/romfs)
/// or in the folder itself. A mod with only exefs/ changes the game's code, which the rewriter does not take: listed, not usable.
struct GameMod: Identifiable, Equatable {
    let name: String
    let romfs: String?
    var id: String { name }
    var usable: Bool { romfs != nil }

    static func folder(for game: LibraryGame, library: String) -> URL {
        let root = library.isEmpty
            ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NS Port Builder")
            : URL(fileURLWithPath: library)
        return root.appendingPathComponent("mods").appendingPathComponent(game.titleID)
    }

    static func list(in folder: URL, titleID: String) -> [GameMod] {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        return names.compactMap { name in
            var dir: ObjCBool = false
            let mod = folder.appendingPathComponent(name)
            guard fm.fileExists(atPath: mod.path, isDirectory: &dir), dir.boolValue else { return nil }
            let candidates = ["romfs", "atmosphere/contents/\(titleID)/romfs", "contents/\(titleID)/romfs"].map { mod.appendingPathComponent($0).path }
            if let found = candidates.first(where: { fm.fileExists(atPath: $0) }) { return GameMod(name: name, romfs: found) }
            let top = ((try? fm.contentsOfDirectory(atPath: mod.path)) ?? []).filter { !$0.hasPrefix(".") }
            let codeOnly = top.allSatisfy { ["exefs", "atmosphere", "contents"].contains($0.lowercased()) } && !top.isEmpty
            return GameMod(name: name, romfs: codeOnly || top.isEmpty ? nil : mod.path)
        }
    }
}

/// A file inside a library root that could not become a library entry on its own during folder discovery.
struct SkippedLibraryItem: Identifiable, Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case orphanSupplement(titleID: String)
        case unextractedArchiveOrSplit
        case unidentifiedWithoutKeys
    }

    let path: String
    let name: String
    let rootPath: String
    let reason: Reason

    var id: String { path }

    /// The 16-digit uppercase base game Title ID expected by an orphan update or DLC, nil for other reasons.
    var expectedBaseTitleID: String? {
        guard case let .orphanSupplement(tid) = reason,
              let raw = UInt64(tid, radix: 16) else { return nil }
        return String(format: "%016llX", TitleID.owner(raw))
    }
}

struct SkippedScanCollector {
    private static let ignoredDirectories: Set<String> = [
        "romfs", "exefs", "extract", "tools", "venv", "archive", "harness", "runs",
        "shader", "msl", "pso", "bench", "xcode", "node_modules", "keys", "firmware",
        "mods", "saves", "export", "frameworks", "template", "payload", "fallback-icons",
        "artwork", "__macosx"
    ]

    private static let splitRarPartRegex = try! NSRegularExpression(pattern: #"^(.+)\.part\d+\.rar$"#, options: .caseInsensitive)
    private static let splitRarVolumeRegex = try! NSRegularExpression(pattern: #"^(.+)\.(?:rar|r\d{2,3})$"#, options: .caseInsensitive)
    private static let splitZipVolumeRegex = try! NSRegularExpression(pattern: #"^(.+)\.(?:zip(?:\.\d{2,3})?|z\d{2,3})$"#, options: .caseInsensitive)
    private static let split7zVolumeRegex = try! NSRegularExpression(pattern: #"^(.+)\.7z(?:\.\d{2,3})?$"#, options: .caseInsensitive)
    private static let splitPackageRegex = try! NSRegularExpression(pattern: #"^(.+\.(?:nsp|nsz|xci|xcz))\.\d{2,3}$"#, options: .caseInsensitive)
    private static let splitRawDigitsRegex = try! NSRegularExpression(pattern: #"^(.+)\.\d{2,3}$"#, options: .caseInsensitive)

    let rootURL: URL
    let rootResolvedPath: String
    private(set) var candidates: [(groupKey: String?, item: SkippedLibraryItem)] = []

    init(root: URL) {
        self.rootURL = root
        self.rootResolvedPath = LibraryRoots.normalized(root.path)
    }

    private func isInsideIgnoredSubdirectory(_ fileURL: URL) -> Bool {
        let resolvedParent = LibraryRoots.normalized(fileURL.deletingLastPathComponent().path)
        guard resolvedParent.hasPrefix(rootResolvedPath) else { return false }
        let suffix = String(resolvedParent.dropFirst(rootResolvedPath.count))
        for rawPart in suffix.split(separator: "/") {
            let part = rawPart.lowercased()
            if Self.ignoredDirectories.contains(part) { return true }
            if part.hasSuffix(".app")
                || part.hasSuffix(".xcarchive")
                || part.hasSuffix(".framework")
                || part.hasSuffix(".bundle")
                || part.hasSuffix(".dsym")
                || part.hasSuffix("_build")
                || part.hasSuffix("-work")
                || part.hasSuffix("_survey") {
                return true
            }
        }
        if FileManager.default.fileExists(atPath: fileURL.deletingLastPathComponent().appendingPathComponent("game.tsv").path) {
            return true
        }
        return false
    }

    private static func firstGroup(_ regex: NSRegularExpression, in text: String) -> String? {
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    static func archiveGroupKey(for fileURL: URL) -> String? {
        let fileName = fileURL.lastPathComponent
        let low = fileName.lowercased()
        if low.hasPrefix("nx2apple") || low.hasPrefix("firmware") || (low.hasPrefix("iphoneos") && low.contains("sdk")) {
            return nil
        }
        let parent = LibraryRoots.normalized(fileURL.deletingLastPathComponent().path)
        if let stem = firstGroup(splitRarPartRegex, in: fileName) ?? firstGroup(splitRarVolumeRegex, in: fileName) {
            return parent + "/" + stem.lowercased() + ".rar#split"
        }
        if let stem = firstGroup(splitZipVolumeRegex, in: fileName) {
            return parent + "/" + stem.lowercased() + ".zip#split"
        }
        if let stem = firstGroup(split7zVolumeRegex, in: fileName) {
            return parent + "/" + stem.lowercased() + ".7z#split"
        }
        if let stem = firstGroup(splitPackageRegex, in: fileName) {
            return parent + "/" + stem.lowercased() + "#split"
        }
        for compound in [".tar.gz", ".tar.xz", ".tar.bz2", ".tar.zst", ".tgz", ".tbz2", ".txz", ".tar"] where low.hasSuffix(compound) {
            return LibraryRoots.normalized(fileURL.path)
        }
        if let stem = firstGroup(splitRawDigitsRegex, in: fileName), !stem.isEmpty {
            return parent + "/" + stem.lowercased() + "#rawsplit"
        }
        return nil
    }

    mutating func observeFile(_ fileURL: URL, resolver: PackageTitleID.Resolver) {
        let fileName = fileURL.lastPathComponent
        guard !fileName.hasPrefix("."), !fileName.hasPrefix("._") else { return }
        guard !isInsideIgnoredSubdirectory(fileURL) else { return }

        let resolvedPath = LibraryRoots.normalized(fileURL.path)
        if let groupKey = Self.archiveGroupKey(for: fileURL) {
            let item = SkippedLibraryItem(
                path: resolvedPath,
                name: fileName,
                rootPath: rootURL.path,
                reason: .unextractedArchiveOrSplit
            )
            candidates.append((groupKey: groupKey, item: item))
            return
        }

        let ext = fileURL.pathExtension.lowercased()
        guard PackageTitleID.supportedExtensions.contains(ext) else { return }
        if let id = resolver.titleID(fileURL.path) {
            guard id & 0xFFF != 0 else { return }
            let supplementHex = String(format: "%016llX", id)
            let item = SkippedLibraryItem(
                path: resolvedPath,
                name: fileName,
                rootPath: rootURL.path,
                reason: .orphanSupplement(titleID: supplementHex)
            )
            candidates.append((groupKey: nil, item: item))
            return
        }

        if TitleID.parse(fileName) == nil, PackageTitleID.hasReadableContainer(fileURL.path) {
            let item = SkippedLibraryItem(
                path: resolvedPath,
                name: fileName,
                rootPath: rootURL.path,
                reason: .unidentifiedWithoutKeys
            )
            candidates.append((groupKey: nil, item: item))
        }
    }
}

extension GameLibrary {
    static func knownBaseTitleIDSet(from titleIDs: some Sequence<String>) -> Set<String> {
        var out = Set<String>()
        for rawID in titleIDs {
            let upper = rawID.uppercased()
            guard upper.count == 16, let value = UInt64(upper, radix: 16) else { continue }
            out.insert(upper)
            out.insert(String(format: "%016llX", TitleID.owner(value)))
            out.insert(String(format: "%016llX", value & ~0xFFF))
        }
        return out
    }

    static func resolveSkippedItems(
        _ rawCandidates: [(groupKey: String?, item: SkippedLibraryItem)],
        knownBaseTitleIDs: Set<String>
    ) -> [SkippedLibraryItem] {
        // Pick the lowest-numbered or primary archive segment (.zip, .part1.rar, .nsp.00) deterministically per group.
        var bestByGroup: [String: SkippedLibraryItem] = [:]
        for (groupKey, item) in rawCandidates {
            guard let groupKey else { continue }
            if let current = bestByGroup[groupKey] {
                let cmp = item.name.localizedStandardCompare(current.name)
                if cmp == .orderedAscending || (cmp == .orderedSame && item.path < current.path) {
                    bestByGroup[groupKey] = item
                }
            } else {
                bestByGroup[groupKey] = item
            }
        }

        var seenPaths = Set<String>()
        var seenGroups = Set<String>()
        var kept: [SkippedLibraryItem] = []

        for (groupKey, rawItem) in rawCandidates {
            let item: SkippedLibraryItem
            if let groupKey {
                guard seenGroups.insert(groupKey).inserted,
                      let chosen = bestByGroup[groupKey] else { continue }
                item = chosen
            } else {
                item = rawItem
            }
            if case let .orphanSupplement(tid) = item.reason, let raw = UInt64(tid, radix: 16) {
                let ownerHex = String(format: "%016llX", TitleID.owner(raw))
                let blockHex = String(format: "%016llX", raw & ~0xFFF)
                if knownBaseTitleIDs.contains(ownerHex) || knownBaseTitleIDs.contains(blockHex) {
                    continue
                }
            }
            guard seenPaths.insert(item.path).inserted else { continue }
            kept.append(item)
        }

        return kept.sorted { left, right in
            let cmp = left.name.localizedStandardCompare(right.name)
            return cmp == .orderedSame ? left.path < right.path : cmp == .orderedAscending
        }
    }

    static func filterSkippedItems(_ items: [SkippedLibraryItem], forRemainingFolders folders: [String]) -> [SkippedLibraryItem] {
        let activeRoots = Set(LibraryRoots.scannable(folders).map { LibraryRoots.normalized($0) })
        guard !activeRoots.isEmpty else { return [] }
        return items.filter { activeRoots.contains(LibraryRoots.normalized($0.rootPath)) }
    }

    /// True when the skipped-files banner is visible in this app session (restarts start fresh, and new skipped paths re-arm it).
    var showsSkippedBanner: Bool {
        !skippedItems.isEmpty && !Set(skippedItems.map(\.path)).isSubset(of: dismissedSkippedPaths)
    }

    func dismissSkippedBanner() {
        guard !skippedItems.isEmpty else { return }
        dismissedSkippedPaths = Set(skippedItems.map(\.path))
    }

    func resetSkippedBannerDismissal() {
        if !dismissedSkippedPaths.isEmpty { dismissedSkippedPaths.removeAll() }
    }

    func rescan(repo: String = RepoLayout.find()) {
        resetSkippedBannerDismissal()
        discover(repo: repo)
    }

    func applySkippedItems(_ next: [SkippedLibraryItem]) {
        skippedItems = next
        if next.isEmpty {
            if !dismissedSkippedPaths.isEmpty { dismissedSkippedPaths.removeAll() }
        } else if !dismissedSkippedPaths.isEmpty, !Set(next.map(\.path)).isSubset(of: dismissedSkippedPaths) {
            dismissedSkippedPaths.removeAll()
        }
    }
}
