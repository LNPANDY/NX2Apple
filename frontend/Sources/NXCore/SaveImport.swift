import Darwin
import Foundation

/// How an import updates existing save folders.
package enum SaveImportMode: String, Codable, Equatable, Sendable, CaseIterable {
    /// Backs up existing saves and replaces the imported save folder(s).
    case replace
    /// Backs up existing saves and merges imported entries into existing folders (ideal for multi-slot saves like Stardew Valley).
    case merge
}

/// Detected structure of a save import source.
package enum SaveImportSourceKind: Equatable, Sendable {
    case jksvZip(titleID: String?)
    case zip
    case archiveFolders([String])
    case slotFolder(name: String)
    case folder
    case files(slotFolder: String?)
}

/// A single planned entry displayed in the import preview sheet.
package struct SaveImportEntry: Equatable, Sendable, Identifiable {
    package let targetFolder: String
    package let relativePath: String
    package let byteCount: UInt64

    package var id: String { displayPath }
    package var displayPath: String { "\(targetFolder)/\(relativePath)" }

    package init(targetFolder: String, relativePath: String, byteCount: UInt64) {
        self.targetFolder = targetFolder
        self.relativePath = relativePath
        self.byteCount = byteCount
    }
}

/// Unified, preflighted save import plan covering folders, `.zip` (JKSV or plain), slot folders, and single/multiple files.
package struct SaveImportPlan: Equatable, Sendable, Identifiable {
    package var id: String { sourceSummary + "|\(fileCount)|\(totalBytes)" }
    package let sources: [URL]
    package let sourceSummary: String
    package let kind: SaveImportSourceKind
    package let fileCount: Int
    package let totalBytes: UInt64
    package let entries: [SaveImportEntry]
    package let hasExistingTargetSave: Bool
    package let recommendedMode: SaveImportMode

    enum Payload: Equatable, Sendable {
        case zip(JKSVArchive.Preview)
        case copies([SaveArchive.PlannedCopy])
    }

    let payload: Payload

    /// Builds a display-only plan for design previews and visual QA without reading disk files.
    package static func galleryPlaceholder(
        sourceSummary: String,
        kind: SaveImportSourceKind,
        entries: [SaveImportEntry],
        hasExistingTargetSave: Bool = true,
        recommendedMode: SaveImportMode = .merge
    ) -> SaveImportPlan {
        let total = entries.reduce(UInt64(0)) { $0 + $1.byteCount }
        return SaveImportPlan(
            sources: [URL(fileURLWithPath: sourceSummary)],
            sourceSummary: sourceSummary,
            kind: kind,
            fileCount: entries.count,
            totalBytes: total,
            entries: entries,
            hasExistingTargetSave: hasExistingTargetSave,
            recommendedMode: recommendedMode,
            payload: .copies([])
        )
    }
}

package enum SaveImportFailure: Error, Equatable, Sendable {
    case gameRunning
    case pendingPullJournal
    case volumeCannotHoldSaves
    case nothingToImport
    case multipleArchivesNotAllowed
    case invalidArchive(String)
    case unsafePath(String)
    case symlinkNotAllowed(String)
    case quotaExceeded
    case titleIDMismatch(expected: String, found: String)
}

/// Unified preflight and execution for all Mac save import formats:
/// - Standard JKSV `.zip` (with Title ID check) and plain PC/Switch `.zip`
/// - Exported `save` / `save_device` directory trees
/// - Per-slot directories (e.g. Stardew Valley `<Farm>_<ID>/` containing `SaveGameInfo` and extensionless main file)
/// - Single or multiple regular files (including extensionless files)
package enum SaveImport {
    /// Recognizes per-slot save folders (such as Stardew Valley `<Farm>_<Seed>/`) by their direct filenames.
    static func isSlotFileSet(folderName: String, directFileNames: [String]) -> Bool {
        guard !folderName.isEmpty, folderName != "save", folderName != "save_device" else { return false }
        let names = Set(directFileNames.filter { !$0.hasPrefix("._") && $0 != ".DS_Store" })
        if names.contains("SaveGameInfo") { return true }
        if names.contains(folderName), !folderName.contains(".") { return true }
        return false
    }

    /// Checks whether `dir` is a real directory that looks like an individual save slot folder rather than a save root.
    package static func looksLikeSlotDirectory(_ dir: URL, fm: FileManager = .default) -> Bool {
        var st = stat()
        guard lstat(dir.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return false }
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
        if names.contains("save") || names.contains("save_device") { return false }
        var directFiles: [String] = []
        for name in names where name != ".DS_Store" && !name.hasPrefix("._") {
            let child = dir.appendingPathComponent(name)
            var cst = stat()
            if lstat(child.path, &cst) == 0, (cst.st_mode & S_IFMT) == S_IFREG {
                directFiles.append(name)
            }
        }
        return isSlotFileSet(folderName: dir.lastPathComponent, directFileNames: directFiles)
    }

    /// Preflights user-selected URLs (1 folder, 1 `.zip`, or 1+ files/folders) without modifying any save files.
    package static func preview(
        _ rawURLs: [URL],
        expectedTitleID: String,
        into save: URL,
        fm: FileManager = .default
    ) throws -> SaveImportPlan {
        var seenInputPaths: Set<String> = []
        let urls = rawURLs.filter { url in
            guard !url.path.isEmpty else { return false }
            return seenInputPaths.insert(url.standardizedFileURL.path).inserted
        }
        guard !urls.isEmpty else { throw SaveImportFailure.nothingToImport }

        // Reject any top-level symlink or missing item upfront.
        var fileURLs: [URL] = []
        var dirURLs: [URL] = []
        for url in urls {
            var st = stat()
            guard lstat(url.path, &st) == 0 else { throw SaveImportFailure.nothingToImport }
            let kind = st.st_mode & S_IFMT
            if kind == S_IFLNK {
                throw SaveImportFailure.symlinkNotAllowed(url.lastPathComponent)
            } else if kind == S_IFDIR {
                dirURLs.append(url)
            } else if kind == S_IFREG {
                fileURLs.append(url)
            }
        }

        let hasExisting = CloudSaveArchive.hasLocalSaveEntries(save: save)

        // Single `.zip` archive (JKSV or plain PC/Switch archive).
        let zipFiles = fileURLs.filter { $0.pathExtension.lowercased() == "zip" }
        if !zipFiles.isEmpty {
            guard urls.count == 1, zipFiles.count == 1, let zipURL = zipFiles.first else {
                throw SaveImportFailure.multipleArchivesNotAllowed
            }
            let jksvPreview: JKSVArchive.Preview
            do {
                jksvPreview = try JKSVArchive.preview(zipURL, expectedTitleID: expectedTitleID, fileManager: fm)
            } catch let failure as JKSVArchive.Failure {
                throw mapJKSVFailure(failure)
            }
            let entries = jksvPreview.plannedFiles.map {
                SaveImportEntry(targetFolder: $0.targetFolder, relativePath: $0.relativePath, byteCount: $0.entry.uncompressedSize)
            }
            let kind: SaveImportSourceKind
            if let tid = jksvPreview.meta?.formattedTitleID {
                kind = .jksvZip(titleID: tid)
            } else if jksvPreview.meta != nil {
                kind = .jksvZip(titleID: nil)
            } else {
                kind = .zip
            }
            let isSlotOnlyZip = jksvPreview.meta == nil
                && jksvPreview.folders == ["save"]
                && isSingleSlotEntrySet(entries)
            return SaveImportPlan(
                sources: [zipURL],
                sourceSummary: zipURL.path,
                kind: kind,
                fileCount: jksvPreview.fileCount,
                totalBytes: jksvPreview.totalBytes,
                entries: entries,
                hasExistingTargetSave: hasExisting,
                recommendedMode: (hasExisting && isSlotOnlyZip) ? .merge : .replace,
                payload: .zip(jksvPreview)
            )
        }

        var copies: [SaveArchive.PlannedCopy] = []
        var entryCount = 0
        var totalBytes: UInt64 = 0
        let sourceKind: SaveImportSourceKind

        do {
            if urls.count == 1, let dir = dirURLs.first {
                var explicitFolders: [String] = []
                for folder in SaveMigration.folders {
                    let sub = dir.appendingPathComponent(folder)
                    var subSt = stat()
                    if lstat(sub.path, &subSt) == 0, (subSt.st_mode & S_IFMT) == S_IFDIR {
                        let before = copies.count
                        try SaveArchive.collectFilesSafely(
                            root: sub,
                            targetFolder: folder,
                            prefix: "",
                            entryCount: &entryCount,
                            totalBytes: &totalBytes,
                            out: &copies,
                            fm: fm
                        )
                        if copies.count > before { explicitFolders.append(folder) }
                    }
                }
                if !copies.isEmpty {
                    sourceKind = .archiveFolders(explicitFolders)
                } else if looksLikeSlotDirectory(dir, fm: fm) {
                    let slot = dir.lastPathComponent
                    guard ZipCodec.isSafePath(slot) else { throw SaveImportFailure.unsafePath(slot) }
                    try SaveArchive.collectFilesSafely(
                        root: dir,
                        targetFolder: "save",
                        prefix: slot,
                        entryCount: &entryCount,
                        totalBytes: &totalBytes,
                        out: &copies,
                        fm: fm
                    )
                    sourceKind = .slotFolder(name: slot)
                } else {
                    try SaveArchive.collectFilesSafely(
                        root: dir,
                        targetFolder: "save",
                        prefix: "",
                        entryCount: &entryCount,
                        totalBytes: &totalBytes,
                        out: &copies,
                        fm: fm
                    )
                    sourceKind = .folder
                }
            } else {
                // Single or multiple regular files (and/or mixed folders): preserve slot subfolder if all files belong to one slot dir.
                let slotParent: String? = {
                    guard dirURLs.isEmpty, !fileURLs.isEmpty else { return nil }
                    let parents = Set(fileURLs.map { $0.deletingLastPathComponent().standardizedFileURL })
                    guard parents.count == 1, let parent = parents.first, looksLikeSlotDirectory(parent, fm: fm) else {
                        return nil
                    }
                    return parent.lastPathComponent
                }()

                for file in fileURLs {
                    let name = file.lastPathComponent
                    let rel = slotParent.map { "\($0)/\(name)" } ?? name
                    if JKSVArchive.isIgnoredMacMetadata(rel) { continue }
                    guard ZipCodec.isSafePath(rel) else { throw SaveImportFailure.unsafePath(rel) }
                    var st = stat()
                    guard lstat(file.path, &st) == 0 else { continue }
                    let kind = st.st_mode & S_IFMT
                    if kind == S_IFLNK { throw SaveImportFailure.symlinkNotAllowed(rel) }
                    guard kind == S_IFREG else { continue }
                    entryCount += 1
                    guard entryCount <= JKSVArchive.maxEntries else { throw SaveImportFailure.quotaExceeded }
                    let size = UInt64(max(0, st.st_size))
                    guard size <= JKSVArchive.maxTotalBytes - totalBytes else { throw SaveImportFailure.quotaExceeded }
                    totalBytes += size
                    copies.append(SaveArchive.PlannedCopy(sourceURL: file, targetFolder: "save", relativePath: rel, byteCount: size))
                }
                for dir in dirURLs {
                    let dirName = dir.lastPathComponent
                    guard ZipCodec.isSafePath(dirName) else { throw SaveImportFailure.unsafePath(dirName) }
                    try SaveArchive.collectFilesSafely(
                        root: dir,
                        targetFolder: "save",
                        prefix: dirName,
                        entryCount: &entryCount,
                        totalBytes: &totalBytes,
                        out: &copies,
                        fm: fm
                    )
                }
                sourceKind = .files(slotFolder: slotParent)
            }
        } catch let failure as SaveArchive.Failure {
            throw mapArchiveFailure(failure)
        }

        guard !copies.isEmpty else { throw SaveImportFailure.nothingToImport }

        // Deduplicate by target display path if the user picked overlapping paths.
        var seen: Set<String> = []
        var uniqueCopies: [SaveArchive.PlannedCopy] = []
        uniqueCopies.reserveCapacity(copies.count)
        for c in copies {
            let key = "\(c.targetFolder)/\(c.relativePath)"
            if seen.insert(key).inserted {
                uniqueCopies.append(c)
            }
        }

        let entries = uniqueCopies.map {
            SaveImportEntry(targetFolder: $0.targetFolder, relativePath: $0.relativePath, byteCount: $0.byteCount)
        }
        let summary: String
        if urls.count == 1 {
            summary = urls[0].path
        } else {
            let folder = urls[0].deletingLastPathComponent().path
            summary = "\(folder) (\(urls.count))"
        }
        let recommendMerge: Bool
        switch sourceKind {
        case .slotFolder, .files:
            recommendMerge = hasExisting
        case .folder, .archiveFolders, .zip, .jksvZip:
            recommendMerge = hasExisting && isSingleSlotEntrySet(entries)
        }
        return SaveImportPlan(
            sources: urls,
            sourceSummary: summary,
            kind: sourceKind,
            fileCount: uniqueCopies.count,
            totalBytes: totalBytes,
            entries: entries,
            hasExistingTargetSave: hasExisting,
            recommendedMode: recommendMerge ? .merge : .replace,
            payload: .copies(uniqueCopies)
        )
    }

    /// Executes a preflighted `SaveImportPlan` with automatic timestamp backup and atomic rollback safety.
    @discardableResult
    package static func execute(
        _ plan: SaveImportPlan,
        into save: URL,
        mode: SaveImportMode,
        gameRunning: Bool,
        now: Date = Date(),
        volumeHolds: (String) -> Bool? = { VolumeSaves.holdsSaves(at: $0) },
        fm: FileManager = .default,
        faultHook: ((String) throws -> Void)? = nil
    ) throws -> URL? {
        do {
            switch plan.payload {
            case .zip(let preview):
                return try JKSVArchive.import(
                    preview,
                    into: save,
                    mode: mode,
                    gameRunning: gameRunning,
                    now: now,
                    volumeHolds: volumeHolds,
                    fileManager: fm,
                    faultHook: faultHook
                )
            case .copies(let copies):
                return try SaveArchive.importPlanned(
                    copies,
                    into: save,
                    mode: mode,
                    gameRunning: gameRunning,
                    now: now,
                    volumeHolds: volumeHolds,
                    fm: fm,
                    faultHook: faultHook
                )
            }
        } catch let failure as JKSVArchive.Failure {
            throw mapJKSVFailure(failure)
        } catch let failure as SaveArchive.Failure {
            throw mapArchiveFailure(failure)
        }
    }

    private static func isSingleSlotEntrySet(_ entries: [SaveImportEntry]) -> Bool {
        guard !entries.isEmpty, entries.allSatisfy({ $0.targetFolder == "save" }) else { return false }
        let tops = Set(entries.compactMap { entry -> String? in
            let parts = entry.relativePath.split(separator: "/")
            return parts.count >= 2 ? String(parts[0]) : nil
        })
        guard tops.count == 1, let slot = tops.first,
              entries.allSatisfy({ $0.relativePath.hasPrefix(slot + "/") }) else {
            return false
        }
        let direct = entries.compactMap { entry -> String? in
            let rest = String(entry.relativePath.dropFirst(slot.count + 1))
            return rest.contains("/") ? nil : rest
        }
        return isSlotFileSet(folderName: slot, directFileNames: direct)
    }

    private static func mapJKSVFailure(_ failure: JKSVArchive.Failure) -> SaveImportFailure {
        switch failure {
        case .gameRunning: return .gameRunning
        case .pendingPullJournal: return .pendingPullJournal
        case .volumeCannotHoldSaves: return .volumeCannotHoldSaves
        case .invalidArchive(let msg): return .invalidArchive(msg)
        case .unsafePath(let path): return .unsafePath(path)
        case .symlinkNotAllowed(let path): return .symlinkNotAllowed(path)
        case .quotaExceeded: return .quotaExceeded
        case .titleIDMismatch(let expected, let found): return .titleIDMismatch(expected: expected, found: found)
        case .nothingToImport: return .nothingToImport
        case .nothingToExport, .destinationInsideSave: return .invalidArchive("Unexpected archive state.")
        }
    }

    private static func mapArchiveFailure(_ failure: SaveArchive.Failure) -> SaveImportFailure {
        switch failure {
        case .gameRunning: return .gameRunning
        case .pendingPullJournal: return .pendingPullJournal
        case .volumeCannotHoldSaves: return .volumeCannotHoldSaves
        case .nothingToImport, .nothingToExport, .destinationInsideSave: return .nothingToImport
        case .unsafePath(let path): return .unsafePath(path)
        case .symlinkNotAllowed(let path): return .symlinkNotAllowed(path)
        case .quotaExceeded: return .quotaExceeded
        }
    }
}
