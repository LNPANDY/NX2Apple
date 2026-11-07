import Foundation
import NXCore

/// Which library games were built with different tools than the selected engine (LNPANDY/NX2Apple#65): a finished build
/// records the engine's commit (LibraryGame.toolsCommit); once the engine has moved on, a game is marked when files a build uses
/// changed between that commit and the engine's HEAD. Only a change that can alter the built game counts, so a docs-only
/// pull marks nothing. The engine is `engine/` of the checkout (EngineLayout.root), a git repository whose HEAD is the pin plus the
/// patch series (tools/engine.py sync), so the diff is exactly what a new pin or a changed patch did to the build's files, and
/// the launcher's own commits never count (#214, step 2: the checkout itself holds no engine files).
/// A Mac game's bundle can also name the shader chain it was built with. This detects a chain change even when the release
/// engine has no Git history or the library has no build commit.
final class ToolsAge: ObservableObject {
    /// The games whose build tools differ from the current engine.
    @Published private(set) var older: Set<UUID> = []
    private var generation = 0

    init(older: Set<UUID> = []) { self.older = older }

    /// Runs git off the main thread; a check started later wins over one still running (the repository may move in between).
    func check(games: [LibraryGame], repo: String) {
        generation += 1
        let mine = generation
        let builds = games.map { (id: $0.id, titleID: $0.titleID, commit: $0.toolsCommit) }
        DispatchQueue.global(qos: .utility).async {
            let result = Self.olderGames(builds, repo: repo).union(Self.shaderChainMismatches(games, repo: repo))
            DispatchQueue.main.async {
                guard mine == self.generation, result != self.older else { return }
                self.older = result
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

    /// The engine's folders and files a build reads (scripts/build_ipa_from_nsp.py's `repo / …` paths): the host, the
    /// graphics layers and their shader chain, the rewriter and extraction tools, the iOS and Mac app shells, the third-party
    /// libraries, the build script itself, and the profile code (game.py, profile_guess.py, the launch settings).
    nonisolated static let buildInputs = ["dm/host/", "dm/gfx/", "dm/tools/", "dm/ios/", "dm/mac/", "dm/third_party/",
                                          "scripts/build_ipa_from_nsp.py", "dm/games/game.py", "dm/games/profile_guess.py",
                                          "dm/games/settings."]

    /// Whether a changed file (a path relative to the engine) can change what a build of this game makes: a build input,
    /// or a file of the game's own profile (dm/games/<title ID>/). Notes (*.md) and tests are read by no build.
    nonisolated static func affects(_ path: String, titleID: String) -> Bool {
        if path.hasSuffix(".md") || path.contains("/tests/") { return false }
        if path.hasPrefix("dm/games/" + titleID + "/") { return true }
        return buildInputs.contains { path.hasPrefix($0) }
    }

    /// The engine's commit (the pin plus the series), for a git engine only (an engine tree has no history to compare against).
    nonisolated static func head(repo: String, git: GitCheckout = SystemGitCheckout()) -> String? {
        let engine = EngineLayout.root(repo)
        guard !engine.isEmpty, FileManager.default.fileExists(atPath: engine + "/.git"), git.binary != nil else { return nil }
        let r = git.run(engine, ["rev-parse", "HEAD"])
        let commit = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.ok && !commit.isEmpty ? commit : nil
    }

    /// The files changed between a recorded commit and the engine's HEAD; nil when git cannot tell (a commit the engine does not
    /// have, as for a game built before step 2 or after engine/ was made anew), which marks nothing rather than everything.
    nonisolated static func changedFiles(since commit: String, repo: String, git: GitCheckout = SystemGitCheckout()) -> [String]? {
        guard git.binary != nil else { return nil }
        let r = git.run(EngineLayout.root(repo), ["diff", "--name-only", "--no-renames", commit, "HEAD", "--"])
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
