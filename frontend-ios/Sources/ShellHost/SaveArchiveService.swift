import Darwin
import Foundation
import ShellUI

/// Errors raised while inspecting, importing, or exporting local iOS game saves.
public enum SaveArchiveFailure: Error, Equatable, Sendable {
    case gameRunning
    case pendingPullJournal
    case invalidArchive(String)
    case unsafePath(String)
    case symlinkNotAllowed(String)
    case quotaExceeded
    case titleIDMismatch(expected: String, found: String)
    case nothingToImport
    case nothingToExport
    case destinationInsideSave
    case sourceUnreadable
}

/// Manages a security-scoped resource access lifetime across preview -> confirm -> import.
public final class SecurityScopedLease: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var active: Bool

    public init(url: URL) {
        self.url = url
        self.active = url.startAccessingSecurityScopedResource()
    }

    public func release() {
        lock.lock()
        let shouldStop = active
        active = false
        lock.unlock()
        if shouldStop {
            url.stopAccessingSecurityScopedResource()
        }
    }

    deinit {
        release()
    }
}

/// Pure-Swift local save import/export service for `ShellHost`, interoperable with Mac `SaveArchive` / `JKSVArchive`
/// and Switch JKSV `.zip` archives.
public enum SaveArchiveService {
    public static let maxEntries = SaveZipCodec.maxEntries
    public static let maxTotalBytes = SaveZipCodec.maxTotalBytes
    public static let metaFileName = ".nx_save_meta.bin"
    public static let metaByteCount = 86

    private static let guestAttr = "org.d2rmobile.guest-name"
    private static let maxMetaBytes = 64 * 1024
    private static let saveFolders = ["save", "save_device"]

    public struct Meta: Equatable, Sendable {
        public var titleID: UInt64
        public var saveType: UInt8

        public var formattedTitleID: String? {
            titleID == 0 ? nil : String(format: "%016llX", titleID)
        }

        public init(titleID: UInt64, saveType: UInt8) {
            self.titleID = titleID
            self.saveType = saveType
        }

        public static func parse(_ data: Data) -> Meta? {
            guard data.count >= metaByteCount else { return nil }
            let bytes = [UInt8](data.prefix(metaByteCount))
            guard Array(bytes[0..<4]) == Array("JKSV".utf8), bytes[4] == 1 else { return nil }
            var tid: UInt64 = 0
            for i in 0..<8 {
                tid |= UInt64(bytes[5 + i]) << (8 * i)
            }
            return Meta(titleID: tid, saveType: bytes[37])
        }

        public func encode() -> Data {
            var bytes = [UInt8](repeating: 0, count: metaByteCount)
            let magic = Array("JKSV".utf8)
            for (i, b) in magic.enumerated() { bytes[i] = b }
            bytes[4] = 1
            for i in 0..<8 {
                bytes[5 + i] = UInt8((titleID >> (8 * i)) & 0xFF)
            }
            bytes[37] = saveType
            return Data(bytes)
        }
    }

    public struct LocalSummary: Equatable, Sendable {
        public var fileCount: Int
        public var totalBytes: UInt64
        public var hasEntries: Bool { fileCount > 0 }
    }

    public struct Preview: Sendable {
        public var source: URL
        public var sourceKind: SaveImportSourceKind
        public var fileCount: Int
        public var totalBytes: UInt64
        public var meta: Meta?
        public var folders: [String]
        let payload: Payload
    }

    enum Payload: Sendable {
        case zip([PlannedZipFile])
        case files([PlannedDiskFile])
    }

    struct PlannedZipFile: Equatable, Sendable {
        let targetFolder: String
        let relativePath: String
        let entry: SaveZipCodec.CentralEntry
    }

    struct PlannedDiskFile: Equatable, Sendable {
        let targetFolder: String
        let relativePath: String
        let fileURL: URL
        let byteSize: UInt64
    }

    // MARK: - Local save summary

    public static func localSummary(in appFolder: URL) -> LocalSummary {
        var files = 0
        var totalBytes: UInt64 = 0
        for folder in saveFolders {
            let dir = appFolder.appendingPathComponent(folder, isDirectory: true)
            guard hasEntries(dir.path) else { continue }
            _ = walk(dir.path, folder) { _, _, st in
                if (st.st_mode & S_IFMT) == S_IFREG {
                    files += 1
                    totalBytes &+= UInt64(max(0, st.st_size))
                }
                return true
            }
        }
        return LocalSummary(fileCount: files, totalBytes: totalBytes)
    }

    public static func hasLocalSaveEntries(in appFolder: URL) -> Bool {
        saveFolders.contains { hasEntries(appFolder.appendingPathComponent($0, isDirectory: true).path) }
    }

    public static func hasPendingPullJournal(in appFolder: URL, fileManager fm: FileManager = .default) -> Bool {
        fm.fileExists(atPath: appFolder.appendingPathComponent("save.pull", isDirectory: false).path)
    }

    // MARK: - Preview (folder / JKSV .zip / standard .zip / single file)

    /// Inspects a picked folder, `.zip` archive, or single file (including extensionless files) off the main thread.
    /// Does not modify any local save files and validates all paths, symlinks, JKSV Title IDs, and shared quotas.
    public static func preview(
        _ sourceURL: URL,
        expectedTitleID: String,
        fileManager fm: FileManager = .default
    ) throws -> Preview {
        let canonicalSource = sourceURL.resolvingSymlinksInPath()
        var st = stat()
        guard lstat(sourceURL.path, &st) == 0 || lstat(canonicalSource.path, &st) == 0 else {
            throw SaveArchiveFailure.sourceUnreadable
        }

        // Check actual filesystem entry kind (follow outer FileProvider path if needed, but validate inner entries strictly).
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sourceURL.path, isDirectory: &isDir) else {
            throw SaveArchiveFailure.sourceUnreadable
        }

        if isDir.boolValue {
            return try previewFolder(sourceURL, expectedTitleID: expectedTitleID, fileManager: fm)
        }
        if sourceURL.pathExtension.lowercased() == "zip" {
            return try previewZip(sourceURL, expectedTitleID: expectedTitleID, fileManager: fm)
        }
        return try previewSingleFile(sourceURL, fileManager: fm)
    }

    private static func previewZip(
        _ zipURL: URL,
        expectedTitleID: String,
        fileManager fm: FileManager
    ) throws -> Preview {
        guard fm.fileExists(atPath: zipURL.path),
              let handle = try? FileHandle(forReadingFrom: zipURL) else {
            throw SaveArchiveFailure.invalidArchive("Cannot open ZIP archive.")
        }
        defer { try? handle.close() }

        let entries = try SaveZipCodec.parseCentralDirectory(handle: handle)
        var wrapperPrefix: String?
        var metaEntry: SaveZipCodec.CentralEntry?

        var filteredFiles: [SaveZipCodec.CentralEntry] = []
        for entry in entries {
            let trimmed = entry.rawName.hasSuffix("/") ? String(entry.rawName.dropLast()) : entry.rawName
            if isIgnoredMacMetadata(trimmed) || entry.isDirectory { continue }
            let last = (trimmed as NSString).lastPathComponent
            if last == metaFileName {
                if !trimmed.contains("/") {
                    metaEntry = entry
                } else {
                    let parts = trimmed.split(separator: "/")
                    if parts.count == 2 {
                        metaEntry = entry
                        let top = String(parts[0])
                        if top != "save" && top != "save_device" {
                            wrapperPrefix = top + "/"
                        }
                    }
                }
                continue
            }
            filteredFiles.append(entry)
        }

        var meta: Meta?
        if let metaEntry {
            guard metaEntry.uncompressedSize <= UInt64(maxMetaBytes) else {
                throw SaveArchiveFailure.invalidArchive("Metadata file is too large.")
            }
            var budget = UInt64(maxMetaBytes)
            let metaData = try SaveZipCodec.extractData(handle: handle, entry: metaEntry, remainingBudget: &budget)
            meta = Meta.parse(metaData)
            if let meta, meta.titleID != 0 {
                let wantID = UInt64(expectedTitleID, radix: 16) ?? 0
                if wantID != 0 && meta.titleID != wantID {
                    throw SaveArchiveFailure.titleIDMismatch(
                        expected: expectedTitleID.uppercased(),
                        found: String(format: "%016llX", meta.titleID)
                    )
                }
            }
        }

        guard !filteredFiles.isEmpty else { throw SaveArchiveFailure.nothingToImport }

        if wrapperPrefix == nil {
            wrapperPrefix = detectWrapperPrefix(files: filteredFiles)
        }

        let stripped: [(String, SaveZipCodec.CentralEntry)] = filteredFiles.compactMap { entry in
            var rel = entry.rawName
            if let prefix = wrapperPrefix, rel.hasPrefix(prefix) {
                rel = String(rel.dropFirst(prefix.count))
            }
            guard !rel.isEmpty, rel != metaFileName else { return nil }
            return (rel, entry)
        }
        guard !stripped.isEmpty else { throw SaveArchiveFailure.nothingToImport }

        let hasExplicitSaveFolders = stripped.contains { rel, _ in
            rel.hasPrefix("save/") || rel.hasPrefix("save_device/")
        }
        let defaultFolder = (meta?.saveType == 3) ? "save_device" : "save"

        var planned: [PlannedZipFile] = []
        var foldersSet: Set<String> = []
        var totalBytes: UInt64 = 0
        var entryLedger = 0

        for (rel, entry) in stripped {
            entryLedger += 1
            guard entryLedger <= maxEntries else { throw SaveArchiveFailure.quotaExceeded }
            let folder: String
            let innerPath: String
            if hasExplicitSaveFolders {
                if rel.hasPrefix("save/") {
                    folder = "save"
                    innerPath = String(rel.dropFirst("save/".count))
                } else if rel.hasPrefix("save_device/") {
                    folder = "save_device"
                    innerPath = String(rel.dropFirst("save_device/".count))
                } else {
                    folder = defaultFolder
                    innerPath = rel
                }
            } else {
                folder = defaultFolder
                innerPath = rel
            }
            guard !innerPath.isEmpty, SaveZipCodec.isSafePath(innerPath) else { continue }
            guard entry.uncompressedSize <= maxTotalBytes - totalBytes else { throw SaveArchiveFailure.quotaExceeded }
            totalBytes += entry.uncompressedSize
            foldersSet.insert(folder)
            planned.append(PlannedZipFile(targetFolder: folder, relativePath: innerPath, entry: entry))
        }

        guard !planned.isEmpty else { throw SaveArchiveFailure.nothingToImport }
        let orderedFolders = saveFolders.filter { foldersSet.contains($0) }
        return Preview(
            source: zipURL,
            sourceKind: meta != nil ? .jksvArchive : .zipArchive,
            fileCount: planned.count,
            totalBytes: totalBytes,
            meta: meta,
            folders: orderedFolders,
            payload: .zip(planned)
        )
    }

    private static func previewFolder(
        _ folderURL: URL,
        expectedTitleID: String,
        fileManager fm: FileManager
    ) throws -> Preview {
        var meta: Meta?
        let topMetaURL = folderURL.appendingPathComponent(metaFileName, isDirectory: false)
        var topMetaStat = stat()
        if lstat(topMetaURL.path, &topMetaStat) == 0 {
            if (topMetaStat.st_mode & S_IFMT) == S_IFLNK {
                throw SaveArchiveFailure.symlinkNotAllowed(metaFileName)
            }
            if (topMetaStat.st_mode & S_IFMT) == S_IFREG {
                guard UInt64(max(0, topMetaStat.st_size)) <= UInt64(maxMetaBytes),
                      let data = try? Data(contentsOf: topMetaURL) else {
                    throw SaveArchiveFailure.invalidArchive("Metadata file is unreadable or too large.")
                }
                meta = Meta.parse(data)
                if let meta, meta.titleID != 0 {
                    let wantID = UInt64(expectedTitleID, radix: 16) ?? 0
                    if wantID != 0 && meta.titleID != wantID {
                        throw SaveArchiveFailure.titleIDMismatch(
                            expected: expectedTitleID.uppercased(),
                            found: String(format: "%016llX", meta.titleID)
                        )
                    }
                }
            }
        }

        var entryLedger = 0
        var totalBytes: UInt64 = 0
        var rawFiles: [(rel: String, url: URL, size: UInt64)] = []

        func walkPickedDir(_ absDir: String, _ relPrefix: String) throws {
            guard let list = namesInByteOrder(absDir) else {
                throw SaveArchiveFailure.sourceUnreadable
            }
            for name in list {
                let rel = relPrefix.isEmpty ? name : "\(relPrefix)/\(name)"
                if isIgnoredMacMetadata(rel) || name == metaFileName { continue }
                let abs = absDir + "/" + name
                var st = stat()
                guard lstat(abs, &st) == 0 else {
                    throw SaveArchiveFailure.sourceUnreadable
                }
                let kind = st.st_mode & S_IFMT
                if kind == S_IFLNK {
                    throw SaveArchiveFailure.symlinkNotAllowed(rel)
                }
                guard SaveZipCodec.isSafePath(rel) else {
                    throw SaveArchiveFailure.unsafePath(rel)
                }
                entryLedger += 1
                guard entryLedger <= maxEntries else {
                    throw SaveArchiveFailure.quotaExceeded
                }
                if kind == S_IFDIR {
                    try walkPickedDir(abs, rel)
                } else if kind == S_IFREG {
                    let size = UInt64(max(0, st.st_size))
                    guard size <= maxTotalBytes - totalBytes else {
                        throw SaveArchiveFailure.quotaExceeded
                    }
                    totalBytes += size
                    rawFiles.append((rel: rel, url: URL(fileURLWithPath: abs), size: size))
                }
            }
        }

        try walkPickedDir(folderURL.path, "")
        guard !rawFiles.isEmpty else { throw SaveArchiveFailure.nothingToImport }

        let hasExplicitSaveFolders = rawFiles.contains { item in
            item.rel.hasPrefix("save/") || item.rel.hasPrefix("save_device/")
        }
        let defaultFolder = (meta?.saveType == 3) ? "save_device" : "save"

        var planned: [PlannedDiskFile] = []
        var foldersSet: Set<String> = []
        for item in rawFiles {
            let folder: String
            let innerPath: String
            if hasExplicitSaveFolders {
                if item.rel.hasPrefix("save/") {
                    folder = "save"
                    innerPath = String(item.rel.dropFirst("save/".count))
                } else if item.rel.hasPrefix("save_device/") {
                    folder = "save_device"
                    innerPath = String(item.rel.dropFirst("save_device/".count))
                } else {
                    folder = defaultFolder
                    innerPath = item.rel
                }
            } else {
                folder = defaultFolder
                innerPath = item.rel
            }
            guard !innerPath.isEmpty else { continue }
            foldersSet.insert(folder)
            planned.append(PlannedDiskFile(
                targetFolder: folder,
                relativePath: innerPath,
                fileURL: item.url,
                byteSize: item.size
            ))
        }

        guard !planned.isEmpty else { throw SaveArchiveFailure.nothingToImport }
        let orderedFolders = saveFolders.filter { foldersSet.contains($0) }
        return Preview(
            source: folderURL,
            sourceKind: .folder,
            fileCount: planned.count,
            totalBytes: totalBytes,
            meta: meta,
            folders: orderedFolders,
            payload: .files(planned)
        )
    }

    private static func previewSingleFile(_ fileURL: URL, fileManager fm: FileManager) throws -> Preview {
        let name = fileURL.lastPathComponent
        if isIgnoredMacMetadata(name) || name == metaFileName {
            throw SaveArchiveFailure.nothingToImport
        }
        var st = stat()
        guard lstat(fileURL.path, &st) == 0 else {
            throw SaveArchiveFailure.sourceUnreadable
        }
        let kind = st.st_mode & S_IFMT
        if kind == S_IFLNK {
            throw SaveArchiveFailure.symlinkNotAllowed(name)
        }
        guard kind == S_IFREG else {
            throw SaveArchiveFailure.sourceUnreadable
        }
        guard SaveZipCodec.isSafePath(name) else {
            throw SaveArchiveFailure.unsafePath(name)
        }
        let size = UInt64(max(0, st.st_size))
        guard size <= maxTotalBytes else {
            throw SaveArchiveFailure.quotaExceeded
        }
        return Preview(
            source: fileURL,
            sourceKind: .singleFile,
            fileCount: 1,
            totalBytes: size,
            meta: nil,
            folders: ["save"],
            payload: .files([PlannedDiskFile(targetFolder: "save", relativePath: name, fileURL: fileURL, byteSize: size)])
        )
    }

    // MARK: - Import (Replace vs Merge with atomic backup & rollback)

    /// Imports a preflighted save preview into `appFolder` (`save` / `save_device`), backing up any existing local save to
    /// `save-backups/YYYY-MM-DD HH.MM.SS before import`, preserving/resolving APFS case collisions, clearing `save.sync`,
    /// and rolling back cleanly if staging or swap fails.
    @discardableResult
    public static func performImport(
        _ preview: Preview,
        into appFolder: URL,
        mode: SaveImportMode,
        gameRunning: Bool,
        now: Date = Date(),
        fileManager fm: FileManager = .default,
        faultHook: ((String) throws -> Void)? = nil
    ) throws -> URL? {
        if gameRunning { throw SaveArchiveFailure.gameRunning }
        if hasPendingPullJournal(in: appFolder, fileManager: fm) { throw SaveArchiveFailure.pendingPullJournal }

        let save = appFolder.appendingPathComponent("save", isDirectory: true)
        try fm.createDirectory(at: appFolder, withIntermediateDirectories: true)

        let staging = appFolder.appendingPathComponent("save.import-stage-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        var trackers: [String: CaseDirectoryTracker] = [:]
        switch mode {
        case .replace:
            for folder in saveFolders {
                let stagedFolder = staging.appendingPathComponent(folder, isDirectory: true)
                if !preview.folders.contains(folder) {
                    let existing = targetFolder(folder, appFolder: appFolder)
                    if hasEntries(existing.path) {
                        try fm.copyItem(at: existing, to: stagedFolder)
                    }
                }
                trackers[folder] = CaseDirectoryTracker(root: stagedFolder, overwriteExisting: false)
            }
        case .merge:
            for folder in saveFolders {
                let stagedFolder = staging.appendingPathComponent(folder, isDirectory: true)
                let existing = targetFolder(folder, appFolder: appFolder)
                if hasEntries(existing.path) {
                    try fm.copyItem(at: existing, to: stagedFolder)
                }
                var tracker = CaseDirectoryTracker(root: stagedFolder, overwriteExisting: true)
                try tracker.seedExistingDirectory()
                trackers[folder] = tracker
            }
        }

        switch preview.payload {
        case .zip(let plannedFiles):
            guard !plannedFiles.isEmpty else { throw SaveArchiveFailure.nothingToImport }
            guard let handle = try? FileHandle(forReadingFrom: preview.source) else {
                throw SaveArchiveFailure.invalidArchive("Cannot open ZIP archive.")
            }
            defer { try? handle.close() }
            var remainingBudget = maxTotalBytes
            for item in plannedFiles {
                guard var tracker = trackers[item.targetFolder] else { continue }
                let destURL = try tracker.prepareFileDestination(relativePath: item.relativePath, fileManager: fm)
                trackers[item.targetFolder] = tracker
                try SaveZipCodec.extractToFile(
                    handle: handle,
                    entry: item.entry,
                    destination: destURL,
                    remainingBudget: &remainingBudget
                )
            }

        case .files(let plannedFiles):
            guard !plannedFiles.isEmpty else { throw SaveArchiveFailure.nothingToImport }
            var remainingBytes = maxTotalBytes
            var entryCount = 0
            for item in plannedFiles {
                entryCount += 1
                guard entryCount <= maxEntries else { throw SaveArchiveFailure.quotaExceeded }
                guard var tracker = trackers[item.targetFolder] else { continue }
                let destURL = try tracker.prepareFileDestination(relativePath: item.relativePath, fileManager: fm)
                trackers[item.targetFolder] = tracker
                try copyRegularFileNoFollow(from: item.fileURL, to: destURL, remainingBudget: &remainingBytes)
            }
        }

        // Enforce unified (entries, bytes) quota on the resulting staged save tree so merged saves stay cloud-sync safe.
        try verifyStagedQuota(staging: staging)

        var backupURL: URL?
        if hasLocalSaveEntries(in: appFolder) {
            let backupsRoot = CloudSaveSyncCheck.backupsRoot(in: appFolder)
            backupURL = try makeImportBackupDirectory(in: backupsRoot, now: now, fileManager: fm)
            do {
                for folder in saveFolders {
                    let src = targetFolder(folder, appFolder: appFolder)
                    if hasEntries(src.path) {
                        try fm.copyItem(at: src, to: backupURL!.appendingPathComponent(folder, isDirectory: true))
                    }
                }
            } catch {
                try? fm.removeItem(at: backupURL!)
                throw error
            }
        }

        try replaceSaveFolders(in: appFolder, from: staging, fileManager: fm, faultHook: faultHook)
        CloudSaveSyncCheck.clearBase(save: save)
        return backupURL
    }

    // MARK: - Export (JKSV compatible .zip)

    /// Packs `<appFolder>/save` and `<appFolder>/save_device` into a standard JKSV-compatible `.zip`
    /// with 86B `.nx_save_meta.bin` and restored `org.d2rmobile.guest-name` case-collision filenames.
    @discardableResult
    public static func exportJKSV(
        from appFolder: URL,
        titleID: String,
        to zipURL: URL,
        fileManager fm: FileManager = .default
    ) throws -> (file: URL, files: Int) {
        let save = appFolder.appendingPathComponent("save", isDirectory: true)
        let saveDevice = appFolder.appendingPathComponent("save_device", isDirectory: true)
        let resolvedDest = zipURL.standardizedFileURL.path
        let resolvedSave = save.standardizedFileURL.path
        let resolvedDevice = saveDevice.standardizedFileURL.path
        if resolvedDest == resolvedSave || resolvedDest.hasPrefix(resolvedSave + "/")
            || resolvedDest == resolvedDevice || resolvedDest.hasPrefix(resolvedDevice + "/") {
            throw SaveArchiveFailure.destinationInsideSave
        }

        let hasSave = hasEntries(save.path)
        let hasDevice = hasEntries(saveDevice.path)
        guard hasSave || hasDevice else { throw SaveArchiveFailure.nothingToExport }

        let includeFolderPrefix = hasSave && hasDevice
        let numericTID = UInt64(titleID, radix: 16) ?? 0
        let saveType: UInt8 = (!hasSave && hasDevice) ? 3 : 1

        var items: [SaveZipCodec.WriteItem] = [
            SaveZipCodec.WriteItem(
                archivePath: metaFileName,
                fileURL: nil,
                data: Meta(titleID: numericTID, saveType: saveType).encode(),
                modDate: Date()
            )
        ]

        for folder in saveFolders {
            let dir = targetFolder(folder, appFolder: appFolder).path
            guard hasEntries(dir) else { continue }
            var entries: [(archivePath: String, fileURL: URL, modDate: Date)] = []
            let ok = collectExportFiles(root: dir, folderPrefix: includeFolderPrefix ? folder : "", out: &entries)
            guard ok else { throw SaveArchiveFailure.invalidArchive("Cannot read local save files.") }
            for e in entries {
                items.append(SaveZipCodec.WriteItem(archivePath: e.archivePath, fileURL: e.fileURL, data: nil, modDate: e.modDate))
            }
        }

        let fileCount = items.count - 1
        guard fileCount > 0 else { throw SaveArchiveFailure.nothingToExport }
        guard items.count <= maxEntries else { throw SaveArchiveFailure.quotaExceeded }

        let parent = zipURL.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let tempZip = URL(fileURLWithPath: "\(zipURL.path).\(getpid()).tmp")
        try? fm.removeItem(at: tempZip)
        do {
            try SaveZipCodec.writeZip(items: items, to: tempZip, fileManager: fm)
            if rename(tempZip.path, zipURL.path) != 0 {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            try? fm.removeItem(at: tempZip)
            throw error
        }
        return (zipURL, fileCount)
    }

    /// Produces a filesystem-safe suggested filename such as `Stardew Valley [0100E65002BB8000].zip`.
    public static func suggestedExportFileName(gameTitle: String, titleID: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let parts = gameTitle.components(separatedBy: invalid).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeTitle = parts.isEmpty ? titleID.uppercased() : parts
        return "\(safeTitle) [\(titleID.uppercased())].zip"
    }

    // MARK: - Atomic folder swap & helpers

    private static func targetFolder(_ folder: String, appFolder: URL) -> URL {
        appFolder.appendingPathComponent(folder, isDirectory: true)
    }

    /// Replaces `appFolder/save` and `appFolder/save_device` from `stagedRoot`, keeping rollback `.old` until complete
    /// swap succeeds, unconditionally removing partial targets and restoring prior folders on any error.
    static func replaceSaveFolders(
        in appFolder: URL,
        from stagedRoot: URL,
        fileManager fm: FileManager = .default,
        faultHook: ((String) throws -> Void)? = nil
    ) throws {
        try fm.createDirectory(at: appFolder, withIntermediateDirectories: true)
        let rollbackRoot = appFolder.appendingPathComponent("save.rollback-\(UUID().uuidString)", isDirectory: true)
        var movedOld: [String] = []
        var swappedOK = false
        defer {
            if swappedOK {
                try? fm.removeItem(at: rollbackRoot)
            }
        }

        do {
            try fm.createDirectory(at: rollbackRoot, withIntermediateDirectories: true)
            for folder in saveFolders {
                let target = targetFolder(folder, appFolder: appFolder)
                if fm.fileExists(atPath: target.path) {
                    let backup = rollbackRoot.appendingPathComponent(folder, isDirectory: true)
                    try fm.moveItem(at: target, to: backup)
                    movedOld.append(folder)
                }
            }
            try faultHook?("afterMoveOld")
            for folder in saveFolders {
                let incoming = stagedRoot.appendingPathComponent(folder, isDirectory: true)
                let target = targetFolder(folder, appFolder: appFolder)
                if fm.fileExists(atPath: incoming.path) {
                    try fm.moveItem(at: incoming, to: target)
                }
            }
            try faultHook?("afterMoveIncoming")
            let mainSave = appFolder.appendingPathComponent("save", isDirectory: true)
            if !fm.fileExists(atPath: mainSave.path) {
                try fm.createDirectory(at: mainSave, withIntermediateDirectories: true)
            }
            swappedOK = true
        } catch {
            for folder in saveFolders {
                try? fm.removeItem(at: targetFolder(folder, appFolder: appFolder))
            }
            var restoredAll = true
            for folder in movedOld {
                let backup = rollbackRoot.appendingPathComponent(folder, isDirectory: true)
                let target = targetFolder(folder, appFolder: appFolder)
                do {
                    try fm.moveItem(at: backup, to: target)
                } catch {
                    restoredAll = false
                }
            }
            if restoredAll {
                try? fm.removeItem(at: rollbackRoot)
            }
            throw error
        }
    }

    private static func copyRegularFileNoFollow(from srcURL: URL, to dstURL: URL, remainingBudget: inout UInt64) throws {
        let srcFD = open(srcURL.path, O_RDONLY | O_NOFOLLOW)
        guard srcFD >= 0 else {
            throw SaveArchiveFailure.sourceUnreadable
        }
        defer { close(srcFD) }

        var st = stat()
        guard fstat(srcFD, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            throw SaveArchiveFailure.sourceUnreadable
        }

        let dstFD = open(dstURL.path, O_WRONLY | O_TRUNC | O_NOFOLLOW, 0o644)
        guard dstFD >= 0 else {
            throw SaveArchiveFailure.invalidArchive("Unable to open destination file for writing.")
        }
        defer { close(dstFD) }

        let chunkSize = 1 << 16
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buf.deallocate() }

        while true {
            let n = read(srcFD, buf, chunkSize)
            if n < 0 && errno == EINTR { continue }
            if n < 0 { throw SaveArchiveFailure.sourceUnreadable }
            if n == 0 { break }
            let count = UInt64(n)
            guard count <= remainingBudget else { throw SaveArchiveFailure.quotaExceeded }
            remainingBudget -= count
            var offset = 0
            while offset < n {
                let w = write(dstFD, buf.advanced(by: offset), n - offset)
                if w < 0 && errno == EINTR { continue }
                if w <= 0 { throw SaveArchiveFailure.invalidArchive("Disk write failed during import.") }
                offset += w
            }
        }
        var times = [st.st_atimespec, st.st_mtimespec]
        _ = futimens(dstFD, &times)
    }

    private static func verifyStagedQuota(staging: URL) throws {
        var entries = 0
        var totalBytes: UInt64 = 0
        for folder in saveFolders {
            let dir = staging.appendingPathComponent(folder, isDirectory: true)
            guard hasEntries(dir.path) else { continue }
            var exceededQuota = false
            let ok = walk(dir.path, folder) { _, _, st in
                entries += 1
                if entries > maxEntries {
                    exceededQuota = true
                    return false
                }
                if (st.st_mode & S_IFMT) == S_IFREG {
                    let sz = UInt64(max(0, st.st_size))
                    if sz > maxTotalBytes - totalBytes {
                        exceededQuota = true
                        return false
                    }
                    totalBytes += sz
                }
                return true
            }
            if exceededQuota { throw SaveArchiveFailure.quotaExceeded }
            if !ok { throw SaveArchiveFailure.invalidArchive("Failed to verify staged save tree.") }
        }
    }

    private static func isIgnoredMacMetadata(_ trimmedPath: String) -> Bool {
        if trimmedPath == "__MACOSX" || trimmedPath.hasPrefix("__MACOSX/") { return true }
        let last = (trimmedPath as NSString).lastPathComponent
        return last == ".DS_Store" || last.hasPrefix("._")
    }

    private static func detectWrapperPrefix(files: [SaveZipCodec.CentralEntry]) -> String? {
        let firstComponents = Set(files.compactMap { entry -> String? in
            let parts = entry.rawName.split(separator: "/", omittingEmptySubsequences: false)
            return parts.count >= 2 ? String(parts[0]) : nil
        })
        guard firstComponents.count == 1,
              files.allSatisfy({ $0.rawName.contains("/") }),
              let root = firstComponents.first else {
            return nil
        }
        let prefix = root + "/"
        let wrapsSaveFolders = files.contains {
            let rest = String($0.rawName.dropFirst(prefix.count))
            return rest.hasPrefix("save/") || rest.hasPrefix("save_device/")
        }
        return wrapsSaveFolders ? prefix : nil
    }

    // MARK: - APFS Case-Collision Tracker

    private struct CaseDirectoryTracker {
        let root: URL
        let overwriteExisting: Bool
        private var usedLowerNames: [String: [String: String]] = [:]
        private var exactMap: [String: [String: String]] = [:]
        private var incomingWritten: Set<String> = []

        init(root: URL, overwriteExisting: Bool) {
            self.root = root
            self.overwriteExisting = overwriteExisting
        }

        mutating func seedExistingDirectory() throws {
            guard hasEntries(root.path) else { return }
            func scanDir(_ absDir: String, _ parentKey: String) throws {
                guard let names = namesInByteOrder(absDir) else { return }
                for physicalName in names where physicalName != ".DS_Store" {
                    let abs = absDir + "/" + physicalName
                    var st = stat()
                    guard lstat(abs, &st) == 0 else { continue }
                    let kind = st.st_mode & S_IFMT
                    guard kind == S_IFDIR || kind == S_IFREG else { continue }
                    let guestName = resolvedGuestComponent(physical: physicalName, absPath: abs)
                    exactMap[parentKey, default: [:]][guestName] = physicalName
                    usedLowerNames[parentKey, default: [:]][physicalName.lowercased()] = guestName
                    if kind == S_IFDIR {
                        let nextKey = parentKey.isEmpty ? physicalName : "\(parentKey)/\(physicalName)"
                        try scanDir(abs, nextKey)
                    }
                }
            }
            try scanDir(root.path, "")
        }

        mutating func prepareFileDestination(relativePath: String, fileManager fm: FileManager) throws -> URL {
            let parts = relativePath.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { throw SaveArchiveFailure.unsafePath(relativePath) }
            try fm.createDirectory(at: root, withIntermediateDirectories: true)

            var currentURL = root
            var currentParentKey = ""

            for (idx, component) in parts.enumerated() {
                let isLast = (idx == parts.count - 1)
                let (physicalName, needsGuestAttr) = resolveName(component, under: currentParentKey)
                currentURL = currentURL.appendingPathComponent(physicalName, isDirectory: !isLast)
                let physicalRel = currentParentKey.isEmpty ? physicalName : "\(currentParentKey)/\(physicalName)"

                if !isLast {
                    if !fm.fileExists(atPath: currentURL.path) {
                        try fm.createDirectory(at: currentURL, withIntermediateDirectories: false)
                        if needsGuestAttr {
                            try writeGuestName(component, to: currentURL.path)
                        }
                    } else {
                        var isDir: ObjCBool = false
                        guard fm.fileExists(atPath: currentURL.path, isDirectory: &isDir), isDir.boolValue else {
                            throw SaveArchiveFailure.invalidArchive("Path conflict between file and directory: \(relativePath)")
                        }
                    }
                    currentParentKey = physicalRel
                } else {
                    if incomingWritten.contains(physicalRel) {
                        throw SaveArchiveFailure.invalidArchive("Duplicate file path in archive: \(relativePath)")
                    }
                    incomingWritten.insert(physicalRel)

                    if fm.fileExists(atPath: currentURL.path) {
                        guard overwriteExisting else {
                            throw SaveArchiveFailure.invalidArchive("Duplicate file path in archive: \(relativePath)")
                        }
                        var isDir: ObjCBool = false
                        if fm.fileExists(atPath: currentURL.path, isDirectory: &isDir), isDir.boolValue {
                            throw SaveArchiveFailure.invalidArchive("Path conflict between file and directory: \(relativePath)")
                        }
                        let fd = open(currentURL.path, O_WRONLY | O_TRUNC | O_NOFOLLOW, 0o644)
                        guard fd >= 0 else {
                            throw SaveArchiveFailure.invalidArchive("Cannot overwrite file at \(relativePath)")
                        }
                        close(fd)
                    } else {
                        let fd = open(currentURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
                        guard fd >= 0 else {
                            throw SaveArchiveFailure.invalidArchive("Cannot create file at \(relativePath)")
                        }
                        close(fd)
                        if needsGuestAttr {
                            try writeGuestName(component, to: currentURL.path)
                        }
                    }
                }
            }
            return currentURL
        }

        private mutating func resolveName(_ guestName: String, under parentKey: String) -> (physical: String, needsAttr: Bool) {
            if let existing = exactMap[parentKey]?[guestName] {
                return (existing, existing != guestName)
            }
            let lower = guestName.lowercased()
            let lowerTable = usedLowerNames[parentKey] ?? [:]
            if lowerTable[lower] == nil {
                exactMap[parentKey, default: [:]][guestName] = guestName
                usedLowerNames[parentKey, default: [:]][lower] = guestName
                return (guestName, false)
            }
            var n = 1
            while true {
                let candidate = ".dm-case-\(n)"
                let candLower = candidate.lowercased()
                if lowerTable[candLower] == nil {
                    exactMap[parentKey, default: [:]][guestName] = candidate
                    usedLowerNames[parentKey, default: [:]][candLower] = candidate
                    return (candidate, true)
                }
                n += 1
            }
        }

        private func writeGuestName(_ name: String, to path: String) throws {
            let bytes = Array(name.utf8)
            let rc = bytes.withUnsafeBytes { raw -> Int32 in
                guard let base = raw.baseAddress else { return -1 }
                return setxattr(path, guestAttr, base, bytes.count, 0, XATTR_NOFOLLOW)
            }
            guard rc == 0 else {
                throw SaveArchiveFailure.invalidArchive("Failed to record case-collision metadata.")
            }
        }
    }

    private static func collectExportFiles(
        root: String,
        folderPrefix: String,
        out: inout [(archivePath: String, fileURL: URL, modDate: Date)]
    ) -> Bool {
        func walkDir(_ absDir: String, _ guestRelDir: String) -> Bool {
            guard let names = namesInByteOrder(absDir) else { return false }
            for name in names where name != ".DS_Store" {
                let abs = absDir + "/" + name
                var st = stat()
                guard lstat(abs, &st) == 0 else { return false }
                let kind = st.st_mode & S_IFMT
                if kind == S_IFLNK { return false }
                guard kind == S_IFDIR || kind == S_IFREG else { continue }
                let guestName = resolvedGuestComponent(physical: name, absPath: abs)
                let rel = guestRelDir.isEmpty ? guestName : "\(guestRelDir)/\(guestName)"
                if kind == S_IFDIR {
                    if !walkDir(abs, rel) { return false }
                } else {
                    let modDate = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
                    out.append((rel, URL(fileURLWithPath: abs), modDate))
                }
            }
            return true
        }
        return walkDir(root, folderPrefix)
    }

    private static func resolvedGuestComponent(physical: String, absPath: String) -> String {
        guard physical.hasPrefix(".dm-case-") else { return physical }
        var buf = [UInt8](repeating: 0, count: 1024)
        let len = getxattr(absPath, guestAttr, &buf, buf.count, 0, XATTR_NOFOLLOW)
        guard len > 0 else { return physical }
        let decoded = String(bytes: buf.prefix(len), encoding: .utf8)
        return (decoded?.isEmpty == false) ? decoded! : physical
    }

    private static func makeImportBackupDirectory(in root: URL, now: Date, fileManager fm: FileManager) throws -> URL {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let stamp = CloudSaveSyncCheck.backupTimestamp(now)
        var name = "\(stamp) before import"
        var n = 2
        while fm.fileExists(atPath: root.appendingPathComponent(name).path) {
            name = "\(stamp) before import \(n)"
            n += 1
        }
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func namesInByteOrder(_ dir: String) -> [String]? {
        guard let d = opendir(dir) else { return nil }
        defer { closedir(d) }
        var out: [[UInt8]] = []
        while let e = readdir(d) {
            let name = withUnsafeBytes(of: e.pointee.d_name) { raw in
                Array(raw.prefix(Int(e.pointee.d_namlen)))
            }
            if name == [46] || name == [46, 46] { continue }
            out.append(name)
        }
        return out.sorted { $0.lexicographicallyPrecedes($1) }.map { String(decoding: $0, as: UTF8.self) }
    }

    private static func hasEntries(_ dir: String) -> Bool {
        (namesInByteOrder(dir) ?? []).contains { $0 != ".DS_Store" }
    }

    private static func walk(_ abs: String, _ rel: String, _ visit: (String, String, stat) -> Bool) -> Bool {
        guard let list = namesInByteOrder(abs) else { return false }
        for name in list where name != ".DS_Store" {
            let a = abs + "/" + name
            let r = rel + "/" + name
            var st = stat()
            guard lstat(a, &st) == 0 else { return false }
            switch st.st_mode & S_IFMT {
            case S_IFDIR:
                guard visit(a, r, st), walk(a, r, visit) else { return false }
            case S_IFREG:
                guard visit(a, r, st) else { return false }
            default:
                continue
            }
        }
        return true
    }
}
