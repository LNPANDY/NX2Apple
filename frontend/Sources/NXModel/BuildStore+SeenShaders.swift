import Foundation
import NXCore

extension BuildStore {
    /// True when the Builds page is configured for a Mac `nxnative` build whose engine supports `--seen-shaders`.
    package var seenShadersEligibleContext: Bool {
        buildUpstream == .nxnative
            && target == BuildTarget.mac
            && detectedGameTitleID16 != nil
            && RepoLayout.supportsSeenShaders(repo.path)
    }

    /// Refreshes `cachedSeenShaders` off the main thread when the selected game or engine changes.
    package func refreshSeenShadersInfo() {
        if seenShadersLoadedKey == "__gallery__" { return }
        guard buildUpstream == .nxnative,
              target == BuildTarget.mac,
              let tid = detectedGameTitleID16,
              RepoLayout.supportsSeenShaders(repo.path) else {
            seenShadersGeneration &+= 1
            seenShadersLoadedKey = ""
            if cachedSeenShaders != nil { cachedSeenShaders = nil }
            return
        }

        let repoPath = repo.path
        let engineRoot = EngineLayout.root(repoPath)
        guard SeenShadersProfile.hasSeenList(titleID: tid, engineRoot: engineRoot) else {
            seenShadersGeneration &+= 1
            seenShadersLoadedKey = ""
            if cachedSeenShaders != nil { cachedSeenShaders = nil }
            return
        }

        let requestKey = "\(engineRoot)|\(tid)"
        if let hit = SeenShadersProfile.cached(titleID: tid, engineRoot: engineRoot) {
            seenShadersLoadedKey = requestKey
            if cachedSeenShaders != hit { cachedSeenShaders = hit }
            return
        }
        if seenShadersLoadedKey == requestKey {
            return
        }

        seenShadersGeneration &+= 1
        let gen = seenShadersGeneration
        seenShadersLoadedKey = requestKey
        Task.detached(priority: .utility) {
            let info = SeenShadersProfile.inspect(titleID: tid, engineRoot: engineRoot)
            await MainActor.run { [weak self] in
                guard let self,
                      self.seenShadersGeneration == gen,
                      self.buildUpstream == .nxnative,
                      self.target == BuildTarget.mac,
                      self.detectedGameTitleID16 == tid,
                      self.repo.path == repoPath else {
                    return
                }
                if info == nil {
                    // Do not pin empty/failed results so future engine syncs can re-evaluate.
                    self.seenShadersLoadedKey = ""
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

    /// Allows the Design Gallery to render the fast-shader toggle deterministically without scanning disk.
    package func setSeenShadersForGallery(_ info: SeenShadersInfo?) {
        seenShadersGeneration &+= 1
        seenShadersLoadedKey = info == nil ? "" : "__gallery__"
        cachedSeenShaders = info
    }
}
