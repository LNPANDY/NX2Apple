import Darwin
import Foundation

/// Saving a game's save as ordinary files and bringing one in (#411).
///
/// Export copies the committed save folders into a folder the player picked: `<picked>/<TITLE ID>/save` (and `save_device`).
/// Import safely stages files into `<DM_SAVE>` (replacing or merging) after backing up the current save to `<DM_SAVE>-backups/<date> before import`,
/// and clears `<DM_SAVE>.sync` so cloud sync picks up the imported save.
package enum SaveArchive {
    package enum Failure: Error, Equatable, Sendable {
        case gameRunning
        case pendingPullJournal
        case nothingToImport
        case nothingToExport
        case destinationInsideSave
        case volumeCannotHoldSaves
        case unsafePath(String)
        case symlinkNotAllowed(String)
        case quotaExceeded
    }

    /// What an import would bring in: the folders of the source and how many files they hold.
    package struct Preview: Equatable {
        package var source: URL
        /// Source folder for each target folder name (`save`, `save_device`).
        package var folders: [String: URL]
        package var fileCount: Int
    }

    struct PlannedCopy: Equatable, Sendable {
        let sourceURL: URL
        let targetFolder: String
        let relativePath: String
        let byteCount: UInt64
    }

    /// The source folder seen as a save: its `save` / `save_device` subfolders when it has them, else the folder itself as `save`.
    package static func preview(_ source: URL, fm: FileManager = .default) -> Preview? {
        var st = stat()
        guard lstat(source.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return nil }
        var found: [String: URL] = [:]
        for name in SaveMigration.folders {
            let sub = source.appendingPathComponent(name)
            var subSt = stat()
            if lstat(sub.path, &subSt) == 0, (subSt.st_mode & S_IFMT) == S_IFDIR, SaveMigration.files(in: sub, fm: fm) > 0 {
                found[name] = sub
            }
        }
        if found.isEmpty, SaveMigration.files(in: source, fm: fm) > 0 { found["save"] = source }
        guard !found.isEmpty else { return nil }
        return Preview(source: source, folders: found, fileCount: found.values.reduce(0) { $0 + SaveMigration.files(in: $1, fm: fm) })
    }

    /// Copies the game's committed save folders to `<destination>/<TITLE ID>/`. Returns that folder and the number of files.
    @discardableResult
    package static func export(save: URL, titleID: String, to destination: URL, fm: FileManager = .default) throws -> (folder: URL, files: Int) {
        let target = destination.appendingPathComponent(titleID.uppercased(), isDirectory: true)
        if target.path.hasPrefix(save.path + "/") || destination.path == save.path { throw Failure.destinationInsideSave }
        var total = 0
        for name in SaveMigration.folders {
            let source = CloudSaveArchive.targetFolder(name, save: save)
            guard SaveMigration.files(in: source, fm: fm) > 0 else { continue }
            var dest = target.appendingPathComponent(name, isDirectory: true)
            if fm.fileExists(atPath: dest.path) { dest = target.appendingPathComponent(name + " " + stamp(Date()), isDirectory: true) }
            total += try SaveMigration.copyTree(source, dest, fm: fm)
        }
        guard total > 0 else { throw Failure.nothingToExport }
        return (target, total)
    }

    /// Replaces or merges the save with the previewed folder. The current save is backed up first and replaced atomically.
    @discardableResult
    package static func `import`(
        _ preview: Preview,
        into save: URL,
        mode: SaveImportMode = .replace,
        gameRunning: Bool,
        now: Date = Date(),
        volumeHolds: (String) -> Bool? = { VolumeSaves.holdsSaves(at: $0) },
        fm: FileManager = .default,
        faultHook: ((String) throws -> Void)? = nil
    ) throws -> URL? {
        guard !preview.folders.isEmpty else { throw Failure.nothingToImport }
        var copies: [PlannedCopy] = []
        var entryCount = 0
        var totalBytes: UInt64 = 0
        for name in SaveMigration.folders {
            guard let sourceDir = preview.folders[name] else { continue }
            try collectFilesSafely(
                root: sourceDir,
                targetFolder: name,
                prefix: "",
                entryCount: &entryCount,
                totalBytes: &totalBytes,
                out: &copies,
                fm: fm
            )
        }
        return try importPlanned(
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

    @discardableResult
    static func importPlanned(
        _ copies: [PlannedCopy],
        into save: URL,
        mode: SaveImportMode,
        gameRunning: Bool,
        now: Date = Date(),
        volumeHolds: (String) -> Bool? = { VolumeSaves.holdsSaves(at: $0) },
        fm: FileManager = .default,
        faultHook: ((String) throws -> Void)? = nil
    ) throws -> URL? {
        if gameRunning { throw Failure.gameRunning }
        if CloudSaveCheck.hasPendingPullJournal(save: save, fm: fm) { throw Failure.pendingPullJournal }
        if volumeHolds(save.path) == false { throw Failure.volumeCannotHoldSaves }
        guard !copies.isEmpty else { throw Failure.nothingToImport }

        let parentDir = save.deletingLastPathComponent()
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let staging = URL(fileURLWithPath: save.path + ".import-stage-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let plannedFolders = Set(copies.map(\.targetFolder))
        for folder in SaveMigration.folders {
            let existing = CloudSaveArchive.targetFolder(folder, save: save)
            if CloudSaveCheck.hasEntries(existing.path),
               (mode == .merge || !plannedFolders.contains(folder)) {
                try fm.copyItem(at: existing, to: staging.appendingPathComponent(folder, isDirectory: true))
            }
        }

        var remainingBudget = JKSVArchive.maxTotalBytes
        for copy in copies {
            guard ZipCodec.isSafePath(copy.relativePath) else { throw Failure.unsafePath(copy.relativePath) }
            let folderRoot = staging.appendingPathComponent(copy.targetFolder, isDirectory: true)
            let destURL = folderRoot.appendingPathComponent(copy.relativePath, isDirectory: false)
            try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destURL.path) {
                var st = stat()
                if lstat(destURL.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK {
                    throw Failure.symlinkNotAllowed(copy.relativePath)
                }
                try fm.removeItem(at: destURL)
            }
            try copyRegularFileSafely(from: copy.sourceURL, to: destURL, remainingBudget: &remainingBudget)
        }

        let backupsRoot = CloudSaveArchive.backupsRoot(for: save)
        var backupURL: URL?
        if CloudSaveArchive.hasLocalSaveEntries(save: save) {
            backupURL = try JKSVArchive.makeImportBackupDirectory(in: backupsRoot, now: now, fileManager: fm)
            do {
                for folder in SaveMigration.folders {
                    let src = CloudSaveArchive.targetFolder(folder, save: save)
                    if CloudSaveCheck.hasEntries(src.path) {
                        try fm.copyItem(at: src, to: backupURL!.appendingPathComponent(folder, isDirectory: true))
                    }
                }
            } catch {
                try? fm.removeItem(at: backupURL!)
                throw error
            }
        }

        try CloudSaveArchive.replaceSaveFolders(save: save, from: staging, fileManager: fm, faultHook: faultHook)
        CloudSaveCheck.clearBase(save: save)
        return backupURL
    }

    static func collectFilesSafely(
        root: URL,
        targetFolder: String,
        prefix: String,
        entryCount: inout Int,
        totalBytes: inout UInt64,
        out: inout [PlannedCopy],
        fm: FileManager,
        depth: Int = 0
    ) throws {
        guard depth <= 64 else { throw Failure.quotaExceeded }
        var rootSt = stat()
        guard lstat(root.path, &rootSt) == 0 else { return }
        let rootKind = rootSt.st_mode & S_IFMT
        if rootKind == S_IFLNK { throw Failure.symlinkNotAllowed(root.lastPathComponent) }
        guard rootKind == S_IFDIR else { return }

        let names = try fm.contentsOfDirectory(atPath: root.path).sorted()
        for name in names {
            let rel = prefix.isEmpty ? name : "\(prefix)/\(name)"
            if JKSVArchive.isIgnoredMacMetadata(rel) { continue }
            guard ZipCodec.isSafePath(rel) else { throw Failure.unsafePath(rel) }
            let child = root.appendingPathComponent(name)
            var st = stat()
            guard lstat(child.path, &st) == 0 else { continue }
            let kind = st.st_mode & S_IFMT
            if kind == S_IFLNK { throw Failure.symlinkNotAllowed(rel) }
            if kind == S_IFDIR {
                entryCount += 1
                guard entryCount <= JKSVArchive.maxEntries else { throw Failure.quotaExceeded }
                try collectFilesSafely(
                    root: child,
                    targetFolder: targetFolder,
                    prefix: rel,
                    entryCount: &entryCount,
                    totalBytes: &totalBytes,
                    out: &out,
                    fm: fm,
                    depth: depth + 1
                )
            } else if kind == S_IFREG {
                entryCount += 1
                guard entryCount <= JKSVArchive.maxEntries else { throw Failure.quotaExceeded }
                let size = UInt64(max(0, st.st_size))
                guard size <= JKSVArchive.maxTotalBytes - totalBytes else { throw Failure.quotaExceeded }
                totalBytes += size
                out.append(PlannedCopy(sourceURL: child, targetFolder: targetFolder, relativePath: rel, byteCount: size))
            }
        }
    }

    private static func copyRegularFileSafely(from source: URL, to dest: URL, remainingBudget: inout UInt64) throws {
        var st = stat()
        guard lstat(source.path, &st) == 0 else { throw Failure.nothingToImport }
        let kind = st.st_mode & S_IFMT
        if kind == S_IFLNK { throw Failure.symlinkNotAllowed(source.lastPathComponent) }
        guard kind == S_IFREG else { throw Failure.unsafePath(source.lastPathComponent) }

        let inFD = open(source.path, O_RDONLY | O_NOFOLLOW)
        guard inFD >= 0 else { throw Failure.nothingToImport }
        defer { close(inFD) }

        let outFD = open(dest.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard outFD >= 0 else { throw Failure.unsafePath(dest.lastPathComponent) }
        defer { close(outFD) }

        let chunkSize = 65_536
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let n = read(inFD, &buffer, chunkSize)
            if n < 0 && errno == EINTR { continue }
            if n < 0 { throw CocoaError(.fileReadUnknown) }
            if n == 0 { break }
            guard UInt64(n) <= remainingBudget else { throw Failure.quotaExceeded }
            remainingBudget -= UInt64(n)
            var offset = 0
            while offset < n {
                let wrote = buffer.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return 0 }
                    return write(outFD, base.advanced(by: offset), n - offset)
                }
                if wrote < 0 && errno == EINTR { continue }
                if wrote <= 0 { throw CocoaError(.fileWriteUnknown) }
                offset += wrote
            }
        }
        var times = [st.st_atimespec, st.st_mtimespec]
        _ = futimens(outFD, &times)
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f.string(from: date)
    }
}
