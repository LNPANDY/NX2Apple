import Foundation
import Combine
import NXCore

/// Where the Python interpreter is, for a store that only needs to read it. `DependencyStore` provides it. Empty: not found yet,
/// and the user of it looks for one itself.
@MainActor package protocol PythonLocation: AnyObject {
    var pythonPath: String { get }
}

/// What the build needs to know about the tools, without the store that installs them: the check ran, everything it needs is
/// there, which interpreter and which dotnet it runs under, and the rows (for the diagnostics report).
@MainActor package protocol DependencyStatus: PythonLocation {
    /// The check has finished at least once since the last one started.
    var checked: Bool { get }
    /// The check finished and no row is missing (a warning row counts as present).
    var allPresent: Bool { get }
    /// The dotnet the build runs under. Empty: none runs.
    var dotnetPath: String { get }
    var deps: [Dep] { get }
}

/// The dependencies (LNPANDY/NX2Apple#387, step 7): the rows of the tools panel (Xcode and its SDK, the Metal toolchain, the
/// Homebrew tools, .NET, the Python packages), the interpreter and the dotnet the build runs under, and the installs. It follows
/// `AppUpdateStore` (`frontend/ARCHITECTURE.md`, "Stores").
///
/// - What it works with comes through `init`: the `Localizer`, a `ProcessRunner` for the installs, the repository (`RepoLocation`)
///   whose lock pins the Metal compiler, the defaults it saves the expanded panel in. The detection is a closure (`scan`) with the
///   real one as default, so a test gives it rows without probing the machine. Whether the iOS SDK is asked for, opening the App
///   Store (Xcode comes from there), the build log and the note after a failed install are closures the app wires.
/// - The work blocks, so it runs off the main actor. `check()` and `install(_:)` set their state first and return the `Task`.
/// - `install` runs the row's own command, and for the Python row the venv install. A row that is installing says so
///   (`Dep.installing`), a failure keeps the tool's first error line and the fix to show (`Dep.lastError`, `Dep.fixHint`).
@MainActor package final class DependencyStore: ObservableObject, DependencyStatus {
    nonisolated package static let expandedKey = "depsExpanded"

    @Published package var deps: [Dep] = []
    /// The check ran. False while one runs, so the panel shows its spinner.
    @Published package var checked = false
    /// Whether the dependency list is expanded. nil = not chosen yet: open while something is
    /// missing (that is when the rows matter), collapsed once everything is green — a set-up
    /// machine never needs the rows again. A manual toggle overrides and is remembered.
    @Published package var expanded: Bool? {
        didSet { if let v = expanded { defaults.set(v, forKey: Self.expandedKey) } }
    }
    /// The interpreter the build runs under, set by the check.
    @Published package var pythonPath = ""
    @Published package var dotnetPath = ""

    private let localizer: Localizer
    private let runner: ProcessRunner
    private let repo: RepoLocation
    private let defaults: UserDefaults
    private let needsIOS: () -> Bool
    private let scan: @Sendable (_ repo: String, _ needsIOS: Bool) -> DependencyCheck.Result
    private let report: @Sendable ([Dep]) -> Void
    private let openAppStore: () -> Void
    private let log: (String) -> Void
    private let installFailed: (String) -> Void

    /// - Parameters:
    ///   - needsIOS: whether the xcode row asks for the iOS SDK (the guided setup's platform choice).
    ///   - scan: the detection, for a repository path and `needsIOS`. Runs off the main actor.
    ///   - report: writes what the check decided (`deps-check.txt`). Runs off the main actor.
    ///   - openAppStore: a row with no command (Xcode) opens the App Store.
    ///   - log: a line for the build log (an install's output).
    ///   - installFailed: the note for a failed install, already translated.
    package init(localizer: Localizer, runner: ProcessRunner, repo: RepoLocation, defaults: UserDefaults = .standard,
                 needsIOS: @escaping () -> Bool = { true },
                 scan: @escaping @Sendable (String, Bool) -> DependencyCheck.Result = { DependencyCheck.scan(needsIOS: $1, repo: $0) },
                 report: @escaping @Sendable ([Dep]) -> Void = { DependencyCheck.writeReport($0, appVersion: AppUpdateStore.appVersion) },
                 openAppStore: @escaping () -> Void = {}, log: @escaping (String) -> Void = { _ in },
                 installFailed: @escaping (String) -> Void = { _ in }) {
        self.localizer = localizer
        self.runner = runner
        self.repo = repo
        self.defaults = defaults
        self.needsIOS = needsIOS
        self.scan = scan
        self.report = report
        self.openAppStore = openAppStore
        self.log = log
        self.installFailed = installFailed
        expanded = defaults.object(forKey: Self.expandedKey) as? Bool
    }

    // ---- What the views and the build read ----

    package var allPresent: Bool { checked && deps.allSatisfy { $0.present } }

    /// Whether the list shows its rows: the choice made, else open while something is missing.
    package var open: Bool { expanded ?? !(checked && allPresent) }

    package func toggle() {
        expanded = !(expanded ?? !allPresent)
    }

    /// Whether the row `id` runs its install now.
    package func isInstalling(_ id: String) -> Bool {
        deps.first { $0.id == id }?.installing ?? false
    }

    /// A row's second column: a path when there is one, else the translated hint.
    /// `detail` carries either a real path, an L10n key, or "key:argument[:argument…]".
    package func detail(of d: Dep) -> String {
        let raw = d.detail
        if raw.isEmpty { return localizer.t(d.hint) }
        if raw.hasPrefix("/") || raw.hasPrefix("~") { return raw }
        if let colon = raw.firstIndex(of: ":") {
            let key = String(raw[..<colon]), arg = String(raw[raw.index(after: colon)...])
            let args = arg.components(separatedBy: ":").map { RepoLayout.shortPath($0) as CVarArg }
            if L10n.table[key] != nil { return String(format: localizer.t(key), arguments: args) }
        }
        if L10n.table[raw] != nil { return localizer.t(raw) }
        return raw
    }

    // ---- The check ----

    /// Looks at this Mac again: the rows, the interpreter and the dotnet. The panel shows its spinner until it has published.
    @discardableResult
    package func check() -> Task<Void, Never> {
        checked = false
        let path = repo.path, needsIOS = needsIOS(), scan = self.scan, report = self.report
        return Task {
            let found = await Task.detached { () -> DependencyCheck.Result in
                let r = scan(path, needsIOS)
                report(r.deps)
                return r
            }.value
            deps = found.deps
            pythonPath = found.python                // the interpreter the build runs under
            dotnetPath = found.dotnet
            checked = true
        }
    }

    // ---- The installs ----

    /// Runs the row's install. The row is installing until it ends, a failure leaves the tool's first error line on it, and the
    /// check runs again at the end. A row with no command (Xcode) opens the App Store, and the player checks again when it is done.
    @discardableResult
    package func install(_ dep: Dep) -> Task<Void, Never> {
        guard !dep.installCmd.isEmpty else {
            openAppStore()   // Xcode comes from the App Store; the user re-checks when it is done
            return Task {}
        }
        guard let i = deps.firstIndex(where: { $0.id == dep.id }) else { return Task {} }
        deps[i].installing = true
        let runner = self.runner, log = self.log, base = pythonPath
        let cmd = dep.installCmd, isPython = dep.id == "python"
        return Task {
            let outcome = await Task.detached { () -> (ok: Bool, failure: (error: String, fix: String)?, output: String?) in
                if isPython {
                    // A venv of our own rather than pip --user: Homebrew's Python is externally
                    // managed (PEP 668) and refuses --user, which used to fail silently.
                    let r = Toolchain.makeVenv(base: base, runner: runner)
                    return (r.ok, nil, r.log)
                }
                let collected = Lines()
                let ok = runner.runCaptured(DependencyCheck.shellCommand(cmd), env: DependencyCheck.installEnvironment()) { line in
                    collected.append(line)
                    DispatchQueue.main.async { log(line + "\n") }
                }
                return (ok, BuildProgress.failureInfo(collected.lines), nil)
            }.value
            if let output = outcome.output { log("\n--- 安装输出 ---\n" + output) }
            if let j = deps.firstIndex(where: { $0.id == dep.id }) {
                if let failure = outcome.failure {
                    deps[j].lastError = outcome.ok ? "" : failure.error
                    deps[j].fixHint = outcome.ok ? "" : failure.fix
                }
                deps[j].installing = false
                if outcome.ok { deps[j].lastError = ""; deps[j].fixHint = "" }
            }
            if !outcome.ok { installFailed(String(format: localizer.t("dep.install.fail"), localizer.t(dep.name))) }
            await check().value
        }
    }

    /// The output lines seen so far, from the pipe's threads and read after the run.
    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var box: [String] = []
        func append(_ l: String) { lock.lock(); box.append(l); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return box }
    }
}
