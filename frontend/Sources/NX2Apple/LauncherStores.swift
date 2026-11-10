import AppKit
import Combine
import NXCore
import NXModel

/// The app's wiring (LNPANDY/NX2Apple#387, step 7): it creates the services and the stores, connects them and hands them to the views.
/// It holds no logic and no state of its own. Every store is a `let`, and a view takes the stores it shows as its own parameters, so a
/// change in one store redraws only the views that observe it.
///
/// What reaches back from one store to another is wired here as closures and narrow protocols: the repository's `didMove` starts the
/// engine sync, the engine sync reads the repository and the interpreter, the build reads the repository, the tools, the engine and
/// the devices, and the stores that need to know whether a build runs ask the build store. What needs AppKit (the file panels, the
/// Finder, quitting) is wired here too.
@MainActor final class LauncherStores {
    let localizer: Localizer
    let runner: ProcessRunner
    let gitCheckout: GitCheckout
    let releases: ReleaseSource
    let repo: RepoStore
    let engineSync: EngineSyncStore
    let dependencies: DependencyStore
    let deviceStore: DeviceStore
    let appUpdates: AppUpdateStore
    let build: BuildStore
    /// The one build queue (#943), kept in Application Support so it survives a restart. A test suite of defaults keeps it in memory.
    let queue: BuildQueueStore
    /// The transfer queue (#1036): game data on its way to devices, beside any build.
    let transfers: TransferQueueStore
    private var transferWatch: AnyCancellable?
    private var queueWatch: AnyCancellable?
    let players: PlayerProfileStore
    let saveSettings: SaveSettingsStore
    let sticks: StickDeadzoneStore
    /// The games' build files (#232), measured and removed by `BuildFiles` (the Free space code).
    let buildFiles = BuildFilesStore(measure: { BuildFiles.measure($0) }, remove: { try BuildFiles.remove($0) })
    private var quitObserver: NSObjectProtocol?

    /// - Parameters:
    ///   - xcrun: runs xcodebuild and devicectl: a test points it at a stand-in.
    ///   - volumesRoot: where external drives are mounted.
    ///   - defaults: where the stores keep their settings: a test passes its own suite, so it neither reads nor writes the shared ones.
    init(localizer: Localizer = Localizer(), runner: ProcessRunner? = nil, gitCheckout: GitCheckout? = nil,
         releases: ReleaseSource = GitHubReleases(), xcrun: String = "/usr/bin/xcrun", volumesRoot: String = "/Volumes",
         defaults: UserDefaults = .standard) {
        _ = Self.endGroupsWhenQuitting
        let runner = runner ?? SystemProcessRunner(defaults: defaults)
        let git = gitCheckout ?? SystemGitCheckout(runner: runner)
        self.localizer = localizer; self.runner = runner; self.gitCheckout = git; self.releases = releases
        let log = BuildLog()
        let laterBuild = Later<BuildStore>(), laterEngine = Later<EngineSyncStore>()

        let repo = RepoStore(
            localizer: localizer, git: git, defaults: defaults,
            buildRunning: { laterBuild.value?.running ?? false },
            isReleaseApp: { laterEngine.value?.usesEngineStore ?? false },
            log: { log.append($0) },
            didMove: { _ = laterEngine.value?.syncEngine() })   // the pull may have moved the pin or the patches
        let dependencies = DependencyStore(
            localizer: localizer, runner: runner, repo: repo, defaults: defaults,
            needsIOS: { Self.needsIOSPlatform(defaults: defaults) },
            openAppStore: { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/App Store.app")) },
            log: { log.append($0) },
            installFailed: { laterBuild.value?.note($0) })
        let engineSync = EngineSyncStore(
            localizer: localizer, runner: runner, repo: repo, python: dependencies, defaults: defaults,
            setRepoPath: { repo.path = $0 },
            buildRunning: { laterBuild.value?.running ?? false },
            autoUpdate: { repo.autoUpdate },
            log: { log.append($0) })
        laterEngine.value = engineSync
        let devices = DeviceStore(runner: runner, xcrun: xcrun, defaults: defaults)
        let updates = AppUpdateStore(
            localizer: localizer, runner: runner, releases: releases, defaults: defaults,
            buildRunning: { (laterBuild.value?.running ?? false) || ProcessGroups.buildProcessesAlive },
            terminate: {
                NSApp.terminate(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(0) }
            })
        let build = BuildStore(
            localizer: localizer, runner: runner, log: log, repo: repo, deps: dependencies, engine: engineSync, devices: devices, defaults: defaults,
            volumesRoot: volumesRoot,
            targetChanged: {
                // A Mac-only setup needs no iOS SDK for a Mac build, but does for an iPhone one (needsIOSPlatform)
                if defaults.string(forKey: OnboardingDefaults.platform) == "mac" { _ = dependencies.check() }
            })
        laterBuild.value = build
        self.repo = repo; self.engineSync = engineSync; self.dependencies = dependencies; self.deviceStore = devices
        self.appUpdates = updates; self.build = build
        let queueFile = defaults === UserDefaults.standard
            ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NX2Apple/build-queue.json") : nil
        let queue = BuildQueueStore(
            file: queueFile, engineID: { engineSync.selection.engineID }, busy: { build.running },
            start: { build.startQueued($0) }, packageBatch: { _ in build.packageDeferred() }, engineChangedReason: { localizer.t("queue.engineChanged") })
        self.queue = queue
        let transferFile = queueFile?.deletingLastPathComponent().appendingPathComponent("transfer-queue.json")
        let transfers = TransferQueueStore(
            file: transferFile,
            perform: { entry, report, finish in build.performTransfer(entry, report: report, finish: finish) },
            cancelRunning: { build.cancelTransfer($0) })
        self.transfers = transfers
        build.transfers = transfers
        // A device that comes back continues the transfers that waited for it. The list is read again every few seconds while one waits.
        transferWatch = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
            .sink { [weak transfers, weak devices] _ in
                MainActor.assumeIsolated {
                    guard let transfers, let devices, transfers.hasWaiting else { return }
                    transfers.deviceConnected(Set(devices.devices.filter(\.reachable).map(\.id)))
                    devices.refresh()
                }
            }
        // A build that ended settles the queue's running entry and starts the next. The hop lets the install step that follows a
        // build raise `running` again first (the BuildRecorder waits the same way).
        queueWatch = build.$running.removeDuplicates().sink { [weak build, weak queue] running in
            guard !running else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let build, let queue, !build.running, queue.running != nil else { return }
                    let outcome = build.queueOutcome
                    queue.buildEnded(succeeded: outcome.succeeded, reason: outcome.reason, stopped: outcome.stopped)
                    if queue.running == nil { build.deferShellPackaging = false }
                }
            }
        }
        self.saveSettings = SaveSettingsStore(defaults: defaults)
        self.sticks = StickDeadzoneStore(defaults: defaults)
        self.players = PlayerProfileStore(defaults: defaults, defaultName: { localizer.t("players.default") })

        // The staged update goes in as the app quits, so the next launch is the new version without interrupting anyone.
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak updates] _ in
            MainActor.assumeIsolated { updates?.appWillTerminate() }
        }
        wirePanels()
    }

    /// The process groups of the builds are `ProcessGroups` (NXCore). Quitting the app ends them: the notification is AppKit's.
    private static let endGroupsWhenQuitting: Void = {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in ProcessGroups.endAll() }
    }()

    /// What the build store asks of AppKit: the open panel, the folder panel, the save panel and the Finder.
    private func wirePanels() {
        build.choosePaths = { pick in
            let p = NSOpenPanel()
            p.canChooseDirectories = false
            p.canChooseFiles = true
            p.allowsMultipleSelection = pick.allowsMultiple
            p.allowedFileTypes = pick.fileTypes
            if let message = pick.message { p.message = message }
            if let prompt = pick.prompt { p.prompt = prompt }
            guard p.runModal() == .OK, !p.urls.isEmpty else { return [] }
            return p.urls.map(\.path)
        }
        build.chooseFolder = {
            let d = Self.buildFolderPanel()
            guard d.runModal() == .OK, let u = d.url else { return nil }
            return u.path
        }
        build.chooseSaveLocation = { title, name in
            let p = NSSavePanel()
            p.title = title
            p.allowedFileTypes = ["ipa"]
            p.nameFieldStringValue = name
            p.canCreateDirectories = true
            guard p.runModal() == .OK else { return nil }
            return p.url
        }
        build.revealFolder = { NSWorkspace.shared.open($0) }
        build.revealItem = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
        build.openApp = { NSWorkspace.shared.openApplication(at: $0, configuration: NSWorkspace.OpenConfiguration()) }
        build.preflightApp = { app, done in Self.preflight(app, done: done) }
    }

    /// The build's check of a new Mac app's first start (#1005, `MacPreflight`): opened through LaunchServices, as Play
    /// opens it, since only that open has macOS check the bundle; hidden, in the background, a new instance even if an
    /// older build of the game runs, kept out of the recent items. Its launcher sees DM_PREFLIGHT and quits at once, once
    /// macOS lets it start. `done` runs when the process has quit, or with the error that kept it from starting; the
    /// BuildStore ends the wait itself after its timeout, and the poll stops then too.
    static func preflight(_ app: URL, done: @escaping @MainActor (Error?) -> Void) {
        let c = NSWorkspace.OpenConfiguration()
        c.activates = false
        c.hides = true
        c.addsToRecentItems = false
        c.createsNewApplicationInstance = true
        c.environment = [MacPreflight.environmentKey: "1"]
        NSWorkspace.shared.openApplication(at: app, configuration: c) { running, error in
            DispatchQueue.main.async {
                guard let running else { done(error); return }
                let deadline = Date().addingTimeInterval(MacPreflight.timeout)
                Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
                    guard running.isTerminated || Date() > deadline else { return }
                    timer.invalidate()
                    MainActor.assumeIsolated { done(running.isTerminated ? nil : MacPreflight.Failure.timedOut) }
                }
            }
        }
    }

    /// The panel of the Build tab's Save to folder. It can make a folder, because the folder for the IPA often does not exist yet.
    static func buildFolderPanel() -> NSOpenPanel {
        let d = NSOpenPanel()
        d.canChooseDirectories = true; d.canChooseFiles = false; d.canCreateDirectories = true
        return d
    }

    /// Whether the xcode row asks for the iOS SDK. Always, as before, unless the guided setup stored a Mac-only choice
    /// and builds are for the Mac: upstream no longer needs the iOS SDK for a Mac build (c464cb24).
    nonisolated static func needsIOSPlatform(defaults: UserDefaults = .standard) -> Bool {
        if OnboardingDefaults.sessionPlatform == "mac" { return false }   // a forced run's choice, not stored yet
        guard defaults.string(forKey: OnboardingDefaults.platform) == "mac" else { return true }
        return BuildTarget.normalized(defaults.string(forKey: "buildTarget")) != BuildTarget.mac
    }
}

/// A store that a closure reaches before it exists: the closures of the stores created first read it, the app fills it in last.
@MainActor private final class Later<T: AnyObject> {
    weak var value: T?
}
