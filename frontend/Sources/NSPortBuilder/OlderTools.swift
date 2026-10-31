import Foundation

/// Which library games were built with older build tools (LNPANDY/NX2Apple#65, after seedds/nxnative#209): a finished build
/// records the checkout's commit (LibraryGame.toolsCommit); once the checkout has moved on, a game is marked when files a
/// build uses changed between that commit and HEAD. Only a change that can alter the built game counts, so a docs-only
/// pull marks nothing. A game built before the commit was recorded, or in a checkout that is not a git one, is never marked.
final class ToolsAge: ObservableObject {
    /// The games whose build is older than the tools in the checkout now.
    @Published private(set) var older: Set<UUID> = []
    private var generation = 0

    init(older: Set<UUID> = []) { self.older = older }

    /// Runs git off the main thread; a check started later wins over one still running (the repository may move in between).
    func check(games: [LibraryGame], repo: String) {
        generation += 1
        let mine = generation
        let builds = games.map { (id: $0.id, titleID: $0.titleID, commit: $0.toolsCommit) }
        DispatchQueue.global(qos: .utility).async {
            let result = Self.olderGames(builds, repo: repo)
            DispatchQueue.main.async {
                guard mine == self.generation, result != self.older else { return }
                self.older = result
            }
        }
    }

    /// The repository's folders and files a build reads (scripts/build_ipa_from_nsp.py's `repo / …` paths): the host, the
    /// graphics layers and their shader chain, the rewriter and extraction tools, the iOS and Mac app shells, the vendored
    /// libraries, the build script itself, and the profile code (game.py, profile_guess.py, the launch settings).
    nonisolated static let buildInputs = ["dm/host/", "dm/gfx/", "dm/tools/", "dm/ios/", "dm/mac/", "dm/third_party/",
                                          "scripts/build_ipa_from_nsp.py", "dm/games/game.py", "dm/games/profile_guess.py",
                                          "dm/games/settings."]

    /// Whether a changed file (a path relative to the repository) can change what a build of this game makes: a build input,
    /// or a file of the game's own profile (dm/games/<title ID>/). Notes (*.md) and tests are read by no build.
    nonisolated static func affects(_ path: String, titleID: String) -> Bool {
        if path.hasSuffix(".md") || path.contains("/tests/") { return false }
        if path.hasPrefix("dm/games/" + titleID + "/") { return true }
        return buildInputs.contains { path.hasPrefix($0) }
    }

    /// The checkout's commit, for a git checkout only (a ZIP copy has no history to compare against).
    nonisolated static func head(repo: String) -> String? {
        guard !repo.isEmpty, FileManager.default.fileExists(atPath: repo + "/.git"), let git = BuildModel.gitBinary() else { return nil }
        let r = BuildModel.runQuiet([git, "-C", repo, "rev-parse", "HEAD"], env: BuildModel.gitEnv())
        let commit = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.ok && !commit.isEmpty ? commit : nil
    }

    /// The files changed between a recorded commit and HEAD; nil when git cannot tell (a commit the checkout does not have,
    /// as after a fresh shallow clone), which marks nothing rather than everything.
    nonisolated static func changedFiles(since commit: String, repo: String) -> [String]? {
        guard let git = BuildModel.gitBinary() else { return nil }
        let r = BuildModel.runQuiet([git, "-C", repo, "diff", "--name-only", "--no-renames", commit, "HEAD", "--"], env: BuildModel.gitEnv())
        guard r.ok else { return nil }
        return r.out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// The games marked: one `git diff` per distinct recorded commit, then each game's files are filtered by its title ID.
    nonisolated static func olderGames(_ builds: [(id: UUID, titleID: String, commit: String)], repo: String) -> Set<UUID> {
        let recorded = builds.filter { !$0.commit.isEmpty }
        guard !recorded.isEmpty, let head = head(repo: repo) else { return [] }
        var diffs: [String: [String]] = [:]
        var marked: Set<UUID> = []
        for build in recorded where build.commit != head {
            if diffs[build.commit] == nil { diffs[build.commit] = changedFiles(since: build.commit, repo: repo) ?? [] }
            if diffs[build.commit]!.contains(where: { affects($0, titleID: build.titleID) }) { marked.insert(build.id) }
        }
        return marked
    }
}
