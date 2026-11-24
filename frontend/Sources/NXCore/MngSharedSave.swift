import Foundation

/// Shared `dm` save routing, MNG #2375 version/binary detection, `.app` `LSEnvironment` injection,
/// and first-time legacy MNG save migration for the 5 tuned unified-builder titles.
package enum MngSharedSave {
    /// Upstream merge commit of `ly05010419/MacNativeGames#2375` (`feat(save): allow optional DM_SAVE override for shared saves`).
    package static let externalDmSaveMergeCommit = "e0577ff2cb9db475a09b3b8cc9381092923ab7b1"

    /// The 5 tuned MNG titles built via `build_app.py` that support external `DM_SAVE` after MNG #2375.
    package static let supportedTitleIDs: Set<String> = MacNativeGamesBuilder.unifiedTitleIDs

    private static let ootTitleID = EngineUpstreamKind.ootSwitch2TitleID
    private static let binaryMarker = Data("host save storage (DM_SAVE):".utf8)

    private struct BinarySupportCacheEntry {
        let plistInode: UInt64
        let plistSize: UInt64
        let plistModified: TimeInterval
        let supported: Bool
    }

    private static let cacheLock = NSLock()
    private static var binarySupportCache: [String: BinarySupportCacheEntry] = [:]

    package static func supportsTitleID(_ titleID: String?) -> Bool {
        guard let normalized = MacNativeGamesBuilder.normalizedHex16(titleID) else { return false }
        return supportedTitleIDs.contains(normalized)
    }

    package static func invalidateCache(forApp path: String) {
        guard !path.isEmpty else { return }
        let key = URL(fileURLWithPath: path).standardizedFileURL.path
        cacheLock.lock()
        binarySupportCache.removeValue(forKey: key)
        cacheLock.unlock()
    }

    /// Detects whether a local MNG checkout contains #2375 (`prepare_external_save` + `use_dm_save` + `getenv("DM_SAVE")`).
    package static func checkoutSupportsSharedSave(
        forTitleID titleID: String? = nil,
        in tree: String,
        fileManager fm: FileManager = .default
    ) -> Bool {
        let trimmed = tree.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, MacNativeGamesBuilder.isUsableTree(trimmed, fileManager: fm) else { return false }

        let normalizedTID: String?
        if let titleID, !titleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let parsed = MacNativeGamesBuilder.normalizedHex16(titleID),
                  supportedTitleIDs.contains(parsed) else {
                return false
            }
            normalizedTID = parsed
        } else {
            normalizedTID = nil
        }

        let root = URL(fileURLWithPath: trimmed, isDirectory: true)
        func fileContains(_ rel: String, marker: String) -> Bool {
            let url = root.appendingPathComponent(rel)
            guard fm.fileExists(atPath: url.path),
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                return false
            }
            return text.contains(marker)
        }

        guard fileContains("shared/runtime/account.c", marker: "getenv(\"DM_SAVE\")") else {
            return false
        }

        let checksOOT = normalizedTID == nil || normalizedTID == ootTitleID
        let checksTOTK = normalizedTID == nil || normalizedTID != ootTitleID

        if checksTOTK {
            guard fileContains("games/totk/app/launcher.m", marker: "prepare_external_save"),
                  fileContains("games/totk/runtime/fs_host.c", marker: "use_dm_save") else {
                return false
            }
        }
        if checksOOT {
            guard fileContains("games/oot/app/launcher.m", marker: "prepare_external_save"),
                  fileContains("games/oot/runtime/fs_host.c", marker: "use_dm_save") else {
                return false
            }
        }
        return true
    }

    /// Detects whether a built MNG `.app` supports external `DM_SAVE` (#2375), checking its `Info.plist` markers first
    /// and falling back to scanning its executable binary for the #2375 `host save storage (DM_SAVE):` marker.
    package static func appSupportsSharedDMSave(
        appPath: String,
        titleID: String? = nil,
        fileManager fm: FileManager = .default
    ) -> Bool {
        guard !appPath.isEmpty else { return false }
        let bundleURL = URL(fileURLWithPath: appPath).standardizedFileURL
        let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let attr = try? fm.attributesOfItem(atPath: plistURL.path),
              let plistSize = attr[.size] as? UInt64,
              let plistModified = (attr[.modificationDate] as? Date)?.timeIntervalSince1970 else {
            return false
        }
        let plistInode = attr[.systemFileNumber] as? UInt64 ?? 0
        let cacheKey = bundleURL.path + "|" + (MacNativeGamesBuilder.normalizedHex16(titleID) ?? "")
        cacheLock.lock()
        if let cached = binarySupportCache[cacheKey],
           cached.plistInode == plistInode,
           cached.plistSize == plistSize,
           cached.plistModified == plistModified {
            cacheLock.unlock()
            return cached.supported
        }
        cacheLock.unlock()

        let supported = computeAppSupportsSharedDMSave(
            bundleURL: bundleURL,
            plistURL: plistURL,
            explicitTitleID: titleID,
            fileManager: fm
        )
        cacheLock.lock()
        if binarySupportCache.count >= 512 { binarySupportCache.removeAll(keepingCapacity: true) }
        binarySupportCache[cacheKey] = BinarySupportCacheEntry(
            plistInode: plistInode,
            plistSize: plistSize,
            plistModified: plistModified,
            supported: supported
        )
        cacheLock.unlock()
        return supported
    }

    private static func computeAppSupportsSharedDMSave(
        bundleURL: URL,
        plistURL: URL,
        explicitTitleID: String?,
        fileManager fm: FileManager
    ) -> Bool {
        guard let data = try? Data(contentsOf: plistURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return false
        }

        let explicitUpstream = (info["DMUpstream"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let bundleID = (info["CFBundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let isMNG = explicitUpstream == EngineUpstreamKind.macNativeGames.rawValue
            || (explicitUpstream == nil && (EngineUpstream.macNativeGamesBundleTitleIDs[bundleID] != nil || bundleID.hasPrefix("org.macnativegames.")))
        guard isMNG else { return false }

        let resolvedTitleID = MacNativeGamesBuilder.normalizedHex16(explicitTitleID)
            ?? MacNativeGamesBuilder.normalizedHex16(info["DMTitleID"] as? String)
            ?? MacNativeGamesBuilder.normalizedHex16(info["MNGTitleID"] as? String)
            ?? MacNativeGamesBuilder.normalizedHex16(EngineUpstream.macNativeGamesBundleTitleIDs[bundleID])
        guard supportsTitleID(resolvedTitleID) else { return false }

        if info["MNGSharedSave"] as? Bool == true {
            return true
        }
        if let lsEnv = info["LSEnvironment"] as? [String: Any],
           let rawSave = lsEnv["DM_SAVE"] as? String,
           !rawSave.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }

        guard let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty,
              executable != ".",
              executable != "..",
              !executable.contains("/") else {
            return false
        }
        let exeURL = bundleURL.appendingPathComponent("Contents/MacOS/" + executable)
        return fileContainsBytes(exeURL, marker: binaryMarker, fileManager: fm)
    }

    private static func fileContainsBytes(_ url: URL, marker: Data, fileManager fm: FileManager) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        if resolved.path == "/usr/bin/true" || resolved.path == "/bin/echo" {
            return false
        }
        guard fm.fileExists(atPath: resolved.path),
              let handle = try? FileHandle(forReadingFrom: resolved) else {
            return false
        }
        defer { try? handle.close() }
        let chunkSize = 262_144
        let overlap = max(0, marker.count - 1)
        var tail = Data()
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: chunkSize) ?? Data()
            } catch {
                return false
            }
            if chunk.isEmpty { break }
            var window = tail
            window.append(chunk)
            if window.range(of: marker) != nil {
                return true
            }
            if window.count > overlap {
                tail = window.subdata(in: (window.count - overlap)..<window.count)
            } else {
                tail = window
            }
        }
        return false
    }
}

/// Save engine descriptor for MNG #2375 builds of the 5 unified-builder games (`TOTK`, `BotW`, `Pokopia`, `DKB`, `OoT`).
/// Shares `dm` save layout with `nxnative`, injects `DM_SAVE` unconditionally (since MNG falls back to `profile/save/<uid>`
/// when `DM_SAVE` is unset), and relies on the launcher for `save.dmsync` pre-launch pull and post-exit push.
package struct MngSharedDmSaveEngine: SaveEngine {
    package init() {}
    package var saveKey: String { "DM_SAVE" }
    package var syncKey: String { CloudSaveSync.key }
    package var choiceKey: String { "DM_SAVE_SYNC_CHOICE" }
    package var unaskedChoice: String? { nil }
    package var psoUserKey: String? { "DM_PSO_USER" }
    package var savesInLibraryFolder: Bool { true }
    package var managesSavesInLauncher: Bool { true }
    package var sharesSaveWithNxnative: Bool { true }
    package var alwaysInjectsSavePath: Bool { true }
    package var syncsCloudInLauncher: Bool { true }

    package func defaultSave(titleID: String, support: URL) -> URL {
        DmSaveEngine().defaultSave(titleID: titleID, support: support)
    }

    package func playerEnvironment(name: String) -> [String: String] { [:] }
    package func takesChoice(app: String) -> Bool { false }
    package func reportCommand(app: String, wait: TimeInterval) -> [String]? { nil }
    package func sendCommand(app: String) -> [String]? { nil }
}

/// Injects `LSEnvironment["DM_SAVE"]` and metadata into built MNG `.app` bundles so Finder double-click,
/// Spotlight, launcher Play, and console mode all resolve the exact same shared `DM_SAVE` directory.
package enum MngAppLaunchConfig {
    package enum ConfigError: Error, LocalizedError {
        case invalidPlist(String)
        case codesignFailed(String)

        package var errorDescription: String? {
            switch self {
            case .invalidPlist(let path): return "Cannot read or update Info.plist at \(path)."
            case .codesignFailed(let detail): return "Failed to re-sign app bundle: \(detail)"
            }
        }
    }

    /// Writes `DM_SAVE` into `Contents/Info.plist` (`LSEnvironment`), stamps `MNGSharedSave`, `DMTitleID`, and `DMUpstream`,
    /// and preserves the bundle's designated identifier signature without `--deep`.
    package static func configure(
        appURL: URL,
        titleID: String,
        savePath: String,
        codesign: Bool = true,
        runner: ProcessRunner = SystemProcessRunner()
    ) throws {
        let tid = titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard MngSharedSave.supportsTitleID(tid), !savePath.isEmpty else { return }
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              var info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            throw ConfigError.invalidPlist(plistURL.path)
        }

        var lsEnv = info["LSEnvironment"] as? [String: Any] ?? [:]
        let currentEnvSave = lsEnv["DM_SAVE"] as? String
        let currentTID = (info["DMTitleID"] as? String)?.uppercased()
        let currentUpstream = (info["DMUpstream"] as? String)?.lowercased()
        let currentMarker = info["MNGSharedSave"] as? Bool ?? false
        if currentEnvSave == savePath && currentTID == tid && currentUpstream == EngineUpstreamKind.macNativeGames.rawValue && currentMarker {
            return
        }

        lsEnv["DM_SAVE"] = savePath
        info["LSEnvironment"] = lsEnv
        info["DMTitleID"] = tid
        info["DMUpstream"] = EngineUpstreamKind.macNativeGames.rawValue
        info["MNGSharedSave"] = true

        let outData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try outData.write(to: plistURL, options: .atomic)

        if codesign {
            let bundleID = (info["CFBundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var args = ["--force", "--sign", "-"]
            if !bundleID.isEmpty {
                args.append("-r=designated => identifier \"\(bundleID)\"")
            }
            args.append(appURL.path)
            let res = runner.capture(ProcessLaunch(executable: "/usr/bin/codesign", arguments: args))
            if !res.ok {
                throw ConfigError.codesignFailed(res.err.isEmpty ? res.out : res.err)
            }
        }

        MngSharedSave.invalidateCache(forApp: appURL.path)
        MacGameBundle.invalidateCache(forApp: appURL.path)
    }

    /// Synchronizes `LSEnvironment["DM_SAVE"]` for an existing #2375 MNG `.app` whenever save path settings change.
    package static func syncIfNeeded(
        appPath: String,
        titleID: String,
        global: SaveGlobalSettings,
        game: SaveGameOverride,
        support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
        isRunning: Bool = false,
        codesign: Bool = true,
        runner: ProcessRunner = SystemProcessRunner()
    ) {
        guard !isRunning, !appPath.isEmpty, MngSharedSave.appSupportsSharedDMSave(appPath: appPath, titleID: titleID) else {
            return
        }
        let target = SaveLocations.effectiveSave(
            titleID: titleID,
            appPath: appPath,
            global: global,
            game: game,
            support: support,
            engine: MngSharedDmSaveEngine()
        ).path.path
        try? configure(appURL: URL(fileURLWithPath: appPath), titleID: titleID, savePath: target, codesign: codesign, runner: runner)
    }
}

/// First-time migration between legacy MNG `profile/save/<uid>/` saves and shared `dm` saves.
/// Never deletes the legacy MNG folder or overwrites an existing `nxnative` save without backing it up first.
package enum MngSaveMigration {
    package enum Assessment: Equatable, Sendable {
        case none
        case mngOnly(mngSource: URL, nxTarget: URL, mngFiles: Int, mngNewest: Date?)
        case bothHaveSaves(mngSource: URL, nxTarget: URL, nxExisting: URL, mngFiles: Int, mngNewest: Date?, nxFiles: Int, nxNewest: Date?)

        package var mngSource: URL? {
            switch self {
            case .none: return nil
            case .mngOnly(let s, _, _, _): return s
            case .bothHaveSaves(let s, _, _, _, _, _, _): return s
            }
        }

        package var nxTarget: URL? {
            switch self {
            case .none: return nil
            case .mngOnly(_, let t, _, _): return t
            case .bothHaveSaves(_, let t, _, _, _, _, _): return t
            }
        }
    }

    package enum Choice: String, Codable, Equatable, Sendable {
        case importMNG
        case keepNxnative
    }

    package struct MigrationResult: Equatable, Sendable {
        package var choice: Choice
        package var backupURL: URL?
        package var copiedFiles: Int
    }

    package enum MigrationError: Error, Equatable, Sendable {
        case gameRunning
        case volumeCannotHoldSaves
        case sourceMissing
        case copyFailed
        case backupFailed
    }

    /// Resolves the active legacy MNG `<profile>/save/<uid>` directory if it exists on disk.
    package static func resolveLegacyMngSaveSource(
        titleID: String,
        support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
        fileManager fm: FileManager = .default
    ) -> URL? {
        guard MngSharedSave.supportsTitleID(titleID) else { return nil }
        let target = MacNativeGamesSaveEngine.resolveSaveTarget(titleID: titleID, support: support, environment: [:])
        if target.revealURL == target.displaySaveURL, isDirectory(target.displaySaveURL, fm: fm) {
            return target.displaySaveURL
        }
        // Fallback if users.txt is missing or stale: inspect `save/` for a unique non-empty 32-hex UID directory.
        let saveBase = target.displaySaveURL.lastPathComponent == "save"
            ? target.displaySaveURL
            : target.displaySaveURL.deletingLastPathComponent()
        guard isDirectory(saveBase, fm: fm),
              let entries = try? fm.contentsOfDirectory(at: saveBase, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        let uidDirs = entries.filter { url in
            let name = url.lastPathComponent
            return name.count == 32 && name.allSatisfy({ $0.isASCII && $0.isHexDigit }) && isDirectory(url, fm: fm) && fileStats(in: url, fm: fm).count > 0
        }
        return uidDirs.first
    }

    /// Assesses whether first-time shared-save migration needs user confirmation.
    package static func assess(
        titleID: String,
        appPath: String,
        global: SaveGlobalSettings,
        game: SaveGameOverride,
        support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
        fileManager fm: FileManager = .default,
        volumeHolds: (String) -> Bool? = { VolumeSaves.holdsSaves(at: $0) }
    ) -> Assessment {
        guard MngSharedSave.supportsTitleID(titleID) else { return .none }
        guard let mngSource = resolveLegacyMngSaveSource(titleID: titleID, support: support, fileManager: fm) else {
            return .none
        }
        let mngStats = fileStats(in: mngSource, fm: fm)
        guard mngStats.count > 0 else { return .none }

        let engine = MngSharedDmSaveEngine()
        let effective = SaveLocations.effectiveSave(
            titleID: titleID,
            appPath: appPath,
            global: global,
            game: game,
            support: support,
            engine: engine,
            volumeHolds: volumeHolds
        )
        let nxTarget = effective.path
        let legacyStd = engine.defaultSave(titleID: titleID, support: support)

        let targetStats = dmSaveStats(base: nxTarget, fm: fm)
        if targetStats.count > 0 {
            return .bothHaveSaves(
                mngSource: mngSource,
                nxTarget: nxTarget,
                nxExisting: nxTarget,
                mngFiles: mngStats.count,
                mngNewest: mngStats.newest,
                nxFiles: targetStats.count,
                nxNewest: targetStats.newest
            )
        }

        if effective.source == .libraryFolder && legacyStd.standardizedFileURL != nxTarget.standardizedFileURL {
            let legacyStats = dmSaveStats(base: legacyStd, fm: fm)
            if legacyStats.count > 0 {
                return .bothHaveSaves(
                    mngSource: mngSource,
                    nxTarget: nxTarget,
                    nxExisting: legacyStd,
                    mngFiles: mngStats.count,
                    mngNewest: mngStats.newest,
                    nxFiles: legacyStats.count,
                    nxNewest: legacyStats.newest
                )
            }
        }

        return .mngOnly(mngSource: mngSource, nxTarget: nxTarget, mngFiles: mngStats.count, mngNewest: mngStats.newest)
    }

    /// Executes the user's explicit migration choice.
    /// - `.keepNxnative`: leaves `nxTarget` and `mngSource` untouched.
    /// - `.importMNG`: backs up existing `nxnative` save (if any) to `<nxTarget>-backups/<stamp> nxnative`,
    ///   copies `mngSource` into `nxTarget` atomically, and keeps `mngSource` untouched as a backup.
    @discardableResult
    package static func execute(
        choice: Choice,
        assessment: Assessment,
        gameRunning: Bool,
        volumeHolds: (String) -> Bool? = { VolumeSaves.holdsSaves(at: $0) },
        now: () -> Date = Date.init,
        fileManager fm: FileManager = .default
    ) throws -> MigrationResult {
        if gameRunning { throw MigrationError.gameRunning }
        switch choice {
        case .keepNxnative:
            return MigrationResult(choice: .keepNxnative, backupURL: nil, copiedFiles: 0)
        case .importMNG:
            let mngSource: URL
            let nxTarget: URL
            let nxExisting: URL?
            switch assessment {
            case .none:
                throw MigrationError.sourceMissing
            case .mngOnly(let s, let t, _, _):
                mngSource = s
                nxTarget = t
                nxExisting = nil
            case .bothHaveSaves(let s, let t, let existing, _, _, _, _):
                mngSource = s
                nxTarget = t
                nxExisting = existing
            }

            guard fileStats(in: mngSource, fm: fm).count > 0 else {
                throw MigrationError.sourceMissing
            }
            if volumeHolds(nxTarget.path) == false {
                throw MigrationError.volumeCannotHoldSaves
            }

            let targetParent = nxTarget.deletingLastPathComponent()
            try? fm.createDirectory(at: targetParent, withIntermediateDirectories: true)

            let stage = targetParent.appendingPathComponent(".mng-migrate-stage-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: stage) }

            let copied: Int
            do {
                copied = try copyTreePreservingDates(from: mngSource, to: stage, fm: fm)
            } catch {
                throw MigrationError.copyFailed
            }
            guard copied > 0 else { throw MigrationError.sourceMissing }

            var backupURL: URL? = nil
            if let existing = nxExisting {
                let backupsRoot = targetParent.appendingPathComponent(nxTarget.lastPathComponent + "-backups", isDirectory: true)
                do {
                    backupURL = try backupExistingDmSave(existing: existing, backupsRoot: backupsRoot, now: now(), fm: fm)
                } catch {
                    throw MigrationError.backupFailed
                }
                if existing.standardizedFileURL != nxTarget.standardizedFileURL,
                   fm.fileExists(atPath: existing.path) || fm.fileExists(atPath: existing.path + "_device") {
                    try? fm.removeItem(at: existing)
                    try? fm.removeItem(atPath: existing.path + "_device")
                }
            }

            // Preserve target rollback copy while swapping in staged import.
            let oldTarget = targetParent.appendingPathComponent(".mng-migrate-old-\(UUID().uuidString)", isDirectory: true)
            let hadTarget = fm.fileExists(atPath: nxTarget.path)
            if hadTarget {
                do {
                    try fm.moveItem(at: nxTarget, to: oldTarget)
                } catch {
                    throw MigrationError.copyFailed
                }
            }
            do {
                try fm.moveItem(at: stage, to: nxTarget)
                if hadTarget { try? fm.removeItem(at: oldTarget) }
                // Remove stale dm device/work/new artifacts when replacing an existing save.
                if nxExisting != nil {
                    try? fm.removeItem(atPath: nxTarget.path + "_device")
                }
                try? fm.removeItem(atPath: nxTarget.path + ".work")
                try? fm.removeItem(atPath: nxTarget.path + ".new")
                return MigrationResult(choice: .importMNG, backupURL: backupURL, copiedFiles: copied)
            } catch {
                if hadTarget && fm.fileExists(atPath: oldTarget.path) {
                    try? fm.removeItem(at: nxTarget)
                    try? fm.moveItem(at: oldTarget, to: nxTarget)
                }
                throw MigrationError.copyFailed
            }
        }
    }

    /// Generates a deterministic fingerprint of MNG legacy source + shared target state for migration receipt tracking.
    package static func stateSignature(for assessment: Assessment) -> String {
        switch assessment {
        case .none:
            return "none"
        case .mngOnly(let s, _, let count, let newest):
            let stamp = newest.map { String(Int64($0.timeIntervalSince1970)) } ?? "0"
            return "mngOnly|\(s.path)|\(count)|\(stamp)"
        case .bothHaveSaves(let s, _, let existing, let mngCount, let mngNewest, let nxCount, let nxNewest):
            let mStamp = mngNewest.map { String(Int64($0.timeIntervalSince1970)) } ?? "0"
            let nStamp = nxNewest.map { String(Int64($0.timeIntervalSince1970)) } ?? "0"
            return "both|\(s.path)|\(mngCount)|\(mStamp)|\(existing.path)|\(nxCount)|\(nStamp)"
        }
    }

    // MARK: - Helpers

    private static func isDirectory(_ url: URL, fm: FileManager) -> Bool {
        var dir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }

    private static func dmSaveStats(base: URL, fm: FileManager) -> (count: Int, newest: Date?) {
        let account = fileStats(in: base, fm: fm)
        let device = fileStats(in: URL(fileURLWithPath: base.path + "_device", isDirectory: true), fm: fm)
        let total = account.count + device.count
        let newest: Date?
        switch (account.newest, device.newest) {
        case let (a?, b?): newest = max(a, b)
        case let (a?, nil): newest = a
        case let (nil, b?): newest = b
        case (nil, nil): newest = nil
        }
        return (total, newest)
    }

    private static func fileStats(in folder: URL, fm: FileManager) -> (count: Int, newest: Date?) {
        guard let walker = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]
        ) else {
            return (0, nil)
        }
        var count = 0
        var newest: Date?
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if name == ".DS_Store" || name.hasPrefix("._") { continue }
            guard let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  vals.isRegularFile == true else {
                continue
            }
            count += 1
            if let mtime = vals.contentModificationDate {
                newest = max(newest ?? mtime, mtime)
            }
        }
        return (count, newest)
    }

    private static func copyTreePreservingDates(from: URL, to: URL, fm: FileManager) throws -> Int {
        try fm.createDirectory(at: to, withIntermediateDirectories: true)
        var copied = 0
        for name in try fm.contentsOfDirectory(atPath: from.path) {
            if name == ".DS_Store" || name.hasPrefix("._") { continue }
            let src = from.appendingPathComponent(name)
            let dst = to.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                copied += try copyTreePreservingDates(from: src, to: dst, fm: fm)
            } else {
                if fm.fileExists(atPath: dst.path) {
                    try fm.removeItem(at: dst)
                }
                try fm.copyItem(at: src, to: dst)
                copied += 1
            }
        }
        return copied
    }

    private static func backupExistingDmSave(existing: URL, backupsRoot: URL, now: Date, fm: FileManager) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stamp = formatter.string(from: now)
        var dest = backupsRoot.appendingPathComponent("\(stamp) nxnative", isDirectory: true)
        var index = 2
        while fm.fileExists(atPath: dest.path) {
            dest = backupsRoot.appendingPathComponent("\(stamp) nxnative \(index)", isDirectory: true)
            index += 1
        }
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        var backedUp = 0
        if fileStats(in: existing, fm: fm).count > 0 {
            backedUp += try copyTreePreservingDates(from: existing, to: dest.appendingPathComponent("save", isDirectory: true), fm: fm)
        }
        let dev = URL(fileURLWithPath: existing.path + "_device", isDirectory: true)
        if fileStats(in: dev, fm: fm).count > 0 {
            backedUp += try copyTreePreservingDates(from: dev, to: dest.appendingPathComponent("save_device", isDirectory: true), fm: fm)
        }
        if backedUp == 0 {
            throw MigrationError.backupFailed
        }
        return dest
    }
}
