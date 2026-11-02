import Foundation
import Combine
import NXCore

/// Where the repository is, for the stores and services that only need to read it. `RepoStore` is the one that implements it.
@MainActor package protocol RepoLocation: AnyObject {
    /// The folder the launcher drives. Empty: none found yet.
    var path: String { get }
    /// `path` is a checkout the launcher can build from.
    var isRepo: Bool { get }
    /// `path` has a .git (a ZIP copy has none).
    var isGit: Bool { get }
}

/// The repository (LNPANDY/NX2Apple#387, step 7): the checkout the launcher drives, its status line and the updates of it. It
/// clones it, checks how far it is behind origin/main, pulls (by hand and by itself when the app opens) and connects a ZIP copy
/// to git. It follows `AppUpdateStore` (`frontend/ARCHITECTURE.md`, "Stores").
///
/// - What it works with comes through `init`: the `GitCheckout` service, the `Localizer`, the defaults it saves the path and the
///   automatic-update switch in. Whether a build runs, whether this is a release app (which has no checkout to update), where
///   the log goes and what happens after the checkout moved are closures the app wires.
/// - The actions check their own conditions: none runs while a build runs or another repository task does.
/// - The git work blocks, so it runs off the main actor. The method that starts it sets `busy` first and returns the `Task`.
/// - The engine sync that follows a clone, a pull and an adoption is not here: it is `didMove`, and the engine has its own store.
@MainActor package final class RepoStore: ObservableObject, RepoLocation {
    nonisolated package static let url = "https://github.com/LNPANDY/NX2Apple.git"
    nonisolated package static let pathKey = "repoPath"
    nonisolated package static let autoUpdateKey = "autoUpdateRepo"

    /// The checkout of this repository the app drives (`RepoLayout.find` picks it at start). Saved when it changes.
    @Published package var path: String {
        didSet { defaults.set(path, forKey: Self.pathKey) }
    }
    /// Clone, pull, adoption or update check in flight: the buttons disable and the status line says what is happening.
    @Published package private(set) var busy = false
    /// The line under the repository row of Settings.
    @Published package var status = ""
    /// nil = not checked yet, 0 = up to date, n = n commits behind origin/main.
    @Published package var behind: Int?
    /// Pull origin/main by itself when the app opens (Settings, on by default), so the build tools are the current ones:
    /// a checkout days behind built with tools main had already fixed (spirv-cross without its x bit, #41).
    @Published package var autoUpdate: Bool {
        didSet { defaults.set(autoUpdate, forKey: Self.autoUpdateKey) }
    }
    /// The commits the automatic update brought when the app opened; the library's activity line names them. nil: none.
    @Published package var autoPulled: Int?
    /// A copy without .git was connected to git and brought to the current version when the app opened (`adoptAtLaunch`).
    @Published package var autoAdopted = false

    private let localizer: Localizer
    private let git: GitCheckout
    private let defaults: UserDefaults
    private let home: String
    private let buildRunning: () -> Bool
    private let isReleaseApp: () -> Bool
    private let log: (String) -> Void
    private let didMove: () -> Void

    /// - Parameters:
    ///   - path: the checkout to start with. nil: `RepoLayout.find`, the saved choice or one next to the app.
    ///   - buildRunning: whether a build runs (the model's flag).
    ///   - isReleaseApp: this app carries its own engine and never clones or pulls.
    ///   - log: a line for the build log (the clone's progress, git's output).
    ///   - didMove: the checkout changed (cloned, pulled, adopted): the engine may be stale now.
    package init(localizer: Localizer, git: GitCheckout, defaults: UserDefaults = .standard, path: String? = nil,
                 home: String = NSHomeDirectory(),
                 buildRunning: @escaping () -> Bool = { false }, isReleaseApp: @escaping () -> Bool = { false },
                 log: @escaping (String) -> Void = { _ in }, didMove: @escaping () -> Void = {}) {
        self.localizer = localizer
        self.git = git
        self.defaults = defaults
        self.home = home
        self.buildRunning = buildRunning
        self.isReleaseApp = isReleaseApp
        self.log = log
        self.didMove = didMove
        self.path = path ?? RepoLayout.find(defaults: defaults, home: home)
        autoUpdate = defaults.object(forKey: Self.autoUpdateKey) as? Bool ?? true
    }

    private func t(_ key: String) -> String { localizer.t(key) }

    package var isRepo: Bool { RepoLayout.isRepo(path) }
    /// A clone has .git; a GitHub "Download ZIP" copy does not (everything builds, but there is
    /// nothing to fetch or pull — the update buttons hide and the note says to re-download instead).
    package var isGit: Bool { FileManager.default.fileExists(atPath: path + "/.git") }

    /// Home shown as ~ (shorter in a one-line row, and it keeps the account name out of screenshots).
    package func shortPath(_ p: String) -> String { RepoLayout.shortPath(p, home: home) }

    /// A task that can run now: no build, no other repository task, a checkout-based app, and git on this Mac.
    private var mayStart: Bool { !buildRunning() && !busy && !isReleaseApp() }

    // ---- Clone ----

    /// First-time flow: clone the project to ~/NX2Apple (the discovery seeds cover it) and select it.
    @discardableResult
    package func clone() -> Task<Void, Never> {
        guard mayStart else { return Task {} }
        guard git.binary != nil else { status = t("repo.gitMissing"); return Task {} }
        let dest = home + "/NX2Apple"
        if FileManager.default.fileExists(atPath: dest) {
            if RepoLayout.isRepo(dest) { path = dest; status = ""; return checkForUpdates() }
            else { status = String(format: t("repo.destBusy"), shortPath(dest)) }
            return Task {}
        }
        busy = true; status = t("repo.downloading")
        let url = Self.url, log = self.log, git = self.git
        log("git clone --depth 1 \(url) \(dest)\n")
        return Task {
            let ok = await Task.detached {
                git.clone(url: url, into: dest) { line in DispatchQueue.main.async { log(line + "\n") } }
            }.value
            busy = false
            if ok && RepoLayout.isRepo(dest) {
                path = dest
                status = String(format: t("repo.downloadDone"), shortPath(dest))
                didMove()
            } else {
                status = t("repo.downloadFail")
                try? FileManager.default.removeItem(atPath: dest)   // a failed clone leaves an empty folder
            }
        }
    }

    // ---- Check, pull ----

    /// Compare the checkout with origin/main. `silent` is the launch-time check: no status text, no
    /// error noise when offline — it only fills `behind` when it can. With the automatic update on, a checkout that is behind is
    /// pulled by it.
    @discardableResult
    package func checkForUpdates(silent: Bool = false) -> Task<Void, Never> {
        guard isRepo, isGit, !isReleaseApp() else { return Task {} }   // a release app updates its engine by version instead
        guard !buildRunning(), !busy, git.binary != nil else {
            if !silent, git.binary == nil { status = t("repo.gitMissing") }
            return Task {}
        }
        busy = true
        if !silent { status = t("repo.checking") }
        let dir = path, git = self.git
        return Task {
            let count = await Task.detached { git.behind(dir) ?? -1 }.value
            busy = false
            if count >= 0 {
                behind = count
                if !silent { status = count == 0 ? t("repo.upToDate") : String(format: t("repo.behind"), count) }
                else if count > 0 && autoUpdate { await autoPull(count).value }   // the check when the app opens
            } else if !silent {
                status = t("repo.netFail")
            }
        }
    }

    /// The status line for a failed pull. A diverged checkout ("Not possible to fast-forward") has its
    /// own commit history — a clone someone worked in, or an old upstream checkout — and no amount of
    /// pulling fixes that; the actionable answer is the repository picker, which is always offered now.
    package func pullFailureMessage(_ gitOutput: String) -> String {
        let diverged = gitOutput.contains("fast-forward") || gitOutput.contains("Diverging")
        return t(diverged ? "repo.pullDiverged" : "repo.pullFail")
    }

    /// Fast-forward the checkout to origin/main. The build keeps everything it needs under
    /// <id>_build/ outside the repository, so a pull never disturbs a previous build's files.
    @discardableResult
    package func pull() -> Task<Void, Never> {
        guard mayStart, isRepo, isGit, git.binary != nil else { return Task {} }
        busy = true; status = t("repo.pulling")
        let dir = path, git = self.git
        return Task {
            let r = await Task.detached { git.pull(dir) }.value
            busy = false
            if r.ok {
                behind = 0; status = t("repo.pulled")
                if !r.out.isEmpty { log(r.out + "\n") }
                didMove()   // the pull may have moved the pin or the patches
            } else {
                status = pullFailureMessage(r.out)
                log(r.out + "\n")
            }
        }
    }

    /// The automatic update when the app opens: a fast-forward to origin/main, only for a checkout on main with no changes
    /// to its tracked files and no build running, so a checkout someone works in is never touched. Settings says what
    /// happened (or why not), and the library's activity line names the new commits.
    @discardableResult
    package func autoPull(_ behind: Int) -> Task<Void, Never> {
        guard mayStart, isRepo, isGit, git.binary != nil else { return Task {} }
        busy = true
        let dir = path, git = self.git
        return Task {
            let pulled = await Task.detached { git.autoPull(dir) }.value
            busy = false
            guard let pulled else { status = t("repo.autoSkipped"); return }
            if pulled.ok {
                self.behind = 0; autoPulled = behind
                status = String(format: t("repo.autoPulled"), behind)
                didMove()
            } else {
                status = pullFailureMessage(pulled.out)
                log(pulled.out + "\n")
            }
        }
    }

    // ---- A ZIP copy ----

    /// The launch-time step for a ZIP copy; a git checkout is left to `checkForUpdates`. Settings and the library's
    /// activity line say what happened.
    @discardableResult
    package func adoptAtLaunch(remote: String = RepoStore.url) -> Task<Void, Never> {
        guard !isReleaseApp() else { return Task {} }
        switch GitRules.zipAdoption(isRepo: isRepo, isGit: isGit, buildRunning: buildRunning(), repoBusy: busy, autoUpdate: autoUpdate) {
        case .notNeeded: break
        case .waitsForBuild: status = t("repo.zipWaits")
        case .autoUpdateOff: break   // Settings says so next to the repository (repo.zipNoAuto): the player chose this
        case .adopt:
            if git.binary == nil { status = t("repo.gitMissing") }
            else { return adoptAsGit(automatic: true, remote: remote) }
        }
        return Task {}
    }

    /// A ZIP copy has no .git: adopt it into git in place (init, remote, fetch, checkout) so the
    /// update buttons work and the folder keeps its path. The copy may hold the player's own edits (a tweaked game
    /// profile), and the checkout resets every tracked file to origin/main, so the copy is recorded first: after the
    /// fetch, the files of the copy that origin/main also has are committed on the local branch `zip-copy-<date>`
    /// (fixed local author, no git identity needed). Only those paths: a build folder or any other file that origin/main
    /// does not track is never committed (and the checkout leaves such files where they are). The build's own files live
    /// outside the repository.
    /// `automatic`: the launch-time adoption (`adoptAtLaunch`). `remote` is GitHub unless a test points it at a local repository.
    @discardableResult
    package func adoptAsGit(automatic: Bool = false, remote: String = RepoStore.url) -> Task<Void, Never> {
        guard mayStart, isRepo, !isGit, git.binary != nil else { return Task {} }
        busy = true; status = t("repo.adopting")
        let dir = path, git = self.git
        return Task {
            let branch = GitRules.zipCopyBranch()
            let (ok, out) = await Task.detached { git.adopt(dir, remote: remote, branch: branch) }.value
            busy = false
            log(out + "\n")
            if ok && isGit {
                // the checkout is origin/main as just fetched: up to date, nothing left to pull
                behind = 0
                status = String(format: t(automatic ? "repo.adoptedAuto" : "repo.adopted"), branch)
                if automatic { autoAdopted = true }
                didMove()
            } else {
                status = t(automatic ? "repo.adoptFailAuto" : "repo.adoptFail")
            }
        }
    }
}
