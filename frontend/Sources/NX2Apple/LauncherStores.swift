import AppKit
import NXCore
import NXModel

/// The app's wiring (LNPANDY/NX2Apple#387, step 7): it creates the services and the stores, connects them and hands them to the views.
/// It holds no logic and no state of its own. Every store is a `let`, and a view takes the stores it shows as its own parameters, so a
/// change in one store redraws only the views that observe it.
///
/// What reaches back from one store to another is wired here as closures and narrow protocols: the repository's `didMove` starts the
/// engine sync, the engine sync reads the repository and the interpreter, the build reads the repository, the tools, the engine and
/// the devices, and the stores that need to know whether a build runs ask the build store. What needs AppKit (the file panels, the
/// alert, the Finder, quitting) is wired here too.
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
    private var quitObserver: NSObjectProtocol?

    /// - Parameters:
    ///   - xcrun: runs xcodebuild and devicectl: a test points it at a stand-in.
    ///   - volumesRoot: where external drives are mounted.
    init(localizer: Localizer = Localizer(), runner: ProcessRunner = SystemProcessRunner(), gitCheckout: GitCheckout? = nil,
         releases: ReleaseSource = GitHubReleases(), xcrun: String = "/usr/bin/xcrun", volumesRoot: String = "/Volumes") {
        _ = Self.endGroupsWhenQuitting
        let git = gitCheckout ?? SystemGitCheckout(runner: runner)
        self.localizer = localizer; self.runner = runner; self.gitCheckout = git; self.releases = releases
        let log = BuildLog()
        let laterBuild = Later<BuildStore>(), laterEngine = Later<EngineSyncStore>()

        let repo = RepoStore(
            localizer: localizer, git: git,
            buildRunning: { laterBuild.value?.running ?? false },
            isReleaseApp: { laterEngine.value?.usesEngineStore ?? false },
            log: { log.append($0) },
            didMove: { _ = laterEngine.value?.syncEngine() })   // the pull may have moved the pin or the patches
        let dependencies = DependencyStore(
            localizer: localizer, runner: runner, repo: repo,
            needsIOS: { Self.needsIOSPlatform() },
            openAppStore: { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/App Store.app")) },
            log: { log.append($0) },
            installFailed: { laterBuild.value?.note($0) })
        let engineSync = EngineSyncStore(
            localizer: localizer, runner: runner, repo: repo, python: dependencies,
            setRepoPath: { repo.path = $0 },
            buildRunning: { laterBuild.value?.running ?? false },
            autoUpdate: { repo.autoUpdate },
            log: { log.append($0) })
        laterEngine.value = engineSync
        let devices = DeviceStore(runner: runner, xcrun: xcrun)
        let updates = AppUpdateStore(
            localizer: localizer, runner: runner, releases: releases,
            buildRunning: { (laterBuild.value?.running ?? false) || ProcessGroups.buildProcessesAlive },
            terminate: {
                NSApp.terminate(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(0) }
            })
        let build = BuildStore(
            localizer: localizer, runner: runner, log: log, repo: repo, deps: dependencies, engine: engineSync, devices: devices,
            volumesRoot: volumesRoot,
            targetChanged: {
                // A Mac-only setup needs no iOS SDK for a Mac build, but does for an iPhone one (needsIOSPlatform)
                if UserDefaults.standard.string(forKey: OnboardingDefaults.platform) == "mac" { _ = dependencies.check() }
            })
        laterBuild.value = build
        self.repo = repo; self.engineSync = engineSync; self.dependencies = dependencies; self.deviceStore = devices
        self.appUpdates = updates; self.build = build

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

    /// What the build store asks of AppKit: the open panel, the folder panel, the save panel, the alert and the Finder.
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
            let d = NSOpenPanel(); d.canChooseDirectories = true; d.canChooseFiles = false
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
        build.showNotice = { text in
            let a = NSAlert()
            a.messageText = text
            a.alertStyle = .informational
            a.addButton(withTitle: "OK")
            a.runModal()
        }
        build.revealFolder = { NSWorkspace.shared.open($0) }
        build.openApp = { NSWorkspace.shared.openApplication(at: $0, configuration: NSWorkspace.OpenConfiguration()) }
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
