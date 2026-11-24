import Foundation
import Combine
import NXCore

/// A file picker request: what the store asks the app's open panel for (`BuildStore.choosePaths`).
package struct FilePick: Equatable {
    package var allowsMultiple: Bool
    package var fileTypes: [String]
    package var message: String?
    package var prompt: String?

    package init(allowsMultiple: Bool, fileTypes: [String], message: String? = nil, prompt: String? = nil) {
        self.allowsMultiple = allowsMultiple
        self.fileTypes = fileTypes
        self.message = message
        self.prompt = prompt
    }
}

/// What the build asks of the engine sync: make `engine/` of the checkout current, and tell when it is done.
@MainActor package protocol EngineSyncing: AnyObject {
    func syncEngine(then: ((Bool) -> Void)?) -> Task<Void, Never>
}

/// What the build asks of the dependency store besides its status: the rows, and the install the card's fix buttons run.
@MainActor package protocol DependencyInstalling: DependencyStatus {
    func isInstalling(_ id: String) -> Bool
    func install(_ dep: Dep) -> Task<Void, Never>
}

extension DependencyStore: DependencyInstalling {}
extension EngineSyncStore: EngineSyncing {}

/// Runs `body` on the main actor, from a queue that is not the main one: the pipe's callbacks and the background install land here.
func hop(_ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(body) }
}

/// The build (LNPANDY/NX2Apple#387, step 7, the last store): the inputs (the four rows, the output folder), the target, the stages
/// and whether a build runs, the script's JSON events, the run itself with its archive step and its hand-off to the device, the
/// failure the card shows and "Build anyway". It follows `AppUpdateStore` (`frontend/ARCHITECTURE.md`, "Stores").
///
/// - What it works with comes through `init`: the `Localizer`, a `ProcessRunner`, the `BuildLog`, and three narrow views of the other
///   stores: `RepoLocation` (where the checkout is), `DependencyInstalling` (the tools: `DependencyStatus` and the install the fix
///   buttons run), `EngineSyncing` (the sync a stale `engine/` needs before a build) and `InstallTarget` (the device, the team and
///   the copy flow). The app wires them.
/// - AppKit reaches it as closures: the file and folder pickers (`choosePaths`, `chooseFolder`, `chooseSaveLocation`), the Finder
///   (`revealFolder`, `openApp`), and `targetChanged`, which the app answers with a new dependency check.
/// - It checks the conditions for its own actions: `canBuild` and the start of a build (`startBuild`).
/// - The pieces live in the `BuildStore+` files: `Inputs`, `Run`, `Failure`, `Archive`, `Install`, `Stale`, `DropFiles`.
@MainActor package final class BuildStore: ObservableObject {
    nonisolated package static let outputKey = "buildOutputDirectory"
    nonisolated package static let targetKey = "buildTarget"
    nonisolated package static let bcOnCPUKey = "bcOnCPU"
    nonisolated package static let savedKeysKey = "savedKeysPath"
    nonisolated package static let buildUpstreamKey = "buildUpstream"
    nonisolated package static let macNativeGamesPathKey = "macNativeGamesPath"
    nonisolated package static let s2armPathKey = "s2armPath"

    @Published package var gameDir = ""
    @Published package var slots: [Slot] = [
        Slot(id: "base", kind: .base, title: "data.base", optional: false),
        Slot(id: "update", kind: .update, title: "data.update", optional: true),
        Slot(id: "dlc", kind: .dlc, title: "data.dlc", optional: true),
        Slot(id: "keys", kind: .keys, title: "data.keys", optional: false),
    ] {
        didSet {
            if slots.map(\.paths) != oldValue.map(\.paths) {
                invalidateKeyProblem()
                if selectedTitleID != nil || failure?.kind == .severalGames {
                    selectedTitleID = nil
                    if failure?.kind == .severalGames {
                        failure = nil
                        doneNote = ""
                    }
                }
                enforceUpstreamForCurrentGame()
                dropFailureOfOtherGame()
                probeBasePackageTitleIDIfNeeded()
            }
        }
    }
    /// The program the player chose for this build, including its device checks and retries.
    var selectedTitleID: String? {
        didSet {
            if selectedTitleID != oldValue {
                enforceUpstreamForCurrentGame()
            }
        }
    }
    /// The game folder the rows came from (BuildStore+GameFolder.swift), nil for packages.
    @Published package var gameFolder: GameFolder.Contents? {
        didSet {
            if gameFolder != oldValue {
                invalidateKeyProblem()
                enforceUpstreamForCurrentGame()
                dropFailureOfOtherGame()
                probeBasePackageTitleIDIfNeeded()
            }
        }
    }
    /// A folder meant as a game folder was refused: the base row says why.
    @Published package var gameFolderRefused = false
    @Published package var outDir: String {
        didSet { defaults.set(outDir, forKey: Self.outputKey) }
    }
    @Published package var stages: [Stage] = []
    /// The first shader rebuild explanation of this build. The view localizes it without pausing progress ingestion.
    @Published package var staleShadersMessageKey: String?
    @Published package var running = false {
        didSet {
            if !running, !buildingGame { runningTarget = target }
            if !running {
                completedOperation = operation?.kind
                operation = nil
            }
            if !running, oldValue {
                applyPendingNxkitSwitch()   // an nxkit update waits for the build (BuildStore+Nxkit.swift)
                enforceUpstreamForCurrentGame()
            }
        }
    }
    /// What runs right now: operation, game and destination, taken when the work starts and independent of the Build form
    /// (BuildStore+Operation.swift). nil when nothing runs.
    @Published package internal(set) var operation: ActiveOperation?
    /// The state gallery: the activity of `operation` without running it (DesignGallery).
    package func setOperationForGallery(_ operation: ActiveOperation?) { self.operation = operation }
    package var completedOperation: ActiveOperation.Kind?
    @Published package var staleFrameworks: [StaleFrameworks.Entry] = []   // the prompt of StaleFrameworksPrompt.swift (#449)
    // The shell folder (shellCachePath, shellRoot, shellRootProblem): BuildStore+ShellRoot.swift.
    @Published package var stopping = false
    /// The build log. Not published: only `BuildLogView` observes it (#387), so a log line redraws the log and nothing else.
    package let log: BuildLog
    package var logTail: String {
        get { log.text }
        set { log.set(newValue) }
    }
    @Published package var done = false
    @Published package var doneNote = ""
    /// What the NSP script stopped on, when it is one of the known early stops (BuildFailureClassifier). nil for a build that
    /// succeeded, is running, or failed some other way (the note then shows the last line of the log, as it always did).
    @Published package var failure: BuildFailure? {
        didSet {
            if failure?.titleIDs != oldValue?.titleIDs { failureChoice = nil }
            failureGameKey = failure == nil ? nil : buildKey
        }
    }
    /// The game the failure is for (its `buildKey` when the failure was set). Another game chosen on the Builds page drops it
    /// (`dropFailureOfOtherGame`), so a failure never shows under a game it did not happen to.
    package private(set) var failureGameKey: String?
    /// The game picked in a "several games" failure's list (BuildFailureCard), not built yet: the footer's Build game builds it.
    @Published package var failureChoice: String?
    /// The failure asks which of several games to build, and the launcher can build one of them.
    package var choosesTitle: Bool { !(failure?.titleIDs.isEmpty ?? true) }
    /// "Build anyway" asked for this stop and waiting for the confirmation dialog.
    @Published package var confirmingOverride: BuildFailureKind?
    /// The one-off `--allow-*` of a confirmed "Build anyway": taken by the next build and never stored.
    package var armedOverride: BuildFailureKind?
    /// Blocking preflight message when `prod.keys` lacks a required `master_key_XX` or `header_key` for the selected packages.
    @Published package var keyProblem: String?
    package var keyCheckGeneration = 0
    /// Total planned stages (`n` from `[k/n]`) and monotonic overall fraction (`0.0...1.0`) for the active build.
    @Published package var totalStages = 0
    @Published package var overallProgress: Double?
    package var peakOverallProgress: Double = 0
    @Published package var macAppPath = ""   // --platform mac-app: the .app this build produced
    package var oneGameIPAPath = ""   // the IPA a one-game export writes (#540), empty for any other build
    /// BuildTarget.ios = the game's framework in the one shared app on an iPhone or iPad, BuildTarget.mac = a double-clickable
    /// Mac app (upstream's --platform mac-app). A Mac app is a different output of the same pipeline, not a
    /// different pipeline: same extraction, rewrite and shaders, then dm/mac/pack_app.py.
    @Published package var target: String {
        didSet {
            // A Mac-only engine (nxkit, MacNativeGames) builds for the Mac whatever was asked. The saved choice stays as the player
            // set it, so the engine that builds for iOS gets it back (`buildUpstream`).
            if isMacOnlyUpstreamSelected {
                if target != BuildTarget.mac { defaults.set(target, forKey: Self.targetKey); target = BuildTarget.mac }
            } else {
                defaults.set(target, forKey: Self.targetKey)
            }
            if !running { runningTarget = target }
            if oldValue != target { targetChanged() }
            refreshSeenShadersInfo()
        }
    }
    /// The target of the operation currently running (or last run), so an iPhone re-sign, reinstall, export or data copy started while
    /// the Build form's `target` picker sits on `mac-app` still reports itself as an iPhone activity.
    @Published package var runningTarget: String
    /// True when `running` is a game build rather than a standalone post-build action (`resignOnDevice`, `reinstallOnDevice`,
    /// `saveIPA`, `sendGameData`, `copyToDrive`, `confirmShellMove`).
    package var buildingGame = true
    /// Decode BC-compressed textures on the CPU. Only relevant for GPUs without BC support
    /// (A15/A16 and older): on a device that has it the GPU path is always better, so the switch
    /// is a compatibility option and defaults off. Passed as DM_PROF_TEX_BC_CPU through --env-file,
    /// which the host reads at start-up — no rebuild of the host needed.
    @Published package var bcOnCPU: Bool {
        didSet { defaults.set(bcOnCPU, forKey: Self.bcOnCPUKey) }
    }
    @Published package var seenShadersOnly: Bool { didSet { defaults.set(seenShadersOnly, forKey: Self.seenShadersOnlyKey) } }
    @Published package var iosSeenShadersOnly: Bool { didSet { defaults.set(iosSeenShadersOnly, forKey: Self.iosSeenShadersKey) } }
    @Published package internal(set) var cachedSeenShaders: SeenShadersInfo?
    @Published package internal(set) var queueHasIOSSeenShadersEligible = false
    var seenShadersProbe = SeenShadersProbeState()
    /// The prod.keys chosen once for every game (Settings, "Keys", #996): a build whose keys row is empty or names a file that is gone
    /// takes it (BuildStore+SavedKeys.swift). Empty when none is saved.
    @Published package internal(set) var savedKeys: String {
        didSet {
            if savedKeys.isEmpty { defaults.removeObject(forKey: Self.savedKeysKey) } else { defaults.set(savedKeys, forKey: Self.savedKeysKey) }
            if savedKeys != oldValue {
                invalidateKeyProblem()
                probeBasePackageTitleIDIfNeeded()
            }
        }
    }
    @Published package var buildUpstream: EngineUpstreamKind {
        didSet {
            if !running && buildUpstream.enforcedTitleIDs != nil && isUpstreamBlockedByCurrentGame(buildUpstream) {
                buildUpstream = .nxnative
                return
            }
            defaults.set(buildUpstream.rawValue, forKey: Self.buildUpstreamKey)
            if isMacOnlyUpstreamSelected && target != BuildTarget.mac {
                target = BuildTarget.mac
            } else if !isMacOnlyUpstreamSelected, oldValue.buildsMacOnly, !running {
                let saved = BuildTarget.saved(defaults)   // back from a Mac-only engine: the player's own choice again
                if saved != target { target = saved }
            }
            if oldValue != buildUpstream {
                upstreamChanged()
            }
            refreshSeenShadersInfo()
            refreshQueueSeenShadersEligibility()
        }
    }
    @Published package var macNativeGamesPath: String {
        didSet {
            defaults.set(macNativeGamesPath, forKey: Self.macNativeGamesPathKey)
            macNativeGamesInstalled = MacNativeGamesBuilder.isUsableTree(macNativeGamesPath)
            refreshUpstreamLocalVersion(for: .macNativeGames)
            let blocksMNG = queue?.queued.contains { !Self.canQueueEntryUseMNG($0, tree: macNativeGamesPath) } ?? false
            if queueBlocksMNG != blocksMNG { queueBlocksMNG = blocksMNG }
            enforceUpstreamForCurrentGame()
        }
    }
    @Published package internal(set) var macNativeGamesInstalled = false
    package var mngRun = false
    @Published package var kidWithSwordPath: String {
        didSet {
            defaults.set(kidWithSwordPath, forKey: Self.kidWithSwordPathKey)
            kidWithSwordInstalled = UpstreamEngineStore.isUsableTree(kidWithSwordPath, kind: .kidWithSword)
            refreshUpstreamLocalVersion(for: .kidWithSword)
        }
    }
    @Published package internal(set) var kidWithSwordInstalled = false
    @Published package var noLagKartPath: String {
        didSet {
            defaults.set(noLagKartPath, forKey: Self.noLagKartPathKey)
            noLagKartInstalled = UpstreamEngineStore.isUsableTree(noLagKartPath, kind: .noLagKart)
            refreshUpstreamLocalVersion(for: .noLagKart)
        }
    }
    @Published package internal(set) var noLagKartInstalled = false
    /// Engine kind used by the active or most recently completed build run.
    package var activeBuildUpstream: EngineUpstreamKind = .nxnative
    @Published package var s2armPath: String {
        didSet {
            defaults.set(s2armPath, forKey: Self.s2armPathKey)
            s2armInstalled = S2ArmBuilder.isUsableTree(s2armPath)
            refreshUpstreamLocalVersion(for: .s2arm)
            if oldValue != s2armPath && buildUpstream == .s2arm {
                upstreamChanged()
            }
        }
    }
    @Published package internal(set) var s2armInstalled = false
    @Published package internal(set) var upstreamDownloads: [EngineUpstreamKind: UpstreamInstallState] = [:]
    @Published package internal(set) var upstreamLocalVersions: [EngineUpstreamKind: UpstreamVersionReceipt] = [:]
    @Published package internal(set) var upstreamRemoteVersions: [EngineUpstreamKind: UpstreamRemoteInfo] = [:]
    package var upstreamDownloadTasks: [EngineUpstreamKind: Task<Void, Never>] = [:]
    package var upstreamDownloadGeneration: [EngineUpstreamKind: UInt64] = [:]
    package var upstreamVersionChecks = UpstreamVersionCheckState()
    @Published package internal(set) var upstreamAutoSwitchRevision: UInt64 = 0
    package var upstreamTransport: EngineTransport = URLSessionEngineTransport()
    package var s2armRun = false
    package var s2armEventsPath = ""
    /// nxkit (Beta), BuildStore+Nxkit.swift (#1460): the pair the next build runs, the version before it, the update's state, the question after a build.
    @Published package internal(set) var nxkitInUse: NxkitVersionStore.Selection?
    @Published package internal(set) var nxkitPreviousVersion: String?
    @Published package internal(set) var nxkitUpdate: NxkitUpdateState = .idle
    @Published package var nxkitFeedback: NxkitFeedbackPrompt?
    /// The app's own pair (Contents/Resources/nxbuild, frontend/nxbuild.pin), nil under `swift run`. Tests and the gallery set their own.
    package var nxkitBundledFolder: String? = NxkitBuilder.bundledFolder(resources: Bundle.main.resourcePath)
    package var nxkitVersions = NxkitVersionStore()
    package var nxkitAvailability = NxkitBuilder.currentAvailability
    /// "Update automatically when the app opens" (RepoStore.autoUpdate), wired by LauncherStores.
    package var nxkitAutoUpdate: () -> Bool = { true }
    /// The update's key and its ad hoc signing, replaced by tests (NxkitUpdate.swift).
    package var nxkitPublicKey = NxkitUpdate.publicKey
    package var nxkitPrepare: @Sendable (URL) -> Bool = NxkitVersionStore.prepare
    package var nxkitRun = false
    var nxkitRunSelection: NxkitVersionStore.Selection?
    var nxkitBuildID = ""
    var nxkitPendingVersion: String?
    @Published package var archivePath = ""  // the romfs folder the pack wrote
    /// True after an iOS fast refresh embedded `DMMSLTR1` shaders into `.img`, reminding the player to replace older `.img` copies.
    @Published package var needsReplaceOldImgReminder = false
    @Published package var updatedImgPath = ""
    /// Where this build's folder actually is: --work-dir when the checkout has it, else the script's
    /// default under the input folder (issue #5 — an upstream checkout has no --work-dir).
    package var effectiveWorkDir = ""
    package var lastBuildCommand: [String] = []   // this session's last build, for Copy diagnostics (Diagnostics.swift)

    // ---- Installing on an iPhone or iPad (Xcode with a development certificate) ----
    @Published package var installedDataComplete: Bool?
    @Published package var installedOn = "" { didSet { installedDataComplete = nil } }       // the device the last build went to (its UDID)
    @Published package var installedAppPath = ""  // the signed app that went there
    @Published package var exportedIPAPath = ""   // the unsigned IPA of an export (#416)
    @Published package var send: DataSend = .idle {  // step 3 of the export: the game data on its way (BuildStore+Send.swift)
        didSet {
            if send != oldValue { finderShown = false }
            guard devices.installDevice == installedOn else { return }
            switch send {
            case .sent: installedDataComplete = true
            case .sending: installedDataComplete = false
            default: break
            }
        }
    }
    /// The player chose the Finder way after the copy to the device did not work: step 3 shows its three steps (#491).
    @Published package var finderShown = false
    @Published package var drive: DriveState?      // the chosen folder's volume and what stops the copy (BuildStore+Send.swift)
    @Published package var driveBatchLabel = ""    // active game label during a multi-game drive copy ("1/3 · Hades")
    var shellRetry: (framework: String, titleID: String, name: String, archive: String)?
    var shellBatchRetry: [DeferredShellGame]?
    var shellDeviceChecked = false
    package let driveCancel = LockedFlag()   // Stop of the copy to a drive (BuildStore+Send.swift)
    @Published package var shellMove: CacheMove = .idle   // Move cache folder (BuildStore+ShellRoot.swift, #427)
    @Published package var nxkitMove: CacheMove = .idle   // the nxkit work folder and the build seeds (BuildStore+CacheFolders.swift)
    @Published package var seedMove: CacheMove = .idle
    package let shellMoveStop = LockedFlag()   // Stop of the cache move that runs (one at a time, on `running`)
    let installCancel = LockedFlag()
    var installPhaseActive = false
    package var fastRefreshActive = false
    package var fastRefreshTitleID: String? = nil {
        didSet {
            if fastRefreshTitleID != oldValue {
                enforceUpstreamForCurrentGame()
            }
        }
    }
    package var fastRefreshGameName: String? = nil
    package var fastRefreshBaseDir: String? = nil
    package var fastRefreshExternalImgPath: String? = nil

    /// Output folder for the current operation: respects fastRefreshBaseDir during fast refresh,
    /// falling back to outDir or inputFolder for standard builds.
    package var effectiveOutputFolder: String {
        if fastRefreshActive, let base = fastRefreshBaseDir, !base.isEmpty {
            return base
        }
        return outDir.isEmpty ? inputFolder : outDir
    }
    /// The home folder the default shell root is in. Tests use a temporary one, so they never touch the real Application Support.
    package var home = NSHomeDirectory()
    /// The launcher's own environment, read for `DM_SEED_CACHE_DIR` (BuildCacheRoots). Tests set their own.
    package var launcherEnvironment = ProcessInfo.processInfo.environment

    // ---- The app's side: AppKit and the wiring, as closures ----
    /// The games whose data can go to a device: the app fills it from the library (title ID, name, the packed data folder).
    package var sharedAppDataSources: () -> [TransferSource] = { [] }
    /// Extra arguments for a Mac app build of a game (title ID in, arguments out): the app adds `--fallback-icon` (#784).
    package var macFallbackIconArguments: (String) -> [String] = { _ in [] }
    /// The transfer queue (#1036), which the app wires. Sending data goes through it so that a build can run beside it.
    package weak var transfers: TransferQueueStore?
    /// The build queue (#943), wired by the app so the Build page's start actions can run a staged queue batch.
    package weak var queue: BuildQueueStore? {
        didSet {
            queue?.macOnly = { [weak self] in self?.isMacOnlyUpstreamSelected ?? false }
            queue?.bindUpstreamProvider(
                currentUpstream: { [weak self] in self?.buildUpstream ?? .nxnative },
                defaultKeysPath: { [weak self] in self?.keysPath ?? "" },
                readPackageTitleID: { [weak self] path, keys in
                    let reader = self?.readPackageTitleID ?? { PackageHeaderTitleID.readHex16(path: $0, keysPath: $1) }
                    return reader(path, keys)
                },
                mngTreePath: { [weak self] in self?.macNativeGamesPath ?? "" }
            )
            queueHasIOS = queue?.hasIOS ?? false
            let count = queue?.games.filter(\.waiting).count ?? 0
            if queuedCount != count { queuedCount = count }
            let blocksMNG = queue?.queued.contains { !Self.canQueueEntryUseMNG($0, tree: macNativeGamesPath) } ?? false
            if queueBlocksMNG != blocksMNG { queueBlocksMNG = blocksMNG }
            enforceUpstreamForCurrentGame()
            refreshQueueSeenShadersEligibility(entries: queue?.entries ?? [])
            queueSubscription = queue?.$entries.sink { [weak self] entries in
                guard let self else { return }
                let queuedEntries = entries.filter { $0.status == .queued }
                self.queueHasIOS = queuedEntries.contains { BuildTarget.normalized($0.target) != BuildTarget.mac }
                let next = QueueGame.grouped(entries).filter(\.waiting).count
                if self.queuedCount != next { self.queuedCount = next }
                let nextBlocksMNG = queuedEntries.contains { !Self.canQueueEntryUseMNG($0, tree: self.macNativeGamesPath) }
                if self.queueBlocksMNG != nextBlocksMNG { self.queueBlocksMNG = nextBlocksMNG }
                self.enforceUpstreamForCurrentGame()
                self.refreshQueueSeenShadersEligibility(entries: entries)
            }
        }
    }
    @Published package private(set) var queueHasIOS = false
    @Published package private(set) var queuedCount = 0
    @Published package private(set) var queueBlocksMNG = false
    package var activeQueueEntryUpstream: EngineUpstreamKind? = nil
    var packageHeaderProbeGeneration: UInt64 = 0
    package var readPackageTitleID: @Sendable (_ path: String, _ keysPath: String) -> String? = {
        PackageHeaderTitleID.readHex16(path: $0, keysPath: $1)
    }
    private var queueSubscription: AnyCancellable?
    /// The running send of each transfer asks this flag whether it was cancelled.
    var transferCancels: [UUID: LockedFlag] = [:]
    package var deferShellPackaging = false
    var deferredExportsIPA = false
    package var queuedExportIPA: Bool?
    package var queuedExportOneGame: Bool?
    package var queuedExportFramework: Bool?
    var skipStaleCheckForQueuedEntry = false
    var afterStaleFrameworks: (() -> Void)?
    package var activeQueuedGameID: UUID?
    package var activeQueuedEntryID: UUID?
    package var activeQueuedArchivePath: String?
    package var activeQueuedRebuildsShaders = false
    package var activeRunStartedAt: Date?
    package var activeRunRebuiltShaders = false
    @Published package var refreshCompletionSummary: RefreshCompletionSummary?
    @Published package var pendingRefreshNotice: RefreshCompletionSummary?
    package var stoppedByPlayer = false
    var deferredShell: [DeferredShellGame] = []
    package var pickedArtworkForTitleID: (String) -> String? = { _ in nil }
    package var onBatchShellInstalled: ([DeferredShellGame], String, String) -> Void = { _, _, _ in }
    package var onBuiltGamesInstalled: (String, String) -> Void = { _, _ in }
    package var chooseKeys: (() -> Void)?          // tests stand in for the file picker
    /// The open panel: the paths the player picked, none when they cancelled.
    package var choosePaths: (FilePick) -> [String] = { _ in [] }
    /// The folder panel of "Save to": the folder's path, nil when they cancelled.
    package var chooseFolder: () -> String? = { nil }
    /// The save panel of "Save IPA" (title, the name offered): where to write, nil when they cancelled.
    package var chooseSaveLocation: (String, String) -> URL? = { _, _ in nil }
    package var revealFolder: (URL) -> Void = { _ in }
    /// A Finder window with this file or folder selected (`activateFileViewerSelecting`).
    package var revealItem: (URL) -> Void = { _ in }
    package var openApp: (URL) -> Void = { _ in }
    /// Opens a new Mac app once, hidden, with DM_PREFLIGHT set, and calls back on the main actor when it has quit, with the
    /// error that stopped it, if any (`MacPreflight`, #1005). Nil: no check, as in the tests that do not set it.
    package var preflightApp: ((URL, @escaping @MainActor (Error?) -> Void) -> Void)?
    /// Cancellable async preflight runner wired by `LauncherStores` so Stop or timeout terminates the hidden check process immediately.
    package var runPreflight: ((URL, TimeInterval) async -> Error?)?
    /// Whether this app's launcher knows DM_PREFLIGHT. Tests stand in for the binary's answer.
    package var preflightSupported: (URL) -> Bool = { MacPreflight.supports($0) }
    /// How long the check may take. Tests shorten it.
    package var preflightTimeout = MacPreflight.timeout
    /// Ends the check's wait now (Stop, or the timeout), while the build's last stage runs it.
    var endPreflight: (@MainActor (Error) -> Void)?
    /// The free bytes on the volume of a folder, nil when unknown. Tests stand in for the system's answer.
    package var spaceAvailable: (String) -> Int64? = { BuildSpace.available(at: $0) }
    /// Stable volume identifier for cross-volume `shellRoot` checks. Tests stand in for deterministic two-volume scenarios.
    package var volumeIdentifier: (String) -> String? = { BuildSpace.volumeID(at: $0) }
    /// Synchronous preflight key validator `(keysPath, packagePaths) -> blockingMessage?` wired by the app target.
    package var preflightKeyProblem: (String, [String]) -> String? = { _, _ in nil }
    /// Whether the build folder is in a cloud folder. Tests stand in for the system's answer.
    package var cloudFolderCheck: (String) -> Bool = { CloudFolder.contains($0) }
    /// Whether the volume of this folder can replace an old Mac app (APFS), nil when unknown. Tests stand in for the system's answer.
    package var appReplaceCheck: (String) -> Bool? = { OutputVolume.supportsAppReplace(at: $0) }
    /// The target changed: the app checks the tools again when a Mac-only setup now needs, or no longer needs, the iOS SDK.
    package var targetChanged: () -> Void
    /// Active builder upstream or S2Arm path changed: re-runs dependency checks for upstream-specific requirements.
    package var upstreamChanged: () -> Void = {}

    // ---- What it works with ----
    package let localizer: Localizer
    package let runner: ProcessRunner
    package let repo: RepoLocation
    package let deps: DependencyInstalling
    package let engine: EngineSyncing
    package let devices: InstallTarget
    package let volumesRoot: String
    let defaults: UserDefaults

    var proc: RunningProcess?
    var staging: String?
    var stagedResignProfiles: AppSignature.StagedProfiles?
    var psoStageID: Int?
    var psoStep = ""
    var psoNativeProgress = false
    var psoPollGeneration = 0
    var psoPollTask: Task<Void, Never>?
    var archiveGeneration = 0

    /// - Parameters:
    ///   - volumesRoot: where external drives are mounted (the failure classifier reads it).
    ///   - targetChanged: see the property of the same name.
    package init(localizer: Localizer, runner: ProcessRunner, log: BuildLog = BuildLog(), repo: RepoLocation, deps: DependencyInstalling,
                 engine: EngineSyncing, devices: InstallTarget, defaults: UserDefaults = .standard, volumesRoot: String = "/Volumes",
                 targetChanged: @escaping () -> Void = {}) {
        self.localizer = localizer
        self.runner = runner
        self.log = log
        self.repo = repo
        self.deps = deps
        self.engine = engine
        self.devices = devices
        self.defaults = defaults
        self.volumesRoot = volumesRoot
        self.targetChanged = targetChanged
        outDir = defaults.string(forKey: Self.outputKey) ?? ""
        let savedTarget = BuildTarget.saved(defaults)
        target = savedTarget
        runningTarget = savedTarget
        bcOnCPU = defaults.bool(forKey: Self.bcOnCPUKey)
        seenShadersOnly = defaults.bool(forKey: Self.seenShadersOnlyKey)
        iosSeenShadersOnly = defaults.bool(forKey: Self.iosSeenShadersKey)
        savedKeys = defaults.string(forKey: Self.savedKeysKey) ?? ""
        let savedMNGPath = defaults.string(forKey: Self.macNativeGamesPathKey) ?? ""
        let savedS2ArmPath = defaults.string(forKey: Self.s2armPathKey) ?? ""
        let savedKWSPath = defaults.string(forKey: Self.kidWithSwordPathKey) ?? ""
        let savedNLKPath = defaults.string(forKey: Self.noLagKartPathKey) ?? ""
        macNativeGamesPath = savedMNGPath
        s2armPath = savedS2ArmPath
        kidWithSwordPath = savedKWSPath
        noLagKartPath = savedNLKPath
        macNativeGamesInstalled = MacNativeGamesBuilder.isUsableTree(savedMNGPath)
        s2armInstalled = S2ArmBuilder.isUsableTree(savedS2ArmPath)
        kidWithSwordInstalled = UpstreamEngineStore.isUsableTree(savedKWSPath, kind: .kidWithSword)
        noLagKartInstalled = UpstreamEngineStore.isUsableTree(savedNLKPath, kind: .noLagKart)
        if let rawUpstream = defaults.string(forKey: Self.buildUpstreamKey),
           let parsedUpstream = EngineUpstreamKind(rawValue: rawUpstream) {
            switch parsedUpstream {
            case .nxnative, .kidWithSword, .noLagKart:
                buildUpstream = parsedUpstream
            case .macNativeGames:
                buildUpstream = MacNativeGamesBuilder.featureEnabled ? .macNativeGames : .nxnative
            case .s2arm:
                buildUpstream = S2ArmBuilder.featureEnabled ? .s2arm : .nxnative
            case .nxkit:
                buildUpstream = NxkitBuilder.featureEnabled && NxkitBuilder.currentAvailability == .available ? .nxkit : .nxnative
            }
        } else {
            buildUpstream = .nxnative
        }
        refreshNxkit()
        if buildUpstream.buildsMacOnly && target != BuildTarget.mac {
            target = BuildTarget.mac   // the saved choice stays for the engine that builds for iOS
            runningTarget = BuildTarget.mac
        }
        refreshUpstreamLocalVersions()
    }

    /// The language and the text this store writes itself: views take strings from the environment.
    package var lang: Lang { get { localizer.lang } set { localizer.lang = newValue } }
    package func t(_ key: String) -> String { localizer.t(key) }

    /// This iPhone build goes straight to a device.
    /// An iPhone or iPad build that makes the shared app as an unsigned IPA (#416): no device, no team.
    package var exportsShell: Bool { target != BuildTarget.mac && (buildUpstream.buildsIOSStandaloneOnly || (queuedExportIPA ?? devices.exportIPA)) }
    /// An export of one game's own IPA with the game data inside (#540): the engine's one-game app, no shared app, nothing to send.
    package var exportsOneGame: Bool { target != BuildTarget.mac && (buildUpstream.buildsIOSStandaloneOnly || (exportsShell && (queuedExportOneGame ?? devices.exportOneGame))) }
    /// An export of a standalone `.framework` for the shared app: no shell IPA build or repack, game data still sent separately.
    package var exportsFramework: Bool { exportsShell && !exportsOneGame && (queuedExportFramework ?? devices.exportFramework) }
    package var installsDirectly: Bool { target != BuildTarget.mac && !devices.installDevice.isEmpty && !devices.signingTeam.isEmpty }

    /// Home shown as ~ (shorter in a one-line row, and it keeps the account name out of screenshots).
    package func shortPath(_ path: String) -> String { RepoLayout.shortPath(path) }

    package var basePath: String { slot("base").paths.first ?? "" }
    package var updatePath: String { slot("update").paths.first ?? "" }
    package var dlcPaths: [String] { slot("dlc").paths }

    package func slot(_ id: String) -> Slot { slots.first { $0.id == id } ?? slots[0] }
    package func updateSlot(_ id: String, _ body: (inout Slot) -> Void) {
        if let i = slots.firstIndex(where: { $0.id == id }) { body(&slots[i]) }
    }

    /// A build may start: the repository is usable, the base game and the keys are there (a game folder needs no keys), the tools
    /// are all present and none runs.
    package var canBuild: Bool { (usesExternalUpstreamRepo || repo.isRepo) && inputsReady && deps.allPresent && !running }

    /// A line for the build card's note, from a store that has no card of its own (the dependency store's failed install).
    package func note(_ text: String) { doneNote = text }

    // MARK: Ending a build

    package func fail(_ why: String) {
        archiveGeneration &+= 1
        fastRefreshExternalImgPath = nil
        stopPSOPoll()
        running = false
        doneNote = why
        say("✗ " + why)
        cleanupStaging()
    }

    package func stop() {
        if running { stoppedByPlayer = true }
        if cacheMoveRuns {
            stopCacheMove()
            return
        }
        if stopPendingInstallOrCopy() { return }
        if let endPreflight {
            endPreflight(MacPreflight.Failure.stopped)
            return
        }
        guard running, !stopping, let proc, proc.isRunning else { return }
        archiveGeneration &+= 1
        stopping = true
        stopPSOPoll()
        if nxkitRun { endNxkitProcess(proc.processIdentifier) } else { ProcessGroups.endGroup(proc.processIdentifier) }   // the script and every tool it started
    }

    package func cleanupStaging() {
        staging = nil   // the folder stays for the next build of this game (#132, InputStaging)
        stagedResignProfiles?.rollback()
        stagedResignProfiles = nil
    }

    /// A stopped build leaves no half-finished stages behind: the progress starts empty again.
    package func resetProgress() {
        archiveGeneration &+= 1
        fastRefreshExternalImgPath = nil
        needsReplaceOldImgReminder = false
        updatedImgPath = ""
        stopPSOPoll()
        stages = []
        log.clear()
    }

    package func markAllDone() {
        stopPSOPoll()
        for i in stages.indices where stages[i].state != .failed {
            stages[i].state = .done
        }
        reconcileScriptStageTotal()
    }

    private static func isPSOStage(_ name: String) -> Bool {
        name == "Pipeline archive" || name == "game framework"
    }

    // MARK: Output parsing

    package func say(_ s: String) { append(s + "\n") }
    package func append(_ s: String) { log.append(s) }

    /// Split into lines (the pipe delivers arbitrary chunks) and turn the script's progress into the stage list.
    /// `--progress json` writes one event per line (stage, step, progress with done / total / frac / eta, stage_end,
    /// say), a count change at most every half second, and anything else on the pipe (a tool's traceback) is log text.
    /// The older `--progress lines` form is still understood:
    ///   [12:00:01] [2/7] extract v720896 …
    ///   [12:00:20] ✓ [2/7] extract v720896 (0:19): 30,000 files, 3.4 GB
    package func ingest(_ chunk: String) {
        for line in log.feed(chunk) { handle(line) }
    }

    package func flushLines() {
        if let rest = log.flush() { handle(rest) }
    }

    package func handle(_ line: String) {
        if line.hasPrefix("{"), let data = line.data(using: .utf8),
           let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let kind = event["ev"] as? String {
            return handleEvent(kind, event)
        }
        append(line + "\n")
        guard let s = BuildProgress.parseStageWithTotal(line) else {
            if mngRun || s2armRun { handleExternalUpstreamLogLine(line) }
            return
        }
        if s.state == .running {
            if Self.isPSOStage(s.name) {
                if s.percent != nil {
                    psoPollGeneration &+= 1
                    psoNativeProgress = true
                    psoPollTask?.cancel()
                    psoPollTask = nil
                } else if psoStageID != s.k {
                    startPSOPoll(stageID: s.k, step: "")
                }
            } else if psoStageID == s.k {
                stopPSOPoll()
            }
        } else if psoStageID == s.k {
            stopPSOPoll()
        }
        if let i = stages.firstIndex(where: { $0.id == s.k }) {
            if !s.name.isEmpty { stages[i].name = s.name }
            if s.state != .pending { stages[i].state = s.state }
            let keepPSOPoll = (s.state == .running && s.percent == nil && psoStageID == s.k && !psoNativeProgress && stages[i].percent != nil)
            if !keepPSOPoll {
                if !s.detail.isEmpty { stages[i].detail = s.detail }
                stages[i].percent = s.percent
            }
        } else if s.state != .pending {
            stages.append(Stage(id: s.k, name: s.name, state: s.state, detail: s.detail, percent: s.percent, started: Date()))
            stages.sort { $0.id < $1.id }
        }
        refreshOverallProgress(parsedTotal: s.n)
    }

    /// The `shaders_stale` event: the cached shader libraries cannot be reused and this build rebuilds them, because the
    /// shader translator changed (`reason` "chain") or the game profile's shader inputs did ("inputs").
    /// The progress card keeps the explanation visible without waiting for an acknowledgment (#862).
    /// Once per build: the script sends the event once per shader step. A reason a newer script adds shows nothing: no text explains it.
    package func noteStaleShaders(reason: String) {
        activeRunRebuiltShaders = true
        guard let text = ["chain": "msg.shadersStale.chain", "inputs": "msg.shadersStale.inputs"][reason], staleShadersMessageKey == nil else { return }
        staleShadersMessageKey = text
    }

    /// One event of `--progress json`: the stage list follows it, and the log gets a readable line (no count updates).
    package func handleEvent(_ kind: String, _ e: [String: Any]) {
        let k = (e["k"] as? NSNumber)?.intValue ?? 0
        func stage(_ update: (inout Stage) -> Void) {
            if let i = stages.firstIndex(where: { $0.id == k }) {
                update(&stages[i])
            } else {
                var s = Stage(id: k, name: e["name"] as? String ?? "")
                update(&s)
                stages.append(s)
                stages.sort { $0.id < $1.id }
            }
        }
        switch kind {
        case "stage":
            let name = e["name"] as? String ?? "", step = e["step"] as? String ?? ""
            let n = (e["n"] as? NSNumber)?.intValue ?? 0
            append("[\(k)/\(n)] \(name)" + (step.isEmpty ? "" : " · \(step)") + " …\n")
            stage {
                $0.name = name
                $0.state = .running
                $0.started = Date()
                $0.detail = step
                $0.percent = nil
                $0.eta = nil
                $0.isScanningLastShaderFiles = false
            }
            if Self.isPSOStage(name) { startPSOPoll(stageID: k, step: step) }
            else if psoStageID == k { stopPSOPoll() }
            refreshOverallProgress(parsedTotal: n)
        case "step":
            let step = e["step"] as? String ?? ""
            append("    · \(step)\n")
            stage {
                $0.detail = step
                $0.percent = nil
                $0.eta = nil
                $0.isScanningLastShaderFiles = false
            }
            if step.hasPrefix("pipeline archive") { startPSOPoll(stageID: k, step: step) }
            else if psoStageID == k { stopPSOPoll() }
            refreshOverallProgress(parsedTotal: nil)
        case "progress":
            let fraction = (e["frac"] as? NSNumber)?.doubleValue
            let done = (e["done"] as? NSNumber)?.intValue
            if psoStageID == k, fraction != nil || done != nil {
                psoPollGeneration &+= 1
                psoNativeProgress = true
                psoPollTask?.cancel()
                psoPollTask = nil
            }
            let detail = BuildProgress.progressDetail(e)
            let eta = (e["eta"] as? NSNumber)?.doubleValue
            stage {
                $0.percent = fraction.map { $0 * 100 }
                $0.detail = detail
                $0.eta = eta
                $0.etaAt = eta == nil ? nil : Date()
                $0.isScanningLastShaderFiles = BuildProgress.isScanningLastShaderFiles(e)
            }
            refreshOverallProgress(parsedTotal: nil)
        case "stage_end":
            if psoStageID == k { stopPSOPoll() }
            let ok = e["ok"] as? Bool ?? true, summary = e["summary"] as? String ?? ""
            let elapsed = BuildProgress.duration((e["elapsed"] as? NSNumber)?.doubleValue ?? 0)
            append("\(ok ? "✓" : "✗") \(e["name"] as? String ?? "") (\(elapsed))" + (summary.isEmpty ? "" : ": \(summary)") + "\n")
            stage {
                $0.state = ok ? .done : .failed
                $0.detail = summary
                $0.percent = ok ? 100 : $0.percent
                $0.eta = nil
                $0.isScanningLastShaderFiles = false
            }
            refreshOverallProgress(parsedTotal: nil)
        case "say":
            let msg = e["msg"] as? String ?? ""
            append(msg + "\n")
        case "shaders_stale":
            noteStaleShaders(reason: e["reason"] as? String ?? "")
        default: break
        }
    }
}
