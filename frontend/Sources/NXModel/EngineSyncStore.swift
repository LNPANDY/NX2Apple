import Foundation
import Combine
import NXCore

/// The engine (LNPANDY/NX2Apple#387, step 7): which engine the launcher builds with and how it gets it. It follows
/// `AppUpdateStore` (`frontend/ARCHITECTURE.md`, "Stores").
///
/// Two kinds of launcher have an engine, and the store does both:
/// - A checkout of the repository (a developer's, or one the launcher cloned) has no engine in git. `syncEngine` runs
///   `tools/engine.py sync` when `engine/` is missing or older than the pin, at launch, after a clone, a pull or an adoption and
///   before a build. It shows a status line while it runs and a failure row when it stops (`syncing`, `failure`).
/// - A release app carries an engine tree in its bundle (`bundle`) and builds from the engine store instead. It seeds the app's
///   own engine there on the first start, asks the selected channel for a newer one (`checkForUpdate`), and switches between
///   channels after a confirmation. `selection` is the channel and the engine it is on, `status` what Settings says.
///
/// - What it works with comes through `init`: the `Localizer`, a `ProcessRunner` for the sync, the repository (`RepoLocation`) and
///   the interpreter (`PythonLocation`) to read, the engine store and the network (`EngineTransport`), the defaults it saves the
///   selection in. Where the build reads its tools from changes with the engine (`setRepoPath`), whether a build runs, whether the
///   automatic update is on and where the log goes are closures the app wires.
/// - The actions check their own conditions: no check or switch while one runs or a build runs.
/// - The work blocks, so it runs off the main actor. The method that starts it sets its state first and returns the `Task`.
@MainActor package final class EngineSyncStore: ObservableObject {
    // ---- The engine of a release app ----

    /// The channel and the engine the launcher is on, saved when it changes.
    @Published package var selection: EngineSelection
    /// A seed, a check or an install runs (the buttons of Settings disable).
    @Published package private(set) var busy = false
    /// The line under the tools section of Settings.
    @Published package var status = ""
    /// A newer engine the launch check found while automatic updates are off: Settings offers it.
    @Published package private(set) var available: EngineUpdate.Engine?
    /// The channel the player picked and is asked to confirm (the switch can change the shader chain).
    @Published package var confirmingChannel: EngineChannel?
    /// An installed engine that waits for the running build to end before the build tools switch to it.
    package var pendingEngine: (engine: EngineUpdate.Engine, channel: EngineChannel)?
    /// The engine tree inside the app bundle. nil for a launcher built from the repository, which keeps its checkout and git.
    /// A release app builds from the engine store instead, and never clones or pulls.
    package var bundle: URL?
    package var usesEngineStore: Bool { bundle != nil }

    // ---- The engine of a checkout ----

    /// A sync runs: the launcher shows a status line with a spinner.
    @Published package private(set) var syncing = false
    /// How the last sync stopped (no network or GitHub unreachable, or another stop), as a failure row with a retry button. nil: none.
    @Published package var failure: BuildFailure?

    /// What waits for the running `tools/engine.py sync` (nil: none runs), and whether another one is due when it ends.
    private var syncWaiting: [(Bool) -> Void]?
    private var syncAgain = false

    private let localizer: Localizer
    private let runner: ProcessRunner
    private let repo: RepoLocation
    private let python: PythonLocation
    private let engineStore: EngineStore
    private let transport: EngineTransport
    private let defaults: UserDefaults
    private let appVersion: String
    private let setRepoPath: (String) -> Void
    private let buildRunning: () -> Bool
    private let autoUpdate: () -> Bool
    private let log: (String) -> Void

    /// - Parameters:
    ///   - bundle: the engine tree of the app. nil: a launcher built from the repository.
    ///   - setRepoPath: the build reads its tools from this folder from now on (an installed engine tree).
    ///   - buildRunning: whether a build runs (the model's flag).
    ///   - autoUpdate: the automatic update is on: the launch check installs by itself.
    ///   - log: a line for the build log (the sync's output).
    package init(localizer: Localizer, runner: ProcessRunner, repo: RepoLocation, python: PythonLocation,
                 engineStore: EngineStore = EngineStore(), transport: EngineTransport = URLSessionEngineTransport(),
                 bundle: URL? = EngineBundle.tree(in: Bundle.main.resourceURL), defaults: UserDefaults = .standard,
                 appVersion: String = AppUpdateStore.appVersion,
                 setRepoPath: @escaping (String) -> Void = { _ in }, buildRunning: @escaping () -> Bool = { false },
                 autoUpdate: @escaping () -> Bool = { true }, log: @escaping (String) -> Void = { _ in }) {
        self.localizer = localizer
        self.runner = runner
        self.repo = repo
        self.python = python
        self.engineStore = engineStore
        self.transport = transport
        self.bundle = bundle
        self.defaults = defaults
        self.appVersion = appVersion
        self.setRepoPath = setRepoPath
        self.buildRunning = buildRunning
        self.autoUpdate = autoUpdate
        self.log = log
        selection = EngineSelection.load(defaults)
    }

    private func t(_ key: String) -> String { localizer.t(key) }

    // ---- The checkout's engine: tools/engine.py sync ----

    /// `tools/engine.py sync` when engine/ is stale (#214): at launch, after a clone, a pull or an adoption, and before a build that
    /// has no other engine. Checkouts only: a release app carries its engine tree (#227) and never syncs. A no-op for a current engine/
    /// or a folder that is an engine tree. `then(ok)` runs on the main actor.
    @discardableResult
    package func syncEngine(then: ((Bool) -> Void)? = nil) -> Task<Void, Never> {
        if syncWaiting != nil {
            syncAgain = true
            if let then { syncWaiting?.append(then) }
            return Task {}
        }
        let path = repo.path
        guard EngineLayout.isStale(path) else { failure = nil; then?(true); return Task {} }
        syncWaiting = then.map { [$0] } ?? []
        syncing = true; failure = nil
        let chosen = python.pythonPath, runner = self.runner, log = self.log
        log("$ python3 tools/engine.py sync\n")
        let tail = Tail()   // what failureKind reads when the sync stops
        return Task {
            let ok = await Task.detached {
                let py = chosen.isEmpty ? Toolchain.findPython().path : chosen
                return EngineLayout.runSync(repo: path, python: py, runner: runner) { line in
                    tail.append(line + "\n")
                    DispatchQueue.main.async { log(line + "\n") }
                }
            }.value
            let waiting = syncWaiting ?? [], again = syncAgain && ok
            syncWaiting = nil; syncAgain = false
            syncing = false
            failure = ok ? nil : BuildFailure(kind: EngineLayout.failureKind(tail.text), gameName: nil)
            if again { syncEngine { ok in waiting.forEach { $0(ok) } } } else { waiting.forEach { $0(ok) } }
        }
    }

    /// The failure row's Try again: clears the row and runs the sync again.
    @discardableResult
    package func retrySync() -> Task<Void, Never> {
        guard !syncing else { return Task {} }
        failure = nil
        return syncEngine()
    }

    /// The last 4000 characters of what the sync printed, written from the background thread that runs it.
    private final class Tail: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ""
        func append(_ s: String) { lock.lock(); value = String((value + s).suffix(4000)); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return value }
    }

    // ---- The release app's engine ----

    /// At launch: build from the selected engine in the store, copy the app's own engine there on the first start,
    /// then ask the selected channel for a newer one. On the stable channel a new app brings its own engine, which
    /// then replaces the one an older app left selected, without the network.
    @discardableResult
    package func prepareEngine() -> Task<Void, Never> {
        guard let bundled = bundle, !busy, let id = EngineStore.identity(of: bundled) else { return Task {} }
        let selected = selection.engineID
        let appMovedOn = selection.channel == .stable && selected != id && selection.version != appVersion
        if !appMovedOn, engineStore.isUsable(selected), let dir = engineStore.directory(for: selected) {
            setRepoPath(dir.path)
            return checkForUpdate(automatic: true)
        }
        busy = true
        status = t("engine.preparing")
        let store = engineStore
        return Task {
            let result = await Task.detached { Result { try EngineInstaller.seed(from: bundled, engineID: id, store: store) } }.value
            busy = false
            switch result {
            case .success:
                // The app's engine is the stable one of this release. A player on experimental gets theirs from the check.
                let engine = EngineUpdate.Engine(id: id, version: appVersion)
                if buildRunning() {   // a build started from the old folder while the copy ran
                    pendingEngine = (engine, selection.channel)
                    status = ""
                } else {
                    switchEngine(to: engine, channel: selection.channel, announce: false)
                    await checkForUpdate(automatic: true).value
                }
            case .failure:
                status = t("engine.seedFail")
            }
        }
    }

    /// Ask the selected channel for its engine. `automatic` is the launch check: it installs only with automatic
    /// updates on, and it says nothing when the engine is current or the network is down.
    @discardableResult
    package func checkForUpdate(automatic: Bool = false) -> Task<Void, Never> {
        runEngineUpdate(channel: selection.channel, install: automatic ? autoUpdate() : true, quiet: automatic)
    }

    /// Install the engine the launch check found (automatic updates off).
    @discardableResult
    package func installAvailable() -> Task<Void, Never> {
        runEngineUpdate(channel: selection.channel, install: true, quiet: false)
    }

    /// The channel picker: a different channel is confirmed first, because the switch can change the shader chain.
    package func requestChannel(_ channel: EngineChannel) {
        guard selection.channel.switchWarningKey(to: channel) != nil, !busy, !buildRunning() else { return }
        confirmingChannel = channel
    }

    /// The alert's button passes the channel it showed, so the order of the alert's own dismissal does not matter.
    @discardableResult
    package func confirmChannel(_ channel: EngineChannel) -> Task<Void, Never> {
        confirmingChannel = nil
        return runEngineUpdate(channel: channel, install: true, quiet: false)
    }

    package func cancelChannel() { confirmingChannel = nil }

    /// The selected channel is only changed once its engine is in place, so Settings never names a channel whose
    /// engine the build does not use.
    private func runEngineUpdate(channel: EngineChannel, install: Bool, quiet: Bool) -> Task<Void, Never> {
        guard usesEngineStore, !busy else { return Task {} }
        guard !buildRunning() else {
            if !quiet { status = t("engine.waitForBuild") }
            return Task {}
        }
        busy = true
        if !quiet { status = t(channel == selection.channel ? "engine.checking" : "engine.switching") }
        let store = engineStore, bundled = bundle, current = selection.engineID, transport = self.transport, version = appVersion
        return Task {
            let outcome = await Task.detached {
                EngineUpdate.run(channel: channel, appVersion: version, current: current, store: store,
                                 bundled: bundled, install: install, transport: transport)
            }.value
            busy = false
            applyOutcome(outcome, channel: channel, quiet: quiet)
        }
    }

    package func applyOutcome(_ outcome: EngineUpdate.Outcome, channel: EngineChannel, quiet: Bool) {
        switch outcome {
        case .current(let engine):
            available = nil
            if selection.channel != channel || selection.version != engine.version {
                selection.channel = channel
                selection.version = engine.version
                selection.save(defaults)
            }
            if !quiet { status = String(format: t("engine.upToDate"), engine.version) }
        case .available(let engine):
            available = engine
            status = String(format: t("engine.available"), engine.version)
        case .installed(let engine, _):
            available = nil
            if buildRunning() {
                pendingEngine = (engine, channel)
                status = String(format: t("engine.waitsForBuild"), engine.version)
            } else {
                switchEngine(to: engine, channel: channel)
            }
        case .failed(let failure):
            if quiet, failure == .network || failure == .noManifest { return }
            let key = EngineUpdate.key(failure)
            status = failure == .noManifest ? String(format: t(key), t(channel.labelKey)) : t(key)
        }
    }

    /// Point the build at an installed tree, keep the one before it, and say whether the shader chain changed.
    /// `announce` off (the app's own engine at launch): only a changed shader chain is worth a line.
    package func switchEngine(to engine: EngineUpdate.Engine, channel: EngineChannel, announce: Bool = true) {
        guard let dir = engineStore.directory(for: engine.id) else { return }
        let old = repo.path
        selection.channel = channel
        selection.switched(to: engine.id, version: engine.version)
        selection.save(defaults)
        setRepoPath(dir.path)
        engineStore.prune(keeping: selection.kept)
        if let change = EngineUpdate.chainChange(from: old, to: dir.path) {
            status = String(format: t("engine.chainChanged"), engine.version, change.old, change.new)
        } else {
            status = announce ? String(format: t("engine.installed"), engine.version) : ""
        }
    }

    /// The build that held an installed engine back has ended (the launcher watches `running`).
    package func applyPendingEngine() {
        guard !buildRunning(), let pending = pendingEngine else { return }
        pendingEngine = nil
        switchEngine(to: pending.engine, channel: pending.channel)
    }

    /// What Settings shows for the engine: its version and the pin it was built from.
    package var detail: String {
        guard !selection.engineID.isEmpty else { return t("engine.none") }
        return String(format: t("engine.detail"), selection.version.isEmpty ? "?" : selection.version, String(selection.engineID.prefix(8)))
    }
}
