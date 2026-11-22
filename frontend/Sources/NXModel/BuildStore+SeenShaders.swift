import Foundation
import NXCore

struct SeenShadersProbeState {
    var generation: UInt64 = 0
    var loadedKey = ""
    var queueGeneration: UInt64 = 0
    var queueLoadedKey = ""
    var queuedIOS: Bool?
}

extension BuildStore {
    nonisolated package static let seenShadersOnlyKey = "seenShadersOnly"
    nonisolated package static let iosSeenShadersKey = "iosSeenShadersOnly"

    package var queuedIOSSeenShaders: Bool? {
        get { seenShadersProbe.queuedIOS }
        set { seenShadersProbe.queuedIOS = newValue }
    }

    /// True when the Builds page is configured for a Mac `nxnative` build whose engine supports `--seen-shaders`.
    package var seenShadersEligibleContext: Bool {
        buildUpstream == .nxnative
            && target == BuildTarget.mac
            && detectedGameTitleID16 != nil
            && RepoLayout.supportsSeenShaders(repo.path)
    }

    /// True when the single-game Build form should show the opt-in iOS fast shader build switch.
    /// Pure in-memory read backed by `refreshSeenShadersInfo()`.
    package var showsIOSSeenShadersToggle: Bool {
        buildUpstream == .nxnative && target != BuildTarget.mac && cachedSeenShaders?.supportsIOS == true
    }

    private func queuedIOSTitleIDs(from entries: [QueueEntry]) -> [String] {
        var unique = Set<String>()
        for entry in entries where entry.status == .queued && BuildTarget.normalized(entry.target) != BuildTarget.mac {
            let tid = entry.titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if !tid.isEmpty { unique.insert(tid) }
        }
        return unique.sorted()
    }

    /// Asynchronously refreshes `queueHasIOSSeenShadersEligible` off the main thread so `InstallCard.body`
    /// never performs synchronous file reads or `stat` calls during SwiftUI redraws.
    package func refreshQueueSeenShadersEligibility(entries: [QueueEntry]? = nil) {
        if seenShadersProbe.queueLoadedKey == "__gallery__" { return }
        let repoPath = repo.path
        guard buildUpstream == .nxnative, !repoPath.isEmpty else {
            seenShadersProbe.queueGeneration &+= 1
            seenShadersProbe.queueLoadedKey = ""
            if queueHasIOSSeenShadersEligible { queueHasIOSSeenShadersEligible = false }
            return
        }

        let titleIDs = queuedIOSTitleIDs(from: entries ?? queue?.entries ?? [])
        guard !titleIDs.isEmpty else {
            seenShadersProbe.queueGeneration &+= 1
            seenShadersProbe.queueLoadedKey = ""
            if queueHasIOSSeenShadersEligible { queueHasIOSSeenShadersEligible = false }
            return
        }

        let engineRoot = EngineLayout.root(repoPath)
        let signature = titleIDs.joined(separator: ",")
        let requestKey = "\(repoPath)|\(engineRoot)|\(signature)"
        if seenShadersProbe.queueLoadedKey == requestKey {
            return
        }

        seenShadersProbe.queueGeneration &+= 1
        let gen = seenShadersProbe.queueGeneration
        seenShadersProbe.queueLoadedKey = requestKey
        Task.detached(priority: .utility) {
            let scriptSupported = RepoLayout.supportsIOSSeenShaders(repoPath)
            let eligible: Bool
            if scriptSupported {
                eligible = titleIDs.contains { tid in
                    SeenShadersProfile.hasSeenList(titleID: tid, engineRoot: engineRoot)
                        && SeenShadersProfile.inspect(titleID: tid, engineRoot: engineRoot)?.supportsIOS == true
                }
            } else {
                eligible = false
            }
            await MainActor.run { [weak self] in
                guard let self,
                      self.seenShadersProbe.queueGeneration == gen,
                      self.buildUpstream == .nxnative,
                      self.repo.path == repoPath else {
                    return
                }
                let currentIDs = self.queuedIOSTitleIDs(from: self.queue?.entries ?? [])
                guard currentIDs == titleIDs else { return }
                if !scriptSupported {
                    // Do not pin missing/unsynced script results so future engine syncs re-evaluate cleanly.
                    self.seenShadersProbe.queueLoadedKey = ""
                }
                if self.queueHasIOSSeenShadersEligible != eligible {
                    self.queueHasIOSSeenShadersEligible = eligible
                }
            }
        }
    }

    /// Refreshes `cachedSeenShaders` asynchronously off the main thread for the currently selected game (Mac or iOS).
    package func refreshSeenShadersInfo() {
        if seenShadersProbe.loadedKey == "__gallery__" { return }
        let repoPath = repo.path
        let isMac = target == BuildTarget.mac
        guard buildUpstream == .nxnative,
              !repoPath.isEmpty,
              let tid = detectedGameTitleID16 else {
            seenShadersProbe.generation &+= 1
            seenShadersProbe.loadedKey = ""
            if cachedSeenShaders != nil { cachedSeenShaders = nil }
            return
        }

        let engineRoot = EngineLayout.root(repoPath)
        let requestKey = "\(isMac ? "mac" : "ios")|\(repoPath)|\(engineRoot)|\(tid)"
        if isMac,
           RepoLayout.supportsSeenShaders(repoPath),
           SeenShadersProfile.hasSeenList(titleID: tid, engineRoot: engineRoot),
           let hit = SeenShadersProfile.cached(titleID: tid, engineRoot: engineRoot) {
            seenShadersProbe.loadedKey = requestKey
            if cachedSeenShaders != hit { cachedSeenShaders = hit }
            return
        }
        if seenShadersProbe.loadedKey == requestKey {
            return
        }

        seenShadersProbe.generation &+= 1
        let gen = seenShadersProbe.generation
        seenShadersProbe.loadedKey = requestKey
        Task.detached(priority: .utility) {
            let scriptSupported = isMac
                ? RepoLayout.supportsSeenShaders(repoPath)
                : RepoLayout.supportsIOSSeenShaders(repoPath)
            let info: SeenShadersInfo?
            if scriptSupported && SeenShadersProfile.hasSeenList(titleID: tid, engineRoot: engineRoot) {
                info = SeenShadersProfile.inspect(titleID: tid, engineRoot: engineRoot)
            } else {
                info = nil
            }
            await MainActor.run { [weak self] in
                guard let self,
                      self.seenShadersProbe.generation == gen,
                      self.buildUpstream == .nxnative,
                      (self.target == BuildTarget.mac) == isMac,
                      self.detectedGameTitleID16 == tid,
                      self.repo.path == repoPath else {
                    return
                }
                if info == nil {
                    // Do not pin empty/unsynced results so future engine syncs can re-evaluate.
                    self.seenShadersProbe.loadedKey = ""
                }
                if self.cachedSeenShaders != info {
                    self.cachedSeenShaders = info
                }
            }
        }
    }

    /// Execution-time guard evaluated per game title ID so mixed queues never pass `--seen-shaders`
    /// to games without `shader_seen.tsv` or to non-Mac/non-nxnative builds.
    package func shouldPassSeenShaders(forTitleID titleID: String?) -> Bool {
        guard seenShadersOnly,
              buildUpstream == .nxnative,
              target == BuildTarget.mac,
              let tid = titleID,
              RepoLayout.supportsSeenShaders(repo.path) else {
            return false
        }
        return SeenShadersProfile.inspect(titleID: tid, engineRoot: EngineLayout.root(repo.path)) != nil
    }

    /// Execution-time guard evaluated per game title ID so mixed queues never pass `--seen-shaders`
    /// to profiles without `ios_seen_shaders` or to non-iOS / non-nxnative builds.
    package func shouldPassIOSSeenShaders(forTitleID titleID: String?, requested: Bool? = nil) -> Bool {
        guard (requested ?? iosSeenShadersOnly),
              buildUpstream == .nxnative,
              target != BuildTarget.mac,
              let tid = titleID,
              RepoLayout.supportsIOSSeenShaders(repo.path) else {
            return false
        }
        return SeenShadersProfile.inspect(titleID: tid, engineRoot: EngineLayout.root(repo.path))?.supportsIOS == true
    }

    /// Allows tests and the Design Gallery to render the fast-shader switch deterministically without scanning disk.
    package func setSeenShadersForGallery(_ info: SeenShadersInfo?) {
        seenShadersProbe.generation &+= 1
        seenShadersProbe.loadedKey = info == nil ? "" : "__gallery__"
        cachedSeenShaders = info
    }

    /// Allows tests and the Design Gallery to render the queued iOS fast-shader switch without scanning disk.
    package func setQueueIOSSeenShadersForGallery(_ eligible: Bool) {
        seenShadersProbe.queueGeneration &+= 1
        seenShadersProbe.queueLoadedKey = eligible ? "__gallery__" : ""
        queueHasIOSSeenShadersEligible = eligible
    }
}
