import Foundation
import NXCore

package struct UpstreamVersionCheckState {
    package var lastCheckedAt: [EngineUpstreamKind: Date] = [:]
    package var generation: [EngineUpstreamKind: UInt64] = [:]
    package var tasks: [EngineUpstreamKind: Task<Void, Never>] = [:]

    package init() {}
}

extension BuildStore {
    /// The state gallery's fixtures set the version GitHub has directly, so a scene shows an update without the network
    /// (GalleryMacNativeGames.swift). The installed version comes from the tree's receipt.
    package func setUpstreamRemoteVersionForGallery(_ remote: UpstreamRemoteInfo) {
        upstreamRemoteVersions[remote.kind] = remote
        refreshUpstreamLocalVersion(for: remote.kind)
    }

    package func upstreamDirectoryPath(for kind: EngineUpstreamKind) -> String {
        switch kind {
        case .nxnative:
            return repo.path
        case .nxkit:
            return ""   // bundled with the app, its version is NxkitVersionStore's (BuildStore+Nxkit.swift)
        case .macNativeGames:
            return macNativeGamesPath
        case .s2arm:
            return s2armPath
        }
    }

    package func refreshUpstreamLocalVersion(for kind: EngineUpstreamKind) {
        let receipt = UpstreamVersion.localReceipt(
            for: kind,
            directory: upstreamDirectoryPath(for: kind),
            repoPath: repo.path
        )
        if let receipt {
            if upstreamLocalVersions[kind] != receipt {
                upstreamLocalVersions[kind] = receipt
            }
        } else if upstreamLocalVersions[kind] != nil {
            upstreamLocalVersions.removeValue(forKey: kind)
        }
    }

    package func refreshUpstreamLocalVersions() {
        for kind in EngineUpstreamKind.allCases {
            refreshUpstreamLocalVersion(for: kind)
        }
    }

    package func upstreamHasUpdate(_ kind: EngineUpstreamKind) -> Bool {
        guard !kind.isBuiltIn, kind != .nxkit, isUpstreamInstalled(kind), !(upstreamDownloads[kind]?.isBusy ?? false) else {
            return false
        }
        return UpstreamVersion.hasUpdate(
            local: upstreamLocalVersions[kind],
            remote: upstreamRemoteVersions[kind]
        )
    }

    package func upstreamVersionBadge(_ kind: EngineUpstreamKind) -> String {
        let local = upstreamLocalVersions[kind] ?? UpstreamVersion.localReceipt(
            for: kind,
            directory: upstreamDirectoryPath(for: kind),
            repoPath: repo.path
        )
        return UpstreamVersion.compactBadgeText(
            kind: kind,
            local: local,
            hasUpdate: upstreamHasUpdate(kind),
            builtInFallback: t("upstream.builtinBadge"),
            installedFallback: t("upstream.installedBadge")
        )
    }

    package func upstreamUpdateTooltip(_ kind: EngineUpstreamKind) -> String? {
        guard upstreamHasUpdate(kind), let remote = upstreamRemoteVersions[kind] else {
            return nil
        }
        return String(format: t("upstream.updateAvailableHelp"), remote.tooltipDetail)
    }

    package func didInstallUpstreamVersion(_ kind: EngineUpstreamKind, previousRemote: UpstreamRemoteInfo?) {
        refreshUpstreamLocalVersion(for: kind)
        guard let installed = upstreamLocalVersions[kind],
              let installedCommit = UpstreamVersion.normalizedCommit(installed.commit) else {
            return
        }
        // If the downloaded zip is already ahead of our cached remote snapshot, update/clear
        // the stale remote entry so the freshly installed copy is not falsely flagged as outdated.
        if let cached = upstreamRemoteVersions[kind],
           UpstreamVersion.normalizedCommit(cached.commit) != installedCommit {
            upstreamRemoteVersions.removeValue(forKey: kind)
            upstreamVersionChecks.lastCheckedAt.removeValue(forKey: kind)
        } else if previousRemote == nil, upstreamRemoteVersions[kind] != nil,
                  UpstreamVersion.normalizedCommit(upstreamRemoteVersions[kind]?.commit) != installedCommit {
            upstreamRemoteVersions.removeValue(forKey: kind)
            upstreamVersionChecks.lastCheckedAt.removeValue(forKey: kind)
        }
    }

    /// Checks GitHub asynchronously for newer commits of installed external upstreams.
    /// Uses a 10-minute in-memory cache for valid non-empty results and never caches failures.
    @discardableResult
    package func checkUpstreamUpdates(
        kinds: [EngineUpstreamKind]? = nil,
        force: Bool = false,
        now: Date = Date()
    ) -> Task<Void, Never> {
        refreshUpstreamLocalVersions()
        let allowed = Set(availableUpstreams)
        let targets = (kinds ?? availableUpstreams).filter { kind in
            allowed.contains(kind) && !kind.isBuiltIn && kind != .nxkit && isUpstreamInstalled(kind) && !(upstreamDownloads[kind]?.isBusy ?? false)
        }
        var spawned: [Task<Void, Never>] = []
        let transport = upstreamTransport

        for kind in targets {
            if !force,
               upstreamRemoteVersions[kind] != nil,
               let last = upstreamVersionChecks.lastCheckedAt[kind],
               now.timeIntervalSince(last) < UpstreamVersion.cacheTTL {
                continue
            }
            let gen = (upstreamVersionChecks.generation[kind] ?? 0) &+ 1
            upstreamVersionChecks.generation[kind] = gen
            upstreamVersionChecks.tasks[kind]?.cancel()

            let task = Task { [weak self] in
                let info = await Task.detached(priority: .utility) {
                    UpstreamVersion.fetchRemoteInfo(for: kind, transport: transport)
                }.value
                guard let self,
                      !Task.isCancelled,
                      self.upstreamVersionChecks.generation[kind] == gen,
                      self.isUpstreamInstalled(kind) else {
                    return
                }
                self.upstreamVersionChecks.tasks.removeValue(forKey: kind)
                // Never cache failures or nil results so the next trigger can retry cleanly.
                guard let info else { return }
                self.upstreamRemoteVersions[kind] = info
                self.upstreamVersionChecks.lastCheckedAt[kind] = now
                // Auto-upgrade local receipt's display version when commit matches (e.g. short SHA -> v0.5.8+).
                if let local = self.upstreamLocalVersions[kind],
                   let localCommit = UpstreamVersion.normalizedCommit(local.commit),
                   localCommit == UpstreamVersion.normalizedCommit(info.commit),
                   !info.version.isEmpty,
                   local.version != info.version {
                    let upgraded = UpstreamVersionReceipt(
                        commit: localCommit,
                        version: info.version,
                        installedAt: local.installedAt
                    )
                    self.upstreamLocalVersions[kind] = upgraded
                    let dirPath = self.upstreamDirectoryPath(for: kind)
                    if !dirPath.isEmpty {
                        let dirURL = URL(fileURLWithPath: dirPath, isDirectory: true)
                        Task.detached(priority: .utility) {
                            try? UpstreamVersion.writeReceipt(upgraded, to: dirURL)
                        }
                    }
                }
            }
            upstreamVersionChecks.tasks[kind] = task
            spawned.append(task)
        }

        return Task {
            for task in spawned {
                await task.value
            }
        }
    }
}
