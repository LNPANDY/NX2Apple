import Darwin
import Foundation

/// Safe pure-Swift JKSV `.zip` import/export for Switch and emulator saves,
/// with Central Directory preflight via `ZipCodec`, shared `(entries, bytes)` quota ledger,
/// `.nx_save_meta.bin` TitleID guard, `.dm-case-N` case-collision xattr mapping,
/// and atomic local save replacement or merge with backup & rollback.
package enum JKSVArchive {
    package static let maxEntries = ZipCodec.maxEntries
    package static let maxTotalBytes = ZipCodec.maxTotalBytes
    package static let metaFileName = ".nx_save_meta.bin"
    package static let metaByteCount = 86

    static let guestAttr = "org.d2rmobile.guest-name"
    private static let maxMetaBytes = 64 * 1024

    package enum Failure: Error, Equatable, Sendable {
        case gameRunning
        case pendingPullJournal
        case volumeCannotHoldSaves
        case invalidArchive(String)
        case unsafePath(String)
        case symlinkNotAllowed(String)
        case quotaExceeded
        case titleIDMismatch(expected: String, found: String)
        case nothingToImport
        case nothingToExport
        case destinationInsideSave
    }

    package struct Meta: Equatable, Sendable {
        package var titleID: UInt64
        package var saveType: UInt8

        package var formattedTitleID: String? {
            titleID == 0 ? nil : String(format: "%016llX", titleID)
        }

        package init(titleID: UInt64, saveType: UInt8) {
            self.titleID = titleID
            self.saveType = saveType
        }

        package static func parse(_ data: Data) -> Meta? {
            guard data.count >= metaByteCount else { return nil }
            let bytes = [UInt8](data.prefix(metaByteCount))
            guard Array(bytes[0..<4]) == Array("JKSV".utf8), bytes[4] == 1 else { return nil }
            var tid: UInt64 = 0
            for i in 0..<8 {
                tid |= UInt64(bytes[5 + i]) << (8 * i)
            }
            return Meta(titleID: tid, saveType: bytes[37])
        }

        package func encode() -> Data {
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

    package struct Preview: Equatable, Sendable {
        package var source: URL
        package var fileCount: Int
        package var totalBytes: UInt64
        package var meta: Meta?
        package var folders: [String]
        let plannedFiles: [PlannedFile]
    }

    struct PlannedFile: Equatable, Sendable {
        let targetFolder: String
        let relativePath: String
        let entry: ZipCodec.CentralEntry
    }

    // MARK: - Preview & Central Directory preflight

    /// Preflights a `.zip` archive completely from its Central Directory before extracting any payload.
    package static func preview(
        _ zipURL: URL,
        expectedTitleID: String,
        fileManager fm: FileManager = .default
    ) throws -> Preview {
        guard fm.fileExists(atPath: zipURL.path),
              let handle = try? FileHandle(forReadingFrom: zipURL) else {
            throw Failure.invalidArchive("Cannot open ZIP archive.")
        }
        defer { try? handle.close() }

        let entries = try ZipCodec.parseCentralDirectory(handle: handle)
        var wrapperPrefix: String?
        var metaEntry: ZipCodec.CentralEntry?

        var filteredFiles: [ZipCodec.CentralEntry] = []
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
                throw Failure.invalidArchive("Metadata file is too large.")
            }
            var budget = UInt64(maxMetaBytes)
            let metaData = try ZipCodec.extractData(handle: handle, entry: metaEntry, remainingBudget: &budget)
            meta = Meta.parse(metaData)
            if let meta, meta.titleID != 0 {
                let wantID = UInt64(expectedTitleID, radix: 16) ?? 0
                if wantID != 0 && meta.titleID != wantID {
                    throw Failure.titleIDMismatch(
                        expected: expectedTitleID.uppercased(),
                        found: String(format: "%016llX", meta.titleID)
                    )
                }
            }
        }

        guard !filteredFiles.isEmpty else { throw Failure.nothingToImport }

        if wrapperPrefix == nil {
            wrapperPrefix = detectWrapperPrefix(files: filteredFiles)
        }

        let stripped: [(String, ZipCodec.CentralEntry)] = filteredFiles.compactMap { entry in
            var rel = entry.rawName
            if let prefix = wrapperPrefix, rel.hasPrefix(prefix) {
                rel = String(rel.dropFirst(prefix.count))
            }
            guard !rel.isEmpty, rel != metaFileName else { return nil }
            return (rel, entry)
        }
        guard !stripped.isEmpty else { throw Failure.nothingToImport }

        let hasExplicitSaveFolders = stripped.contains { rel, _ in
            rel.hasPrefix("save/") || rel.hasPrefix("save_device/")
        }
        let defaultFolder = (meta?.saveType == 3) ? "save_device" : "save"

        var planned: [PlannedFile] = []
        var foldersSet: Set<String> = []
        var totalBytes: UInt64 = 0

        for (rel, entry) in stripped {
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
            guard !innerPath.isEmpty else { continue }
            guard entry.uncompressedSize <= maxTotalBytes - totalBytes else { throw Failure.quotaExceeded }
            totalBytes += entry.uncompressedSize
            foldersSet.insert(folder)
            planned.append(PlannedFile(targetFolder: folder, relativePath: innerPath, entry: entry))
        }

        guard !planned.isEmpty else { throw Failure.nothingToImport }
        let orderedFolders = ["save", "save_device"].filter { foldersSet.contains($0) }
        return Preview(
            source: zipURL,
            fileCount: planned.count,
            totalBytes: totalBytes,
            meta: meta,
            folders: orderedFolders,
            plannedFiles: planned
        )
    }

    // MARK: - Import & Export

    /// Atomically imports a preflighted `.zip` into `save` (replacing or merging), backing up any existing save first,
    /// stripping `.nx_save_meta.bin`, resolving APFS case collisions with `.dm-case-N` + xattr,
    /// and clearing `<save>.sync` on success so the next cloud sync detects the new save.
    @discardableResult
    package static func `import`(
        _ preview: Preview,
        into save: URL,
        mode: SaveImportMode = .replace,
        gameRunning: Bool,
        now: Date = Date(),
        volumeHolds: (String) -> Bool? = { VolumeSaves.holdsSaves(at: $0) },
        fileManager fm: FileManager = .default,
        faultHook: ((String) throws -> Void)? = nil
    ) throws -> URL? {
        if gameRunning { throw Failure.gameRunning }
        if CloudSaveCheck.hasPendingPullJournal(save: save, fm: fm) { throw Failure.pendingPullJournal }
        if volumeHolds(save.path) == false { throw Failure.volumeCannotHoldSaves }
        guard !preview.plannedFiles.isEmpty else { throw Failure.nothingToImport }

        guard let handle = try? FileHandle(forReadingFrom: preview.source) else {
            throw Failure.invalidArchive("Cannot open ZIP archive.")
        }
        defer { try? handle.close() }

        let parentDir = save.deletingLastPathComponent()
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let staging = URL(fileURLWithPath: save.path + ".jksv-stage-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        if mode == .merge {
            for folder in SaveMigration.folders {
                let existing = CloudSaveArchive.targetFolder(folder, save: save)
                if CloudSaveCheck.hasEntries(existing.path) {
                    try fm.copyItem(at: existing, to: staging.appendingPathComponent(folder, isDirectory: true))
                }
            }
        }

        var remainingBudget = maxTotalBytes
        var trackers: [String: CaseDirectoryTracker] = [
            "save": CaseDirectoryTracker(root: staging.appendingPathComponent("save", isDirectory: true), overwriteExisting: mode == .merge, fileManager: fm),
            "save_device": CaseDirectoryTracker(root: staging.appendingPathComponent("save_device", isDirectory: true), overwriteExisting: mode == .merge, fileManager: fm)
        ]

        for item in preview.plannedFiles {
            guard var tracker = trackers[item.targetFolder] else { continue }
            let destURL = try tracker.prepareFileDestination(relativePath: item.relativePath, fileManager: fm)
            trackers[item.targetFolder] = tracker
            try ZipCodec.extractToFile(
                handle: handle,
                entry: item.entry,
                destination: destURL,
                remainingBudget: &remainingBudget
            )
        }

        let backupsRoot = CloudSaveArchive.backupsRoot(for: save)
        var backupURL: URL?
        if CloudSaveArchive.hasLocalSaveEntries(save: save) {
            backupURL = try makeImportBackupDirectory(in: backupsRoot, now: now, fileManager: fm)
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

        if mode == .replace {
            for folder in SaveMigration.folders where !preview.folders.contains(folder) {
                let existing = CloudSaveArchive.targetFolder(folder, save: save)
                if CloudSaveCheck.hasEntries(existing.path) {
                    try fm.copyItem(at: existing, to: staging.appendingPathComponent(folder, isDirectory: true))
                }
            }
        }

        try CloudSaveArchive.replaceSaveFolders(save: save, from: staging, fileManager: fm, faultHook: faultHook)
        CloudSaveCheck.clearBase(save: save)
        return backupURL
    }

    /// Exports the game's committed `save` and `save_device` into a JKSV-compatible `.zip` with 86B `.nx_save_meta.bin`
    /// and restored case-collision `org.d2rmobile.guest-name` paths.
    @discardableResult
    package static func export(
        save: URL,
        titleID: String,
        to zipURL: URL,
        fileManager fm: FileManager = .default
    ) throws -> (file: URL, files: Int) {
        let resolvedDest = zipURL.standardizedFileURL.path
        let resolvedSave = save.standardizedFileURL.path
        if resolvedDest == resolvedSave || resolvedDest.hasPrefix(resolvedSave + "/") || resolvedDest.hasPrefix(resolvedSave + "_device/") {
            throw Failure.destinationInsideSave
        }

        let hasSave = CloudSaveCheck.hasEntries(save.path)
        let hasDevice = CloudSaveCheck.hasEntries(save.path + "_device")
        guard hasSave || hasDevice else { throw Failure.nothingToExport }

        let includeFolderPrefix = hasSave && hasDevice
        let numericTID = UInt64(titleID, radix: 16) ?? 0
        let saveType: UInt8 = (!hasSave && hasDevice) ? 3 : 1

        var items: [ZipCodec.WriteItem] = [
            ZipCodec.WriteItem(archivePath: metaFileName, fileURL: nil, data: Meta(titleID: numericTID, saveType: saveType).encode(), modDate: Date())
        ]

        for (index, folder) in SaveMigration.folders.enumerated() {
            let dir = index == 0 ? save.path : save.path + "_device"
            guard CloudSaveCheck.hasEntries(dir) else { continue }
            var entries: [(archivePath: String, fileURL: URL, modDate: Date)] = []
            let ok = collectExportFiles(root: dir, folderPrefix: includeFolderPrefix ? folder : "", out: &entries)
            guard ok else { throw Failure.invalidArchive("Cannot read local save files.") }
            for e in entries {
                items.append(ZipCodec.WriteItem(archivePath: e.archivePath, fileURL: e.fileURL, data: nil, modDate: e.modDate))
            }
        }

        let fileCount = items.count - 1
        guard fileCount > 0 else { throw Failure.nothingToExport }
        guard items.count <= maxEntries else { throw Failure.quotaExceeded }

        let parent = zipURL.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let tempZip = URL(fileURLWithPath: "\(zipURL.path).\(getpid()).tmp")
        try? fm.removeItem(at: tempZip)
        do {
            try ZipCodec.writeZip(items: items, to: tempZip, fileManager: fm)
            if rename(tempZip.path, zipURL.path) != 0 {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            try? fm.removeItem(at: tempZip)
            throw error
        }
        return (zipURL, fileCount)
    }

    // MARK: - Helpers & APFS case-collision tracker

    static func isIgnoredMacMetadata(_ trimmedPath: String) -> Bool {
        if trimmedPath == "__MACOSX" || trimmedPath.hasPrefix("__MACOSX/") { return true }
        let parts = trimmedPath.split(separator: "/")
        if parts.contains(where: { $0 == "__MACOSX" }) { return true }
        let last = (trimmedPath as NSString).lastPathComponent
        return last == ".DS_Store" || last.hasPrefix("._")
    }

    private static func detectWrapperPrefix(files: [ZipCodec.CentralEntry]) -> String? {
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
        if wrapsSaveFolders { return prefix }

        // Keep slot directories (like Stardew Valley's `<Farm>_<Seed>/`) intact when they are the sole top-level folder.
        let directChildNames = files.compactMap { entry -> String? in
            let rest = String(entry.rawName.dropFirst(prefix.count))
            return rest.contains("/") ? nil : rest
        }
        if SaveImport.isSlotFileSet(folderName: root, directFileNames: directChildNames) {
            return nil
        }

        // Unwrap a 16-hex Title ID wrapper or an outer container wrapping a slot subdirectory (e.g. `1RLtR8/Thien_335352527/SaveGameInfo`).
        let isTitleIDRoot = root.count == 16 && root.allSatisfy { $0.isASCII && $0.isHexDigit }
        if isTitleIDRoot { return prefix }

        var directSubdirFiles: [String: [String]] = [:]
        for entry in files {
            let rest = String(entry.rawName.dropFirst(prefix.count))
            let parts = rest.split(separator: "/", omittingEmptySubsequences: false)
            if parts.count == 2 {
                directSubdirFiles[String(parts[0]), default: []].append(String(parts[1]))
            }
        }
        if directSubdirFiles.contains(where: { SaveImport.isSlotFileSet(folderName: $0.key, directFileNames: $0.value) }) {
            return prefix
        }
        return nil
    }

    struct CaseDirectoryTracker {
        let root: URL
        let overwriteExisting: Bool
        private var usedLowerNames: [String: [String: String]] = [:]
        private var exactMap: [String: [String: String]] = [:]

        init(root: URL, overwriteExisting: Bool = false, fileManager fm: FileManager = .default) {
            self.root = root
            self.overwriteExisting = overwriteExisting
            if overwriteExisting, fm.fileExists(atPath: root.path) {
                seedExisting(at: root, parentKey: "", fileManager: fm)
            }
        }

        private mutating func seedExisting(at dir: URL, parentKey: String, fileManager fm: FileManager) {
            guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
            for physical in items where physical != ".DS_Store" && !physical.hasPrefix("._") {
                let abs = dir.appendingPathComponent(physical)
                var st = stat()
                guard lstat(abs.path, &st) == 0 else { continue }
                let guest = JKSVArchive.resolvedGuestComponent(physical: physical, absPath: abs.path)
                exactMap[parentKey, default: [:]][guest] = physical
                usedLowerNames[parentKey, default: [:]][physical.lowercased()] = guest
                if (st.st_mode & S_IFMT) == S_IFDIR {
                    let nextKey = parentKey.isEmpty ? physical : "\(parentKey)/\(physical)"
                    seedExisting(at: abs, parentKey: nextKey, fileManager: fm)
                }
            }
        }

        mutating func prepareFileDestination(relativePath: String, fileManager fm: FileManager) throws -> URL {
            let parts = relativePath.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { throw Failure.unsafePath(relativePath) }
            try fm.createDirectory(at: root, withIntermediateDirectories: true)

            var currentURL = root
            var currentParentKey = ""

            for (idx, component) in parts.enumerated() {
                let isLast = (idx == parts.count - 1)
                let (physicalName, needsGuestAttr) = resolveName(component, under: currentParentKey)
                currentURL = currentURL.appendingPathComponent(physicalName, isDirectory: !isLast)
                if !isLast {
                    if !fm.fileExists(atPath: currentURL.path) {
                        try fm.createDirectory(at: currentURL, withIntermediateDirectories: false)
                        if needsGuestAttr {
                            try writeGuestName(component, to: currentURL.path)
                        }
                    } else if overwriteExisting {
                        var st = stat()
                        if lstat(currentURL.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK {
                            throw Failure.symlinkNotAllowed(relativePath)
                        }
                    }
                    currentParentKey = currentParentKey.isEmpty ? physicalName : "\(currentParentKey)/\(physicalName)"
                } else {
                    if fm.fileExists(atPath: currentURL.path) {
                        if overwriteExisting {
                            var st = stat()
                            if lstat(currentURL.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK {
                                throw Failure.symlinkNotAllowed(relativePath)
                            }
                            try fm.removeItem(at: currentURL)
                        } else {
                            throw Failure.invalidArchive("Duplicate file path in ZIP archive: \(relativePath)")
                        }
                    }
                    let fd = open(currentURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
                    guard fd >= 0 else {
                        throw Failure.invalidArchive("Cannot create file at \(relativePath)")
                    }
                    close(fd)
                    if needsGuestAttr {
                        try writeGuestName(component, to: currentURL.path)
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
                throw Failure.invalidArchive("Failed to record case-collision metadata.")
            }
        }
    }

    private static func collectExportFiles(
        root: String,
        folderPrefix: String,
        out: inout [(archivePath: String, fileURL: URL, modDate: Date)]
    ) -> Bool {
        func walkDir(_ absDir: String, _ guestRelDir: String) -> Bool {
            guard let names = CloudSaveCheck.names(absDir) else { return false }
            for name in names where name != ".DS_Store" {
                let abs = absDir + "/" + name
                var st = stat()
                guard lstat(abs, &st) == 0 else { return false }
                let kind = st.st_mode & S_IFMT
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

    static func resolvedGuestComponent(physical: String, absPath: String) -> String {
        guard physical.hasPrefix(".dm-case-") else { return physical }
        var buf = [UInt8](repeating: 0, count: 1024)
        let len = getxattr(absPath, guestAttr, &buf, buf.count, 0, XATTR_NOFOLLOW)
        guard len > 0 else { return physical }
        let decoded = String(bytes: buf.prefix(len), encoding: .utf8)
        return (decoded?.isEmpty == false) ? decoded! : physical
    }

    static func makeImportBackupDirectory(in root: URL, now: Date, fileManager fm: FileManager) throws -> URL {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stamp = f.string(from: now)
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
}
