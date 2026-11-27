import Foundation
import Observation
import ShellControllers
import ShellUI
#if canImport(UIKit)
import UIKit
#endif
#if os(iOS)
import GameController
#endif

/// Where the host finds things. Everything the model touches outside itself is here, so tests point it at a temporary folder.
public struct ShellHostConfig: Sendable {
    /// `Games/`: one `<title ID>/` bundle folder per game, or `Bundle.main.privateFrameworksURL`.
    public var gamesRoot: URL
    /// Optional writable `Documents/Frameworks/` directory where hot-pushed `DmGame<ID>.framework` bundles live.
    public var hotFrameworksRoot: URL?
    /// The app's `Documents/games/`: `<title ID>/` holds a game's data, save, temp and log.txt (patch 0003's layout).
    public var appDataRoot: URL
    /// Writable `Documents/Banners/` directory storing per-game `custom.jpg` and backfilled `auto.jpg` covers.
    public var bannersRoot: URL
    public var environment: HostEnvironment
    /// Opened by "Update app". Nil: the shell says no address is configured.
    public var updateURL: URL?
    public var defaults: @Sendable (String) -> UserDefaults
    public var openURL: @MainActor @Sendable (URL) -> Void
    public var copyToPasteboard: @MainActor @Sendable (String) -> Void
    public var saveImageToPhotos: @MainActor @Sendable (Data) async -> Bool
    /// Fetches official 16:9 banner bytes for games missing bundled banners. Injectable for offline tests.
    public var fetchBannerData: @Sendable (URL) async -> Data?
    /// Status-aware fetcher used by the default network path so 5xx/timeouts never poison the negative cache.
    public var fetchBannerOutcome: (@Sendable (URL) async -> GameBannerStore.DirectImageOutcome)?
    /// Fetches Nintendo store pages/images for `ec.nintendo.com` fallback. Nil uses the built-in bounded transport.
    public var fetchStoreResponse: GameBannerStore.StoreHTTPFetcher?
    /// Fetches online cheats JSON for `IOSCheatFetcher`. Nil uses `URLSession.shared`.
    public var fetchCheatsTransport: IOSCheatFetcher.Transport?
    public var prepareFloatingGuide: (@MainActor @Sendable (HomeScreenGuideRequest) -> Void)?
    public var cancelPreparedFloatingGuide: (@MainActor @Sendable () -> Void)?
    public var startFloatingGuide: (@MainActor @Sendable (HomeScreenGuideRequest) async -> Bool)?
    public var stopFloatingGuide: (@MainActor @Sendable () -> Void)?
    public var activeRunningGameID: @MainActor @Sendable () -> String?
    public var requestStopRunningGame: @MainActor @Sendable () -> Void
    /// The clock, for the last-played date and its wording.
    public var now: @Sendable () -> Date
    /// Expiration date of `embedded.mobileprovision`, or nil when absent or unreadable.
    public var provisioningExpiration: @Sendable () -> Date?
    /// Secure storage backing for the imported sideload `.p12` certificate (Keychain in production; in-memory in tests).
    public var sideloadCertBacking: any SideloadCertBacking
    /// Host app bundle identifier stamped into locally re-signed external framework CodeDirectories.
    public var hostBundleID: @Sendable () -> String
    /// Whether the running app's signing profile allows mapping external frameworks from `Documents/Frameworks/`.
    public var supportsHotFrameworkLoading: @Sendable () -> Bool
    /// Split-part byte size used by startup `DataParts.joinAll` (defaults to 512 MiB).
    public var joinPartSize: Int64
    var onJoinProgress: (@Sendable (DataParts.Progress) -> Void)?
    var directoryWatchDebounceInterval: TimeInterval = 0.6
    var directoryWatchPartStableWindow: TimeInterval = 1.0

    public init(gamesRoot: URL, appDataRoot: URL, hotFrameworksRoot: URL? = nil,
                bannersRoot: URL? = nil,
                environment: HostEnvironment = HostEnvironment(), updateURL: URL? = nil,
                defaults: @escaping @Sendable (String) -> UserDefaults = GameDefaults.suite(for:),
                openURL: @escaping @MainActor @Sendable (URL) -> Void = ShellHostConfig.systemOpen,
                copyToPasteboard: @escaping @MainActor @Sendable (String) -> Void = ShellHostConfig.systemCopyToPasteboard,
                saveImageToPhotos: @escaping @MainActor @Sendable (Data) async -> Bool = ShellHostConfig.systemSaveImageToPhotos,
                fetchBannerData: (@Sendable (URL) async -> Data?)? = nil,
                fetchBannerOutcome: (@Sendable (URL) async -> GameBannerStore.DirectImageOutcome)? = nil,
                fetchStoreResponse: GameBannerStore.StoreHTTPFetcher? = nil,
                fetchCheatsTransport: IOSCheatFetcher.Transport? = nil,
                prepareFloatingGuide: (@MainActor @Sendable (HomeScreenGuideRequest) -> Void)? = nil,
                cancelPreparedFloatingGuide: (@MainActor @Sendable () -> Void)? = nil,
                startFloatingGuide: (@MainActor @Sendable (HomeScreenGuideRequest) async -> Bool)? = nil,
                stopFloatingGuide: (@MainActor @Sendable () -> Void)? = nil,
                activeRunningGameID: @escaping @MainActor @Sendable () -> String? = { nil },
                requestStopRunningGame: @escaping @MainActor @Sendable () -> Void = {},
                now: @escaping @Sendable () -> Date = { Date() },
                provisioningExpiration: @escaping @Sendable () -> Date? = { ProvisioningProfile.bundledExpiration() },
                sideloadCertBacking: any SideloadCertBacking = KeychainCertBacking(),
                hostBundleID: @escaping @Sendable () -> String = { Bundle.main.bundleIdentifier ?? "" },
                supportsHotFrameworkLoading: @escaping @Sendable () -> Bool = { true },
                joinPartSize: Int64 = DataParts.partSize) {
        self.gamesRoot = gamesRoot
        self.hotFrameworksRoot = hotFrameworksRoot
        self.appDataRoot = appDataRoot
        self.bannersRoot = bannersRoot ?? appDataRoot.deletingLastPathComponent().appendingPathComponent("Banners", isDirectory: true)
        self.environment = environment
        self.updateURL = updateURL
        self.defaults = defaults
        self.openURL = openURL
        self.copyToPasteboard = copyToPasteboard
        self.saveImageToPhotos = saveImageToPhotos
        self.fetchBannerData = fetchBannerData ?? GameBannerStore.fetchRemoteBanner
        if let fetchBannerOutcome {
            self.fetchBannerOutcome = fetchBannerOutcome
        } else if fetchBannerData == nil {
            self.fetchBannerOutcome = { url in await GameBannerStore.fetchRemoteBannerOutcome(from: url) }
        } else {
            self.fetchBannerOutcome = nil
        }
        self.fetchStoreResponse = fetchStoreResponse
        self.fetchCheatsTransport = fetchCheatsTransport
        self.prepareFloatingGuide = prepareFloatingGuide
        self.cancelPreparedFloatingGuide = cancelPreparedFloatingGuide
        self.startFloatingGuide = startFloatingGuide
        self.stopFloatingGuide = stopFloatingGuide
        self.activeRunningGameID = activeRunningGameID
        self.requestStopRunningGame = requestStopRunningGame
        self.now = now
        self.provisioningExpiration = provisioningExpiration
        self.sideloadCertBacking = sideloadCertBacking
        self.hostBundleID = hostBundleID
        self.supportsHotFrameworkLoading = supportsHotFrameworkLoading
        self.joinPartSize = joinPartSize
        self.onJoinProgress = nil
    }

    @MainActor public static func systemOpen(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }

    @MainActor public static func systemCopyToPasteboard(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }

    @MainActor public static func systemSaveImageToPhotos(_ pngData: Data) async -> Bool {
        #if os(iOS)
        return await PhotoLibraryImageSaver.saveToSystemPhotoLibrary(pngData)
        #else
        return false
        #endif
    }

    /// The app's `Documents/games/`.
    public static func defaultAppDataRoot() -> URL {
        (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("games", isDirectory: true)
    }

    /// The app's writable `Documents/Frameworks/` directory for hot-pushed game frameworks.
    public static func defaultHotFrameworksRoot() -> URL {
        (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Frameworks", isDirectory: true)
    }

    /// The app's writable `Documents/Banners/` directory for custom and backfilled covers.
    public static func defaultBannersRoot() -> URL {
        (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Banners", isDirectory: true)
    }
}

/// The host behind the views: turns the catalogue, the saved settings, the picked folders and the controllers into
/// `GameDetail` values, and acts on `ShellActions`. `ShellUI` stays view-only, every file is read here.
@MainActor @Observable public final class ShellHostModel {
    public static let didReturnToLibraryNotification = Notification.Name("DMShellDidReturnToLibrary")
    public private(set) var details: [GameDetail] = []
    public private(set) var entries: [CatalogueEntry] = []
    public internal(set) var activityLog: ActivityLogSnapshot = .empty
    public private(set) var controllers: [ControllerInfo] = []
    public private(set) var input = ShellInputLog()
    /// A short message the host view shows as an alert.
    public var notice: String?
    /// The log the host view shows in a read-only sheet.
    public var log: LogPresentation?
    /// Play is preparing the game's resources or handing over to the engine.
    public private(set) var launchingGame = false {
        didSet { handleBusyStateChanged() }
    }
    /// Pure-black transition overlay active while resolving/switching/launching a deep link.
    public private(set) var isDeepLinkLaunching = false {
        didSet { handleBusyStateChanged() }
    }
    /// Cloud save conflict or unreadable-archive prompt awaiting the player's decision before launch.
    public var cloudConflict: CloudSavePrompt?
    /// Mild heads-up when the app's provisioning profile expires within 48 hours.
    public private(set) var signingWarning: SigningWarning?
    /// Summary of the imported sideload `.p12` certificate stored in Keychain, if any.
    public private(set) var sideloadCertificate: SideloadCertificateSummary?

    public private(set) var globalPadMap = PadMap()
    public private(set) var padMerge = false
    /// The last controller state, sent only while the button test is open.
    public private(set) var padSnapshot: PadSnapshot?

    private struct PendingCloudLaunch {
        var generation: UInt64
        var game: LaunchableGame
        var report: CloudSaveSyncCheck.Report
    }

    @ObservationIgnored let config: ShellHostConfig
    @ObservationIgnored private let launcher: any GameLauncher
    @ObservationIgnored private let picker: any FolderPicker
    @ObservationIgnored private let certificatePicker: any SideloadCertificatePicker
    @ObservationIgnored let cheatPicker: any CheatFilePicker
    @ObservationIgnored let savePresenter: any SaveTransferPresenter
    @ObservationIgnored private let sideloadCertificateStore: SideloadCertificateStore
    @ObservationIgnored private var pendingPKCS12Data: Data?
    @ObservationIgnored var pendingCheatImport: (gameID: String, token: String, targetBuildID: String, data: Data)?
    @ObservationIgnored var cheatsOpGeneration: [String: UInt64] = [:]
    @ObservationIgnored var cheatsSummaries: [String: GameCheatsSummary] = [:]
    @ObservationIgnored var cheatsScanTask: Task<Void, Never>?
    @ObservationIgnored var cheatsScanGeneration: UInt64 = 0
    @ObservationIgnored var pendingSaveImports: [String: PendingSaveImport] = [:]
    @ObservationIgnored var saveOpGeneration: [String: UInt64] = [:]
    @ObservationIgnored var localSaveSummaries: [String: SaveArchiveService.LocalSummary] = [:]
    @ObservationIgnored private var certificateGeneration: UInt64 = 0
    @ObservationIgnored private var certificateLoadTask: Task<Void, Never>?
    @ObservationIgnored private let adapter = GamepadAdapter()
    @ObservationIgnored private let homeScreenGuidePiP = HomeScreenGuidePiPController()
    @ObservationIgnored private var dataStores: [String: BookmarkStore] = [:]
    @ObservationIgnored private var cloudStores: [String: BookmarkStore] = [:]
    @ObservationIgnored private var artwork: [URL: Artwork] = [:]
    @ObservationIgnored private var resolvedProfiles: [String: LauncherProfile] = [:]
    /// The shell-level settings every game falls back to (game > shell > built-in).
    @ObservationIgnored public let shellSettings: ShellSettingsStore
    /// Persistent per-title play history stored outside per-game data directories (#1161).
    @ObservationIgnored public let playHistory: PlayHistoryStore
    @ObservationIgnored private let shellData: BookmarkStore
    @ObservationIgnored private let shellCloud: BookmarkStore
    @ObservationIgnored private var shellChoices: [String]
    /// The shell data folder the games were matched in by identity, each game's matched folder by title ID, and the scan in flight.
    @ObservationIgnored private var scannedShellFolder: String?
    @ObservationIgnored private var shellMatches: [String: URL] = [:]
    @ObservationIgnored private var shellScan: Task<Void, Never>?
    @ObservationIgnored private var romfsChecks: [URL: RomfsCheck] = [:]
    @ObservationIgnored private var joinAndClaimTask: Task<Void, Never>?
    @ObservationIgnored private var pendingJoinAndClaim = false
    @ObservationIgnored private var pendingReloadAfterClaim = false
    @ObservationIgnored private var pendingExcludedPartPaths: Set<String> = []
    @ObservationIgnored private var joinGeneration: UInt64 = 0
    @ObservationIgnored private var joiningProgress: [String: DataParts.Progress] = [:]
    @ObservationIgnored nonisolated(unsafe) private var directoryWatcher: GameDirectoryWatcher?
    @ObservationIgnored private var pickGeneration: [String: UInt64] = [:]
    @ObservationIgnored private var shellDataPickGeneration: UInt64 = 0
    @ObservationIgnored private var pickedDataNotes: [String: String] = [:]
    @ObservationIgnored private var cloudCheckGeneration: UInt64 = 0
    @ObservationIgnored private var pendingCloudLaunch: PendingCloudLaunch?
    @ObservationIgnored private var backupScanGeneration: UInt64 = 0
    @ObservationIgnored var backupScanTask: Task<Void, Never>?
    @ObservationIgnored private var latestBackups: [String: String] = [:]
    @ObservationIgnored private var bannerFetchGeneration: UInt64 = 0
    @ObservationIgnored private var bannerFetchTask: Task<Void, Never>?
    @ObservationIgnored private var attemptedBannerFetches: Set<String> = []
    @ObservationIgnored private var signingCheckTask: Task<Void, Never>?
    @ObservationIgnored private var signingWarningDismissed = false
    @ObservationIgnored private var deepLinkGeneration: UInt64 = 0
    @ObservationIgnored private var pendingDeepLinkSuccessURL: URL?
    @ObservationIgnored private var pendingDeepLinkErrorURL: URL?
    @ObservationIgnored private var queuedDeepLinkRequest: DeepLinkRequest?
    @ObservationIgnored private var stoppingRunningGame = false
    @ObservationIgnored private var activeDeepLinkTask: Task<Void, Never>?
    @ObservationIgnored private var deepLinkCloudPending = false
    @ObservationIgnored nonisolated(unsafe) private var defaultsObserver: (any NSObjectProtocol)?
    @ObservationIgnored nonisolated(unsafe) private var foregroundObserver: (any NSObjectProtocol)?
    @ObservationIgnored nonisolated(unsafe) private var returnObserver: (any NSObjectProtocol)?

    public init(config: ShellHostConfig, launcher: any GameLauncher = StubGameLauncher(), picker: any FolderPicker = NoFolderPicker(),
                certificatePicker: any SideloadCertificatePicker = NoSideloadCertificatePicker(),
                cheatPicker: any CheatFilePicker = NoCheatFilePicker(),
                savePresenter: any SaveTransferPresenter = NoSaveTransferPresenter(),
                shellSettings: ShellSettingsStore = .current, playHistory: PlayHistoryStore? = nil) {
        self.config = config
        self.launcher = launcher
        self.picker = picker
        self.certificatePicker = certificatePicker
        self.cheatPicker = cheatPicker
        self.savePresenter = savePresenter
        self.sideloadCertificateStore = SideloadCertificateStore(backing: config.sideloadCertBacking, now: config.now)
        self.shellSettings = shellSettings
        self.playHistory = playHistory ?? PlayHistoryStore(fileURL: PlayHistoryStore.defaultFileURL(appDataRoot: config.appDataRoot))
        self.playHistory.recoverStaleSessionIfNeeded()
        shellData = BookmarkStore(defaults: shellSettings.defaults, key: ShellSettingsStore.dataFolderKey)
        shellCloud = BookmarkStore(defaults: shellSettings.defaults, key: ShellSettingsStore.cloudSavesKey)
        shellChoices = Self.choices(of: shellSettings)
        globalPadMap = shellSettings.padMap
        padMerge = shellSettings.padMerge
        reload(afterClaim: true)
        // Off the main actor, it lists folders and may write GB: a file the Mac launcher sent in parts is joined first (#899), then
        // the game files are kept out of the iCloud backup (#618), also what an earlier version put there. A joined file can make a
        // game playable, so the library is read again.
        scheduleJoinAndClaim(isStartup: true)
        let watcher = GameDirectoryWatcher(
            appDataRoot: config.appDataRoot,
            hotFrameworksRoot: config.hotFrameworksRoot,
            debounceInterval: config.directoryWatchDebounceInterval,
            partStableWindow: config.directoryWatchPartStableWindow
        ) { [weak self] hint in
            Task { @MainActor [weak self] in
                self?.handleDirectoryChange(hint)
            }
        }
        directoryWatcher = watcher
        watcher.setPaused(isBusyWithGame)
        watcher.start()
        let expirationReader = config.provisioningExpiration
        let clock = config.now
        signingCheckTask = Task { [weak self] in
            let expiration = await Task.detached(priority: .utility) { expirationReader() }.value
            guard let self, !self.signingWarningDismissed else { return }
            self.signingWarning = ProvisioningProfile.warning(expiration: expiration, now: clock())
        }
        let certStore = sideloadCertificateStore
        let certGen = certificateGeneration
        certificateLoadTask = Task { [weak self] in
            let summary = await Task.detached(priority: .utility) { certStore.loadSummary() }.value
            guard let self, self.certificateGeneration == certGen else { return }
            self.sideloadCertificate = summary
        }
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.defaultsDidChange() }
        }
        #if canImport(UIKit)
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stopHomeScreenFloatingGuide()
                guard !self.isBusyWithGame else { return }
                self.reload()
            }
        }
        #endif
        returnObserver = NotificationCenter.default.addObserver(forName: Self.didReturnToLibraryNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleReturnToLibrary() }
        }
    }

    deinit {
        directoryWatcher?.stop()
        defaultsObserver.map(NotificationCenter.default.removeObserver)
        foregroundObserver.map(NotificationCenter.default.removeObserver)
        returnObserver.map(NotificationCenter.default.removeObserver)
    }

    /// Shell choices that change the displayed game defaults.
    private static func choices(of settings: ShellSettingsStore) -> [String] {
        [settings.gameDefaults.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","), settings.padMap.envValue ?? ""]
    }

    /// Rebuilds the details in place after a shell folder, overlay or controller mapping changes.
    public func refreshAll() {
        globalPadMap = shellSettings.padMap
        padMerge = shellSettings.padMerge
        shellChoices = Self.choices(of: shellSettings)
        startShellScan()
        details = entries.map(detail(for:))
        rebuildActivityLog()
    }

    public func setPadMerge(_ on: Bool) {
        shellSettings.storePadMerge(on)
        refreshAll()
    }

    public func dismissSigningWarning() {
        signingWarningDismissed = true
        signingWarning = nil
    }

    var isBusyWithGame: Bool {
        if launchingGame || isDeepLinkLaunching { return true }
        if let runningID = config.activeRunningGameID(), !runningID.isEmpty { return true }
        return false
    }

    private func handleBusyStateChanged() {
        let busy = isBusyWithGame
        directoryWatcher?.setPaused(busy)
        drainDeferredWorkIfIdle()
    }

    private func drainDeferredWorkIfIdle() {
        guard !isBusyWithGame else { return }
        if pendingReloadAfterClaim {
            pendingReloadAfterClaim = false
            reload(afterClaim: true)
        }
        if pendingJoinAndClaim {
            let excluded = pendingExcludedPartPaths
            pendingExcludedPartPaths.removeAll()
            scheduleJoinAndClaim(excludedPartPaths: excluded)
        }
    }

    private func handleDirectoryChange(_ hint: GameDirectoryWatcher.ChangeHint) {
        if isBusyWithGame {
            pendingJoinAndClaim = true
            pendingExcludedPartPaths = hint.unstablePartPaths
            return
        }
        scheduleJoinAndClaim(excludedPartPaths: hint.unstablePartPaths)
    }

    func waitForStartupTasks() async {
        await directoryWatcher?.waitUntilReady()
        while let task = joinAndClaimTask {
            await task.value
        }
        await signingCheckTask?.value
        await certificateLoadTask?.value
        await backupScanTask?.value
        await cheatsScanTask?.value
        await bannerFetchTask?.value
        for task in romfsChecks.values.compactMap(\.task) {
            await task.value
        }
    }

    private func applyJoinProgress(_ progress: DataParts.Progress, generation: UInt64) {
        guard joinGeneration == generation, !isBusyWithGame, entries.contains(where: { $0.id == progress.titleID }) else { return }
        joiningProgress[progress.titleID] = progress
        refresh(progress.titleID)
    }

    private struct JoinPassInputs: Sendable {
        var generation: UInt64
        var isStartup: Bool
        var dataRoot: URL
        var gamesRoot: URL
        var hotRoot: URL?
        var bannersRoot: URL
        var partSize: Int64
        var excludedPartPaths: Set<String>
        var progressHook: (@Sendable (DataParts.Progress) -> Void)?
    }

    private func makeJoinPassInputs(isStartup: Bool, excludedPartPaths: Set<String>) -> JoinPassInputs {
        joinGeneration &+= 1
        return JoinPassInputs(
            generation: joinGeneration,
            isStartup: isStartup,
            dataRoot: config.appDataRoot,
            gamesRoot: config.gamesRoot,
            hotRoot: config.hotFrameworksRoot,
            bannersRoot: config.bannersRoot,
            partSize: config.joinPartSize,
            excludedPartPaths: excludedPartPaths,
            progressHook: config.onJoinProgress
        )
    }

    private func scheduleJoinAndClaim(isStartup: Bool = false, excludedPartPaths: Set<String> = []) {
        if !isStartup && isBusyWithGame {
            pendingJoinAndClaim = true
            pendingExcludedPartPaths = excludedPartPaths
            return
        }
        if joinAndClaimTask != nil {
            pendingJoinAndClaim = true
            pendingExcludedPartPaths = excludedPartPaths
            return
        }
        pendingJoinAndClaim = false
        pendingExcludedPartPaths.removeAll()
        let initialInputs = makeJoinPassInputs(isStartup: isStartup, excludedPartPaths: excludedPartPaths)
        joinAndClaimTask = Task { [weak self] in
            var currentInputs: JoinPassInputs? = initialInputs
            while let inputs = currentInputs {
                let runGeneration = inputs.generation
                let progressHook = inputs.progressHook
                let reportProgress: @Sendable (DataParts.Progress) -> Void = { [weak self] progress in
                    Task { @MainActor in
                        self?.applyJoinProgress(progress, generation: runGeneration)
                    }
                    progressHook?(progress)
                }

                let didChange = await Task.detached(priority: .utility) { () -> Bool in
                    let documents = inputs.dataRoot.deletingLastPathComponent()
                    DataParts.writeFeatures(documents: documents)
                    let hadReadyHot = inputs.hotRoot.map { GameCatalogue.hasReadyStagedFramework(in: $0) } ?? false
                    let allEntries = GameCatalogue.scan(root: inputs.gamesRoot, hotRoot: inputs.hotRoot, gameDataRoot: inputs.dataRoot)
                    var minRomfsSizes: [String: Int64] = [:]
                    for entry in allEntries {
                        if let manifest = entry.manifest, let expected = DataLocator.expectedImageSize(manifest), expected > 0 {
                            minRomfsSizes[entry.id.uppercased()] = expected
                        }
                    }
                    let joined = DataParts.joinAll(
                        appDataRoot: inputs.dataRoot,
                        partSize: inputs.partSize,
                        minimumRomfsSizes: minRomfsSizes,
                        excludedPartPaths: inputs.excludedPartPaths,
                        onProgress: reportProgress
                    )
                    let claimed = LooseRomfsClaimer.claimAll(documents: documents, appDataRoot: inputs.dataRoot, entries: allEntries)
                    if inputs.isStartup || !joined.isEmpty || !claimed.isEmpty {
                        BackupExclusion.apply(appDataRoot: inputs.dataRoot)
                        if FileManager.default.fileExists(atPath: inputs.bannersRoot.path) {
                            BackupExclusion.exclude(inputs.bannersRoot)
                        }
                    }
                    return !joined.isEmpty || !claimed.isEmpty || hadReadyHot
                }.value

                guard let self else { return }
                self.finishJoinPass(changed: didChange, generation: runGeneration)

                guard self.pendingJoinAndClaim else { break }
                if self.isBusyWithGame {
                    break
                }
                self.pendingJoinAndClaim = false
                let nextExcluded = self.pendingExcludedPartPaths
                self.pendingExcludedPartPaths.removeAll()
                currentInputs = self.makeJoinPassInputs(isStartup: false, excludedPartPaths: nextExcluded)
            }
            self?.joinAndClaimTask = nil
        }
    }

    private func finishJoinPass(changed: Bool, generation: UInt64) {
        let invalidated = (joinGeneration != generation)
        // Advance the generation so any queued progress update from this finished pass is ignored.
        joinGeneration &+= 1
        let affected = Array(joiningProgress.keys)
        joiningProgress.removeAll()
        if changed {
            if isBusyWithGame {
                pendingReloadAfterClaim = true
            } else {
                pendingReloadAfterClaim = false
                reload(afterClaim: true)
            }
        } else if !invalidated || !affected.isEmpty {
            for id in affected { refresh(id) }
        }
    }

    func startBackupScan() {
        backupScanTask?.cancel()
        backupScanGeneration &+= 1
        let generation = backupScanGeneration
        let targets = entries.map { ($0.id, appFolder(for: $0.id)) }
        guard !targets.isEmpty else {
            latestBackups.removeAll()
            localSaveSummaries.removeAll()
            return
        }
        backupScanTask = Task { [weak self] in
            let scanned = await Task.detached(priority: .utility) { () -> (backups: [String: String], saves: [String: SaveArchiveService.LocalSummary]) in
                var foundBackups: [String: String] = [:]
                var foundSaves: [String: SaveArchiveService.LocalSummary] = [:]
                for (id, folder) in targets where !Task.isCancelled {
                    if let backup = CloudSaveSyncCheck.latestBackup(in: folder) {
                        foundBackups[id] = backup.label
                    }
                    foundSaves[id] = SaveArchiveService.localSummary(in: folder)
                }
                return (foundBackups, foundSaves)
            }.value
            guard let self, !Task.isCancelled, self.backupScanGeneration == generation else { return }
            let previousBackups = self.latestBackups
            let previousSaves = self.localSaveSummaries
            self.latestBackups = scanned.backups
            self.localSaveSummaries = scanned.saves
            let changedBackups = Set(previousBackups.keys).union(scanned.backups.keys).filter { previousBackups[$0] != scanned.backups[$0] }
            let changedSaves = Set(previousSaves.keys).union(scanned.saves.keys).filter { previousSaves[$0] != scanned.saves[$0] }
            for id in changedBackups.union(changedSaves) { self.refresh(id) }
        }
    }

    /// Looks for every game's image by identity in the shell data folder. The drive is read off the main actor: until the scan is
    /// done the games show what the by-name paths give (usually "Needs game data"), then the details are built again. A new
    /// folder starts a new scan and drops the old matches, the same folder keeps its matches unless `force`.
    private func startShellScan(force: Bool = false) {
        guard case .url(let folder) = shellData.resolve() else {
            shellScan?.cancel(); shellScan = nil; scannedShellFolder = nil; shellMatches = [:]; return
        }
        if !force && scannedShellFolder == folder.path { return }
        shellScan?.cancel()
        shellScan = nil
        scannedShellFolder = folder.path
        shellMatches = [:]
        let wanted: [(titleID: String, identity: RomfsIdentity, chain: String, gfxAPI: String?)] = entries.compactMap { e in
            guard e.problem == nil, let m = e.manifest, let ident = RomfsIdentity.parse(m.romfsIdentity) else { return nil }
            return (m.titleID, ident, m.chain, m.gfxAPI)
        }
        guard !wanted.isEmpty else { return }
        // `shellData.resolve()` above opened the bookmark's security scope and `BookmarkStore` keeps it open while this folder is
        // chosen (until another is stored or it is cleared), so the detached scan and its header reads run inside it.
        shellScan = Task { [weak self] in
            let found = await Task.detached(priority: .utility) { () -> [String: URL] in
                let index = ShellDataIndex(folder: folder)
                var matches: [String: URL] = [:]
                for item in wanted where !Task.isCancelled {
                    if let url = index.imageURL(matching: item.identity, preferredChain: item.chain, explicitGfxAPI: item.gfxAPI) {
                        matches[item.titleID] = url
                    }
                }
                return matches
            }.value
            guard let self, !Task.isCancelled, self.scannedShellFolder == folder.path else { return }
            self.shellScan = nil
            self.shellMatches = found
            if !found.isEmpty {
                self.details = self.entries.map(self.detail(for:))
                self.rebuildActivityLog()
            }
        }
    }

    /// For tests: returns when the shell scan and the pending RomFS identity checks are done.
    func waitForDataChecks() async {
        await directoryWatcher?.waitUntilReady()
        while let task = joinAndClaimTask {
            await task.value
        }
        await shellScan?.value
        await signingCheckTask?.value
        await certificateLoadTask?.value
        await backupScanTask?.value
        await cheatsScanTask?.value
        await bannerFetchTask?.value
        for entry in entries { _ = await verifiedData(for: entry) }
    }

    private func defaultsDidChange() {
        if Self.choices(of: shellSettings) != shellChoices { refreshAll() }
    }

    private func gameEnvURL(for id: String) -> URL {
        appFolder(for: id).appendingPathComponent("env.txt")
    }

    private func gameEnvOverrides(for id: String) -> [String: String] {
        GameEnvFileSync.readOverrides(at: gameEnvURL(for: id))
    }

    private func makeSettingsStore(for id: String, profile: LauncherProfile) -> GameSettingsStore {
        GameSettingsStore(
            profile: profile,
            defaults: config.defaults(id),
            shell: shellSettings.gameDefaults,
            envFile: gameEnvOverrides(for: id)
        )
    }

    private func reconcileInGameChangesWithEnvFile(for id: String, profile: LauncherProfile) {
        let envURL = gameEnvURL(for: id)
        let overrides = GameEnvFileSync.readOverrides(at: envURL)
        guard !overrides.isEmpty else { return }
        let store = GameSettingsStore(profile: profile, defaults: config.defaults(id), shell: shellSettings.gameDefaults, envFile: overrides)
        for setting in profile.settings where overrides[setting.env] != nil && store.hasExplicitChoice(setting) {
            let explicit = store.value(of: setting)
            _ = store.set(setting.env, to: explicit)
            GameEnvFileSync.syncKey(setting.env, value: store.savedValue(for: setting.env), in: envURL)
        }
    }

    private func refreshSettingsAfterGameReturn() {
        shellChoices = Self.choices(of: shellSettings)
        for entry in entries {
            if let profile = cachedOrResolvedProfile(for: entry.id) {
                reconcileInGameChangesWithEnvFile(for: entry.id, profile: profile)
                refreshSettings(entry.id, profile: profile)
            } else {
                refresh(entry.id)
            }
        }
    }

    // MARK: Catalogue

    /// Reads the games folder again and sorts the library (see `LibraryOrder`). Only this and the first load re-sort:
    /// a change to one game updates it in place.
    public func reload() {
        reload(afterClaim: false)
    }

    private func reload(afterClaim: Bool) {
        forgetCheckedRomfsImages()
        resolvedProfiles.removeAll()
        if let hotRoot = config.hotFrameworksRoot {
            GameCatalogue.promoteStagedFrameworks(in: hotRoot, gameDataRoot: config.appDataRoot)
        }
        let scanned = GameCatalogue.scan(root: config.gamesRoot, hotRoot: config.hotFrameworksRoot, gameDataRoot: config.appDataRoot).filter { !isDeleted($0) }
        let built = scanned.map(detail(for:))
        let order = LibraryOrder.ids(of: built.map(\.game), lastPlayed: Dictionary(uniqueKeysWithValues: scanned.compactMap { e in
            effectiveLastPlayed(e.id).map { (e.id, $0) } }))
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        entries = scanned.sorted { position[$0.id] ?? 0 < position[$1.id] ?? 0 }
        details = built.sorted { position[$0.id] ?? 0 < position[$1.id] ?? 0 }
        rebuildActivityLog()
        startShellScan(force: true)
        startBackupScan()
        startCheatsSummaryScan()
        startMissingBannerFetch()
        directoryWatcher?.refreshTargets()
        if !afterClaim && !isBusyWithGame {
            scheduleJoinAndClaim()
        }
    }

    private func lastPlayed(_ id: String) -> Date? { LastPlayedStore(defaults: config.defaults(id)).date }

    func refreshHostGame(_ id: String) {
        refresh(id)
    }

    func refresh(_ id: String) {
        if let e = entries.firstIndex(where: { $0.id == id }), let d = details.firstIndex(where: { $0.id == id }) {
            details[d] = detail(for: entries[e])
        }
        rebuildActivityLog()
    }

    func updateCheatsSummary(_ summary: GameCheatsSummary, for id: String) {
        cheatsSummaries[id] = summary
        guard let d = details.firstIndex(where: { $0.id == id }) else { return }
        details[d].cheatsSummary = summary
    }

    private func settingsSnapshot(for id: String, profile: LauncherProfile) -> (sections: [SettingSection], hasModifiedSettings: Bool) {
        let store = makeSettingsStore(for: id, profile: profile)
        let fromShell = Set(profile.settings.filter(store.isFromShell).map(\.env))
        let fromEnvFile = Set(profile.settings.filter(store.isFromEnvFile).map(\.env))
        let pad = GamePadMapStore(defaults: config.defaults(id))
        let sections = SettingsPresenter.sections(profile: profile, values: store.values(), fromShell: fromShell, fromEnvFile: fromEnvFile)
        // A profile-provided DM_PAD_MAP row owns the mapping, so do not offer conflicting shell overrides.
        let padSections = profile.settings.contains { $0.env == "DM_PAD_MAP" } ? [] : [pad.section()]
        return (sections + padSections, store.hasModifiedSettings || !pad.entries.isEmpty)
    }

    /// Updates only settings rows and the modified flag in place so tapping a control never re-runs disk or bookmark I/O.
    private func refreshSettings(_ id: String, profile: LauncherProfile) {
        guard let d = details.firstIndex(where: { $0.id == id }) else {
            refresh(id)
            return
        }
        let snapshot = settingsSnapshot(for: id, profile: profile)
        details[d].sections = snapshot.sections
        details[d].hasModifiedSettings = snapshot.hasModifiedSettings
    }

    private func cachedOrResolvedProfile(for id: String) -> LauncherProfile? {
        if let cached = resolvedProfiles[id] { return cached }
        guard let entry = entry(id), let resolved = profile(for: entry) else { return nil }
        resolvedProfiles[id] = resolved
        return resolved
    }

    private func entry(_ id: String) -> CatalogueEntry? { entries.first { $0.id == id } }

    public func appFolder(for id: String) -> URL { config.appDataRoot.appendingPathComponent(id, isDirectory: true) }

    private func dataStore(_ id: String) -> BookmarkStore {
        if let s = dataStores[id] { return s }
        let s = BookmarkStore(defaults: config.defaults(id), key: BookmarkStore.gameDataKey)
        dataStores[id] = s
        return s
    }

    private func cloudStore(_ id: String) -> BookmarkStore {
        if let s = cloudStores[id] { return s }
        let s = BookmarkStore(defaults: config.defaults(id), key: BookmarkStore.cloudSavesKey)
        cloudStores[id] = s
        return s
    }

    enum CloudSaves { case off, own(URL), stale, shell(URL), none }

    /// Where the game's cloud saves go: off when the player turned them off for the game, then the game's own folder,
    /// then the shell settings' folder.
    func cloudSaves(_ id: String) -> CloudSaves {
        if config.defaults(id).bool(forKey: GameDefaults.cloudSavesOffKey) { return .off }
        switch cloudStore(id).resolve() {
        case .url(let url): return .own(url)
        case .stale: return .stale
        case .none:
            if case .url(let url) = shellCloud.resolve() { return .shell(url) }
            return .none
        }
    }

    private struct RomfsCheck {
        struct Stamp: Equatable {
            let size: NSNumber?
            let modified: Date?
            let volume: NSNumber?
            let file: NSNumber?
        }

        let stamp: Stamp
        var task: Task<Void, Never>?
        var identity: RomfsIdentity?
        var titles: Set<String>
    }

    /// A copy in place can preserve the file stamp. Retry completed checks when the player explicitly refreshes or plays.
    private func forgetCheckedRomfsImages() {
        romfsChecks = romfsChecks.filter { $0.value.task != nil }
    }

    /// Only stat on the main actor. A replacement starts a new check even when its size and modification date stayed the same.
    private func matchesRomfs(_ url: URL, expected: RomfsIdentity, title: String, pending: (Task<Void, Never>) -> Void) -> Bool {
        guard let info = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        let stamp = RomfsCheck.Stamp(size: info[.size] as? NSNumber, modified: info[.modificationDate] as? Date,
                                    volume: info[.systemNumber] as? NSNumber, file: info[.systemFileNumber] as? NSNumber)
        if let check = romfsChecks[url], check.stamp == stamp {
            if let task = check.task {
                romfsChecks[url]?.titles.insert(title)
                pending(task)
            }
            return check.identity == expected
        }
        romfsChecks[url]?.task?.cancel()
        let task = Task { [weak self] in
            let identity = await Task.detached(priority: .utility) { RomfsIdentity.ofImage(at: url) }.value
            guard !Task.isCancelled, let self, let check = self.romfsChecks[url] else { return }
            self.romfsChecks[url] = RomfsCheck(stamp: stamp, identity: identity, titles: [])
            for title in check.titles { self.refresh(title) }
        }
        romfsChecks[url] = RomfsCheck(stamp: stamp, task: task, titles: [title])
        pending(task)
        return false
    }

    private func data(for entry: CatalogueEntry, pending: (Task<Void, Never>) -> Void = { _ in }) -> DataResolution {
        guard let manifest = entry.manifest, entry.problem == nil else { return .missing }
        return DataLocator.locate(manifest: manifest, picked: dataStore(entry.id).resolve(), appFolder: appFolder(for: entry.id),
                                  global: shellData.resolve(), shellMatch: shellMatches[manifest.titleID]) { url, identity in
            matchesRomfs(url, expected: identity, title: entry.id, pending: pending)
        }
    }

    /// A pending higher-priority location must finish before Play can use a lower-priority fallback.
    private func verifiedData(for entry: CatalogueEntry) async -> DataResolution {
        while !Task.isCancelled {
            var firstCheck: Task<Void, Never>?
            let result = data(for: entry) { if firstCheck == nil { firstCheck = $0 } }
            if let firstCheck { await firstCheck.value }
            else if result.source != .picked, let shellScan,
                    entry.manifest.flatMap({ RomfsIdentity.parse($0.romfsIdentity) }) != nil { await shellScan.value }
            else { return result }
        }
        return .missing
    }

    private func profile(for entry: CatalogueEntry, data: DataResolution? = nil) -> LauncherProfile? {
        guard let base = entry.profile, entry.problem == nil else { return nil }
        // A DM_LANG row of the game's own list stays, except the all-languages row of a game with no language list (the engine's
        // fallback): the RomFS names the languages it really has (#668)
        if let row = base.settings.first(where: { $0.env == "DM_LANG" }), !RomfsLanguages.isFallbackRow(row) { return base }
        guard let romfs = (data ?? self.data(for: entry)).romfsURL else { return base }
        return RomfsLanguages.applying(to: base, options: RomfsLanguages.options(forRomfs: romfs))
    }

    private func image(_ url: URL?) -> Artwork? {
        guard let url else { return nil }
        if let a = artwork[url] { return a }
        guard let bytes = try? Data(contentsOf: url), let a = Artwork(id: url.path, data: bytes) else { return nil }
        artwork[url] = a
        return a
    }

    private func detail(for entry: CatalogueEntry) -> GameDetail {
        let data = data(for: entry)
        if data.source == .picked {
            pickedDataNotes.removeValue(forKey: entry.id)
        }
        var state = GameStateResolver.state(for: entry, data: data, environment: config.environment)
        let readiness = ShaderResources.readiness(entry: entry, appFolder: appFolder(for: entry.id), dataURL: data.url, romfsURL: data.romfsURL)
        if data.found && state == .playable {
            switch readiness {
            case .ready:
                break
            case .staleTrailer:
                state = .needsDataUpdate(staleChain: true)
            case .missing:
                state = .needsDataUpdate(staleChain: false)
            }
        }
        if Self.isMissingOrNeedsUpdate(state), let progress = joiningProgress[entry.id], progress.totalBytes > 0 {
            let clampedDone = min(max(0, progress.doneBytes), progress.totalBytes)
            let rawPercent = Int((Double(clampedDone) / Double(progress.totalBytes) * 100.0).rounded(.down))
            let percent = min(99, max(0, rawPercent))
            let doneSize = Self.formatByteSize(clampedDone)
            let totalSize = Self.formatByteSize(progress.totalBytes)
            state = .joiningGameData(percent: percent, doneSize: doneSize, totalSize: totalSize)
        }
        let locale = activeHostLocale
        let historyRecord = playHistory[entry.id]
        let played = effectiveLastPlayed(entry.id)
        let playTime = (historyRecord?.seconds ?? 0) >= 60
            ? ShellFormat.duration(historyRecord?.seconds ?? 0, locale: locale)
            : nil
        let playedLabel = played.map { ShellFormat.played($0, now: config.now(), locale: locale) }
        let recentlyPlayedLabel: String? = {
            let joined = ShellFormat.metaLine(playTime, playedLabel)
            return joined.isEmpty ? nil : joined
        }()
        let playSummary: String? = {
            guard let historyRecord, historyRecord.sessions > 0 else { return nil }
            let durationText = playTime ?? ShellFormat.underOneMinute()
            return ShellFormat.playSummary(duration: durationText, sessions: historyRecord.sessions)
        }()
        let bannerResolution = GameBannerStore.resolve(for: entry, bannersRoot: config.bannersRoot)
        let resolvedBanner = bannerResolution.candidates.lazy.compactMap { self.image($0) }.first
        let tile = GameTile(id: entry.id, title: entry.title, subtitle: entry.manifest.map { ShellFormat.version($0.displayVersion) } ?? "",
                            banner: resolvedBanner, icon: image(entry.iconURL), state: state,
                            recentlyPlayed: recentlyPlayedLabel, version: entry.manifest?.displayVersion ?? "",
                            isSwitch2: entry.manifest?.console == "switch2",
                            hasCustomCover: bannerResolution.hasCustomCover)
        guard let profile = profile(for: entry, data: data) else {
            resolvedProfiles.removeValue(forKey: entry.id)
            return GameDetail(game: tile, dataNote: dataNote(for: entry.id, data: data, found: false, readiness: readiness),
                              playSummary: playSummary)
        }
        resolvedProfiles[entry.id] = profile
        var cloud: String?
        var cloudNote = ""
        var cloudFromShell = false
        switch cloudSaves(entry.id) {
        case .own(let url): cloud = url.lastPathComponent
        case .stale: cloudNote = hostText("The folder you chose before is no longer readable. Please choose it again.")
        case .shell(let url): cloud = hostText("\(url.lastPathComponent) (from Settings)"); cloudFromShell = true
        case .off, .none: break
        }
        let latestBackup = latestBackups[entry.id]
        if let latestBackup, cloudNote.isEmpty {
            cloudNote = hostText("Latest local backup: \(latestBackup)")
        }
        var shellFolder = false
        if case .url = shellCloud.resolve() { shellFolder = true }
        let snapshot = settingsSnapshot(for: entry.id, profile: profile)
        let cheatsSummary = cheatsSummaries[entry.id]
        let saveSummary = localSaveSummaries[entry.id]
        return GameDetail(
            game: tile, sections: snapshot.sections,
            dataSource: dataSource(data), dataNote: dataNote(for: entry.id, data: data, found: data.found, readiness: readiness),
            cloudSaves: cloud, cloudNote: cloudNote, dlc: dlc(data), hasModifiedSettings: snapshot.hasModifiedSettings,
            dataFromShell: data.source == .shell, cloudFromShell: cloudFromShell,
            cloudCanUseShell: shellFolder && !cloudFromShell,
            latestSaveBackup: latestBackup, playSummary: playSummary, cheatsSummary: cheatsSummary,
            hasLocalSave: saveSummary?.hasEntries == true,
            localSaveSummary: formattedLocalSaveSummary(saveSummary))
    }

    private func dataSource(_ data: DataResolution) -> String {
        switch data.source {
        case .app: hostText("This app's folder")
        case .picked: data.url?.lastPathComponent ?? ""
        case .shell: hostText("\(data.url?.lastPathComponent ?? "") (from Settings)")
        case nil: ""
        }
    }

    private func dataNote(for id: String, data: DataResolution, found: Bool, readiness: ShaderReadiness) -> String {
        if found {
            switch readiness {
            case .ready:
                return ""
            case .staleTrailer(let imgChain, let expChain):
                if let progress = joiningProgress[id], progress.totalBytes > 0 {
                    let clampedDone = min(max(0, progress.doneBytes), progress.totalBytes)
                    let doneSize = Self.formatByteSize(clampedDone)
                    let totalSize = Self.formatByteSize(progress.totalBytes)
                    return hostText("Joining .nxpart split files in this app's folder (\(doneSize) of \(totalSize)).")
                }
                if !imgChain.isEmpty && !expChain.isEmpty {
                    return hostText("Shader files in this game data (\(imgChain)) do not match this app's version (\(expChain)). Send or copy updated game data from NX2Apple.")
                } else {
                    return hostText("Shader files in this game data do not match this app's version. Send or copy updated game data from NX2Apple.")
                }
            case .missing(let hadUnjoinedParts):
                if let progress = joiningProgress[id], progress.totalBytes > 0 {
                    let clampedDone = min(max(0, progress.doneBytes), progress.totalBytes)
                    let doneSize = Self.formatByteSize(clampedDone)
                    let totalSize = Self.formatByteSize(progress.totalBytes)
                    return hostText("Joining .nxpart split files in this app's folder (\(doneSize) of \(totalSize)).")
                }
                if hadUnjoinedParts {
                    return hostText("Shader files (msl) for this game are incomplete or still transferring. Wait for transfer to complete or send the game data again from NX2Apple.")
                } else {
                    return hostText("Shader files (msl) for this game are missing from its data folder. Send or copy the game data again from NX2Apple.")
                }
            }
        }
        if let progress = joiningProgress[id], progress.totalBytes > 0 {
            let clampedDone = min(max(0, progress.doneBytes), progress.totalBytes)
            let doneSize = Self.formatByteSize(clampedDone)
            let totalSize = Self.formatByteSize(progress.totalBytes)
            return hostText("Joining .nxpart split files in this app's folder (\(doneSize) of \(totalSize)).")
        }
        if let customNote = pickedDataNotes[id], !customNote.isEmpty {
            return customNote
        }
        if data.pickedIsStale {
            return hostText("The location you picked before is no longer readable (the app was signed differently). Please choose it again.")
        }
        return hostText("Choose the folder holding romfs.img (or the game's title ID folder) on this device, an external drive, or iCloud Drive.")
    }

    private static func isMissingOrNeedsUpdate(_ state: GameState) -> Bool {
        switch state {
        case .needsGameData, .needsDataUpdate: true
        default: false
        }
    }

    private func dlc(_ data: DataResolution) -> String {
        guard let url = data.url else { return hostText("No additional content") }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("aoc").path))?.filter { !$0.hasPrefix(".") } ?? []
        switch names.count {
        case 0: return hostText("No additional content")
        case 1: return hostText("1 additional content pack")
        default: return hostText("\(names.count) additional content packs")
        }
    }

    // MARK: Actions

    /// The closures for `LibraryView`.
    public var actions: ShellActions {
        ShellActions(
            onPlay: { [weak self] id in self?.play(id) },
            onChange: { [weak self] id, setting, value in self?.change(id, setting: setting, value: value) },
            onPickGameData: { [weak self] id in self?.pickGameData(id) },
            onUseAppData: { [weak self] id in self?.useAppData(id) },
            onPickCloudSaves: { [weak self] id in self?.pickCloudSaves(id) },
            onDisableCloudSaves: { [weak self] id in self?.disableCloudSaves(id) },
            onResetDefaults: { [weak self] id in self?.resetDefaults(id) },
            onShowLog: { [weak self] id in self?.showLog(id) },
            onAppUpdate: { [weak self] in self?.appUpdate() },
            onPickShellData: { [weak self] in self.map { model in Task { await model.pickShellDataNow() } } },
            onPickShellCloud: { [weak self] in self.map { model in Task { await model.pickShellCloudNow() } } },
            onUseShellCloud: { [weak self] id in self?.useShellCloudSaves(id) },
            onClearShellData: { [weak self] in self?.clearShellData() },
            onClearShellCloud: { [weak self] in self?.clearShellCloud() },
            onGlobalPadMapChange: { [weak self] setting, value in
                guard let self else { return }
                if setting == "swapAB" { self.shellSettings.setPadSwapAB(value == "1") }
                else { self.shellSettings.setPadButton(setting, to: value) }
                self.refreshAll()
            },
            onGlobalPadMapReset: { [weak self] in self?.shellSettings.resetPadMap(); self?.refreshAll() },
            onButtonTest: { [weak self] open in self?.buttonTest(open) },
            onPadMergeChange: { [weak self] on in self?.setPadMerge(on) },
            onRestoreSaveBackup: { [weak self] id in self?.restoreLatestSaveBackup(id) },
            onDeleteGame: { [weak self] id, saves in self?.deleteGame(id, saves: saves) },
            onOpenHomeButtonSettings: { [weak self] in self?.openHomeButtonSettings() },
            onCopyShortcutURL: { [weak self] id in self?.copyShortcutURL(for: id) },
            onAddToHomeScreen: { [weak self] id in
                guard let self else { return false }
                return await self.saveIconAndOpenShortcuts(for: id, showFloatingGuide: true)
            },
            onAddToHomeScreenWithGuide: { [weak self] id, showFloatingGuide in
                guard let self else { return false }
                return await self.saveIconAndOpenShortcuts(for: id, showFloatingGuide: showFloatingGuide)
            },
            onPrepareHomeScreenGuide: { [weak self] id in
                self?.prepareHomeScreenFloatingGuide(for: id)
            },
            onCancelPreparedHomeScreenGuide: { [weak self] in
                self?.cancelPreparedHomeScreenFloatingGuide()
            },
            onSaveCustomCover: { [weak self] id, jpegData in
                self?.saveCustomCover(for: id, jpegData: jpegData)
            },
            onResetCustomCover: { [weak self] id in
                self?.resetCustomCover(for: id)
            },
            onPickSideloadCertificateFile: { [weak self] in
                guard let self else { return .cancelled }
                return await self.pickSideloadCertificateFileNow()
            },
            onConfirmSideloadCertificatePassword: { [weak self] password in
                guard let self else { return nil }
                return await self.confirmSideloadCertificatePasswordNow(password)
            },
            onCancelSideloadCertificateImport: { [weak self] in
                self?.cancelSideloadCertificateImport()
            },
            onRemoveSideloadCertificate: { [weak self] in
                self?.removeSideloadCertificate()
            },
            onLoadCheats: { [weak self] id in
                self?.loadCheatsSnapshot(for: id) ?? GameCheatsSnapshot(gameID: id, gameTitle: "")
            },
            onLoadCheatsAsync: { [weak self] id in
                guard let self else { return GameCheatsSnapshot(gameID: id, gameTitle: "") }
                return await self.loadCheatsSnapshotAsync(for: id)
            },
            onToggleCheatMaster: { [weak self] id, on in
                self?.setCheatMaster(for: id, on: on) ?? GameCheatsSnapshot(gameID: id, gameTitle: "")
            },
            onToggleCheatMasterAsync: { [weak self] id, on in
                guard let self else { return GameCheatsSnapshot(gameID: id, gameTitle: "") }
                return await self.setCheatMasterAsync(for: id, on: on)
            },
            onToggleCheatEntry: { [weak self] id, key, on in
                self?.setCheatEntry(for: id, key: key, on: on) ?? GameCheatsSnapshot(gameID: id, gameTitle: "")
            },
            onToggleCheatEntryAsync: { [weak self] id, key, on in
                guard let self else { return GameCheatsSnapshot(gameID: id, gameTitle: "") }
                return await self.setCheatEntryAsync(for: id, key: key, on: on)
            },
            onImportCheatFile: { [weak self] id in
                guard let self else { return .cancelled }
                return await self.importCheatFileNow(for: id)
            },
            onConfirmMismatchCheatImport: { [weak self] id, token in
                self?.confirmMismatchCheatImport(for: id, token: token) ?? .cancelled
            },
            onConfirmMismatchCheatImportAsync: { [weak self] id, token in
                guard let self else { return .cancelled }
                return await self.confirmMismatchCheatImportAsync(for: id, token: token)
            },
            onCancelMismatchCheatImport: { [weak self] id in
                self?.cancelMismatchCheatImport(for: id)
            },
            onDismissCheatFuseAlert: { [weak self] id in
                self?.dismissCheatFuseAlert(for: id) ?? GameCheatsSnapshot(gameID: id, gameTitle: "")
            },
            onDismissCheatFuseAlertAsync: { [weak self] id in
                guard let self else { return GameCheatsSnapshot(gameID: id, gameTitle: "") }
                return await self.dismissCheatFuseAlertAsync(for: id)
            },
            onFetchCheats: { [weak self] id in
                guard let self else { return .failed("") }
                return await self.fetchCheatsAsync(for: id)
            },
            onMergeOnlineCheats: { [weak self] id, preview in
                guard let self else { return .failed("") }
                return await self.mergeOnlineCheatsAsync(for: id, preview: preview)
            },
            onReplaceOnlineCheats: { [weak self] id, preview in
                guard let self else { return .failed("") }
                return await self.replaceWithOnlineCheatsAsync(for: id, preview: preview)
            },
            onDeleteCheatFile: { [weak self] id in
                self?.deleteCheatFile(for: id) ?? GameCheatsSnapshot(gameID: id, gameTitle: "")
            },
            onDeleteCheatFileAsync: { [weak self] id in
                guard let self else { return GameCheatsSnapshot(gameID: id, gameTitle: "") }
                return await self.deleteCheatFileAsync(for: id)
            },
            onPickSaveImport: { [weak self] id in
                guard let self else { return .cancelled }
                return await self.pickSaveImportNow(for: id)
            },
            onConfirmSaveImport: { [weak self] id, token, mode in
                guard let self else { return .cancelled }
                return await self.confirmSaveImportNow(for: id, token: token, mode: mode)
            },
            onCancelSaveImport: { [weak self] id, token in
                self?.cancelSaveImport(for: id, token: token)
            },
            onExportSave: { [weak self] id in
                guard let self else { return .cancelled }
                return await self.exportSaveNow(for: id)
            })
    }

    // MARK: Sideload .p12 certificate management

    public func pickSideloadCertificateFileNow() async -> SideloadCertificatePickResult {
        switch await certificatePicker.pickCertificateOutcome() {
        case .picked(let data, let fileName):
            guard !data.isEmpty else {
                return .failed(SideloadCertificateError.emptyFile.localizedDescription)
            }
            guard data.count <= SideloadCertificateStore.maxFileBytes else {
                return .failed(SideloadCertificateError.fileTooLarge.localizedDescription)
            }
            pendingPKCS12Data = data
            return .picked(fileName: fileName)
        case .cancelled:
            return .cancelled
        case .unavailable:
            return .failed(hostText("The file picker could not open here. Open the app on its own and try again."))
        case .unreadable:
            return .failed(hostText("The selected certificate file could not be read."))
        }
    }

    public func confirmSideloadCertificatePasswordNow(_ password: String) async -> String? {
        guard let data = pendingPKCS12Data else {
            return SideloadCertificateError.emptyFile.localizedDescription
        }
        pendingPKCS12Data = nil
        certificateGeneration &+= 1
        let generation = certificateGeneration
        let store = sideloadCertificateStore
        let outcome: Result<SideloadCertificateSummary, Error> = await Task.detached(priority: .userInitiated) {
            Result { try store.importPKCS12(data: data, password: password) }
        }.value
        guard certificateGeneration == generation else { return nil }
        switch outcome {
        case .success(let summary):
            sideloadCertificate = summary
            return nil
        case .failure(let error):
            // Keep the staged .p12 bytes while the password sheet stays open for retry; cancelSideloadCertificateImport clears them.
            pendingPKCS12Data = data
            return error.localizedDescription
        }
    }

    public func cancelSideloadCertificateImport() {
        pendingPKCS12Data = nil
    }

    public func removeSideloadCertificate() {
        Task { await removeSideloadCertificateNow() }
    }

    public func removeSideloadCertificateNow() async {
        pendingPKCS12Data = nil
        certificateGeneration &+= 1
        let generation = certificateGeneration
        let store = sideloadCertificateStore
        let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
            Result { try store.remove() }
        }.value
        guard certificateGeneration == generation else { return }
        switch result {
        case .success:
            sideloadCertificate = nil
        case .failure(let error):
            notice = error.localizedDescription
        }
    }

    // MARK: Custom and backfilled covers

    /// Atomically saves a user-cropped 16:9 JPEG cover and immediately refreshes the game's artwork.
    public func saveCustomCover(for id: String, jpegData: Data) {
        guard entry(id) != nil else { return }
        do {
            let url = try GameBannerStore.saveCustomBanner(jpegData, for: id, bannersRoot: config.bannersRoot)
            artwork.removeValue(forKey: url)
            refresh(id)
        } catch {
            notice = hostText("The custom cover could not be saved.")
        }
    }

    /// Removes the user's custom cover and immediately restores the default banner/icon.
    public func resetCustomCover(for id: String) {
        guard entry(id) != nil else { return }
        if let removed = GameBannerStore.removeCustomBanner(for: id, bannersRoot: config.bannersRoot) {
            artwork.removeValue(forKey: removed)
        }
        refresh(id)
        startMissingBannerFetch()
    }

    /// Low-priority background backfill of official 16:9 banners for installed games lacking bundled/custom/auto banners.
    /// Tries built-in `KnownGameBanners` first, then `ec.nintendo.com` (US -> HK) and `api.nlib.cc` according to title type.
    /// Only definitive `.saved` / `.notFound` outcomes are recorded in `attemptedBannerFetches`; cancellation, transient
    /// errors, and budget cutoffs leave remaining titles eligible for automatic retry on subsequent reloads.
    private func startMissingBannerFetch() {
        let bannersRoot = config.bannersRoot
        let candidates: [CatalogueEntry] = entries.filter { entry in
            let key = entry.id.uppercased()
            guard !attemptedBannerFetches.contains(key) else { return false }
            return GameBannerStore.needsBackfill(for: entry, bannersRoot: bannersRoot)
        }
        guard !candidates.isEmpty else { return }

        bannerFetchTask?.cancel()
        bannerFetchGeneration &+= 1
        let generation = bannerFetchGeneration
        let fetcher = config.fetchBannerData
        let outcomeFetcher = config.fetchBannerOutcome
        let storeTransport = config.fetchStoreResponse
        let clock = config.now

        bannerFetchTask = Task { [weak self] in
            var errorBudgetElapsed: TimeInterval = 0
            for entry in candidates {
                guard !Task.isCancelled else { return }
                if errorBudgetElapsed >= GameBannerStore.batchErrorBudget { return }
                let started = clock()
                let outcome: GameBannerStore.BackfillOutcome = await Task.detached(priority: .utility) {
                    await GameBannerStore.fetchAndSaveAutoBanner(
                        for: entry,
                        bannersRoot: bannersRoot,
                        fetchBannerData: fetcher,
                        fetchBannerOutcome: outcomeFetcher,
                        storeTransport: storeTransport
                    )
                }.value
                guard let self, !Task.isCancelled, self.bannerFetchGeneration == generation else { return }
                switch outcome {
                case .saved(let savedURL):
                    self.attemptedBannerFetches.insert(entry.id.uppercased())
                    if self.entry(entry.id) != nil {
                        self.artwork.removeValue(forKey: savedURL)
                        self.refresh(entry.id)
                    }
                case .notFound:
                    self.attemptedBannerFetches.insert(entry.id.uppercased())
                case .transientFailure:
                    errorBudgetElapsed += max(0, clock().timeIntervalSince(started))
                }
            }
        }
    }

    public func change(_ id: String, setting: String, value: String) {
        guard let profile = cachedOrResolvedProfile(for: id) else { return }
        if setting.hasPrefix("pad.") {
            GamePadMapStore(defaults: config.defaults(id)).change(setting, value: value)
        } else {
            let store = makeSettingsStore(for: id, profile: profile)
            if store.set(setting, to: value) {
                GameEnvFileSync.syncKey(setting, value: store.savedValue(for: setting), in: gameEnvURL(for: id))
            }
        }
        refreshSettings(id, profile: profile)
    }

    public func resetDefaults(_ id: String) {
        guard let profile = cachedOrResolvedProfile(for: id) else { return }
        GameSettingsStore(profile: profile, defaults: config.defaults(id)).reset()
        GameEnvFileSync.clearKeys(Set(profile.settings.map(\.env)), in: gameEnvURL(for: id))
        GamePadMapStore(defaults: config.defaults(id)).reset()
        refreshSettings(id, profile: profile)
    }

    /// The folder the player picked, nil on a cancel. A picker that could not be shown says so in the notice (#1049).
    private func pickedFolder() async -> URL? {
        switch await picker.pickFolderOutcome() {
        case .picked(let url): return url
        case .cancelled: return nil
        case .unavailable:
            notice = hostText("The folder picker could not open here. Open the app on its own and try again.")
            return nil
        }
    }

    public func pickGameData(_ id: String) {
        Task { await pickGameDataNow(id) }
    }

    func pickGameDataNow(_ id: String) async {
        guard let url = await pickedFolder() else { return }
        let generation = (pickGeneration[id] ?? 0) &+ 1
        pickGeneration[id] = generation
        guard let currentEntry = entry(id) else { return }

        if let manifest = currentEntry.manifest, currentEntry.problem == nil {
            let folderMatchesGame = await Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard FileManager.default.fileExists(atPath: url.path) else { return false }
                let appFallback = FileManager.default.temporaryDirectory.appendingPathComponent("nx-unused-\(UUID().uuidString)", isDirectory: true)
                let check = DataLocator.locate(manifest: manifest, picked: .url(url), appFolder: appFallback)
                return check.source == .picked
            }.value
            guard pickGeneration[id] == generation, let latestEntry = entry(id) else { return }
            if !folderMatchesGame {
                // Keep any previously working folder bookmark intact when the newly picked folder has no data for this game.
                let knownTitles = Dictionary(uniqueKeysWithValues: entries.map { ($0.id.uppercased(), $0.title) })
                var identityOwners: [RomfsIdentity: String] = [:]
                var ambiguousIdentities = Set<RomfsIdentity>()
                for other in entries where other.id.caseInsensitiveCompare(id) != .orderedSame {
                    guard let raw = other.manifest?.romfsIdentity,
                          let parsed = RomfsIdentity.parse(raw),
                          !ambiguousIdentities.contains(parsed) else { continue }
                    if let prev = identityOwners[parsed], prev != other.title {
                        identityOwners.removeValue(forKey: parsed)
                        ambiguousIdentities.insert(parsed)
                    } else {
                        identityOwners[parsed] = other.title
                    }
                }
                let knownIdentities = identityOwners
                let finding = await Task.detached(priority: .userInitiated) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return DataFolderDiagnostics.diagnose(folder: url, manifest: manifest, knownTitles: knownTitles, knownIdentities: knownIdentities)
                }.value
                guard pickGeneration[id] == generation, let refreshedEntry = entry(id) else { return }
                let message = DataFolderDiagnostics.message(
                    for: finding,
                    gameTitle: refreshedEntry.title,
                    gameID: id,
                    folderName: url.lastPathComponent
                )
                if !data(for: refreshedEntry).found {
                    pickedDataNotes[id] = message
                    refresh(id)
                }
                notice = message
                return
            }
        }

        pickedDataNotes.removeValue(forKey: id)
        guard dataStore(id).store(url) else {
            notice = hostText("That location could not be remembered. Try a different one.")
            return
        }
        forgetCheckedRomfsImages()
        guard let latestEntry = entry(id) else { return }
        let resolved = await verifiedData(for: latestEntry)
        guard pickGeneration[id] == generation else { return }
        refresh(id)
        if resolved.source != .picked,
           let game = details.first(where: { $0.id == id })?.game, Self.isMissingOrNeedsUpdate(game.state) {
            notice = hostText("No game data for \(game.title) was found in that folder.")
        }
    }

    public func useAppData(_ id: String) {
        pickGeneration[id] = (pickGeneration[id] ?? 0) &+ 1
        pickedDataNotes.removeValue(forKey: id)
        dataStore(id).clear()
        refresh(id)
        if let game = details.first(where: { $0.id == id })?.game, Self.isMissingOrNeedsUpdate(game.state) {
            notice = hostText("This app's folder has no data for this game yet. Copy it to games/\(id) in this app's folder in Files.")
        }
    }

    public func pickCloudSaves(_ id: String) {
        Task { await pickCloudSavesNow(id) }
    }

    func pickCloudSavesNow(_ id: String) async {
        guard let url = await pickedFolder() else { return }
        if cloudStore(id).store(url) { config.defaults(id).removeObject(forKey: GameDefaults.cloudSavesOffKey) }
        else { notice = hostText("That folder could not be remembered. Try a different one.") }
        refresh(id)
    }

    private enum ShellDataFolderCheck: Sendable {
        case unreadable
        case noGameData
        case matched
    }

    func pickShellDataNow() async {
        guard let url = await pickedFolder() else { return }
        shellDataPickGeneration &+= 1
        let generation = shellDataPickGeneration
        let manifests = entries.compactMap { entry in
            entry.problem == nil ? entry.manifest : nil
        }
        let check = await Task.detached(priority: .userInitiated) { () -> ShellDataFolderCheck in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                return .unreadable
            }
            let index = ShellDataIndex(folder: url)
            if manifests.isEmpty {
                return index.hasAnyImage ? .matched : .noGameData
            }
            let appFallback = FileManager.default.temporaryDirectory.appendingPathComponent("nx-unused-\(UUID().uuidString)", isDirectory: true)
            for manifest in manifests {
                let shellMatch: URL?
                if let ident = RomfsIdentity.parse(manifest.romfsIdentity) {
                    shellMatch = index.imageURL(matching: ident, preferredChain: manifest.chain, explicitGfxAPI: manifest.gfxAPI)
                } else {
                    shellMatch = nil
                }
                let resolved = DataLocator.locate(
                    manifest: manifest,
                    picked: .none,
                    appFolder: appFallback,
                    global: .url(url),
                    shellMatch: shellMatch
                )
                if resolved.source == .shell {
                    return .matched
                }
            }
            return .noGameData
        }.value
        guard shellDataPickGeneration == generation else { return }
        switch check {
        case .unreadable:
            notice = hostText("That folder could not be remembered. Try a different one.")
            return
        case .noGameData:
            notice = hostText("No game data for your installed games was found in “\(url.lastPathComponent)”. Choose a folder containing a game's romfs.img.")
            return
        case .matched:
            break
        }
        guard shellData.store(url) else { notice = hostText("That folder could not be remembered. Try a different one."); return }
        forgetCheckedRomfsImages()
        shellSettings.storeDataFolderName(url.lastPathComponent)
        startShellScan(force: true)
        refreshAll()
    }

    func pickShellCloudNow() async {
        guard let url = await pickedFolder() else { return }
        guard shellCloud.store(url) else { notice = hostText("That folder could not be remembered. Try a different one."); return }
        shellSettings.storeCloudSavesFolderName(url.lastPathComponent)
        refreshAll()
    }

    public func disableCloudSaves(_ id: String) {
        cloudStore(id).clear()
        config.defaults(id).set(true, forKey: GameDefaults.cloudSavesOffKey)
        refresh(id)
    }

    /// The game follows the shell settings' cloud-saves folder again.
    public func useShellCloudSaves(_ id: String) {
        cloudStore(id).clear()
        config.defaults(id).removeObject(forKey: GameDefaults.cloudSavesOffKey)
        refresh(id)
    }

    func clearShellData() {
        shellDataPickGeneration &+= 1
        shellData.clear()
        shellSettings.clearDataFolderName()
        refreshAll()
    }

    func clearShellCloud() {
        shellCloud.clear()
        shellSettings.clearCloudSavesFolderName()
        refreshAll()
    }

    public func showLog(_ id: String) {
        guard let entry = entry(id) else { return }
        let app = appFolder(for: id)
        let folders = [data(for: entry).url, app].compactMap { $0 }
        // The shell's engine writes Documents/log.txt (EngineLaunchPlan) for whichever game ran last, so it counts only when that run was this game's
        let engine = config.appDataRoot.deletingLastPathComponent().appendingPathComponent("log.txt")
        let found = folders.lazy.compactMap { LogReader.read($0.appendingPathComponent("log.txt")) }.first
            ?? (LogReader.isRun(of: id, engine) ? LogReader.read(engine) : nil)
        log = LogPresentation(gameID: id, title: entry.title, text: found?.text, truncated: found?.truncated ?? false)
    }

    // MARK: Delete

    /// Deletes the game's folder in this app (its saves only when `saves`), forgets the folders the player picked for its data
    /// and cloud saves (those folders are the player's and are not touched) and when it was played, and takes the game off the
    /// list. The game's framework inside the app stays: see `GameDeletion`.
    public func deleteGame(_ id: String, saves: Bool) {
        guard let entry = entry(id) else { return }
        joinGeneration &+= 1
        joiningProgress.removeValue(forKey: id)
        pickGeneration[id] = (pickGeneration[id] ?? 0) &+ 1
        saveOpGeneration[id] = (saveOpGeneration[id] ?? 0) &+ 1
        cancelAllPendingSaveImports(for: id)
        pickedDataNotes.removeValue(forKey: id)
        latestBackups.removeValue(forKey: id)
        localSaveSummaries.removeValue(forKey: id)
        resolvedProfiles.removeValue(forKey: id)
        if let customURL = GameBannerStore.customBannerURL(for: id, bannersRoot: config.bannersRoot) {
            artwork.removeValue(forKey: customURL)
        }
        if let autoURL = GameBannerStore.autoBannerURL(for: id, bannersRoot: config.bannersRoot) {
            artwork.removeValue(forKey: autoURL)
        }
        if pendingCloudLaunch?.game.titleID == id {
            cancelCloudConflict()
        }
        var failed = GameDeletion.delete(in: appFolder(for: id), saves: saves)
        if let hotRoot = config.hotFrameworksRoot {
            let entryParent = entry.directory.deletingLastPathComponent().standardizedFileURL
            if entryParent == hotRoot.standardizedFileURL {
                MachOLocalSigner.removeReceipt(for: entry.directory)
                if !GameCatalogue.discardFolder(entry.directory, in: hotRoot) {
                    failed.append(entry.directory)
                }
            }
            let canonicalHot = hotRoot.appendingPathComponent("DmGame\(id.uppercased()).framework", isDirectory: true)
            MachOLocalSigner.removeReceipt(for: canonicalHot)
            if FileManager.default.fileExists(atPath: canonicalHot.path),
               !GameCatalogue.discardFolder(canonicalHot, in: hotRoot) {
                failed.append(canonicalHot)
            }
        }
        dataStore(id).clear()
        cloudStore(id).clear()
        dataStores.removeValue(forKey: id)
        cloudStores.removeValue(forKey: id)
        let defaults = config.defaults(id)
        defaults.removeObject(forKey: LastPlayedStore.key)
        let bundledAfterHotRemoval = GameCatalogue.scan(root: config.gamesRoot).first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
        defaults.set(GameDeletion.stamp(bundledAfterHotRemoval ?? entry), forKey: GameDeletion.deletedKey)
        reload()
        if !failed.isEmpty { notice = hostText("Some files of \(entry.title) could not be deleted.") }
    }

    /// Deleted, and still the same build with no game data in its folder. A new build or game data in the folder brings the
    /// game back, and the mark is dropped.
    private func isDeleted(_ entry: CatalogueEntry) -> Bool {
        let defaults = config.defaults(entry.id)
        guard let deleted = defaults.string(forKey: GameDeletion.deletedKey) else { return false }
        let hasData = entry.manifest.map { DataLocator.romfs(in: appFolder(for: entry.id), manifest: $0, .default) != nil } ?? false
        if deleted == GameDeletion.stamp(entry) && !hasData { return true }
        defaults.removeObject(forKey: GameDeletion.deletedKey)
        return false
    }

    public func appUpdate() {
        guard let url = config.updateURL else { notice = hostText("No update address is set up for this app."); return }
        config.openURL(url)
    }

    private enum LaunchOutcome {
        case launched
        case promptedCloudConflict
        case failed(String?)
    }

    public func copyShortcutURL(for id: String) {
        guard let entry = entry(id) else { return }
        config.copyToPasteboard(DeepLinkRouter.shortcutURLString(for: entry))
    }

    public func prepareHomeScreenFloatingGuide(for id: String) {
        guard let currentEntry = entry(id) else { return }
        let iconPNG = HomeScreenShortcutSupport.renderSquareIconPNG(for: currentEntry, size: 512)
        let request = HomeScreenGuideRequest(
            gameTitle: currentEntry.title,
            iconPNG: iconPNG,
            steps: HomeScreenGuideSteps.shortcutsSteps(),
            hintText: HomeScreenGuideSteps.pipControlsHint()
        )
        if let customPrepare = config.prepareFloatingGuide {
            customPrepare(request)
        } else {
            homeScreenGuidePiP.prepare(request)
        }
    }

    public func cancelPreparedHomeScreenFloatingGuide() {
        homeScreenGuidePiP.cancelPrepared()
        config.cancelPreparedFloatingGuide?()
    }

    public func stopHomeScreenFloatingGuide() {
        homeScreenGuidePiP.stop()
        config.stopFloatingGuide?()
    }

    @discardableResult
    public func saveIconAndOpenShortcuts(for id: String, showFloatingGuide: Bool = true) async -> Bool {
        guard let initialEntry = entry(id),
              let pngData = HomeScreenShortcutSupport.renderSquareIconPNG(for: initialEntry, size: 512) else {
            return false
        }
        let saved = await config.saveImageToPhotos(pngData)
        guard let currentEntry = entry(id) else { return false }
        config.copyToPasteboard(currentEntry.title)
        guard saved else { return false }
        if showFloatingGuide {
            let request = HomeScreenGuideRequest(
                gameTitle: currentEntry.title,
                iconPNG: pngData,
                steps: HomeScreenGuideSteps.shortcutsSteps(),
                hintText: HomeScreenGuideSteps.pipControlsHint()
            )
            if let customStart = config.startFloatingGuide {
                _ = await customStart(request)
            } else {
                _ = await homeScreenGuidePiP.start(request)
            }
        } else {
            stopHomeScreenFloatingGuide()
        }
        config.openURL(HomeScreenShortcutSupport.createShortcutURL)
        return true
    }

    @discardableResult
    public func handleDeepLink(_ url: URL) -> Bool {
        guard DeepLinkRouter.isLaunchURL(url) else { return false }
        guard let request = DeepLinkRouter.parse(url) else {
            let message = hostText("No game was specified in the shortcut link.")
            if let errorURL = DeepLinkRouter.extractErrorCallback(from: url) {
                config.openURL(DeepLinkRouter.errorCallbackURL(base: errorURL, message: message))
            } else {
                notice = message
            }
            return true
        }

        deepLinkGeneration &+= 1
        let generation = deepLinkGeneration
        activeDeepLinkTask?.cancel()
        deepLinkCloudPending = false

        if !stoppingRunningGame,
           let runningID = config.activeRunningGameID(), !runningID.isEmpty,
           let matched = DeepLinkRouter.matchEntry(target: request.target, in: entries),
           matched.id.caseInsensitiveCompare(runningID) == .orderedSame {
            queuedDeepLinkRequest = nil
            pendingDeepLinkSuccessURL = request.successURL
            pendingDeepLinkErrorURL = request.errorURL
            isDeepLinkLaunching = false
            return true
        }

        isDeepLinkLaunching = true
        activeDeepLinkTask = Task { [weak self] in
            await self?.processDeepLinkRequest(request, generation: generation)
        }
        return true
    }

    @discardableResult
    func handleDeepLinkNow(_ url: URL) async -> Bool {
        let accepted = handleDeepLink(url)
        if accepted {
            await activeDeepLinkTask?.value
        }
        return accepted
    }

    func waitForDeepLinkTask() async {
        await activeDeepLinkTask?.value
    }

    private func processDeepLinkRequest(_ request: DeepLinkRequest, generation: UInt64) async {
        while let task = joinAndClaimTask {
            await task.value
        }
        guard deepLinkGeneration == generation, !Task.isCancelled else { return }

        let preserveRunningSession = stoppingRunningGame || !(config.activeRunningGameID() ?? "").isEmpty

        var resolvedEntry = DeepLinkRouter.matchEntry(target: request.target, in: entries)
        if resolvedEntry == nil {
            reload()
            resolvedEntry = DeepLinkRouter.matchEntry(target: request.target, in: entries)
        }
        guard let matched = resolvedEntry else {
            failDeepLink(request, message: hostText("Game \"\(request.target)\" was not found."), preserveRunningSession: preserveRunningSession)
            return
        }

        if let runningID = config.activeRunningGameID(), !runningID.isEmpty {
            if !stoppingRunningGame, matched.id.caseInsensitiveCompare(runningID) == .orderedSame {
                queuedDeepLinkRequest = nil
                pendingDeepLinkSuccessURL = request.successURL
                pendingDeepLinkErrorURL = request.errorURL
                isDeepLinkLaunching = false
                return
            }
            pendingDeepLinkSuccessURL = nil
            pendingDeepLinkErrorURL = nil
            queuedDeepLinkRequest = request
            isDeepLinkLaunching = true
            if !stoppingRunningGame {
                stoppingRunningGame = true
                config.requestStopRunningGame()
            }
            return
        }

        if cloudConflict != nil {
            cancelCloudConflict(notifyDeepLink: false)
        }

        if matched.problem == nil {
            _ = await verifiedData(for: matched)
            guard deepLinkGeneration == generation, !Task.isCancelled else { return }
            refresh(matched.id)
        }

        guard let latestEntry = entry(matched.id),
              let detail = details.first(where: { $0.id == latestEntry.id }) else {
            failDeepLink(request, message: hostText("Game \"\(request.target)\" was not found."), preserveRunningSession: preserveRunningSession)
            return
        }

        guard detail.game.state == .playable else {
            failDeepLink(request, message: unplayableDeepLinkMessage(for: detail.game.state, title: latestEntry.title), preserveRunningSession: preserveRunningSession)
            return
        }

        pendingDeepLinkSuccessURL = request.successURL
        pendingDeepLinkErrorURL = request.errorURL

        let outcome = await playInternal(latestEntry.id, suppressErrorNotice: request.errorURL != nil)
        guard deepLinkGeneration == generation else { return }

        switch outcome {
        case .launched:
            isDeepLinkLaunching = false
        case .promptedCloudConflict:
            deepLinkCloudPending = true
            isDeepLinkLaunching = false
        case .failed(let message):
            let fallback = hostText("\(latestEntry.title) could not be launched.")
            failDeepLink(request, message: message ?? fallback)
        }
    }

    @MainActor
    func handleReturnToLibrary() {
        stoppingRunningGame = false
        refreshSettingsAfterGameReturn()
        startBackupScan()
        startCheatsSummaryScan()
        if let queued = queuedDeepLinkRequest {
            queuedDeepLinkRequest = nil
            pendingDeepLinkSuccessURL = nil
            pendingDeepLinkErrorURL = nil
            deepLinkCloudPending = false
            isDeepLinkLaunching = true
            deepLinkGeneration &+= 1
            let generation = deepLinkGeneration
            activeDeepLinkTask?.cancel()
            activeDeepLinkTask = Task { [weak self] in
                await self?.processDeepLinkRequest(queued, generation: generation)
            }
            return
        }
        let successURL = pendingDeepLinkSuccessURL
        pendingDeepLinkSuccessURL = nil
        pendingDeepLinkErrorURL = nil
        deepLinkCloudPending = false
        isDeepLinkLaunching = false
        if let successURL {
            config.openURL(successURL)
        }
        directoryWatcher?.setPaused(isBusyWithGame)
        if !isBusyWithGame {
            if pendingReloadAfterClaim {
                pendingReloadAfterClaim = false
                reload(afterClaim: true)
            }
            let excluded = pendingExcludedPartPaths
            pendingExcludedPartPaths.removeAll()
            scheduleJoinAndClaim(excludedPartPaths: excluded)
        }
    }

    private func failDeepLink(_ request: DeepLinkRequest, message: String, preserveRunningSession: Bool = false) {
        if !preserveRunningSession {
            queuedDeepLinkRequest = nil
            pendingDeepLinkSuccessURL = nil
            pendingDeepLinkErrorURL = nil
            deepLinkCloudPending = false
            isDeepLinkLaunching = false
        } else {
            isDeepLinkLaunching = queuedDeepLinkRequest != nil
        }
        if let errorURL = request.errorURL {
            config.openURL(DeepLinkRouter.errorCallbackURL(base: errorURL, message: message))
        } else {
            notice = message
        }
    }

    private func unplayableDeepLinkMessage(for state: GameState, title: String) -> String {
        switch state {
        case .broken(let reason, let detail, _):
            return detail.isEmpty ? reason : detail
        default:
            return hostText("\(title) is not ready to launch.")
        }
    }

    private func clearDeepLinkStateForManualPlay() {
        deepLinkGeneration &+= 1
        activeDeepLinkTask?.cancel()
        activeDeepLinkTask = nil
        pendingDeepLinkSuccessURL = nil
        pendingDeepLinkErrorURL = nil
        queuedDeepLinkRequest = nil
        stoppingRunningGame = false
        deepLinkCloudPending = false
        isDeepLinkLaunching = false
    }

    public func play(_ id: String) {
        clearDeepLinkStateForManualPlay()
        Task { await playNow(id) }
    }

    func playNow(_ id: String) async {
        clearDeepLinkStateForManualPlay()
        _ = await playInternal(id, suppressErrorNotice: false)
    }

    private func playInternal(_ id: String, suppressErrorNotice: Bool) async -> LaunchOutcome {
        guard !launchingGame, cloudConflict == nil,
              let entry = entry(id), let manifest = entry.manifest, let framework = entry.frameworkURL,
              details.first(where: { $0.id == id })?.game.state == .playable else {
            return .failed(nil)
        }
        stopHomeScreenFloatingGuide()
        cloudCheckGeneration &+= 1
        let checkGeneration = cloudCheckGeneration
        pendingCloudLaunch = nil
        launchingGame = true
        defer { launchingGame = false }
        forgetCheckedRomfsImages()
        let resolved = await verifiedData(for: entry)
        let gameAppFolder = appFolder(for: id)
        guard cloudCheckGeneration == checkGeneration,
              let latestEntry = self.entry(id), latestEntry.manifest == manifest, let dataURL = resolved.url else {
            refresh(id)
            let updatedState = details.first(where: { $0.id == id })?.game.state
            return .failed(updatedState.map { unplayableDeepLinkMessage(for: $0, title: entry.title) })
        }
        let readiness = ShaderResources.readiness(entry: latestEntry, appFolder: gameAppFolder, dataURL: dataURL, romfsURL: resolved.romfsURL)
        guard case .ready(let shaderSource) = readiness,
              let profile = profile(for: latestEntry, data: resolved) else {
            refresh(id)
            let updatedState = details.first(where: { $0.id == id })?.game.state
            return .failed(updatedState.map { unplayableDeepLinkMessage(for: $0, title: latestEntry.title) })
        }
        var cloud: URL?
        switch cloudSaves(id) {
        case .own(let url), .shell(let url): cloud = url
        case .off, .stale, .none: break
        }
        var game = LaunchableGame(
            titleID: id, name: entry.title, manifest: manifest, directory: entry.directory, frameworkURL: framework, dataURL: dataURL,
            romfsURL: resolved.romfsURL, appFolder: gameAppFolder, environment: launchEnvironment(profile: profile, id: id),
            cloudSavesURL: cloud, shellEnvironment: shellSettings.gameDefaults,
            shellFallbackKeys: launchShellFallbackKeys(profile: profile, id: id),
            builtInDefaultKeys: launchBuiltInDefaultKeys(profile: profile, id: id),
            fallbackBundledFrameworkURL: latestEntry.fallbackBundledFrameworkURL)
        if case .trailer = shaderSource {
            game.usesEmbeddedShaderTrailer = true
        }

        if let cloudFolder = cloud {
            let report = await Task.detached(priority: .userInitiated) {
                CloudSaveSyncCheck.inspect(cloudFolder: cloudFolder, titleID: id, appFolder: gameAppFolder)
            }.value
            guard cloudCheckGeneration == checkGeneration, self.entry(id)?.manifest == manifest else { return .failed(nil) }
            if report.outcome.requiresPrompt {
                let rawDevice = (report.cloud?.device ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let shownDevice = (rawDevice.isEmpty || rawDevice == "unknown") ? hostText("Another device") : rawDevice
                pendingCloudLaunch = PendingCloudLaunch(generation: checkGeneration, game: game, report: report)
                cloudConflict = CloudSavePrompt(
                    gameID: id,
                    gameTitle: entry.title,
                    isUnreadable: report.outcome == .unreadable,
                    reason: report.reason ?? "",
                    cloudDevice: shownDevice,
                    cloudSaved: Self.formatSaveDate(report.cloud?.saved),
                    localSaved: Self.formatSaveDate(report.local.saved)
                )
                return .promptedCloudConflict
            }
            for (k, v) in CloudSaveSyncCheck.nonInteractiveEnvironment() {
                game.environment[k] = v
            }
        }

        switch await finishLaunch(game, expectedGeneration: checkGeneration, suppressNotice: suppressErrorNotice) {
        case .launched:
            return .launched
        case .cancelled:
            return .failed(nil)
        case .failed(let failure):
            return .failed(failure)
        }
    }

    public func resolveCloudConflict(_ decision: CloudSaveDecision) {
        Task { await resolveCloudConflictNow(decision) }
    }

    public func cancelCloudConflict() {
        cancelCloudConflict(notifyDeepLink: true)
    }

    private func cancelCloudConflict(notifyDeepLink: Bool) {
        cloudCheckGeneration &+= 1
        pendingCloudLaunch = nil
        cloudConflict = nil
        if deepLinkCloudPending {
            let errorURL = pendingDeepLinkErrorURL
            pendingDeepLinkSuccessURL = nil
            pendingDeepLinkErrorURL = nil
            deepLinkCloudPending = false
            isDeepLinkLaunching = false
            if notifyDeepLink, let errorURL {
                config.openURL(DeepLinkRouter.errorCallbackURL(base: errorURL, message: hostText("Launch cancelled.")))
            }
        }
    }

    public func cancelCloudConflictIfPending() {
        guard pendingCloudLaunch != nil else { return }
        cancelCloudConflict()
    }

    func resolveCloudConflictNow(_ decision: CloudSaveDecision) async {
        if decision == .cancel {
            cancelCloudConflict()
            return
        }
        guard !launchingGame, let pending = pendingCloudLaunch else { return }
        let isUnreadable = pending.report.outcome == .unreadable
        let syncChoice: CloudSaveSyncCheck.Choice
        switch decision {
        case .playOffline where isUnreadable:
            syncChoice = .offline
        case .useCloud where !isUnreadable:
            syncChoice = .cloud
        case .useDevice where !isUnreadable:
            syncChoice = .local
        default:
            return
        }

        pendingCloudLaunch = nil
        cloudConflict = nil
        launchingGame = true
        defer { launchingGame = false }

        let now = config.now()
        let report = pending.report
        let folder = pending.game.appFolder
        let choiceResult = await Task.detached(priority: .userInitiated) { () -> Result<[String: String], Error> in
            Result { try CloudSaveSyncCheck.applyChoice(syncChoice, report: report, appFolder: folder, now: now) }
        }.value

        guard cloudCheckGeneration == pending.generation,
              entry(pending.game.titleID)?.manifest == pending.game.manifest else {
            return
        }

        switch choiceResult {
        case .failure(let error):
            if deepLinkCloudPending {
                let errorURL = pendingDeepLinkErrorURL
                pendingDeepLinkSuccessURL = nil
                pendingDeepLinkErrorURL = nil
                deepLinkCloudPending = false
                if let errorURL {
                    config.openURL(DeepLinkRouter.errorCallbackURL(base: errorURL, message: error.localizedDescription))
                } else {
                    notice = error.localizedDescription
                }
            } else {
                notice = error.localizedDescription
            }
        case .success(let env):
            var game = pending.game
            for (k, v) in env {
                game.environment[k] = v
            }
            startBackupScan()
            await backupScanTask?.value
            let wasDeepLink = deepLinkCloudPending
            let errorURL = pendingDeepLinkErrorURL
            deepLinkCloudPending = false
            if case .failed(let failure) = await finishLaunch(game, expectedGeneration: pending.generation, suppressNotice: wasDeepLink && errorURL != nil), wasDeepLink {
                pendingDeepLinkSuccessURL = nil
                pendingDeepLinkErrorURL = nil
                if let errorURL {
                    config.openURL(DeepLinkRouter.errorCallbackURL(base: errorURL, message: failure))
                }
            }
        }
    }

    public func restoreLatestSaveBackup(_ id: String) {
        Task { await restoreLatestSaveBackupNow(id) }
    }

    func restoreLatestSaveBackupNow(_ id: String) async {
        guard !launchingGame, entry(id) != nil else { return }
        cloudCheckGeneration &+= 1
        let checkGeneration = cloudCheckGeneration
        let folder = appFolder(for: id)
        let now = config.now()
        let result = await Task.detached(priority: .userInitiated) { () -> CloudSaveSyncCheck.BackupInfo? in
            try? CloudSaveSyncCheck.restoreLatestBackup(in: folder, now: now)
        }.value
        guard cloudCheckGeneration == checkGeneration, entry(id) != nil else { return }
        guard let restored = result else {
            notice = hostText("The save backup could not be restored.")
            return
        }
        startBackupScan()
        await backupScanTask?.value
        refresh(id)
        notice = hostText("Restored the save backup from \(restored.label). Your previous save was backed up first.")
    }

    private enum FinishLaunchOutcome {
        case launched
        case cancelled
        case failed(String)
    }

    private func isLaunchStillValid(_ game: LaunchableGame, expectedGeneration: UInt64) -> Bool {
        cloudCheckGeneration == expectedGeneration
            && !stoppingRunningGame
            && entry(game.titleID)?.manifest == game.manifest
    }

    private func finishLaunch(_ baseGame: LaunchableGame, expectedGeneration: UInt64, suppressNotice: Bool = false) async -> FinishLaunchOutcome {
        var game = baseGame
        // Remembered when Play is triggered, even if the launcher then fails (the stub). The order changes at the next load.
        LastPlayedStore(defaults: config.defaults(game.titleID)).record(config.now())
        refresh(game.titleID)
        do {
            let hotRoot = config.hotFrameworksRoot
            let isHotExternal = hotRoot.map { MachOLocalSigner.isInsideAllowedRoot(game.frameworkURL, allowedRoot: $0) } ?? false
            var usedCachedReceipt = false

            if let hotRoot, isHotExternal {
                guard config.supportsHotFrameworkLoading() else {
                    throw HotFrameworkUnsupportedError(
                        message: hostText("This app signature does not support loading games from Documents/Frameworks. Reinstall the app from NX2Apple on your computer.")
                    )
                }
                let fwURL = game.frameworkURL
                let hostID = config.hostBundleID()
                let store = sideloadCertificateStore
                let clock = config.now
                usedCachedReceipt = try await Task.detached(priority: .userInitiated) { () throws -> Bool in
                    guard store.hasCertificate else { return false }
                    let didSign = try MachOLocalSigner.ensureSignedIfNeeded(
                        frameworkURL: fwURL,
                        allowedRoot: hotRoot,
                        hostBundleID: hostID,
                        store: store,
                        now: clock()
                    )
                    return !didSign
                }.value
                guard isLaunchStillValid(game, expectedGeneration: expectedGeneration) else {
                    return .cancelled
                }
            }

            game.shaderResourcesURL = try await ShaderResources.shared.prepare(game)
            guard isLaunchStillValid(game, expectedGeneration: expectedGeneration) else {
                return .cancelled
            }

            let launchCheatsStore = GameCheatsStore(titleID: game.titleID, appFolder: game.appFolder, frameworkURL: game.frameworkURL)
            await Task.detached(priority: .userInitiated) {
                launchCheatsStore.seedBundledCheatsIfNeeded()
            }.value
            guard isLaunchStillValid(game, expectedGeneration: expectedGeneration) else {
                return .cancelled
            }

            do {
                try await launcher.launch(game)
                recordSessionDidStart(for: game)
                return .launched
            } catch let launchError {
                // If an external framework skipped signing via a cached `.nx-local-sign.json` receipt and then failed
                // to launch (e.g. modified bundle resources or iOS `sigRefused`), clear the stale receipt, force a
                // fresh-inode re-sign once, and retry launch so the player is never stuck in a receipt deadlock.
                guard usedCachedReceipt, let hotRoot, isHotExternal else {
                    throw launchError
                }
                let fwURL = game.frameworkURL
                let hostID = config.hostBundleID()
                let store = sideloadCertificateStore
                let clock = config.now
                let didForceSign = try await Task.detached(priority: .userInitiated) { () throws -> Bool in
                    MachOLocalSigner.removeReceipt(for: fwURL)
                    guard store.hasCertificate else { return false }
                    let identity = try store.loadIdentity()
                    _ = try MachOLocalSigner.signFramework(
                        at: fwURL,
                        allowedRoot: hotRoot,
                        identity: identity,
                        hostBundleID: hostID,
                        now: clock()
                    )
                    return true
                }.value
                guard isLaunchStillValid(game, expectedGeneration: expectedGeneration) else {
                    return .cancelled
                }
                guard didForceSign else {
                    throw launchError
                }
                do {
                    try await launcher.launch(game)
                    recordSessionDidStart(for: game)
                    return .launched
                } catch {
                    // Keep the receipt cleared after a failed retry so the next attempt can recover cleanly.
                    MachOLocalSigner.removeReceipt(for: fwURL)
                    throw error
                }
            }
        } catch {
            guard isLaunchStillValid(game, expectedGeneration: expectedGeneration) else {
                return .cancelled
            }
            if !suppressNotice {
                notice = error.localizedDescription
            }
            return .failed(error.localizedDescription)
        }
    }

    static func formatByteSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: max(0, bytes))
    }

    private static func formatSaveDate(_ date: Date?) -> String {
        guard let date else { return "" }
        let locale: Locale
        if let code = HostStrings.captureBundle?.bundleURL.deletingPathExtension().lastPathComponent, !code.isEmpty {
            locale = Locale(identifier: code)
        } else {
            locale = .autoupdatingCurrent
        }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale))
    }

    /// The right-stick hint's words: a few, no semicolon, short enough for the right third of a small phone.
    static var touchHint: String { hostText("Right stick: drag here") }

    /// Shown once below the gear button when a physical controller is connected, fading with the button.
    static var padQuitHint: String { hostText("Hold {-} and {+} to quit") }

    /// DM_HOME_QUIT_TEXT: the game's quit prompt in the player's language, one text per line in the engine's order (home_quit.h): the hold
    /// indicator, the title with the game's name, the note, Quit and Cancel. The engine draws it when Quit is picked in the in-game menu (the gear)
    /// or Home is held. The menu item reads the title without its question mark.
    static func quitPromptText(gameName: String) -> String {
        [hostText("Keep holding to quit"), hostText("Quit \(gameName)?"),
         hostText("Unsaved progress will be lost. You will return to your games."), hostText("Quit"), hostText("Cancel")]
            .map { $0.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n")
    }

    /// DM_GAME_MENU_TEXT: the in-game menu's own words in the player's language, one per line in the engine's order (GameMenu.swift):
    /// title, Controller layout, Tap layout, Set in env.txt, and "%@, set in env.txt".
    static var gameMenuText: String {
        let currentEnvTemplate = HostStrings.bundle.localizedString(forKey: "%@, set in env.txt", value: "%@, set in env.txt", table: nil)
        return [hostText("More settings on the start screen"),
                hostText("Controller layout"),
                hostText("Tap"),
                hostText("Set in env.txt"),
                currentEnvTemplate]
            .map { $0.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n")
    }

    /// A game's values for the engine: its own choices, then the shell's defaults. A game whose settings list has no
    /// performance overlay row still gets the shell's choice.
    func launchEnvironment(profile: LauncherProfile, id: String) -> [String: String] {
        let shellDefaults = shellSettings.gameDefaults
        let envOverrides = gameEnvOverrides(for: id)
        let store = GameSettingsStore(profile: profile, defaults: config.defaults(id), shell: shellDefaults, envFile: envOverrides)
        var env = store.values()
        for (key, value) in shellDefaults where env[key] == nil {
            if key == "DM_TOUCH_SIZE_PORTRAIT",
               let touchSize = profile.settings.first(where: { $0.env == "DM_TOUCH_SIZE" }),
               !store.isFromShell(touchSize),
               envOverrides["DM_TOUCH_SIZE_PORTRAIT"] == nil {
                continue
            }
            if key == "DM_TOUCH_STICK_PORTRAIT",
               let touchStick = profile.settings.first(where: { $0.env == "DM_TOUCH_STICK" }),
               !store.isFromShell(touchStick),
               envOverrides["DM_TOUCH_STICK_PORTRAIT"] == nil {
                continue
            }
            env[key] = value
        }
        // The words the engine shows once per launch where the 3D layout's undrawn right stick is (patch 0067), in the player's language.
        env["DM_TOUCH_HINT"] = Self.touchHint
        // Shown once below the gear button while a physical controller is connected, in the player's language.
        env["DM_PAD_QUIT_HINT"] = Self.padQuitHint
        // The quit prompt's words (patch 0068), as the Mac launcher passes them for its Home button prompt.
        env["DM_HOME_QUIT_TEXT"] = Self.quitPromptText(gameName: entry(id)?.title ?? id)
        // The in-game menu's own words (patch 0124), as the Mac's build bakes them into a game's own app.
        env["DM_GAME_MENU_TEXT"] = Self.gameMenuText
        if let cheatsMenuText = ShellCheatsMenuText.encode() {
            env["DM_CHEATS_MENU_TEXT"] = cheatsMenuText
        }
        if let shellMenu = ShellInGameMenu.encode(profile: profile, titleID: id, shellDefaults: shellSettings.gameDefaults, envFileOverrides: envOverrides) {
            env["DM_SHELL_MENU"] = shellMenu
        }
        // A launcher.json DM_PAD_MAP row is authoritative, including an empty value.
        if !profile.settings.contains(where: { $0.env == "DM_PAD_MAP" }) {
            env["DM_PAD_MAP"] = PadMap.merged(global: shellSettings.padMap,
                                            game: GamePadMapStore(defaults: config.defaults(id)).entries).envValue
        }
        return env
    }

    func launchShellFallbackKeys(profile: LauncherProfile, id: String) -> Set<String> {
        let store = makeSettingsStore(for: id, profile: profile)
        var keys = Set(profile.settings.filter { store.isFromShell($0) }.map(\.env))
        let profileEnvs = Set(profile.settings.map(\.env))
        for key in shellSettings.gameDefaults.keys where !profileEnvs.contains(key) {
            keys.insert(key)
        }
        return keys
    }

    func launchBuiltInDefaultKeys(profile: LauncherProfile, id: String) -> Set<String> {
        let store = makeSettingsStore(for: id, profile: profile)
        return Set(profile.settings.filter { !store.hasExplicitChoice($0) && !store.isFromShell($0) }.map(\.env))
    }

    // MARK: Controllers

    /// Starts reading GameController: the connected controllers become `controllers`, their buttons `input`.
    public func startControllers() {
        adapter.onInput = { [weak self] action, device in
            guard let self, !self.launchingGame else { return }
            self.input.append(action, device: device)
        }
        // Releases go on while a game launches: a button pressed before it still comes up for the echo window.
        adapter.onRelease = { [weak self] action, device in self?.input.append(action, device: device, released: true) }
        adapter.onControllersChange = { [weak self] connected in
            self?.controllers = connected.map(Self.info(for:))
        }
        adapter.start()
    }

    public func stopControllers() { adapter.stop() }

    /// True on iOS 27+ when a controller is connected and Home Button Override has not yet been deferred to the app.
    public var canOpenHomeButtonSettings: Bool {
        #if os(iOS)
        if #available(iOS 27.0, *), !controllers.isEmpty,
           let status = try? GCControllerHomeButtonSettingsManager().controllerHomeButtonInAppAction {
            return status.action != .defer && status.action != .unavailable
        }
        #endif
        return false
    }

    /// Opens the system Game Controller Home Button Override screen (or falls back to app settings).
    public func openHomeButtonSettings() {
        #if os(iOS)
        if #available(iOS 27.0, *) {
            do {
                try GCControllerHomeButtonSettingsManager().openControllerHomeButtonSettings(for: .customizeInAppAction)
                return
            } catch {}
        }
        if let url = URL(string: UIApplication.openSettingsURLString) {
            config.openURL(url)
        }
        #endif
    }

    /// The button test opened or closed: the adapter reports every controller state in between.
    public func buttonTest(_ open: Bool) {
        adapter.onSnapshot = open ? { [weak self] in self?.padSnapshot = $0 } : nil
        if !open { padSnapshot = nil }
    }

    static func info(for c: ConnectedController) -> ControllerInfo {
        ControllerInfo(id: c.id, name: c.name, player: hostText("Player \(c.player)"), batteryPercent: c.batteryPercent, charging: c.charging)
    }
}

private struct HotFrameworkUnsupportedError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
