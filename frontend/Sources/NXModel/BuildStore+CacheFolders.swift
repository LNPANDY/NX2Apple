import Foundation
import NXCore

// The cache folders Settings can move (#427): the shell cache, the nxkit work folder and the build seeds. Each has a row in
// Settings, Tools, with Open, Move and the way back to the default place. A move runs on the build store's `running` flag, as the
// copy to a drive does, so no build, install or export starts while it runs, and it cannot start while one of them runs. One move
// runs at a time. The rules and the file work are CacheFolderMove's, the places are BuildCacheRoots' (and ShellLibrary's for the
// shell cache).
//
// A saved root on an external drive that is not connected is not reachable: a build that writes there stops before it starts,
// with a note that says so, rather than make the folder on this Mac's disk. The row still offers the way back to the default.

/// The caches Settings can move.
package enum CacheFolder: String, CaseIterable, Sendable {
    case shell, nxkit, seeds
}

/// The state of a cache folder's move, as its row shows it.
package enum CacheMove: Equatable {
    case idle
    /// The confirmation: from where to where, the sizes, and what stops it.
    case confirm(CacheFolderMove.Plan)
    case moving(phase: CacheFolderMove.Phase, done: Int64, total: Int64)
    /// The cache is in its new place (the path).
    case moved(String)
    /// The cache is in its new place, but the old folder could not be removed fully (new place, old place).
    case movedOldStays(String, old: String)
    /// Stopped: the cache stays where it was (the path).
    case stopped(String)
    /// The move failed: the reason, and where the cache stays.
    case failed(String, stays: String)
}

/// The shell cache's move state had this name first.
package typealias ShellMove = CacheMove

extension BuildStore {
    // MARK: The places

    /// The nxkit work root: one folder per game inside it (NxkitBuilder.workDirectory).
    package var nxkitWorkRoot: String { BuildCacheRoots.nxkitRoot(defaults: defaults, home: home) }
    /// The build seed root: `DM_SEED_CACHE_DIR` of the launcher's environment, else the saved one, else the default.
    package var seedCacheRoot: String { BuildCacheRoots.seedRoot(defaults: defaults, home: home, env: launcherEnvironment) }
    /// Where a Fast Refresh without an output folder builds: beside the seed root.
    package var refreshBuildsRoot: String { BuildCacheRoots.refreshBuilds(seedRoot: seedCacheRoot) }
    /// What every engine process gets added to its environment: the seed root when it is not the default.
    package var seedEnvironment: [String: String] { BuildCacheRoots.seedEnvironment(defaults: defaults, home: home, env: launcherEnvironment) }

    package func cachePath(_ cache: CacheFolder) -> String {
        switch cache {
        case .shell: return shellCachePath
        case .nxkit: return nxkitWorkRoot
        case .seeds: return seedCacheRoot
        }
    }

    package func defaultCachePath(_ cache: CacheFolder) -> String {
        switch cache {
        case .shell: return ShellRootMigration.defaultRoot(home: home)
        case .nxkit: return BuildCacheRoots.defaultNxkitRoot(home: home)
        case .seeds: return BuildCacheRoots.defaultSeedRoot(home: home)
        }
    }

    /// The cache is in the default place, so there is no way back to offer.
    package func cacheIsDefault(_ cache: CacheFolder) -> Bool { cachePath(cache) == defaultCachePath(cache) }

    /// The cache's folder is on an external drive that is not connected.
    package func cacheUnreachable(_ cache: CacheFolder) -> Bool { BuildCacheRoots.unreachable(cachePath(cache), volumes: volumesRoot) }

    /// The launcher's environment names the seed root (`DM_SEED_CACHE_DIR`): a move would not change the folder that is used.
    package func cacheFixedByEnvironment(_ cache: CacheFolder) -> Bool {
        cache == .seeds && BuildCacheRoots.seedRootFromEnvironment(launcherEnvironment)
    }

    /// Why an nxkit build cannot use its work folder (`nil`: it can): the drive with it is not connected.
    package func nxkitWorkRootProblem() -> String? {
        cacheUnreachable(.nxkit) ? String(format: t("nxkitCache.driveMissing"), shortPath(nxkitWorkRoot)) : nil
    }

    /// Why an engine build cannot write its build seed (`nil`: it can): the drive with the seeds is not connected.
    package func seedRootProblem() -> String? {
        cacheUnreachable(.seeds) ? String(format: t("seedCache.driveMissing"), shortPath(seedCacheRoot)) : nil
    }

    // MARK: The move

    package func cacheMove(_ cache: CacheFolder) -> CacheMove {
        switch cache {
        case .shell: return shellMove
        case .nxkit: return nxkitMove
        case .seeds: return seedMove
        }
    }

    private func setCacheMove(_ cache: CacheFolder, _ state: CacheMove) {
        switch cache {
        case .shell: shellMove = state
        case .nxkit: nxkitMove = state
        case .seeds: seedMove = state
        }
    }

    /// A cache folder is moving now.
    package var cacheMoveRuns: Bool {
        CacheFolder.allCases.contains { if case .moving = cacheMove($0) { return true } else { return false } }
    }

    /// The confirmation for a move into `folder` (the cache goes into a new folder inside it).
    package func prepareCacheMove(_ cache: CacheFolder, into folder: String) {
        let destination: String
        switch cache {
        case .shell: destination = ShellRootMove.destination(inside: folder)
        case .nxkit: destination = BuildCacheRoots.nxkitDestination(inside: folder)
        case .seeds: destination = BuildCacheRoots.seedDestination(inside: folder)
        }
        prepareCacheMove(cache, to: destination)
    }

    /// The confirmation for the way back to the default place.
    package func prepareCacheMoveToDefault(_ cache: CacheFolder) {
        prepareCacheMove(cache, to: defaultCachePath(cache))
    }

    private func prepareCacheMove(_ cache: CacheFolder, to destination: String) {
        guard !cacheMoveRuns, !cacheFixedByEnvironment(cache) else { return }
        setCacheMove(cache, .confirm(cachePlan(cache, to: destination)))
    }

    private func cachePlan(_ cache: CacheFolder, to destination: String) -> CacheFolderMove.Plan {
        let source = cachePath(cache)
        switch cache {
        case .shell: return ShellRootMove.plan(from: source, to: destination)
        case .nxkit: return CacheFolderMove.plan(BuildCacheRoots.nxkitMoves(from: source, to: destination))
        case .seeds: return CacheFolderMove.plan(BuildCacheRoots.seedMoves(from: source, to: destination))
        }
    }

    /// The confirmed move starts, off the main thread. Refused while a build, an install, an export or another move runs.
    @discardableResult
    package func confirmCacheMove(_ cache: CacheFolder) -> Task<Void, Never>? {
        guard !running, case .confirm(let shown) = cacheMove(cache) else { return nil }
        // Plan again: a build may have written to the cache since the confirmation was shown
        let plan = cachePlan(cache, to: shown.destination)
        guard plan.problem == nil else { setCacheMove(cache, .confirm(plan)); return nil }
        buildingGame = false; runningTarget = BuildTarget.ios
        running = true
        shellMoveStop.set(false)
        setCacheMove(cache, .moving(phase: .copying, done: 0, total: plan.bytes))
        let stop = shellMoveStop
        return Task { @MainActor in
            let outcome = await Task.detached(priority: .userInitiated) {
                CacheFolderMove.run(plan, progress: { phase, done, total in
                    hop { [weak self] in
                        guard let self, case .moving = self.cacheMove(cache) else { return }
                        self.setCacheMove(cache, .moving(phase: phase, done: done, total: total))
                    }
                }, stop: { stop.value })
            }.value
            self.finishCacheMove(cache, plan, outcome)
        }
    }

    /// Stop while a cache moves: the partial copy goes, the old folder stays as it was and keeps being used.
    package func stopCacheMove() { shellMoveStop.set(true) }

    /// Back to the plain row, after the confirmation or the result.
    package func dismissCacheMove(_ cache: CacheFolder) {
        if case .moving = cacheMove(cache) { return }
        setCacheMove(cache, .idle)
    }

    private func saveCacheRoot(_ cache: CacheFolder, _ root: String) {
        switch cache {
        case .shell:
            defaults.set(root, forKey: "shellRoot")
            if root == ShellRootMigration.defaultRoot(home: home) { defaults.removeObject(forKey: ShellRootMove.pickedKey) }
            else { defaults.set(true, forKey: ShellRootMove.pickedKey) }
        case .nxkit:
            BuildCacheRoots.save(root, key: BuildCacheRoots.nxkitKey, default: defaultCachePath(.nxkit), defaults: defaults)
        case .seeds:
            BuildCacheRoots.save(root, key: BuildCacheRoots.seedKey, default: defaultCachePath(.seeds), defaults: defaults)
        }
    }

    private func finishCacheMove(_ cache: CacheFolder, _ plan: CacheFolderMove.Plan, _ outcome: CacheFolderMove.Outcome) {
        running = false
        let name = ["shell": "Cache folder", "nxkit": "nxkit work folder", "seeds": "Build seeds"][cache.rawValue] ?? "Cache folder"
        switch outcome {
        case .moved:
            saveCacheRoot(cache, plan.destination)
            setCacheMove(cache, .moved(plan.destination))
            say("\(name) moved: \(plan.source) → \(plan.destination)")
        case .movedOldStays:
            saveCacheRoot(cache, plan.destination)
            setCacheMove(cache, .movedOldStays(plan.destination, old: plan.source))
            say("\(name) moved to \(plan.destination), the old folder \(plan.source) could not be removed fully")
        case .stopped:
            setCacheMove(cache, .stopped(plan.source))
        case .failed(let failure):
            let why: String
            switch failure {
            case .io(let text): why = text.trimmingCharacters(in: CharacterSet(charactersIn: ".。 "))   // the text goes on after it
            case .mismatch(let path): why = String(format: t("shellCache.fail.mismatch"), path)
            case .ledger: why = t("shellCache.fail.ledger")
            }
            setCacheMove(cache, .failed(why, stays: plan.source))
            say("\(name) not moved (\(why)), it stays in \(plan.source)")
        }
    }
}
