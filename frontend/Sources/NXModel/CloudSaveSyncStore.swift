import Combine
import Foundation
import NXCore

/// Manages off-game immediate `save.dmsync` status inspection, synchronization, and conflict resolution for a Mac game.
/// All blocking filesystem / iCloud coordination runs off the main actor and validates both a generation token
/// and active `titleID` before writing back.
@MainActor package final class CloudSaveSyncStore: ObservableObject {
    package struct ConflictPrompt: Equatable, Identifiable, Sendable {
        package var id = UUID()
        package var plan: CloudSaveNow.SyncPlan
        package var local: CloudSaveCheck.Save
        package var cloud: CloudSaveCheck.Save
        package var backupsFolder: URL

        package init(plan: CloudSaveNow.SyncPlan, local: CloudSaveCheck.Save, cloud: CloudSaveCheck.Save) {
            self.plan = plan
            self.local = local
            self.cloud = cloud
            self.backupsFolder = CloudSaveArchive.backupsRoot(for: plan.save)
        }
    }

    @Published package var status: CloudSaveNow.SyncStatus = .idle
    @Published package var conflict: ConflictPrompt?
    @Published package var lastOutcome: CloudSaveNow.SyncOutcome?
    @Published package var lastFailure: CloudSaveNow.SyncFailure?
    @Published package private(set) var busy = false

    private let fetcher: any CloudFileFetching
    private let volumeHolds: @Sendable (String) -> Bool?
    private let now: @Sendable () -> Date
    private var generation: UInt64 = 0
    private var activeTitleID: String?

    package init(
        fetcher: any CloudFileFetching = CoordinatedCloudFetch(),
        volumeHolds: @escaping @Sendable (String) -> Bool? = { VolumeSaves.holdsSaves(at: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetcher = fetcher
        self.volumeHolds = volumeHolds
        self.now = now
    }

    package func reset() {
        generation &+= 1
        activeTitleID = nil
        busy = false
        status = .idle
        conflict = nil
        lastOutcome = nil
        lastFailure = nil
    }

    @discardableResult
    package func inspect(plan: CloudSaveNow.SyncPlan) -> Task<Void, Never> {
        // Never bump generation or clobber state while a sync/conflict operation is in flight.
        guard !busy else { return Task {} }
        generation &+= 1
        let gen = generation
        let normalizedID = plan.titleID.uppercased()
        activeTitleID = normalizedID
        let fetcher = self.fetcher
        lastOutcome = nil
        lastFailure = nil
        status = .checking
        return Task { [weak self] in
            let measured = await Task.detached(priority: .utility) {
                CloudSaveNow.inspect(plan: plan, fetcher: fetcher)
            }.value
            guard let self,
                  self.generation == gen,
                  self.activeTitleID == normalizedID,
                  !self.busy else { return }
            self.status = measured
        }
    }

    @discardableResult
    package func syncNow(
        plan: CloudSaveNow.SyncPlan,
        isRunning: @escaping @Sendable () -> Bool
    ) -> Task<Void, Never> {
        guard !busy else { return Task {} }
        generation &+= 1
        let gen = generation
        let normalizedID = plan.titleID.uppercased()
        activeTitleID = normalizedID
        let fetcher = self.fetcher
        let volumeHolds = self.volumeHolds
        let now = self.now
        busy = true
        lastOutcome = nil
        lastFailure = nil
        conflict = nil
        status = .syncing

        return Task { [weak self] in
            let outcome: (Result<CloudSaveNow.SyncOutcome, CloudSaveNow.SyncFailure>, CloudSaveNow.SyncStatus) = await Task.detached(priority: .userInitiated) {
                let res = CloudSaveNow.syncNow(
                    plan: plan,
                    isRunning: isRunning,
                    fetcher: fetcher,
                    volumeHolds: volumeHolds,
                    now: now
                )
                let refreshed = CloudSaveNow.inspect(plan: plan, fetcher: fetcher)
                return (res, refreshed)
            }.value
            guard let self,
                  self.generation == gen,
                  self.activeTitleID == normalizedID else { return }
            self.busy = false
            switch outcome.0 {
            case .success(let done):
                self.lastOutcome = done
                self.status = outcome.1
            case .failure(let failure):
                if case .conflict(let local, let cloud) = failure {
                    self.conflict = ConflictPrompt(plan: plan, local: local, cloud: cloud)
                    self.status = .conflict(local: local, cloud: cloud)
                } else {
                    self.lastFailure = failure
                    self.status = .failed(failure)
                }
            }
        }
    }

    @discardableResult
    package func resolveConflict(
        _ choice: CloudSaveCheck.Choice,
        prompt: ConflictPrompt,
        isRunning: @escaping @Sendable () -> Bool
    ) -> Task<Void, Never> {
        guard !busy else { return Task {} }
        generation &+= 1
        let gen = generation
        let normalizedID = prompt.plan.titleID.uppercased()
        activeTitleID = normalizedID
        let fetcher = self.fetcher
        let volumeHolds = self.volumeHolds
        let now = self.now
        busy = true
        conflict = nil
        lastOutcome = nil
        lastFailure = nil
        status = .syncing

        return Task { [weak self] in
            let outcome: (Result<CloudSaveNow.SyncOutcome, CloudSaveNow.SyncFailure>, CloudSaveNow.SyncStatus) = await Task.detached(priority: .userInitiated) {
                let res = CloudSaveNow.resolveConflict(
                    choice,
                    expectedLocalHash: prompt.local.hash,
                    expectedCloudHash: prompt.cloud.hash,
                    plan: prompt.plan,
                    isRunning: isRunning,
                    fetcher: fetcher,
                    volumeHolds: volumeHolds,
                    now: now
                )
                let refreshed = CloudSaveNow.inspect(plan: prompt.plan, fetcher: fetcher)
                return (res, refreshed)
            }.value
            guard let self,
                  self.generation == gen,
                  self.activeTitleID == normalizedID else { return }
            self.busy = false
            switch outcome.0 {
            case .success(let done):
                self.lastOutcome = done
                self.status = outcome.1
            case .failure(let failure):
                self.lastFailure = failure
                self.status = .failed(failure)
            }
        }
    }
}
