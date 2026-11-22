import Foundation

/// Off-game bidirectional `save.dmsync` inspection and synchronization for Mac games,
/// enforcing runtime mutual exclusion, `.pull` recovery journal protection, `.nosync` atomic cloud writes,
/// and Check-Read-Revalidate conflict safety.
package enum CloudSaveNow {
    package struct SyncPlan: Equatable, Sendable {
        package var titleID: String
        package var gameName: String
        package var save: URL
        package var legacySave: URL?
        package var cloudFile: URL
        package var isDefaultPlayer: Bool

        package init(
            titleID: String,
            gameName: String,
            save: URL,
            legacySave: URL? = nil,
            cloudFile: URL,
            isDefaultPlayer: Bool = true
        ) {
            self.titleID = titleID
            self.gameName = gameName
            self.save = save
            self.legacySave = legacySave
            self.cloudFile = cloudFile
            self.isDefaultPlayer = isDefaultPlayer
        }
    }

    package enum SyncOutcome: Equatable, Sendable {
        case alreadyInStep
        case pulled(backup: URL?)
        case pushed(backup: URL?)
    }

    package enum SyncFailure: Error, Equatable, Sendable {
        case gameRunning
        case pendingPullJournal
        case nonDefaultPlayer
        case volumeCannotHoldSaves
        case cloudUnreachable(String)
        case cloudWrongGame
        case cloudDamaged
        case conflict(local: CloudSaveCheck.Save, cloud: CloudSaveCheck.Save)
        case changedDuringOperation
        case packFailed
        case unpackFailed
        case writeFailed
    }

    package enum SyncStatus: Equatable, Sendable {
        case idle
        case checking
        case inStep(local: CloudSaveCheck.Save, cloud: CloudSaveCheck.Save?)
        case onlyCloudChanged(local: CloudSaveCheck.Save, cloud: CloudSaveCheck.Save)
        case onlyLocalChanged(local: CloudSaveCheck.Save, cloud: CloudSaveCheck.Save?)
        case conflict(local: CloudSaveCheck.Save, cloud: CloudSaveCheck.Save)
        case unreadable(local: CloudSaveCheck.Save, reason: SyncFailure)
        case pendingPullRecovery
        case nonDefaultPlayer
        case syncing
        case synced(SyncOutcome)
        case failed(SyncFailure)
    }

    /// Resolves which local save directory holds the active files (library save vs legacy `~/Library` save).
    package static func sourceSave(for plan: SyncPlan) -> URL {
        if CloudSaveCheck.localSave(save: plan.save)?.hash != nil {
            return plan.save
        }
        if let legacy = plan.legacySave, CloudSaveCheck.localSave(save: legacy)?.hash != nil {
            return legacy
        }
        return plan.save
    }

    /// Evaluates current local, base (`.sync`), and cloud (`save.dmsync`) state without modifying anything.
    package static func inspect(
        plan: SyncPlan,
        fetcher: any CloudFileFetching = CoordinatedCloudFetch(),
        cancelled: @escaping @Sendable () -> Bool = { false },
        fileManager fm: FileManager = .default
    ) -> SyncStatus {
        guard plan.isDefaultPlayer else { return .nonDefaultPlayer }
        guard !CloudSaveCheck.hasPendingPullJournal(save: plan.save, fm: fm) else { return .pendingPullRecovery }

        let scanSave = sourceSave(for: plan)
        guard let local = CloudSaveCheck.localSave(save: scanSave) else {
            return .failed(.unpackFailed)
        }
        let baseHash = CloudSaveCheck.base(save: plan.save)

        let cloudState = fetchAndVerifyCloud(plan: plan, fetcher: fetcher, cancelled: cancelled)
        switch cloudState {
        case .failure(let failure):
            return .unreadable(local: local, reason: failure)
        case .success(let cloud):
            let outcome = CloudSaveCheck.decide(local: local, base: baseHash, cloud: cloud)
            switch outcome {
            case .same:
                return .inStep(local: local, cloud: cloud.hash == nil ? nil : cloud)
            case .onlyCloudChanged:
                return .onlyCloudChanged(local: local, cloud: cloud)
            case .onlyLocalChanged, .noCloudSave:
                return .onlyLocalChanged(local: local, cloud: cloud.hash == nil ? nil : cloud)
            case .bothChanged:
                return .conflict(local: local, cloud: cloud)
            case .unreadable:
                return .unreadable(local: local, reason: .cloudDamaged)
            }
        }
    }

    /// Performs non-conflicting sync (`alreadyInStep`, `pull`, or `push`) with runtime and `.pull` safety guards.
    /// Returns `.failure(.conflict(local, cloud))` if both sides changed so the caller can ask the user.
    package static func syncNow(
        plan: SyncPlan,
        isRunning: @escaping @Sendable () -> Bool,
        fetcher: any CloudFileFetching = CoordinatedCloudFetch(),
        volumeHolds: (String) -> Bool? = { VolumeSaves.holdsSaves(at: $0) },
        now: @escaping @Sendable () -> Date = { Date() },
        cancelled: @escaping @Sendable () -> Bool = { false },
        fileManager fm: FileManager = .default
    ) -> Result<SyncOutcome, SyncFailure> {
        guard plan.isDefaultPlayer else { return .failure(.nonDefaultPlayer) }
        guard !isRunning() else { return .failure(.gameRunning) }
        guard !CloudSaveCheck.hasPendingPullJournal(save: plan.save, fm: fm) else { return .failure(.pendingPullJournal) }

        let scanSave = sourceSave(for: plan)
        guard let local = CloudSaveCheck.localSave(save: scanSave) else { return .failure(.unpackFailed) }
        let baseHash = CloudSaveCheck.base(save: plan.save)

        switch fetchAndVerifyCloud(plan: plan, fetcher: fetcher, cancelled: cancelled) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let cloud):
            let outcome = CloudSaveCheck.decide(local: local, base: baseHash, cloud: cloud)
            switch outcome {
            case .same:
                if let hash = local.hash, baseHash != hash {
                    _ = CloudSaveCheck.writeBase(save: plan.save, hash: hash)
                }
                return .success(.alreadyInStep)
            case .onlyCloudChanged:
                return pullCloud(
                    plan: plan,
                    expectedCloudHash: cloud.hash,
                    isRunning: isRunning,
                    volumeHolds: volumeHolds,
                    now: now,
                    fileManager: fm
                )
            case .onlyLocalChanged, .noCloudSave:
                return pushLocal(
                    plan: plan,
                    sourceSave: scanSave,
                    expectedLocalHash: local.hash,
                    backupExistingCloud: false,
                    isRunning: isRunning,
                    fileManager: fm
                )
            case .bothChanged:
                return .failure(.conflict(local: local, cloud: cloud))
            case .unreadable:
                return .failure(.cloudDamaged)
            }
        }
    }

    /// Resolves a conflict after the user picked `.cloud` or `.local`.
    /// Re-reads local and cloud states before writing (Check-Read-Revalidate) so external modifications are never overwritten blindly.
    package static func resolveConflict(
        _ choice: CloudSaveCheck.Choice,
        expectedLocalHash: String?,
        expectedCloudHash: String?,
        plan: SyncPlan,
        isRunning: @escaping @Sendable () -> Bool,
        fetcher: any CloudFileFetching = CoordinatedCloudFetch(),
        volumeHolds: (String) -> Bool? = { VolumeSaves.holdsSaves(at: $0) },
        now: @escaping @Sendable () -> Date = { Date() },
        cancelled: @escaping @Sendable () -> Bool = { false },
        fileManager fm: FileManager = .default
    ) -> Result<SyncOutcome, SyncFailure> {
        guard choice != .offline else { return .success(.alreadyInStep) }
        guard plan.isDefaultPlayer else { return .failure(.nonDefaultPlayer) }
        guard !isRunning() else { return .failure(.gameRunning) }
        guard !CloudSaveCheck.hasPendingPullJournal(save: plan.save, fm: fm) else { return .failure(.pendingPullJournal) }

        let scanSave = sourceSave(for: plan)
        guard let currentLocal = CloudSaveCheck.localSave(save: scanSave) else { return .failure(.unpackFailed) }
        guard currentLocal.hash == expectedLocalHash else { return .failure(.changedDuringOperation) }

        switch fetchAndVerifyCloud(plan: plan, fetcher: fetcher, cancelled: cancelled) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let currentCloud):
            guard currentCloud.hash == expectedCloudHash else { return .failure(.changedDuringOperation) }
            switch choice {
            case .cloud:
                return pullCloud(
                    plan: plan,
                    expectedCloudHash: currentCloud.hash,
                    isRunning: isRunning,
                    volumeHolds: volumeHolds,
                    now: now,
                    fileManager: fm
                )
            case .local:
                return pushLocal(
                    plan: plan,
                    sourceSave: scanSave,
                    expectedLocalHash: currentLocal.hash,
                    backupExistingCloud: currentCloud.hash != nil,
                    now: now,
                    isRunning: isRunning,
                    fileManager: fm
                )
            case .offline:
                return .success(.alreadyInStep)
            }
        }
    }

    // MARK: - Internal helpers

    private static func fetchAndVerifyCloud(
        plan: SyncPlan,
        fetcher: any CloudFileFetching,
        cancelled: @escaping @Sendable () -> Bool
    ) -> Result<CloudSaveCheck.Save, SyncFailure> {
        switch fetcher.fetch(plan.cloudFile, cancelled: cancelled) {
        case .cancelled:
            return .failure(.cloudUnreachable("Sync cancelled."))
        case .failed(let reason):
            return .failure(.cloudUnreachable(reason))
        case .missing:
            return .success(.empty)
        case .ready:
            guard let verified = CloudSaveArchive.readArchive(at: plan.cloudFile, into: nil) else {
                return .failure(.cloudDamaged)
            }
            if let packedTitle = verified.titleID, !packedTitle.isEmpty,
               packedTitle.caseInsensitiveCompare(plan.titleID) != .orderedSame {
                return .failure(.cloudWrongGame)
            }
            return .success(verified.save)
        }
    }

    private static func pullCloud(
        plan: SyncPlan,
        expectedCloudHash: String?,
        isRunning: @escaping @Sendable () -> Bool,
        volumeHolds: (String) -> Bool?,
        now: @escaping @Sendable () -> Date,
        fileManager fm: FileManager
    ) -> Result<SyncOutcome, SyncFailure> {
        guard let cloudHash = expectedCloudHash, !cloudHash.isEmpty else { return .failure(.cloudDamaged) }
        guard volumeHolds(plan.save.path) != false else { return .failure(.volumeCannotHoldSaves) }
        guard !isRunning() else { return .failure(.gameRunning) }
        guard !CloudSaveCheck.hasPendingPullJournal(save: plan.save, fm: fm) else { return .failure(.pendingPullJournal) }

        let staging = URL(fileURLWithPath: plan.save.path + ".sync-stage-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            return .failure(.writeFailed)
        }

        guard let unpacked = CloudSaveArchive.readArchive(at: plan.cloudFile, into: staging, fileManager: fm),
              unpacked.save.hash == cloudHash else {
            return .failure(.unpackFailed)
        }
        if let packedTitle = unpacked.titleID, !packedTitle.isEmpty,
           packedTitle.caseInsensitiveCompare(plan.titleID) != .orderedSame {
            return .failure(.cloudWrongGame)
        }

        guard !isRunning() else { return .failure(.gameRunning) }

        var backupURL: URL?
        if CloudSaveArchive.hasLocalSaveEntries(save: plan.save) {
            do {
                backupURL = try CloudSaveArchive.backupLocalSave(
                    save: plan.save,
                    now: now(),
                    side: "local",
                    prune: false,
                    fileManager: fm
                )
            } catch {
                return .failure(.writeFailed)
            }
        }

        do {
            try CloudSaveArchive.replaceSaveFolders(save: plan.save, from: staging, fileManager: fm)
        } catch {
            return .failure(.writeFailed)
        }

        if let backupURL {
            CloudSaveArchive.pruneBackups(
                for: plan.save,
                side: "local",
                protectedNames: [backupURL.lastPathComponent],
                fileManager: fm
            )
        }
        guard CloudSaveCheck.writeBase(save: plan.save, hash: cloudHash) else {
            return .failure(.writeFailed)
        }
        return .success(.pulled(backup: backupURL))
    }

    private static func pushLocal(
        plan: SyncPlan,
        sourceSave: URL,
        expectedLocalHash: String?,
        backupExistingCloud: Bool,
        now: @escaping @Sendable () -> Date = { Date() },
        isRunning: @escaping @Sendable () -> Bool,
        fileManager fm: FileManager
    ) -> Result<SyncOutcome, SyncFailure> {
        guard !isRunning() else { return .failure(.gameRunning) }
        guard !CloudSaveCheck.hasPendingPullJournal(save: plan.save, fm: fm) else { return .failure(.pendingPullJournal) }
        guard let currentHash = CloudSaveCheck.localSave(save: sourceSave)?.hash,
              currentHash == expectedLocalHash else {
            return .failure(.changedDuringOperation)
        }

        var backupURL: URL?
        if backupExistingCloud, fm.fileExists(atPath: plan.cloudFile.path) {
            do {
                backupURL = try CloudSaveArchive.backupCloudArchive(
                    cloudFile: plan.cloudFile,
                    save: plan.save,
                    now: now(),
                    fileManager: fm
                )
            } catch {
                return .failure(.writeFailed)
            }
        }

        guard !isRunning() else { return .failure(.gameRunning) }
        guard let packed = CloudSaveArchive.writeCloudAtomically(
            save: sourceSave,
            titleID: plan.titleID,
            to: plan.cloudFile,
            fileManager: fm
        ), let packedHash = packed.save.hash else {
            return .failure(.packFailed)
        }

        guard CloudSaveCheck.writeBase(save: plan.save, hash: packedHash) else {
            return .failure(.writeFailed)
        }
        return .success(.pushed(backup: backupURL))
    }
}
