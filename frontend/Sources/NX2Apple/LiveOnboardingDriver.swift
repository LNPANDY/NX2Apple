import AppKit
import Combine
import NXCore
import NXModel
import NXLauncher

/// UserDefaults keys of the guided setup. `platform` is also read by `LauncherStores.needsIOSPlatform`.
enum OnboardingDefaults {
    /// An NSPB_ONBOARDING_FORCE run's platform choice, in memory only (nothing is stored until it finishes).
    static var sessionPlatform: String?
    static let completed = "onboarding.completed"
    static let step = "onboarding.step"
    static let platform = "onboarding.platform"
    static let keysSkipped = "onboarding.keysSkipped"
    static let inProgress = "onboarding.inProgress"

    /// A selection made in the main window supersedes an earlier skip, even if its drive is currently disconnected.
    static func resumeKeysSkip(in defaults: UserDefaults, keysSlotIsEmpty: Bool) -> Bool {
        guard defaults.bool(forKey: keysSkipped) else { return false }
        if keysSlotIsEmpty { return true }
        defaults.removeObject(forKey: keysSkipped)
        return false
    }
}

/// What `xcode-select`, `xcodebuild -license check` and `-checkFirstLaunchStatus` say, without anything of the machine's
/// other state. License and first launch only count while an Xcode (not the Command Line Tools) is selected.
struct XcodeProbe: Equatable {
    var appPath: String?            // an Xcode.app: the selected one, else the first in /Applications
    var selectedAppUnavailable = false
    var selectedIsXcode = false     // `xcode-select -p` points into an Xcode.app, not the Command Line Tools
    var licenseAccepted = false
    var firstLaunchDone = false
    var version: String?            // from `xcodebuild -version` of appPath ("27.2"); nil when unreadable
    var developerDir: String? { appPath.map { $0 + "/Contents/Developer" } }
    var needsAdmin: Bool { !(selectedIsXcode && licenseAccepted && firstLaunchDone) }
}

enum AdminResult: Equatable { case ok, cancelled, failed(String) }

/// Everything the driver does to the machine, injectable: tests give fakes, so none of them runs xcodebuild, sudo or a network.
struct OnboardingEnvironment {
    var defaults: UserDefaults = .standard
    var home = NSHomeDirectory()
    var freeBytes: () -> Int64? = { OnboardingEnvironment.homeVolumeFreeBytes() }
    var osVersion: () -> OperatingSystemVersion = { ProcessInfo.processInfo.operatingSystemVersion }
    /// Whether a working Xcode is there, for the poll while the App Store installs it: `xcodebuild -version` must exit 0,
    /// because the App Store creates Xcode.app while it is still downloading. Runs off the main thread.
    var xcodeInstalled: () async -> Bool = { await Task.detached { OnboardingEnvironment.xcodeApps().first != nil }.value }
    /// Only whether an Xcode*.app folder exists (no process): the Welcome estimate reads it.
    var xcodeFolderExists: () -> Bool = { XcodeSelection.app().map(XcodeSelection.isXcode) ?? (OnboardingEnvironment.xcodeFolders().first != nil) }
    var xcodeProbe: () async -> XcodeProbe = { await OnboardingEnvironment.liveProbe() }
    /// One administrator prompt around the whole script (`OnboardingAdmin.source`).
    var runAdmin: (_ developerDir: String) async -> AdminResult = { await OnboardingAdmin.run(developerDir: $0) }
    /// A tool without administrator rights; `line` gets its output as it comes. Returns success and the combined output.
    var run: (_ command: [String], _ line: @escaping (String) -> Void) async -> (ok: Bool, output: String) = { await OnboardingEnvironment.liveRun($0, $1) }
    /// Detection again, finished when it has published (`DependencyStore.check`).
    var detectDeps: (DependencyStore) async -> Void = { await $0.refreshDepsAndWait() }
    /// One install through the launcher's own mechanics (`DependencyStore.install`); its end shows as a new detection.
    var installDep: (DependencyStore, Dep) -> Void = { dependencies, d in MainActor.assumeIsolated { _ = dependencies.install(d) } }
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    private var customKeyCheck: ((_ keys: String, _ base: String) async -> KeyCheck.Outcome)?
    var keyCheck: (_ keys: String, _ base: String) async -> KeyCheck.Outcome {
        get {
            if let customKeyCheck { return customKeyCheck }
            return { keys, base in
                await Task.detached { KeyCheck.run(KeyCheck.Inputs(keys: keys, files: base.isEmpty ? [] : [base])) }.value
            }
        }
        set {
            customKeyCheck = newValue
        }
    }
    var keyCheckFiles: ((_ keys: String, _ files: [String]) async -> KeyCheck.DetailedOutcome)?

    func checkKeys(_ keys: String, files: [String]) async -> KeyCheck.DetailedOutcome {
        if let keyCheckFiles {
            return await keyCheckFiles(keys, files)
        }
        if let customKeyCheck {
            let outcome = await customKeyCheck(keys, files.first ?? "")
            return KeyCheck.DetailedOutcome(outcome: outcome, file: files.dropFirst().first { !$0.isEmpty }.map { ($0 as NSString).lastPathComponent })
        }
        return await Task.detached { KeyCheck.runDetailed(KeyCheck.Inputs(keys: keys, files: files)) }.value
    }
    var scanGames: (_ folder: URL, _ repo: String, _ keys: String) async -> [LibraryGame] = { folder, repo, keys in
        await Task.detached { GameLibrary.sourceGames(in: folder, repo: repo, headerKey: PackageTitleID.headerKey(keysFile: keys)) }.value
    }
    var fetchArtwork: (_ titleIDs: [String]) async -> Void = { ids in _ = await ArtworkStore.shared.fetchMissing(ids, language: Lang.initial().code) }
    var pollInterval = 3.0
    var advanceDelay = 0.7

    /// The files `~/.switch/prod.keys`, `~/Downloads/prod.keys` and the games folder's, whichever exist.
    func keyCandidates(gamesFolder: String) -> [String] {
        var paths = [home + "/.switch/prod.keys", home + "/Downloads/prod.keys"]
        if !gamesFolder.isEmpty { paths += [gamesFolder + "/prod.keys", gamesFolder + "/keys/prod.keys"] }
        return paths.filter { FileManager.default.fileExists(atPath: $0) }
    }

    static func homeVolumeFreeBytes() -> Int64? {
        BuildSpace.available(at: NSHomeDirectory())
    }

    static func xcodeFolders(in directory: String = "/Applications") -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }.sorted().map { directory + "/" + $0 }
    }

    /// Xcode*.app that really work: the App Store creates the folder while Xcode is still downloading, so only an
    /// `xcodebuild -version` that exits 0 counts.
    static func xcodeApps(in directory: String = "/Applications") -> [String] {
        xcodeFolders(in: directory).filter { Toolchain.runOK($0 + "/Contents/Developer/usr/bin/xcodebuild", ["-version"]) }
    }

    static func liveProbe(defaults: UserDefaults = .standard) async -> XcodeProbe {
        await Task.detached {
            var probe = XcodeProbe()
            if let app = XcodeSelection.app(in: defaults), !XcodeSelection.isXcode(app) {
                probe.selectedAppUnavailable = true
                return probe
            }
            let runner = SystemProcessRunner(defaults: defaults)
            let selected = runner.output("/usr/bin/xcode-select", ["-p"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if selected.hasSuffix(".app/Contents/Developer") {
                probe.selectedIsXcode = true
                probe.appPath = String(selected.dropLast("/Contents/Developer".count))
            } else if XcodeSelection.app(in: defaults) == nil { probe.appPath = xcodeApps().first }
            if let dir = probe.developerDir {
                if let text = runner.output("/usr/bin/xcodebuild", ["-version"], env: ["DEVELOPER_DIR": dir, "PATH": "/usr/bin:/bin"]) {
                    probe.version = OnboardingNVN.xcodeVersion(from: text)
                }
            }
            if probe.selectedIsXcode {
                probe.licenseAccepted = runner.runOK("/usr/bin/xcodebuild", ["-license", "check"])
                probe.firstLaunchDone = runner.runOK("/usr/bin/xcodebuild", ["-checkFirstLaunchStatus"])
            }
            return probe
        }.value
    }

    static func liveRun(_ command: [String], _ line: @escaping (String) -> Void) async -> (ok: Bool, output: String) {
        await Task.detached {
            final class Box: @unchecked Sendable {
                private let lock = NSLock(); private var buffer = ""
                func add(_ l: String) { lock.lock(); buffer += l + "\n"; lock.unlock() }
                var text: String { lock.lock(); defer { lock.unlock() }; return buffer }
            }
            let box = Box()
            let ok = SystemProcessRunner().runCaptured(command, env: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "USER": NSUserName()]) { l in
                box.add(l)
                line(l)
            }
            return (ok, box.text)
        }.value
    }
}

/// The one administrator prompt: select Xcode, accept its license, run its first-launch install.
enum OnboardingAdmin {
    /// AppleScript for `do shell script ... with administrator privileges`. The Xcode path goes through AppleScript's own
    /// `quoted form of`, so a space or a quote in it cannot break out of the command.
    static func source(developerDir: String) -> String {
        let literal = developerDir.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"/usr/bin/xcode-select -s \" & quoted form of \"\(literal)\" "
            + "& \" && /usr/bin/xcodebuild -license accept && /usr/bin/xcodebuild -runFirstLaunch\" with administrator privileges"
    }

    /// osascript's exit status and stderr as a result: -128 is the person cancelling the password prompt.
    static func result(status: Int32, stderr: String) -> AdminResult {
        if status == 0 { return .ok }
        if stderr.contains("(-128)") { return .cancelled }
        return .failed(stderr)
    }

    /// Runs the script with `/usr/bin/osascript` as a child process, off the main thread (NSAppleScript is not thread-safe).
    /// The script is one argument, so the path is never interpolated into a shell command line of ours.
    static func run(developerDir: String) async -> AdminResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", source(developerDir: developerDir)]
                let err = Pipe()
                p.standardError = err; p.standardOutput = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { return continuation.resume(returning: .failed(error.localizedDescription)) }
                let data = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                continuation.resume(returning: result(status: p.terminationStatus, stderr: String(data: data, encoding: .utf8) ?? ""))
            }
        }
    }
}

extension DependencyStore {
    /// `DependencyStore.check()`, finished: returns once the new detection has been published.
    func refreshDepsAndWait() async {
        await check().value
    }
}

/// What the app does on launch, and from where the launcher asks for the setup again.
enum OnboardingLaunch {
    /// Setup counts as complete when the tools are all present, a keys file is known and a games folder is set. A player
    /// who has built a game already has all three in effect.
    static func setupComplete(depsPresent: Bool, keysKnown: Bool, gamesKnown: Bool) -> Bool { depsPresent && keysKnown && gamesKnown }
    enum Destination { case launcher, onboarding, forced }

    @MainActor static func decide(defaults: UserDefaults, force: Bool, keysSlotIsEmpty: Bool, setupComplete: () async -> Bool) async -> Destination {
        if force { return .forced }
        if defaults.bool(forKey: OnboardingDefaults.completed) { return .launcher }
        // A discovered file must not complete an explicitly keyless setup behind the player's back.
        if defaults.bool(forKey: OnboardingDefaults.inProgress), OnboardingDefaults.resumeKeysSkip(in: defaults, keysSlotIsEmpty: keysSlotIsEmpty) {
            return .onboarding
        }
        guard await setupComplete() else { return .onboarding }
        defaults.set(true, forKey: OnboardingDefaults.completed)
        defaults.set(false, forKey: OnboardingDefaults.inProgress)
        return .launcher
    }
    static func forced(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool { environment["NSPB_ONBOARDING_FORCE"] == "1" }
}

/// The real driver: the guided setup over the launcher's own `LauncherStores` (detection and installs) and `GameLibrary`.
///
/// One value, `state`, is what the view draws. Detection comes from `stores.dependencies.deps` (refreshed through `stores.dependencies.check`),
/// installs run through `stores.dependencies.install` one at a time, the keys and game slots are the ones the Builds page uses, and
/// the games folder is the library's. Nothing about prod.keys' content is kept: the keys are checked by `KeyCheck`, and
/// only their path is stored.
@MainActor final class LiveOnboardingDriver: OnboardingDriver {
    @Published var state = OnboardingState()
    let stores: LauncherStores
    var model: BuildStore { stores.build }
    let library: GameLibrary
    let env: OnboardingEnvironment
    /// Called once when the setup closes: to the launcher, either way.
    var onExit: (OnboardingState.Exit) -> Void = { _ in }

    var probe = XcodeProbe()
    var probed = false
    var waitingForXcode = false      // Get Xcode was pressed: poll /Applications
    var xcodeBusy = false            // the finish-setup run owns state.xcode
    var backgroundStarted = false
    var failedDeps: [String: OnboardingFailure] = [:]
    var currentInstall: String?
    var sawRecheck = false
    var logMark = 0
    var suppressAdvance = false
    var tasks: [String: Task<Void, Never>] = [:]
    var subscriptions: Set<AnyCancellable> = []
    let ephemeral: Bool
    var installApproved: Bool       // background installs may start (always, except in an ephemeral run before an install action)
    private var pending: [String: Any] = [:]   // an ephemeral run's preference writes, applied by `flush`
    private var pendingTarget: String?
    private var pendingKeys: String?   // an ephemeral run's saved keys (#996): a path to save, "" to forget them, applied by `flush`

    /// A preference write — an ephemeral run holds it back.
    func store(_ value: Any?, _ key: String) {
        if ephemeral {
            pending[key] = value ?? NSNull()
            return
        }
        if let value { env.defaults.set(value, forKey: key) } else { env.defaults.removeObject(forKey: key) }
    }

    /// The held-back writes, once the player finishes or sets up later.
    private func flush() {
        guard ephemeral else { return }
        for (key, value) in pending { if value is NSNull { env.defaults.removeObject(forKey: key) } else { env.defaults.set(value, forKey: key) } }
        pending.removeAll()
        OnboardingDefaults.sessionPlatform = nil
        if let target = pendingTarget {
            model.target = target
            pendingTarget = nil
        }
        if let keys = pendingKeys {
            applyKeys(keys)
            pendingKeys = nil
        }
    }

    /// The keys of every game (Settings, "Keys", #996): a file chosen here is saved, Skip leaves the saved one alone. An ephemeral run holds it back.
    func keepKeys(_ path: String) {
        if ephemeral { pendingKeys = path } else { applyKeys(path) }
    }

    private func applyKeys(_ path: String) {
        if path.isEmpty { model.forgetSavedKeys() } else { model.saveKeys(path) }
    }

    func t(_ key: String) -> String { L10n.string(key, stores.localizer.lang) }

    /// `fresh` ignores a stored step (Run setup again); otherwise a stored, unfinished run resumes where it stopped.
    /// `ephemeral` (NSPB_ONBOARDING_FORCE) starts from Welcome, keeps every preference write in memory until the player finishes
    /// or picks Set up later, and installs nothing until an install action is pressed, so a test leaves no trace.
    init(stores: LauncherStores, library: GameLibrary, env: OnboardingEnvironment = OnboardingEnvironment(), fresh: Bool = false,
         ephemeral: Bool = false) {
        self.stores = stores; self.library = library; self.env = env; self.ephemeral = ephemeral
        installApproved = !ephemeral
        let d = env.defaults
        if ephemeral {
            store(nil, OnboardingDefaults.keysSkipped)
            updateWelcome()
            return
        }
        if fresh {
            d.removeObject(forKey: OnboardingDefaults.step); d.removeObject(forKey: OnboardingDefaults.platform)
            d.removeObject(forKey: OnboardingDefaults.keysSkipped)
            d.set(false, forKey: OnboardingDefaults.inProgress)
        }
        if let raw = d.string(forKey: OnboardingDefaults.platform), let platform = OnboardingPlatform(rawValue: raw) {
            state.platform = .selected(platform)
        }
        if d.bool(forKey: OnboardingDefaults.inProgress), let raw = d.string(forKey: OnboardingDefaults.step),
           let step = OnboardingStep(rawValue: raw) {
            state.step = step
            if OnboardingDefaults.resumeKeysSkip(in: d, keysSlotIsEmpty: model.keysPath.isEmpty) {
                state.keys = .skipped
            } else if step.index > OnboardingStep.keys.index {
                if model.keysReady { state.keys = .valid }   // the row's keys, or the ones saved in Settings
                else { state.step = .keys }
            }
            // A stored step beyond Platform without a platform cannot be right; start from the choice.
            if step.index > OnboardingStep.platform.index && state.selectedPlatform == nil { state.step = .platform }
        }
        updateWelcome()
    }
    deinit { tasks.values.forEach { $0.cancel() } }

    /// Starts watching the model and revalidates the stored step. Called once by whoever shows the view.
    func activate() {
        subscriptions.removeAll()
        stores.dependencies.$checked.removeDuplicates().sink { [weak self] checked in
            guard let self else { return }
            if !checked {
                self.sawRecheck = true
                return
            }
            self.spawn("refresh") { d in await d.modelDidRefresh() }
        }.store(in: &subscriptions)
        bindProgressStreams()
        spawn("activate") { d in
            await d.revalidate()
            d.enter(d.state.step)
        }
    }

    // MARK: Intents

    func start() {
        guard state.step == .welcome, state.exit == nil else { return }
        store(true, OnboardingDefaults.inProgress)
        next()
    }

    func choosePlatform(_ platform: OnboardingPlatform) {
        guard state.step == .platform, state.exit == nil else { return }
        state.platform = .selected(platform)
        store(platform.rawValue, OnboardingDefaults.platform)   // before the detection below reads it
        if ephemeral { OnboardingDefaults.sessionPlatform = platform.rawValue }   // the detection reads it from here
        let target: String? = platform == .mac ? "mac-app" : (platform == .iphone ? "ios" : nil)   // "both" leaves the target as it is
        if let target { if ephemeral { pendingTarget = target } else { model.target = target } }
        updateWelcome()
        backgroundStarted = true
        spawn("platform") { d in
            await d.env.detectDeps(d.stores.dependencies)      // the xcode row's iOS requirement just changed
            await d.modelDidRefresh()
        }
    }

    func getXcode() {
        guard state.step == .xcode, state.xcode == .missing, state.exit == nil else { return }
        installApproved = true
        waitingForXcode = true
        state.xcode = .downloading
        env.openURL(URL(string: "macappstore://apps.apple.com/app/id497799835")!)
        pollForXcode()
    }

    func finishXcodeSetup() {
        guard state.step == .xcode, state.xcode == .needsSetup, state.exit == nil else { return }
        installApproved = true
        state.xcode = .settingUp
        xcodeBusy = true
        spawn("finish") { d in await d.runFinishXcode() }
    }

    func retry(_ step: OnboardingStep) {
        guard state.step == step, state.exit == nil else { return }
        switch step {
        case .xcode:
            installApproved = true
            failedDeps.removeAll()
            if case .failed = state.xcode { state.xcode = .needsSetup }
            xcodeBusy = false
            spawn("retry") { d in
                if d.state.xcode == .disconnected { await d.env.detectDeps(d.stores.dependencies) }
                await d.modelDidRefresh()
            }
        case .keys: enter(.keys)
        case .games: state.games = .empty; enter(.games)
        default: break
        }
    }

    func chooseKeys(_ url: URL) {
        guard state.step == .keys, state.exit == nil else { return }
        validateKeys(url)
    }

    func confirmKeys() {
        guard state.step == .keys, state.exit == nil, case let .found(url) = state.keys else { return }
        validateKeys(url)
    }

    func skipKeys() {
        guard state.canSkipKeys else { return }
        model.updateSlot("keys") { $0.paths = []; $0.problem = "" }
        // Skip leaves a keys file that is already saved alone: the keys stay optional here, and Settings holds them (#996)
        state.keys = .skipped
        store(true, OnboardingDefaults.keysSkipped)
        state.games = .empty   // rescan a previously visited folder for a build input that works without keys
        next()
    }

    func chooseGames(_ url: URL) {
        guard state.step == .games, state.exit == nil else { return }
        state.games = .scanning
        spawn("games") { d in await d.scanGames(url) }
    }

    func back() {
        let old = state.step
        state.back()
        guard old != state.step else { return }
        suppressAdvance = true   // a step left behind stays reachable: Back must not bounce forward again
        enter(state.step)
    }

    func next() {
        let old = state.step
        state.next()
        guard old != state.step else { return }
        suppressAdvance = false
        enter(state.step)
    }

    func skipForLater() {
        guard state.exit == nil else { return }
        persistStep()
        store(true, OnboardingDefaults.inProgress)
        flush()
        close(.later)
    }

    func openLibrary() {
        guard state.step == .done, state.primaryEnabled else { return }
        store(true, OnboardingDefaults.completed)
        store(false, OnboardingDefaults.inProgress)
        store(nil, OnboardingDefaults.step)
        store(nil, OnboardingDefaults.keysSkipped)
        flush()
        if library.selectedID == nil { library.selectedID = library.games.first?.id }
        close(.library)
    }

    private func close(_ exit: OnboardingState.Exit) {
        state.exit = exit
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        subscriptions.removeAll()
        onExit(exit)
    }

    // MARK: Steps

    /// Waits for the work started so far (tests, the view never needs it).
    func settle() async {
        for _ in 0..<6 { for task in Array(tasks.values) { await task.value } }
    }

    func persistStep() { store(state.step.rawValue, OnboardingDefaults.step) }

    func spawn(_ name: String, _ body: @escaping (LiveOnboardingDriver) async -> Void) {
        tasks[name]?.cancel()
        tasks[name] = Task { @MainActor [weak self] in
            guard let self, self.state.exit == nil else { return }
            await body(self)
        }
    }

    func enter(_ step: OnboardingStep) {
        guard state.exit == nil else { return }
        persistStep()
        if step != .xcode { tasks["poll"]?.cancel(); tasks["poll"] = nil }   // the Xcode poll stops when its step is left
        switch step {
        case .welcome: updateWelcome()
        case .platform: break
        case .xcode:
            if state.selectedPlatform != nil { backgroundStarted = true }
            if waitingForXcode { pollForXcode() }
            spawn("enter.xcode") { d in
                if !d.stores.dependencies.checked { await d.env.detectDeps(d.stores.dependencies) }
                await d.modelDidRefresh()
            }
        case .keys:
            guard state.keys != .skipped else { return }
            state.keys = .searching
            spawn("enter.keys") { d in await d.searchKeys() }
        case .games:
            spawn("enter.games") { d in await d.enterGames() }
        case .done:
            if state.done == .celebrating {
                spawn("done") { d in
                    try? await Task.sleep(nanoseconds: UInt64(d.env.advanceDelay * 0.5 * 1_000_000_000))
                    d.state.done = .ready
                }
            }
        }
    }

    /// A stored step past Xcode is only kept while Xcode and the tools still hold; otherwise the player returns to Xcode.
    func revalidate() async {
        guard state.step.index > OnboardingStep.xcode.index else { return }
        if !stores.dependencies.checked { await env.detectDeps(stores.dependencies) }
        probe = await env.xcodeProbe(); probed = true
        let (xcode, _) = OnboardingXcode.evaluate(probe: probe, metalReady: dep("metal")?.present ?? false,
                                                  iosReady: dep("xcode")?.present ?? false, includesIOS: state.selectedPlatform?.includesIOS == true)
        if xcode != .ready { state.step = .xcode; persistStep() }
        updateWelcome()
    }

    // MARK: Welcome

    /// Rough room the setup takes, not a measurement: Xcode when it is missing (about 3 GB to download, about 12 GB installed,
    /// and the room twice over while it unpacks: 15), the Metal Toolchain (about 1), the iOS platform when the player plays
    /// on an iPhone (about 8, as the Platform step says), and the tools, Python packages, .NET SDK and caches (about 4).
    /// Platform is not chosen yet at Welcome, so it counts the Mac only; choosePlatform computes it again.
    nonisolated static func neededGB(xcodeMissing: Bool, includesIOS: Bool) -> Int {
        (xcodeMissing ? 15 : 0) + 1 + (includesIOS ? 8 : 0) + 4
    }

    func updateWelcome() {
        let needed = Self.neededGB(xcodeMissing: probed ? probe.appPath == nil : !env.xcodeFolderExists(),
                                   includesIOS: state.selectedPlatform?.includesIOS == true)
        // Whole GB as Finder counts them (10^9). Without a reading the volume is taken to have room: nothing to warn about.
        let free = env.freeBytes().map { Int($0 / 1_000_000_000) } ?? needed
        state.welcome = .requirements(freeGB: free, neededGB: needed)
        state.osTooOldForNVN = OnboardingNVN.osTooOld(env.osVersion())
        state.xcodeTooOldForNVN = probed && probe.appPath != nil && OnboardingNVN.xcodeTooOld(probe.version)
    }

    // MARK: Xcode

    func dep(_ id: String) -> Dep? { stores.dependencies.deps.first { $0.id == id } }

    /// Every detection that finished: Xcode's state, the background tasks, and the next install.
    func modelDidRefresh() async {
        guard stores.dependencies.checked, state.exit == nil else { return }
        concludeInstall()
        await refreshXcode()
        recomputeBackground()
        pumpInstalls()
        advanceIfReady()
    }

    func refreshXcode() async {
        guard !xcodeBusy else { return }
        probe = await env.xcodeProbe(); probed = true
        guard !xcodeBusy, state.exit == nil else { return }
        let includesIOS = state.selectedPlatform?.includesIOS == true
        let (xcode, setup) = OnboardingXcode.evaluate(probe: probe, metalReady: dep("metal")?.present ?? false,
                                                      iosReady: dep("xcode")?.present ?? false, includesIOS: includesIOS)
        state.setup = setup
        if case .failed = state.xcode, xcode != .ready && xcode != .disconnected { return }   // a failure stays until Retry
        if xcode == .missing {
            state.xcode = waitingForXcode ? .downloading : .missing
        } else {
            waitingForXcode = false
            state.xcode = xcode
        }
        updateWelcome()
    }

    /// Looks for an Xcode every few seconds, cheaply (a folder listing), until one is there or the step is left.
    private func pollForXcode() {
        spawn("poll") { d in
            while !Task.isCancelled, d.state.step == .xcode, d.state.exit == nil {
                try? await Task.sleep(nanoseconds: UInt64(d.env.pollInterval * 1_000_000_000))
                if Task.isCancelled { return }
                if await d.env.xcodeInstalled() {
                    d.waitingForXcode = false
                    await d.refreshXcode()
                    d.advanceIfReady()
                    return
                }
            }
        }
    }

    func runFinishXcode() async {
        defer { xcodeBusy = false }
        let includesIOS = state.selectedPlatform?.includesIOS == true
        func fail(_ key: String, _ details: String) {
            state.xcode = .failed(OnboardingFailure(message: t(key), details: Self.tail(details)))
        }
        if probe.needsAdmin {
            // The normal admin script switches the system Xcode. Let a launcher-only Xcode finish its own first launch.
            if let app = stores.dependencies.xcodeApp {
                if XcodeSelection.isXcode(app) { env.openURL(URL(fileURLWithPath: app)) }
                return fail("xcodeChoice.finishSetup", app)
            }
            guard let dir = probe.developerDir else { return fail("onboarding.error.xcode", "No Xcode.app was found.") }
            for task in [OnboardingSetupTask.selected, .license, .firstLaunch] where state.setup[task] != .done { state.setup[task] = .running(nil) }
            switch await env.runAdmin(dir) {
            case .ok: break
            case .cancelled:   // not an error: the player said no to the password prompt
                xcodeBusy = false
                state.xcode = .needsSetup
                for task in [OnboardingSetupTask.selected, .license, .firstLaunch] where state.setup[task] != .done { state.setup[task] = .queued }
                return
            case let .failed(output): return fail("onboarding.error.xcode", output)
            }
            probe = await env.xcodeProbe()
            for task in [OnboardingSetupTask.selected, .license, .firstLaunch] { state.setup[task] = .done }
            await env.detectDeps(stores.dependencies)   // with Xcode selected, the Metal and iOS rows read differently
        }
        let metalMissing = !(dep("metal")?.present ?? false)
        if metalMissing {
            let r = await download(.metal, Toolchain.metalToolchainCmd)
            if !r.ok { return fail("onboarding.error.metal", r.output) }
        }
        let iosMissing = includesIOS && !(dep("xcode")?.present ?? false)
        if iosMissing {
            let r = await download(.ios, Toolchain.iosPlatformCmd)
            if !r.ok { return fail("onboarding.error.ios", r.output) }
        }
        await env.detectDeps(stores.dependencies)
        xcodeBusy = false
        await refreshXcode()
        // A download that returned success but left the part missing is a failure, not an endless "set up" loop.
        if state.xcode == .needsSetup { fail("onboarding.error.xcode", "Xcode setup finished but a part is still missing.") }
        await modelDidRefresh()
    }

    private func download(_ task: OnboardingSetupTask, _ command: [String]) async -> (ok: Bool, output: String) {
        state.setup[task] = .running(nil)
        let result = await env.run(command) { [weak self] line in
            guard let fraction = Self.progress(in: line) else { return }
            Task { @MainActor in
                if self?.state.setup[task] != .done { self?.state.setup[task] = .running(fraction) }
            }
        }
        if result.ok { state.setup[task] = .done }
        return result
    }

    /// The last percentage in a line of `xcodebuild -download…` output ("Downloading … 45.3% …"), as a fraction.
    nonisolated static func progress(in text: String) -> Double? {
        guard let re = try? NSRegularExpression(pattern: #"(\d{1,3}(?:\.\d+)?)\s*%"#) else { return nil }
        let ns = text as NSString
        guard let m = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).last,
              let n = Double(ns.substring(with: m.range(at: 1))) else { return nil }
        return min(max(n / 100, 0), 1)
    }

    /// Command output for the diagnostics, trimmed to its end.
    nonisolated static func tail(_ text: String, limit: Int = 4000) -> String {
        text.count <= limit ? text : "…" + text.suffix(limit)
    }
}

/// The Xcode step's states from what was probed: a pure function, so the mapping is tested without a machine.
enum OnboardingXcode {
    static func evaluate(probe: XcodeProbe, metalReady: Bool, iosReady: Bool, includesIOS: Bool)
        -> (xcode: OnboardingState.Xcode, setup: [OnboardingSetupTask: OnboardingTaskState]) {
        if probe.selectedAppUnavailable { return (.disconnected, [:]) }
        guard probe.appPath != nil else { return (.missing, [:]) }
        var setup: [OnboardingSetupTask: OnboardingTaskState] = [
            .selected: probe.selectedIsXcode ? .done : .queued,
            .license: probe.selectedIsXcode && probe.licenseAccepted ? .done : .queued,
            .firstLaunch: probe.selectedIsXcode && probe.firstLaunchDone ? .done : .queued,
            .metal: metalReady ? .done : .queued,
        ]
        if includesIOS { setup[.ios] = iosReady ? .done : .queued }
        // A missing download counts like the three admin steps: Finish setup does all of it.
        return (setup.values.allSatisfy(\.isDone) ? .ready : .needsSetup, setup)
    }
}
