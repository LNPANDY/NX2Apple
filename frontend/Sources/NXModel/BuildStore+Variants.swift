import Foundation
import NXCore

// Specialized `nxnative` fork variants (`Kid with Sword`, `No Lag Kart`) and unified game-tuned allowlist / recommendation logic.

extension BuildStore {
    nonisolated package static let kidWithSwordPathKey = "kidWithSwordPath"
    nonisolated package static let noLagKartPathKey = "noLagKartPath"

    /// True when the active engine is a specialized `nxnative` fork driven by `scripts/build_ipa_from_nsp.py`.
    package var isNxnativeVariantSelected: Bool {
        buildUpstream.isNxnativeVariant
    }

    /// True when the active engine builds iOS apps only as standalone one-game IPAs (no shared shell or `.framework`).
    package var forcesStandaloneOneGameIPA: Bool {
        target != BuildTarget.mac && buildUpstream.buildsIOSStandaloneOnly
    }

    /// Resolves the `nxnative`-family engine tree root for the active build (built-in engine or installed variant tree).
    package func activeNxnativeEngineRoot(for upstream: EngineUpstreamKind? = nil) -> String {
        let kind = upstream ?? buildUpstream
        switch kind {
        case .kidWithSword:
            return kidWithSwordPath
        case .noLagKart:
            return noLagKartPath
        case .nxnative, .s2arm, .macNativeGames, .nxkit:
            return EngineLayout.root(repo.path)
        }
    }

    /// Builds an isolated work directory path so specialized variants (especially shader-chain forks like No Lag Kart)
    /// never pollute default `nxnative` caches.
    package func nxnativeWorkDirectory(baseOut: String, tidHex: String, upstream: EngineUpstreamKind? = nil) -> String {
        let kind = upstream ?? buildUpstream
        if let suffix = kind.workDirSuffix, !suffix.isEmpty {
            return baseOut + "/" + tidHex + "_" + suffix + "_build"
        }
        return baseOut + "/" + tidHex + "_build"
    }

    /// True when a queue entry is eligible for `upstream` (target compatibility + enforced title ID and input allowlist).
    package static func canQueueEntryUseUpstream(_ entry: QueueEntry, upstream: EngineUpstreamKind, mngTree: String = "") -> Bool {
        if upstream == .macNativeGames {
            return canQueueEntryUseMNG(entry, tree: mngTree)
        }
        if entry.fastRefresh { return upstream == .nxnative }
        if upstream.buildsMacOnly && BuildTarget.normalized(entry.target) != BuildTarget.mac {
            return false
        }
        return upstream.supportsTitleID(entry.titleID)
    }

    /// True when the staged build queue holds any waiting entry that `kind` cannot build.
    package func isUpstreamBlockedByQueuedBuilds(_ kind: EngineUpstreamKind) -> Bool {
        if kind == .macNativeGames {
            return isMNGBlockedByQueuedBuilds
        }
        guard kind.enforcedTitleIDs != nil else { return false }
        if activeQueueEntryUpstream == kind {
            return false
        }
        guard let queued = queue?.queued, !queued.isEmpty else { return false }
        return queued.contains { !Self.canQueueEntryUseUpstream($0, upstream: kind, mngTree: macNativeGamesPath) }
    }

    /// Default-Deny allowlist gate for specialized engines (`MacNativeGames`, `Kid with Sword`, `No Lag Kart`).
    /// Only pure empty state or a recognized title ID inside the engine's allowlist permits selecting it.
    package func isUpstreamBlockedByCurrentGame(_ kind: EngineUpstreamKind) -> Bool {
        if kind == .macNativeGames {
            return isMNGBlockedByCurrentGame
        }
        guard kind.enforcedTitleIDs != nil else { return false }
        if isUpstreamBlockedByQueuedBuilds(kind) {
            return true
        }
        if let tid = detectedGameTitleID16 {
            return !kind.supportsTitleID(tid)
        }
        return hasSelectedGameInput
    }

    /// Localized reason key explaining why `kind` is currently disabled in the engine selector.
    package func blockedReasonKey(for kind: EngineUpstreamKind) -> String {
        if kind == .macNativeGames {
            return mngBlockedReasonKey
        }
        if isUpstreamBlockedByQueuedBuilds(kind) {
            switch kind {
            case .macNativeGames: return "upstream.mngBlockedByQueue"
            case .kidWithSword: return "upstream.kwsBlockedByQueue"
            case .noLagKart: return "upstream.noLagKartBlockedByQueue"
            case .nxnative, .s2arm, .nxkit: return "upstream.mngBlockedByQueue"
            }
        }
        switch kind {
        case .macNativeGames: return "upstream.mngOnlyFiveTitles"
        case .kidWithSword: return "upstream.kwsOnlyTitle"
        case .noLagKart: return "upstream.noLagKartOnlyTitle"
        case .nxnative, .s2arm, .nxkit: return "upstream.mngOnlyFiveTitles"
        }
    }

    /// All game-tuned engines compatible with the currently selected game (ordered with best match for current target first).
    package var tunedEnginesForCurrentGame: [EngineUpstreamKind] {
        guard let tid = detectedGameTitleID16 else { return [] }
        let all = EngineUpstream.tunedEngines(forTitleID: tid, macNativeGamesEnabled: MacNativeGamesBuilder.featureEnabled)
            .filter { $0 != .macNativeGames || isCurrentGameMNGSupported }
        guard !all.isEmpty else { return [] }
        let normalizedTarget = BuildTarget.normalized(target)
        if normalizedTarget != BuildTarget.mac {
            let iosFirst = all.filter { $0.supportsIOS }
            let macOnly = all.filter { !$0.supportsIOS }
            return iosFirst + macOnly
        }
        return all
    }

    /// Primary recommended game-tuned engine for the currently selected game when the user is on a general engine.
    package var recommendedTunedEngine: EngineUpstreamKind? {
        guard !running, buildUpstream.group == .general else { return nil }
        guard let tid = detectedGameTitleID16 else { return nil }
        let preferred = EngineUpstream.recommendedTunedEngine(
            forTitleID: tid,
            target: target,
            macNativeGamesEnabled: MacNativeGamesBuilder.featureEnabled
        )
        if let preferred, !isUpstreamBlockedByCurrentGame(preferred) {
            return preferred
        }
        return tunedEnginesForCurrentGame.first { !isUpstreamBlockedByCurrentGame($0) }
    }

    /// True when the Builds engine switcher should display a non-blocking tuned-engine recommendation bar.
    package var shouldRecommendTunedEngine: Bool {
        recommendedTunedEngine != nil
    }

    /// One-click helper used by recommendation banners: selects an installed engine immediately or downloads and switches to it.
    package func downloadAndSwitchToUpstream(_ kind: EngineUpstreamKind) {
        guard !running, !isUpstreamBlockedByCurrentGame(kind) else { return }
        if isUpstreamInstalled(kind) {
            selectUpstream(kind)
            upstreamAutoSwitchRevision &+= 1
        } else {
            _ = downloadUpstream(kind)
        }
    }

    /// Reverts any enforced specialized upstream back to `nxnative` when the active game or queue no longer qualifies.
    func enforceSpecializedUpstreamsForCurrentGame() {
        guard !running else { return }
        if buildUpstream.enforcedTitleIDs != nil && isUpstreamBlockedByCurrentGame(buildUpstream) {
            buildUpstream = .nxnative
        }
    }

    /// Applies specialized variant validation before launching a `nxnative`-family build.
    /// Returns nil when valid, or a localized failure reason when blocked.
    func validateNxnativeVariantBeforeBuild(engineRoot: String) -> String? {
        guard buildUpstream.isNxnativeVariant else { return nil }
        guard !engineRoot.isEmpty, UpstreamEngineStore.isUsableTree(engineRoot, kind: buildUpstream) else {
            return String(format: t("upstream.variantInvalid"), buildUpstream.displayName)
        }
        if isUpstreamBlockedByCurrentGame(buildUpstream) {
            return t(blockedReasonKey(for: buildUpstream))
        }
        return nil
    }
}
