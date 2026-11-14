import Foundation
import NXCore
import NXModel

/// Which library games were built with different tools than the selected engine (LNPANDY/NX2Apple#65): a finished build
/// records the engine's commit (LibraryGame.toolsCommit) and once the engine has moved on, a game is marked when files a build uses
/// changed between that commit and the engine's HEAD. Only a change that can alter the built game counts, so a docs-only
/// pull marks nothing. The engine is `engine/` of the checkout (EngineLayout.root), a git repository whose HEAD is the pin plus the
/// patch series (tools/engine.py sync), so the diff is exactly what a new pin or a changed patch did to the build's files, and
/// the launcher's own commits never count (#214, step 2: the checkout itself holds no engine files).
/// A Mac game's bundle can also name the shader chain it was built with. This detects a chain change even when the release
/// engine has no Git history or the library has no build commit.
final class ToolsAge: ObservableObject {
    /// The games whose build tools differ from the current engine.
    @Published private(set) var older: Set<UUID> = []
    /// Per-game 4-state refresh assessments computed off the main thread alongside `older`.
    @Published private(set) var assessments: [UUID: GameRefreshAssessment] = [:]
    /// In-flight external-drive probe state for single-game hero refresh, preventing re-entrant clicks and stale callbacks.
    @Published var singleRefreshProbingGameID: UUID?
    var singleRefreshProbeGeneration = 0
    private var generation = 0

    init(older: Set<UUID> = [], assessments: [UUID: GameRefreshAssessment] = [:]) {
        self.older = older
        self.assessments = assessments
    }

    func cancelSingleRefreshProbe() {
        singleRefreshProbeGeneration &+= 1
        if singleRefreshProbingGameID != nil {
            singleRefreshProbingGameID = nil
        }
    }

    /// Runs git and disk checks off the main thread. A check started later wins over one still running.
    func check(
        games: [LibraryGame],
        repo: String,
        appVersion: String = AppUpdateStore.appVersion,
        libraryFolder: String = "",
        seedRoot: String = BuildSeedCache.defaultRoot()
    ) {
        generation += 1
        let mine = generation
        let builds = games.map { (id: $0.id, titleID: $0.titleID, commit: $0.toolsCommit) }
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let engineHead = Self.head(repo: repo)
            var diffCache: [String: [String]?] = [:]
            func lookupDiff(_ commit: String) -> [String]? {
                if let cached = diffCache[commit] { return cached }
                let computed = Self.changedFiles(since: commit, repo: repo)
                diffCache.updateValue(computed, forKey: commit)
                return computed
            }

            let gitMarked = Self.olderGames(builds, head: engineHead, lookupDiff: lookupDiff)
            let result = gitMarked.union(Self.shaderChainMismatches(games, repo: repo))

            var assessmentsMap: [UUID: GameRefreshAssessment] = [:]
            assessmentsMap.reserveCapacity(games.count)
            for game in games {
                let isMarkedOlder = result.contains(game.id)
                let hasMac = Self.hasMacBuildOffThread(game)
                let hasIOS = Self.hasIOSBuildOffThread(game, fm: fm)
                let hasInputs = Self.hasReadableSourceInputs(game, fm: fm)
                let outDir = Self.resolvedOutputDirectory(for: game, libraryFolder: libraryFolder)
                let gitSpecificChanged = Self.specificChangeFlag(
                    commit: game.toolsCommit,
                    titleID: game.titleID,
                    head: engineHead,
                    lookupDiff: lookupDiff
                )
                assessmentsMap[game.id] = GameUpdateCatalog.assess(
                    titleID: game.titleID,
                    isMarkedOlder: isMarkedOlder,
                    hasMacBuild: hasMac,
                    macAppPath: game.appPath,
                    hasIOSBuild: hasIOS,
                    hasReadableSourceInputs: hasInputs,
                    outDir: outDir,
                    gameName: game.name,
                    appVersion: appVersion,
                    gitSpecificChanged: gitSpecificChanged,
                    seedRoot: seedRoot,
                    repoPath: repo
                )
            }

            DispatchQueue.main.async {
                guard mine == self.generation else { return }
                if result != self.older { self.older = result }
                if assessmentsMap != self.assessments { self.assessments = assessmentsMap }
            }
        }
    }

    /// The packer stamps the chain in NVN bundles. A missing stamp is normal for other graphics backends.
    nonisolated private static func shaderChainMismatches(_ games: [LibraryGame], repo: String) -> Set<UUID> {
        let pattern = #"\A[0-9a-f]{12}\z"#
        guard let current = EngineLayout.shaderChain(repo: repo),
              current.range(of: pattern, options: .regularExpression) != nil else { return [] }
        return Set(games.compactMap { game in
            guard !game.appPath.isEmpty,
                  let app = try? MacGameBundle.read(URL(fileURLWithPath: game.appPath)),
                  app.titleID == game.titleID,
                  let chain = app.shaderChain, chain != current,
                  chain.range(of: pattern, options: .regularExpression) != nil else { return nil }
            return game.id
        })
    }

    nonisolated private static func hasMacBuildOffThread(_ game: LibraryGame) -> Bool {
        guard !game.appPath.isEmpty,
              let app = try? MacGameBundle.read(URL(fileURLWithPath: game.appPath)) else { return false }
        return app.titleID == game.titleID
    }

    nonisolated private static func hasIOSBuildOffThread(_ game: LibraryGame, fm: FileManager) -> Bool {
        if game.hasShellFramework || game.shellIPAExists { return true }
        if !game.installedDevice.isEmpty && game.installedViaShellReceipt { return true }
        if !game.ipaPath.isEmpty && fm.fileExists(atPath: game.ipaPath) { return true }
        if !game.iosAppPath.isEmpty && fm.fileExists(atPath: game.iosAppPath + "/Info.plist") { return true }
        return false
    }

    nonisolated private static func hasReadableSourceInputs(_ game: LibraryGame, fm: FileManager) -> Bool {
        if let folder = game.inputs[GameLibrary.folderInput]?.first, !folder.isEmpty {
            return fm.isReadableFile(atPath: folder)
        }
        guard let bases = game.inputs["base"], !bases.isEmpty else { return false }
        return bases.allSatisfy { !$0.isEmpty && fm.isReadableFile(atPath: $0) }
    }

    nonisolated static func resolvedOutputDirectory(for game: LibraryGame, libraryFolder: String = "") -> String {
        if !game.outputDirectory.isEmpty { return game.outputDirectory }
        if !game.sourceFolder.isEmpty { return game.sourceFolder }
        if let base = game.inputs["base"]?.first, !base.isEmpty {
            return (base as NSString).deletingLastPathComponent
        }
        if !game.archivePath.isEmpty {
            let parent = (game.archivePath as NSString).deletingLastPathComponent
            if (parent as NSString).lastPathComponent == "games" {
                return (parent as NSString).deletingLastPathComponent
            }
            return parent
        }
        if !game.appPath.isEmpty {
            return (game.appPath as NSString).deletingLastPathComponent
        }
        if !game.ipaPath.isEmpty {
            return (game.ipaPath as NSString).deletingLastPathComponent
        }
        return libraryFolder
    }

    /// The engine's folders and files a build reads (scripts/build_ipa_from_nsp.py's `repo / …` paths): the host, the
    /// graphics layers and their shader chain, the rewriter and extraction tools, the iOS and Mac app shells, the third-party
    /// libraries, the build script itself, and the profile code (game.py, profile_guess.py, the launch settings).
    nonisolated static let buildInputs = ["dm/host/", "dm/gfx/", "dm/tools/", "dm/ios/", "dm/mac/", "dm/third_party/",
                                          "scripts/build_ipa_from_nsp.py", "dm/games/game.py", "dm/games/profile_guess.py",
                                          "dm/games/settings."]

    /// Whether a changed file (a path relative to the engine) is inside this game's own profile (`dm/games/<TID>/`),
    /// excluding documentation and test files.
    nonisolated static func isGameSpecificChange(_ path: String, titleID: String) -> Bool {
        guard !titleID.isEmpty else { return false }
        if path.hasSuffix(".md") || path.contains("/tests/") { return false }
        let prefix = "dm/games/" + titleID + "/"
        return path.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil
    }

    /// Whether a changed file (a path relative to the engine) can change what a build of this game makes: a build input,
    /// or a file of the game's own profile (dm/games/<title ID>/). Notes (*.md) and tests are read by no build.
    nonisolated static func affects(_ path: String, titleID: String) -> Bool {
        if path.hasSuffix(".md") || path.contains("/tests/") { return false }
        if isGameSpecificChange(path, titleID: titleID) { return true }
        return buildInputs.contains { path.hasPrefix($0) }
    }

    /// Determines whether git history shows a game-specific profile change since `commit`, or `nil` when commit is empty,
    /// the engine is a release tree without git history, or git cannot diff `commit`.
    nonisolated static func specificChangeFlag(
        commit: String,
        titleID: String,
        head: String?,
        lookupDiff: (String) -> [String]?
    ) -> Bool? {
        guard !commit.isEmpty, let head else { return nil }
        if commit == head { return false }
        if commit.hasPrefix(releasePrefix) || head.hasPrefix(releasePrefix) { return nil }
        guard let files = lookupDiff(commit) else { return nil }
        return files.contains { isGameSpecificChange($0, titleID: titleID) }
    }

    /// What identifies the engine a build used. A git engine: its commit (the pin plus the series). A release engine tree has no
    /// history but names itself (`.engine-id`, `<pin>-<12 hex of the series>`): `engine:<id>` then, so a game built with it can
    /// tell that the engine moved on (LNPANDY/NX2Apple#944). nil when the engine says neither.
    nonisolated static func head(repo: String, git: GitCheckout = SystemGitCheckout()) -> String? {
        let engine = EngineLayout.root(repo)
        guard !engine.isEmpty else { return nil }
        if FileManager.default.fileExists(atPath: engine + "/.git"), git.binary != nil {
            let r = git.run(engine, ["rev-parse", "HEAD"])
            let commit = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            if r.ok && !commit.isEmpty { return commit }
        }
        return EngineStore.identity(of: URL(fileURLWithPath: engine)).map { releasePrefix + $0 }
    }

    nonisolated static let releasePrefix = "engine:"

    /// The files changed between a recorded commit and the engine's HEAD, or nil when git cannot tell (a commit the engine does not
    /// have, as for a game built before step 2 or after engine/ was made anew), which marks nothing rather than everything.
    nonisolated static func changedFiles(since commit: String, repo: String, git: GitCheckout = SystemGitCheckout()) -> [String]? {
        guard git.binary != nil else { return nil }
        let r = git.run(EngineLayout.root(repo), ["diff", "--name-only", "--no-renames", commit, "HEAD", "--"])
        guard r.ok else { return nil }
        return r.out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// The games marked: one `git diff` per distinct recorded commit, then each game's files are filtered by its title ID.
    nonisolated static func olderGames(_ builds: [(id: UUID, titleID: String, commit: String)], repo: String) -> Set<UUID> {
        var diffs: [String: [String]?] = [:]
        return olderGames(builds, head: head(repo: repo)) { commit in
            if let cached = diffs[commit] { return cached }
            let computed = changedFiles(since: commit, repo: repo)
            diffs.updateValue(computed, forKey: commit)
            return computed
        }
    }

    nonisolated private static func olderGames(
        _ builds: [(id: UUID, titleID: String, commit: String)],
        head: String?,
        lookupDiff: (String) -> [String]?
    ) -> Set<UUID> {
        let recorded = builds.filter { !$0.commit.isEmpty }
        guard !recorded.isEmpty, let head else { return [] }
        var marked: Set<UUID> = []
        for build in recorded where build.commit != head {
            // A release engine tree has no history to diff: any other engine than the one the game was built with counts, and the
            // note says "different tools", never that a fix is in it. The files that changed are unknown there.
            if build.commit.hasPrefix(releasePrefix) || head.hasPrefix(releasePrefix) {
                marked.insert(build.id)
                continue
            }
            if let files = lookupDiff(build.commit), files.contains(where: { affects($0, titleID: build.titleID) }) {
                marked.insert(build.id)
            }
        }
        return marked
    }
}
