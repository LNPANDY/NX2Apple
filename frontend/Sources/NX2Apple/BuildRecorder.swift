import Combine
import Foundation
import NXCore
import NXModel
import NXLauncher

/// Writes a build into the library: the game when it starts, the app it made when it ends. It lives as long as the session
/// (LauncherSession), not the window: console mode takes LauncherView down, and a build that ended there was never recorded,
/// so the game stayed unbuilt in the library (an empty appPath).
@MainActor final class BuildRecorder: ObservableObject {
    /// The library entry of the running build, from its start until it is recorded.
    @Published private(set) var activeBuildID: UUID?
    /// The engine's commit when the running build started (ToolsAge).
    private(set) var buildCommit = ""
    /// A build was written into the library: the view refreshes what it reads from it (artwork, signatures, ToolsAge).
    let recorded = PassthroughSubject<Void, Never>()

    private let build: BuildStore
    private let library: GameLibrary
    private let engine: EngineSyncStore
    private let repoPath: () -> String
    private var watching: Set<AnyCancellable> = []

    /// - Parameter activeBuildID: visual QA: a build drawn as running on this game.
    init(stores: LauncherStores, library: GameLibrary, activeBuildID: UUID? = nil) {
        build = stores.build; self.library = library; engine = stores.engineSync
        repoPath = { [repo = stores.repo] in repo.path }
        self.activeBuildID = activeBuildID
        stores.settleFinishedBuild = { [weak self] in self?.settleBeforeNextQueuedBuild() }
        build.onBatchShellInstalled = { [weak self] games, app, device in
            guard let self else { return }
            for item in games {
                let found = item.gameID.flatMap { id in self.library.games.first { $0.id == id } }
                    ?? self.library.games.first { $0.titleID.caseInsensitiveCompare(item.titleID) == .orderedSame }
                if let game = found {
                    let commit = game.toolsCommit.isEmpty ? self.buildCommit : game.toolsCommit
                    self.library.recordCompletedIOS(archive: item.archive, app: app, device: device, commit: commit, for: game.id)
                }
            }
            self.library.recordSharedAppInstalled(app: app, device: device)
            self.recorded.send()
        }
        build.onBuiltGamesInstalled = { [weak self] app, device in
            guard let self else { return }
            self.library.recordSharedAppInstalled(app: app, device: device)
            self.recorded.send()
        }
        build.$running.removeDuplicates().sink { [weak self] in self?.runningChanged($0) }.store(in: &watching)
        build.$done.removeDuplicates().sink { [weak self] done in
            if done { DispatchQueue.main.async { self?.record() } }
        }.store(in: &watching)
        Publishers.CombineLatest(build.$stages, build.$overallProgress).sink { [weak self] stages, overall in
            guard let self, self.build.running else { return }
            DockProgress.update(overall ?? stages.last { $0.state == .running }?.percent.map { $0 / 100 })
        }.store(in: &watching)
    }

    /// `running` as it is about to change (a Published sink runs before the store holds the new value).
    private func runningChanged(_ running: Bool) {
        if !running { DockProgress.update(nil) }
        if running && build.buildingGame && activeBuildID == nil { activeBuildID = library.rememberInputs(build) }
        if running && build.buildingGame && activeBuildID != nil {   // the tools this build runs: a pull waits for the build (RepoStore.pull, autoPull)
            buildCommit = ""
            let dir = repoPath()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let commit = ToolsAge.head(repo: dir) ?? ""
                DispatchQueue.main.async { self?.buildCommit = commit }
            }
        }
        if !running {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.build.running else { return }   // a build may have started since the idle notification
                if self.build.done { self.record() }
                self.activeBuildID = nil
                self.engine.applyPendingEngine()   // an engine installed during the build takes over once it is recorded
            }
        }
    }

    private func settleBeforeNextQueuedBuild() {
        if build.done { record() }
        activeBuildID = nil
    }

    private func record() {
        guard build.done, build.buildingGame, let id = activeBuildID else { return }
        if build.runningTarget == BuildTarget.mac {
            library.recordCompletedApp(path: build.macAppPath, commit: buildCommit, for: id)
        } else if !build.installedAppPath.isEmpty {
            library.recordCompletedIOS(archive: build.archivePath, app: build.installedAppPath, device: build.installedOn, commit: buildCommit, for: id)
        } else if !build.archivePath.isEmpty, var game = library.games.first(where: { $0.id == id }) {
            game.archivePath = build.archivePath
            game.lastTarget = BuildTarget.ios
            if !buildCommit.isEmpty { game.toolsCommit = buildCommit }
            library.upsert(game)
        }
        recorded.send()
    }
}
