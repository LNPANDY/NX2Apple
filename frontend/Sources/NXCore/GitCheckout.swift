import Foundation

/// The repository checkout the launcher drives: clone, fetch, pull, how far it is behind origin/main, and the adoption of a ZIP copy
/// into git. It starts git through a `ProcessRunner` and touches the disk, and keeps no state, so the launcher's flows can be tested
/// with a fake.
package protocol GitCheckout {
    /// The git binary, nil when this Mac has none.
    var binary: String? { get }
    /// `git -C dir args`, output captured. A Mac without git answers with a failure.
    func run(_ dir: String, _ args: [String]) -> ProcessResult
    /// A shallow clone of `url` into `dest`, its progress lines to `line` (blocking). true when git exited 0.
    func clone(url: String, into dest: String, line: @escaping (String) -> Void) -> Bool
    /// How many commits origin/main has that the checkout does not, after a fetch. nil when git cannot tell (offline).
    func behind(_ dir: String) -> Int?
    /// Fast-forward to origin/main.
    func pull(_ dir: String) -> ProcessResult
    /// The pull of the automatic update: only for a checkout on main with no changes to its tracked files. nil: not allowed.
    func autoPull(_ dir: String) -> ProcessResult?
    /// Connect a copy without .git to `remote` in place and bring it to origin/main, the copy kept on the local branch `branch`.
    /// `log` is the commands and what they printed. A failed adoption removes the .git it made.
    func adopt(_ dir: String, remote: String, branch: String) -> (ok: Bool, log: String)
}

/// The decisions about a checkout that need no git: pure over their inputs.
package enum GitRules {
    /// A checkout the automatic update may move: on main, with no changes to tracked files (untracked files stay; a pull
    /// that would overwrite one fails as a fast-forward and says so).
    package static func autoPullAllowed(branch: String, status: String) -> Bool {
        branch.trimmingCharacters(in: .whitespacesAndNewlines) == "main" && status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The local branch that keeps a ZIP copy as it was when it is connected to git.
    package static func zipCopyBranch(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return "zip-copy-" + f.string(from: date)
    }

    /// What the launch does with the configured repository when it is a copy without .git (#87: a ZIP copy never updated
    /// itself, so its build tools were older than the app).
    package enum ZipAdoption: Equatable { case notNeeded, adopt, waitsForBuild, autoUpdateOff }

    /// Adopt a valid checkout without .git into git, but never while a build runs (or another repository task),
    /// and not when the player turned the automatic update off.
    package static func zipAdoption(isRepo: Bool, isGit: Bool, buildRunning: Bool, repoBusy: Bool, autoUpdate: Bool) -> ZipAdoption {
        guard isRepo, !isGit else { return .notNeeded }
        if buildRunning || repoBusy { return .waitsForBuild }
        return autoUpdate ? .adopt : .autoUpdateOff
    }
}

/// Runs the system's git.
package struct SystemGitCheckout: GitCheckout {
    private let runner: ProcessRunner
    private let candidates: [String]

    package init(runner: ProcessRunner = SystemProcessRunner(),
                 candidates: [String] = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]) {
        self.runner = runner; self.candidates = candidates
    }

    package var binary: String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// A GUI app has no shell PATH: git gets the folders Homebrew and the system put it in.
    package static func environment() -> [String: String] {
        ["PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin", "HOME": NSHomeDirectory()]
    }

    package func run(_ dir: String, _ args: [String]) -> ProcessResult {
        guard let git = binary else { return .failedToStart("git is not installed") }
        return runner.runQuiet([git, "-C", dir] + args, env: Self.environment())
    }

    package func clone(url: String, into dest: String, line: @escaping (String) -> Void) -> Bool {
        guard let git = binary else { return false }
        // Shallow: a quarter of the bytes and a third of the time of a full clone, and fetch /
        // pull keep working on it (verified); the history is of no use to someone who wants to build.
        return runner.runCaptured([git, "clone", "--depth", "1", "--single-branch", "--progress", url, dest], env: Self.environment(), line: line)
    }

    package func behind(_ dir: String) -> Int? {
        guard run(dir, ["fetch", "origin", "main"]).ok else { return nil }
        let count = run(dir, ["rev-list", "--count", "HEAD..origin/main"])
        guard count.ok else { return nil }
        return Int(count.out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    package func pull(_ dir: String) -> ProcessResult {
        run(dir, ["pull", "--ff-only", "origin", "main"])
    }

    package func autoPull(_ dir: String) -> ProcessResult? {
        let branch = run(dir, ["rev-parse", "--abbrev-ref", "HEAD"])
        let status = run(dir, ["status", "--porcelain", "--untracked-files=no"])
        guard branch.ok, status.ok, GitRules.autoPullAllowed(branch: branch.out, status: status.out) else { return nil }
        return pull(dir)
    }

    /// A ZIP copy has no .git: adopt it into git in place (init, remote, fetch, checkout) so the update buttons work and the folder keeps
    /// its path. The copy may hold the player's own edits (a tweaked game profile), and the checkout resets every tracked file to
    /// origin/main, so the copy is recorded first: after the fetch, the files of the copy that origin/main also has are committed on the
    /// local branch `branch` (fixed local author, no git identity needed). Only those paths: a build folder or any other file that
    /// origin/main does not track is never committed (and the checkout leaves such files where they are). The build's own files live
    /// outside the repository.
    package func adopt(_ dir: String, remote: String, branch: String) -> (ok: Bool, log: String) {
        var out = "", ok = true
        func step(_ args: [String]) -> ProcessResult {
            let r = run(dir, args)
            out += "$ git \(args.joined(separator: " "))\n\(r.out)\n"
            return r
        }
        // Nothing in the folder changes before the fetch has worked, so an offline failure leaves the copy as it was.
        ok = step(["init"]).ok && step(["remote", "add", "origin", remote]).ok && step(["fetch", "--depth", "1", "origin", "main"]).ok
        if ok {
            let tree = step(["ls-tree", "-r", "-z", "--name-only", "origin/main"])
            let present = tree.out.split(separator: "\0").map(String.init).filter { FileManager.default.fileExists(atPath: dir + "/" + $0) }
            let list = NSTemporaryDirectory() + "nspb-zip-paths-\(UUID().uuidString.prefix(8)).txt"
            defer { try? FileManager.default.removeItem(atPath: list) }
            let identity = ["-c", "user.name=NX2Apple", "-c", "user.email=nx2apple@localhost", "-c", "commit.gpgsign=false"]
            ok = tree.ok
                && step(["symbolic-ref", "HEAD", "refs/heads/" + branch]).ok
                && ((try? Data(present.joined(separator: "\0").utf8).write(to: URL(fileURLWithPath: list))) != nil)
                && step(["add", "--pathspec-from-file=" + list, "--pathspec-file-nul"]).ok
                && step(identity + ["commit", "--allow-empty", "-m", "The ZIP copy as it was before it was connected to git"]).ok
                && step(["checkout", "-f", "-B", "main", "origin/main"]).ok
        }
        if ok { _ = run(dir, ["branch", "--set-upstream-to=origin/main", "main"]) }   // checkout -B usually set it
        // A failed adoption (offline) must not leave the .git that `git init` made: the copy would count as a
        // checkout from then on, and neither the launch nor the button would try again. The caller checked that there was no .git
        // before, so this removes only what this call created.
        if !ok { try? FileManager.default.removeItem(atPath: dir + "/.git") }
        return (ok, out)
    }
}
