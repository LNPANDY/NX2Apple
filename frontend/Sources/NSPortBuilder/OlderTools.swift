import Foundation

/// Which library games were built with older build tools (LNPANDY/NX2Apple#65, after seedds/nxnative#209): a finished build
/// records the checkout's commit (LibraryGame.toolsCommit); once the checkout has moved on, a game is marked when files a
/// build uses changed between that commit and HEAD. Only a change that can alter the built game counts, so a docs-only
/// pull marks nothing. A game built before the commit was recorded, or in a checkout that is not a git one, is never marked.
final class ToolsAge: ObservableObject {
    /// The games whose build is older than the tools in the checkout now. A pinned game ("keep this build")
    /// is never here: the player said it plays well.
    @Published private(set) var older: Set<UUID> = []
    /// The games whose own profile (`dm/games/<title ID>/`) changed since their build: informative even for
    /// a pinned game, since the fixes are the player's to take or leave.
    @Published private(set) var profileChanged: Set<UUID> = []
    private var generation = 0

    init(older: Set<UUID> = [], profileChanged: Set<UUID> = []) {
        self.older = older
        self.profileChanged = profileChanged
    }

    /// Runs git off the main thread; a check started later wins over one still running (the repository may move in between).
    func check(games: [LibraryGame], repo: String) {
        generation += 1
        let mine = generation
        let builds = games.map { (id: $0.id, titleID: $0.titleID, commit: $0.toolsCommit, pinned: $0.pinned) }
        DispatchQueue.global(qos: .utility).async {
            let result = Self.classify(builds: builds, repo: repo)
            DispatchQueue.main.async {
                guard mine == self.generation,
                      result != Verdict(older: self.older, profileChanged: self.profileChanged) else { return }
                self.older = result.older
                self.profileChanged = result.profileChanged
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

    /// The verdict for a set of builds: which are older than the checkout's tools, and which games' own
    /// profiles changed since their build. `pinned` keeps a game out of `older` — the player said this build
    /// plays well — while its profile changes are still reported.
    struct Verdict: Equatable {
        let older: Set<UUID>
        let profileChanged: Set<UUID>
    }

    nonisolated static func classify(builds: [(id: UUID, titleID: String, commit: String, pinned: Bool)], repo: String) -> Verdict {
        let recorded = builds.filter { !$0.commit.isEmpty }
        guard !recorded.isEmpty, let head = head(repo: repo) else { return Verdict(older: [], profileChanged: []) }
        var diffs: [String: [String]] = [:]
        var older: Set<UUID> = [], profileChanged: Set<UUID> = []
        for build in recorded where build.commit != head {
            if diffs[build.commit] == nil { diffs[build.commit] = changedFiles(since: build.commit, repo: repo) ?? [] }
            let profileTouched = diffs[build.commit]!.contains { affects($0, titleID: build.titleID) && $0.hasPrefix("dm/games/") }
            if profileTouched { profileChanged.insert(build.id) }
            if !build.pinned, diffs[build.commit]!.contains(where: { affects($0, titleID: build.titleID) }) { older.insert(build.id) }
        }
        return Verdict(older: older, profileChanged: profileChanged)
    }

    /// Compatibility with the older entry point: which games are older, none pinned.
    nonisolated static func olderGames(builds: [(id: UUID, titleID: String, commit: String)], repo: String) -> Set<UUID> {
        classify(builds: builds.map { (id: $0.id, titleID: $0.titleID, commit: $0.commit, pinned: false) }, repo: repo).older
    }
}
