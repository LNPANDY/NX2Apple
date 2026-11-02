import Foundation
import Combine
import NXCore

/// The launcher's self-update (LNPANDY/NX2Apple#387): the release check, the staged update, the update sheet, the uninstall
/// plan and the version the check compares. It is the reference store: `frontend/ARCHITECTURE.md` ("Stores") describes the
/// pattern, and later stores follow it.
///
/// - It is `@MainActor`, an `ObservableObject`, and owns its `@Published` state. Views observe it and call its methods.
/// - It gets what it works with through `init`: the `Localizer` for its status text, a `ProcessRunner` (ditto, xattr), a
///   `ReleaseSource` (the network), the bundle it may replace and the defaults it saves its switch in. Tests pass in fakes.
/// - It checks the conditions for its own actions: no install while a build runs, none for a copy built from the repository.
/// - What needs AppKit reaches it as closures: quitting the app and relaunching it (`terminate`, `relaunch`). The app also
///   calls `appWillTerminate()` from AppKit's notification.
/// - The rules that need no state (what is verified, which copies replace themselves, parsing, the version compare) are
///   `AppUpdate` in `NXCore`.
///
/// A check or a staging runs as a `Task` on the main actor. The method that starts one returns it, so a test awaits it.
@MainActor package final class AppUpdateStore: ObservableObject {
    /// Bump together with each release tag: the update check compares it with the latest release.
    /// `build-mac-app.yml`, `sync-upstream.yml`, `tools/try-local` and `RELEASING.md` read this line. Keep it in this form.
    nonisolated package static let appVersion = "1.0.1"

    /// The version this store compares releases with: `appVersion`, unless a test passes another.
    nonisolated package let version: String

    /// The update the check found: the tag, the asset to download, its digest, and the release notes the sheet shows. The
    /// notes are why the sheet exists: "update available" alone told a user nothing about what they would get.
    @Published package var update: AppUpdate.Release?
    /// A check or a download is running.
    @Published package private(set) var busy = false
    /// Whether the "a new version is out" sheet is up: opened by the launch check and by Check for updates, so a user learns
    /// what changed before deciding, not after downloading.
    @Published package var showUpdateSheet = false
    /// The uninstall row's dialog: computed when the row is pressed, run when the player confirms.
    @Published package var uninstallPlan: Uninstall.Plan?
    /// The line under the app section of Settings.
    @Published package var status = ""
    /// Set when the last update attempt was refused (a release this macOS cannot open, a bad download): the sheet shows it.
    @Published package private(set) var blocked: String?
    /// The release that is downloaded, verified and unpacked: it goes in when the app quits, or with Restart now.
    @Published package var staged: AppUpdate.Staged?
    /// Where a rename-era install put the new app (the old bundle name is gone): the Dock entry that points at the old path
    /// is stale until the player pins the new one again.
    @Published package private(set) var renamedInstall: String?
    /// Whether this copy may replace itself. A launcher built from the repository never does (tests set it).
    @Published package var installability: AppUpdate.Installability

    /// Download a new release by itself and install it when the app quits (Settings, on by default). Off, the Update button in
    /// Settings downloads, swaps in and relaunches.
    @Published package var automatic: Bool {
        didSet {
            defaults.set(automatic, forKey: Self.automaticKey)
            if automatic, staged == nil, let u = update { stage(u, automatic: true) }
        }
    }
    nonisolated package static let automaticKey = "autoUpdateApp"

    private let localizer: Localizer
    private let runner: ProcessRunner
    private let releases: ReleaseSource
    private let bundle: URL
    private let bundleIdentifier: String
    private let runningOS: OperatingSystemVersion
    private let defaults: UserDefaults
    private let buildRunning: () -> Bool
    private let relaunch: (URL) -> Bool
    private let terminate: () -> Void
    private let uninstall: (Uninstall.Plan) -> (removed: [String], failures: [String])
    private let trashOldApp: Bool

    /// - Parameters:
    ///   - buildRunning: whether a build of this app runs (the model's flag, and any process group of one still alive).
    ///   - relaunch: starts the new copy once this process has exited.
    ///   - terminate: quits the app.
    ///   - uninstall: removes what a plan names and says what went and what failed.
    ///   - trashOldApp: the replaced bundle goes to the Trash (a test says false, so it leaves nothing there).
    package init(localizer: Localizer, runner: ProcessRunner, releases: ReleaseSource,
                             version: String = AppUpdateStore.appVersion,
                             bundle: URL = Bundle.main.bundleURL, bundleIdentifier: String? = Bundle.main.bundleIdentifier,
                             runningOS: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
                             defaults: UserDefaults = .standard,
                             buildRunning: @escaping () -> Bool = { ProcessGroups.buildProcessesAlive },
                             relaunch: @escaping (URL) -> Bool = { AppUpdate.relaunch($0) },
                             terminate: @escaping () -> Void = {},
                             uninstall: @escaping (Uninstall.Plan) -> (removed: [String], failures: [String]) = { Uninstall.run($0) },
                         trashOldApp: Bool = true) {
        self.localizer = localizer
        self.runner = runner
        self.releases = releases
        self.version = version
        self.bundle = bundle
        self.bundleIdentifier = bundleIdentifier ?? ""
        self.runningOS = runningOS
        self.defaults = defaults
        self.buildRunning = buildRunning
        self.relaunch = relaunch
        self.terminate = terminate
        self.uninstall = uninstall
        self.trashOldApp = trashOldApp
        installability = AppUpdate.installability(bundle, appVersion: version)
        automatic = defaults.object(forKey: Self.automaticKey) as? Bool ?? true
    }

    private func t(_ key: String) -> String { localizer.t(key) }

    /// No build of this app is running: none in the model, and no process group of one still alive (a stopped build's tools
    /// can take a moment to go).
    package var mayInstall: Bool { !buildRunning() }

    // ---- The check ----

    /// Ask GitHub for the latest release. `silent` (the launch check) only surfaces a found update: "up to date" and network
    /// failures stay quiet. A slow or blocked network just times out. With automatic updates on, a found release is
    /// downloaded and staged in the background.
    @discardableResult
    package func checkForUpdate(silent: Bool = false) -> Task<Void, Never> {
        guard !busy else { return Task {} }
        busy = true
        if !silent { status = t("app.checking") }
        return Task {
            let data = await releases.latestRelease()
            finishCheck(AppUpdate.check(latest: data, current: version), silent: silent)
        }
    }

    private func finishCheck(_ outcome: AppUpdate.Check, silent: Bool) {
        busy = false
        switch outcome {
        case .found(let f):
            update = f
            switch installability {
            case .developer: status = String(format: t("app.devBuild"), f.tag)
            case .readOnly: status = String(format: t("app.readOnly"), f.tag)
            case .ok:
                if staged?.release == f { status = String(format: t("app.ready"), f.tag) }
                else if automatic { stage(f, automatic: true) }
                else { status = String(format: t("app.found"), f.tag) }
                // The sheet opens either way: it is the only place the release notes appear, and "a new version is out"
                // without saying what changed is what made people press Update blindly or not at all. In automatic mode it
                // is also where Restart now lives, and it says the download is already running.
                showUpdateSheet = true
            }
        case .unreachable:
            if !silent { status = t("app.netFail") }
        case .noAsset(let tag):
            // The release exists; this app just cannot find its own asset name in it.
            if !silent { status = String(format: t("app.noAsset"), tag); update = nil }
        case .upToDate:
            if !silent { status = t("app.upToDate") }
        }
    }

    // ---- Download, verify, unpack ----

    /// Download the release, check it against its digest, unpack it and check the app inside, all in the background: the result
    /// waits in `staged`. `automatic` (the switch) refuses a release whose digest GitHub did not give, the Update button
    /// accepts it, as before. `then` gets the staged copy (the button installs it at once).
    @discardableResult
    package func stage(_ release: AppUpdate.Release, automatic: Bool, then: ((AppUpdate.Staged) -> Void)? = nil) -> Task<Void, Never> {
        guard !busy, installability == .ok, let url = URL(string: release.url) else { return Task {} }
        busy = true
        blocked = nil
        status = String(format: t(automatic ? "app.staging" : "app.downloading"), release.tag)
        let expectedID = bundleIdentifier, runner = runner, runningOS = runningOS
        return Task {
            let root = AppUpdate.freshStagingRoot()
            let zip = root.appendingPathComponent("update.zip")
            let result: Result<AppUpdate.Staged, AppUpdate.StageFailure>
            if await releases.download(url, to: zip) {
                result = await Task.detached {
                    AppUpdate.stage(zip: zip, release: release, in: root, expectedID: expectedID, requireDigest: automatic,
                                    runningOS: runningOS, runner: runner)
                }.value
            } else {
                result = .failure(.network)
            }
            finishStaging(result, release: release, then: then)
        }
    }

    private func finishStaging(_ result: Result<AppUpdate.Staged, AppUpdate.StageFailure>, release: AppUpdate.Release,
                               then: ((AppUpdate.Staged) -> Void)?) {
        busy = false
        switch result {
        case .success(let s):
            staged = s
            status = String(format: t("app.ready"), release.tag)
            then?(s)
        case .failure(let why):
            if case .needsNewerMacOS(let min) = why {
                // Nothing was installed: the running version stays, and says why
                status = String(format: t(why.key), release.tag, min, AppUpdate.describe(runningOS))
            } else {
                status = String(format: t(why.key), release.tag)
            }
            blocked = status
        }
    }

    // ---- Install ----

    /// Swap the staged app in. `relaunch` (Restart now, the Update button) opens the new copy and quits, at quit the next
    /// launch is the new version. Refused while a build runs.
    @discardableResult
    package func install(relaunch relaunchNow: Bool, at current: URL? = nil) -> Bool {
        guard let staged, installability == .ok else { return false }
        let current = current ?? bundle
        let placed: URL
        do {
            placed = try AppUpdate.install(staged.app, over: current, buildRunning: !mayInstall, trashOld: trashOldApp, runner: runner)
        } catch AppUpdate.InstallError.failed(let why) {
            status = String(format: t("app.installFail"), why)
            return false
        } catch {
            status = t("app.waitForBuild")
            return false
        }
        self.staged = nil
        // A rename era (nxnative, NS Port Builder, NX2Apple) installs under the release's own bundle name. The Dock entry
        // pointing at the old path goes stale once, so the log says where the new copy landed instead of leaving the player
        // to find it.
        if placed != current {
            fputs("launcher: the update was installed as \(placed.lastPathComponent) (the app was renamed); "
                + "the previous \(current.lastPathComponent) was removed - re-pin it in the Dock\n", stderr)
            renamedInstall = placed.path
        }
        if relaunchNow {
            status = String(format: t("app.relaunching"), staged.release.tag)
            // The old instance is still running, so opening the same bundle now would only activate it: a helper opens the
            // new copy once this process has exited.
            if relaunch(placed) { terminate() } else { status = String(format: t("app.relaunchFail"), staged.release.tag) }
        }
        return true
    }

    /// Restart now (Settings, the library's activity line): install and relaunch, never during a build.
    package func restartNow() {
        guard staged != nil else { return }
        guard mayInstall else { status = t("app.waitForBuild"); return }
        install(relaunch: true)
    }

    /// The Update button (automatic updates off, or a release they would not take): download and verify, swap in, relaunch. A
    /// staged copy of the same release goes in as it is. Not during a build: the relaunch would end it.
    package func performUpdate() {
        guard let upd = update, !busy, installability == .ok else { return }
        guard mayInstall else { status = t("app.waitForBuild"); return }
        if staged?.release == upd { install(relaunch: true); return }
        stage(upd, automatic: false) { [weak self] _ in
            guard let self else { return }
            self.status = self.t("app.installing")
            self.install(relaunch: true)
        }
    }

    /// The app is quitting (AppKit's notification, forwarded by the app). The staged update goes in, so the next launch is the
    /// new version without interrupting anyone. A build running at that moment is being ended by the same quit: the swap then
    /// waits for a later quit (the next launch stages the release again) rather than run while the build's tools are alive.
    package func appWillTerminate() {
        guard automatic, staged != nil, mayInstall else { return }
        install(relaunch: false)
    }

    // ---- Uninstall ----

    /// The player confirmed the uninstall dialog: remove what the plan names and say what went and what did not.
    package func confirmUninstall() {
        guard let plan = uninstallPlan else { return }
        let result = uninstall(plan)
        uninstallPlan = nil
        if result.failures.isEmpty {
            status = String(format: t("uninstall.done"), result.removed.count)
        } else {
            status = t("uninstall.failed") + "\n" + result.failures.joined(separator: "\n")
        }
    }
}
