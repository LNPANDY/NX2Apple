import Foundation
import NXCore

package enum UpstreamInstallState: Equatable, Sendable {
    package enum FailureReason: Equatable, Sendable {
        case download
        case extract
    }

    case builtIn
    case notInstalled
    case downloading(fraction: Double?, progressText: String)
    case extracting
    case installed
    case failed(FailureReason)

    package var isBusy: Bool {
        switch self {
        case .downloading, .extracting:
            return true
        case .builtIn, .notInstalled, .installed, .failed:
            return false
        }
    }
}

extension BuildStore {
    package var upstreamsRootURL: URL {
        UpstreamEngineStore.root(forHome: home)
    }

    package func adoptInstalledUpstreams() {
        let store = UpstreamEngineStore(root: upstreamsRootURL)
        if !macNativeGamesInstalled, let dir = store.usableDirectory(for: .macNativeGames) {
            macNativeGamesPath = dir.path
        }
        if !s2armInstalled, let dir = store.usableDirectory(for: .s2arm) {
            s2armPath = dir.path
        }
        if buildUpstream == .macNativeGames && !macNativeGamesInstalled {
            buildUpstream = .nxnative
        } else if buildUpstream == .s2arm && !s2armInstalled {
            buildUpstream = .nxnative
        }
    }

    package func isUpstreamInstalled(_ kind: EngineUpstreamKind) -> Bool {
        switch kind {
        case .nxnative:
            return true
        case .macNativeGames:
            return macNativeGamesInstalled
        case .s2arm:
            return s2armInstalled
        }
    }

    package func upstreamState(_ kind: EngineUpstreamKind) -> UpstreamInstallState {
        if kind == .nxnative {
            return .builtIn
        }
        if let active = upstreamDownloads[kind] {
            if case .failed = active, isUpstreamInstalled(kind) {
                return .installed
            }
            return active
        }
        return isUpstreamInstalled(kind) ? .installed : .notInstalled
    }

    package func canSelectUpstream(_ kind: EngineUpstreamKind) -> Bool {
        guard !running else { return false }
        switch kind {
        case .nxnative:
            return true
        case .macNativeGames:
            return MacNativeGamesBuilder.featureEnabled && macNativeGamesInstalled && !(upstreamDownloads[.macNativeGames]?.isBusy ?? false)
        case .s2arm:
            return S2ArmBuilder.featureEnabled && s2armInstalled && !(upstreamDownloads[.s2arm]?.isBusy ?? false)
        }
    }

    package func selectUpstream(_ kind: EngineUpstreamKind) {
        guard canSelectUpstream(kind) else { return }
        buildUpstream = kind
        if kind == .macNativeGames && target != BuildTarget.mac {
            target = BuildTarget.mac
        }
    }

    @discardableResult
    package func downloadUpstream(_ kind: EngineUpstreamKind) -> Task<Void, Never> {
        guard kind != .nxnative, !running else { return Task {} }
        if kind == .macNativeGames && !MacNativeGamesBuilder.featureEnabled { return Task {} }
        if kind == .s2arm && !S2ArmBuilder.featureEnabled { return Task {} }
        if upstreamDownloads[kind]?.isBusy == true { return Task {} }

        upstreamDownloads[kind] = .downloading(fraction: nil, progressText: "")
        let store = UpstreamEngineStore(root: upstreamsRootURL)
        let transport = upstreamTransport

        return Task { [weak self] in
            let result = await Task.detached {
                store.downloadAndInstall(
                    kind: kind,
                    transport: transport,
                    onProgress: { written, expected in
                        let formatted = EngineUpdate.formatDownloadProgress(written: written, expected: expected)
                        hop {
                            guard self?.upstreamDownloads[kind]?.isBusy == true else { return }
                            self?.upstreamDownloads[kind] = .downloading(fraction: formatted.fraction, progressText: formatted.text)
                        }
                    },
                    onExtracting: {
                        hop {
                            self?.upstreamDownloads[kind] = .extracting
                        }
                    }
                )
            }.value

            guard let self else { return }
            switch result {
            case .success(let url):
                switch kind {
                case .nxnative:
                    break
                case .macNativeGames:
                    self.macNativeGamesPath = url.path
                case .s2arm:
                    self.s2armPath = url.path
                }
                self.upstreamDownloads.removeValue(forKey: kind)
            case .failure(let err):
                let reason: UpstreamInstallState.FailureReason = err == .download ? .download : .extract
                self.upstreamDownloads[kind] = .failed(reason)
            }
        }
    }
}
