import AppKit
import Combine

/// UserDefaults keys of the guided setup. `platform` is also read by `BuildModel.needsIOSPlatform`.
enum OnboardingDefaults {
    /// An NSPB_ONBOARDING_FORCE run's platform choice, in memory only (nothing is stored until it finishes).
    static var sessionPlatform: String?
    static let completed = "onboarding.completed"
    static let step = "onboarding.step"
    static let platform = "onboarding.platform"
    static let inProgress = "onboarding.inProgress"
}

/// What `xcode-select`, `xcodebuild -license check` and `-checkFirstLaunchStatus` say, without anything of the machine's
/// other state. License and first launch only count while an Xcode (not the Command Line Tools) is selected.
struct XcodeProbe: Equatable {
    var appPath: String?            // an Xcode.app: the selected one, else the first in /Applications
    var selectedIsXcode = false     // `xcode-select -p` points into an Xcode.app, not the Command Line Tools
    var licenseAccepted = false
    var firstLaunchDone = false
    var version: String?            // from `xcodebuild -version` of appPath ("27.1"); nil when unreadable
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
    var xcodeFolderExists: () -> Bool = { OnboardingEnvironment.xcodeFolders().first != nil }
    var xcodeProbe: () async -> XcodeProbe = { await OnboardingEnvironment.liveProbe() }
    /// One administrator prompt around the whole script (`OnboardingAdmin.source`).
    var runAdmin: (_ developerDir: String) async -> AdminResult = { await OnboardingAdmin.run(developerDir: $0) }
    /// A tool without administrator rights; `line` gets its output as it comes. Returns success and the combined output.
    var run: (_ command: [String], _ line: @escaping (String) -> Void) async -> (ok: Bool, output: String) = { await OnboardingEnvironment.liveRun($0, $1) }
    /// Detection again, finished when it has published (`BuildModel.checkDeps`).
    var detectDeps: (BuildModel) async -> Void = { await $0.refreshDepsAndWait() }
    /// One install through the launcher's own mechanics (`BuildModel.installDep`); its end shows as a new detection.
    var installDep: (BuildModel, BuildModel.Dep) -> Void = { $0.installDep($1) }
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var keyCheck: (_ keys: String, _ base: String) async -> KeyCheck.Outcome = { keys, base in
        await Task.detached { KeyCheck.run(KeyCheck.Inputs(keys: keys, files: base.isEmpty ? [] : [base])) }.value
    }
    var scanGames: (_ folder: URL, _ repo: String) async -> [LibraryGame] = { folder, repo in
        await Task.detached { GameLibrary.sourceGames(in: folder, repo: repo) }.value
    }
    var fetchArtwork: (_ titleIDs: [String]) async -> Void = { ids in _ = await ArtworkStore.shared.fetchMissing(ids) }
    var pollInterval = 3.0
    var advanceDelay = 0.7

    /// The files `~/.switch/prod.keys`, `~/Downloads/prod.keys` and the games folder's, whichever exist.
    func keyCandidates(gamesFolder: String) -> [String] {
        var paths = [home + "/.switch/prod.keys", home + "/Downloads/prod.keys"]
        if !gamesFolder.isEmpty { paths += [gamesFolder + "/prod.keys", gamesFolder + "/keys/prod.keys"] }
        return paths.filter { FileManager.default.fileExists(atPath: $0) }
    }

    static func homeVolumeFreeBytes() -> Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static func xcodeFolders(in directory: String = "/Applications") -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }.sorted().map { directory + "/" + $0 }
    }

    /// Xcode*.app that really work: the App Store creates the folder while Xcode is still downloading, so only an
    /// `xcodebuild -version` that exits 0 counts.
    static func xcodeApps(in directory: String = "/Applications") -> [String] {
        xcodeFolders(in: directory).filter { BuildModel.runOK($0 + "/Contents/Developer/usr/bin/xcodebuild", ["-version"]) }
    }

    static func liveProbe() async -> XcodeProbe {
        await Task.detached {
            var probe = XcodeProbe()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select"); p.arguments = ["-p"]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            var selected = ""
            if (try? p.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
                if p.terminationStatus == 0 { selected = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            }
            if let r = selected.range(of: ".app/Contents/Developer") {
                probe.selectedIsXcode = true
                probe.appPath = String(selected[..<r.lowerBound]) + ".app"
            } else { probe.appPath = xcodeApps().first }
            if let dir = probe.developerDir {
                let v = Process()
                v.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild"); v.arguments = ["-version"]
                v.environment = ["DEVELOPER_DIR": dir, "PATH": "/usr/bin:/bin"]
                let out = Pipe(); v.standardOutput = out; v.standardError = FileHandle.nullDevice
                if (try? v.run()) != nil {
                    let data = out.fileHandleForReading.readDataToEndOfFile(); v.waitUntilExit()
                    if v.terminationStatus == 0 { probe.version = OnboardingNVN.xcodeVersion(from: String(data: data, encoding: .utf8) ?? "") }
                }
            }
            if probe.selectedIsXcode {
                probe.licenseAccepted = BuildModel.runOK("/usr/bin/xcodebuild", ["-license", "check"])
                probe.firstLaunchDone = BuildModel.runOK("/usr/bin/xcodebuild", ["-checkFirstLaunchStatus"])
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
            let ok = BuildModel.runCaptured(command, env: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "USER": NSUserName()]) { l in
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

extension BuildModel {
    /// `checkDeps()`, finished: returns once the new detection has been published.
    func refreshDepsAndWait() async {
        checkDeps()
        for await checked in $depsChecked.values where checked { break }
    }
}

/// What the app does on launch, and from where the launcher asks for the setup again.
enum OnboardingLaunch {
    /// Setup counts as complete when the tools are all present, a keys file is known and a games folder is set. A player
    /// who has built a game already has all three in effect.
    static func setupComplete(depsPresent: Bool, keysKnown: Bool, gamesKnown: Bool) -> Bool { depsPresent && keysKnown && gamesKnown }
    /// `force` (NSPB_ONBOARDING_FORCE=1) shows it whatever the state.
    static func shouldShow(completed: Bool, setupComplete: Bool, force: Bool = false) -> Bool { force || (!completed && !setupComplete) }
    static func forced(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool { environment["NSPB_ONBOARDING_FORCE"] == "1" }
}

/// The real driver: the guided setup over the launcher's own `BuildModel` (detection and installs) and `GameLibrary`.
///
/// One value, `state`, is what the view draws. Detection comes from `model.deps` (refreshed through `model.checkDeps`),
/// installs run through `model.installDep` one at a time, the keys and game slots are the ones the Builds page uses, and
/// the games folder is the library's. Nothing about prod.keys' content is kept: the keys are checked by `KeyCheck`, and
/// only their path is stored.
@MainActor final class LiveOnboardingDriver: OnboardingDriver {
    @Published private(set) var state = OnboardingState()
    let model: BuildModel
    let library: GameLibrary
    private let env: OnboardingEnvironment
    /// Called once when the setup closes: to the launcher, either way.
    var onExit: (OnboardingState.Exit) -> Void = { _ in }

    private var probe = XcodeProbe()
    private var probed = false
    private var waitingForXcode = false      // Get Xcode was pressed: poll /Applications
    private var xcodeBusy = false            // the finish-setup run owns state.xcode
    private var backgroundStarted = false
    private var failedDeps: [String: OnboardingFailure] = [:]
    private var currentInstall: String?
    private var sawRecheck = false
    private var logMark = 0
    private var suppressAdvance = false
    private var tasks: [String: Task<Void, Never>] = [:]
    private var subscription: AnyCancellable?
    private let ephemeral: Bool
    private var installApproved: Bool       // background installs may start (always, except in an ephemeral run before an install action)
    private var pending: [String: Any] = [:]   // an ephemeral run's preference writes, applied by `flush`
    private var pendingTarget: String?

    /// A preference write; an ephemeral run holds it back.
    private func store(_ value: Any?, _ key: String) {
        if ephemeral { pending[key] = value ?? NSNull(); return }
        if let value { env.defaults.set(value, forKey: key) } else { env.defaults.removeObject(forKey: key) }
    }

    /// The held-back writes, once the player finishes or sets up later.
    private func flush() {
        guard ephemeral else { return }
        for (key, value) in pending { if value is NSNull { env.defaults.removeObject(forKey: key) } else { env.defaults.set(value, forKey: key) } }
        pending.removeAll()
        OnboardingDefaults.sessionPlatform = nil
        if let target = pendingTarget { model.target = target; pendingTarget = nil }
    }

    private func t(_ key: String) -> String { L10n.string(key, model.lang) }

    /// `fresh` ignores a stored step (Run setup again); otherwise a stored, unfinished run resumes where it stopped.
    /// `ephemeral` (NSPB_ONBOARDING_FORCE) starts from Welcome, keeps every preference write in memory until the player finishes
    /// or picks Set up later, and installs nothing until an install action is pressed, so a test leaves no trace.
    init(model: BuildModel, library: GameLibrary, env: OnboardingEnvironment = OnboardingEnvironment(), fresh: Bool = false,
         ephemeral: Bool = false) {
        self.model = model; self.library = library; self.env = env; self.ephemeral = ephemeral
        installApproved = !ephemeral
        let d = env.defaults
        if ephemeral {
            updateWelcome()
            return
        }
        if fresh {
            d.removeObject(forKey: OnboardingDefaults.step); d.removeObject(forKey: OnboardingDefaults.platform)
            d.set(false, forKey: OnboardingDefaults.inProgress)
        }
        if let raw = d.string(forKey: OnboardingDefaults.platform), let platform = OnboardingPlatform(rawValue: raw) {
            state.platform = .selected(platform)
        }
        if d.bool(forKey: OnboardingDefaults.inProgress), let raw = d.string(forKey: OnboardingDefaults.step),
           let step = OnboardingStep(rawValue: raw) {
            // A stored step beyond Platform without a platform cannot be right; start from the choice.
            state.step = (step.index > OnboardingStep.platform.index && state.selectedPlatform == nil) ? .platform : step
        }
        updateWelcome()
    }
    deinit { tasks.values.forEach { $0.cancel() } }

    /// Starts watching the model and revalidates the stored step. Called once by whoever shows the view.
    func activate() {
        subscription = model.$depsChecked.removeDuplicates().sink { [weak self] checked in
            guard let self else { return }
            if !checked { self.sawRecheck = true; return }
            self.spawn("refresh") { d in await d.modelDidRefresh() }
        }
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
            await d.env.detectDeps(d.model)      // the xcode row's iOS requirement just changed
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
            spawn("retry") { d in await d.modelDidRefresh() }
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
        flush()
        if library.selectedID == nil { library.selectedID = library.games.first?.id }
        close(.library)
    }

    private func close(_ exit: OnboardingState.Exit) {
        state.exit = exit
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
        subscription = nil
        onExit(exit)
    }

    // MARK: Steps

    /// Waits for the work started so far (tests; the view never needs it).
    func settle() async {
        for _ in 0..<6 { for task in Array(tasks.values) { await task.value } }
    }

    private func persistStep() { store(state.step.rawValue, OnboardingDefaults.step) }

    private func spawn(_ name: String, _ body: @escaping (LiveOnboardingDriver) async -> Void) {
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
                if !d.model.depsChecked { await d.env.detectDeps(d.model) }
                await d.modelDidRefresh()
            }
        case .keys:
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
        if !model.depsChecked { await env.detectDeps(model) }
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

    private func dep(_ id: String) -> BuildModel.Dep? { model.deps.first { $0.id == id } }

    /// Every detection that finished: Xcode's state, the background tasks, and the next install.
    func modelDidRefresh() async {
        guard model.depsChecked, state.exit == nil else { return }
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
        if case .failed = state.xcode, xcode != .ready { return }   // a failure stays until Retry
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
            await env.detectDeps(model)   // with Xcode selected, the Metal and iOS rows read differently
        }
        let metalMissing = !(dep("metal")?.present ?? false)
        if metalMissing {
            let r = await download(.metal, BuildModel.metalToolchainCmd)
            if !r.ok { return fail("onboarding.error.metal", r.output) }
        }
        let iosMissing = includesIOS && !(dep("xcode")?.present ?? false)
        if iosMissing {
            let r = await download(.ios, BuildModel.iosPlatformCmd)
            if !r.ok { return fail("onboarding.error.ios", r.output) }
        }
        await env.detectDeps(model)
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

    // MARK: Background tools

    /// The "tools" card is Homebrew and the brew formulas the build uses: every row that is none of Xcode, Python or .NET.
    private static let handled: Set<String> = ["xcode", "metal", "python", "dotnet"]
    private func deps(for task: OnboardingBackgroundTask) -> [BuildModel.Dep] {
        switch task {
        case .python: return model.deps.filter { $0.id == "python" }
        case .dotnet: return model.deps.filter { $0.id == "dotnet" }
        case .tools: return model.deps.filter { !Self.handled.contains($0.id) }
        }
    }

    func recomputeBackground() {
        guard backgroundStarted, model.depsChecked else { return }
        for task in OnboardingBackgroundTask.allCases {
            let rows = deps(for: task)
            if rows.allSatisfy(\.present) { state.background[task] = .done }
            else if let failure = rows.compactMap({ failedDeps[$0.id] }).first { state.background[task] = .failed(failure) }
            else if rows.contains(where: \.installing) || rows.contains(where: { $0.id == currentInstall }) { state.background[task] = .running(nil) }
            else { state.background[task] = .queued }
        }
    }

    /// One install at a time, in the order Python, .NET, tools. Homebrew and its formulas need Xcode's command line tools,
    /// so they wait for Xcode to be ready; the other two start at once.
    func pumpInstalls() {
        guard installApproved, backgroundStarted, model.depsChecked, currentInstall == nil, state.exit == nil else { return }
        for task in OnboardingBackgroundTask.allCases {
            if task == .tools && state.xcode != .ready { continue }
            guard let next = deps(for: task).first(where: { !$0.present && failedDeps[$0.id] == nil && !$0.installing }) else { continue }
            currentInstall = next.id
            sawRecheck = false
            logMark = model.logTail.count
            env.installDep(model, next)
            recomputeBackground()
            return
        }
    }

    /// An install finished and detection ran again: either its row is present now, or it failed.
    private func concludeInstall() {
        guard let id = currentInstall, sawRecheck else { return }
        currentInstall = nil
        if dep(id)?.present == false {
            let name = dep(id).map { t($0.name) } ?? id
            let output = model.logTail.count >= logMark ? String(model.logTail.dropFirst(logMark)) : model.logTail
            failedDeps[id] = OnboardingFailure(message: String(format: t("dep.install.fail"), name), details: Self.tail(output))
        }
    }

    // MARK: Keys

    func searchKeys() async {
        let known = model.keysPath
        let candidates = ([known].filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) })
            + env.keyCandidates(gamesFolder: library.folder.isEmpty ? model.gameDir : library.folder)
        if let first = candidates.first { state.keys = .found(URL(fileURLWithPath: first)) } else { state.keys = .empty }
    }

    private func validateKeys(_ url: URL) {
        state.keys = .validating
        spawn("keys") { d in
            let scoped = url.startAccessingSecurityScopedResource()   // a no-op outside a sandbox
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let outcome = await d.env.keyCheck(url.path, d.model.basePath)
            guard d.state.exit == nil else { return }
            switch outcome {
            case .fits, .cannotCheck:
                d.model.updateSlot("keys") { $0.paths = [url.path]; $0.problem = "" }
                d.state.keys = .valid
                d.advanceIfReady()
            default:
                d.state.keys = .invalid(KeyCheck.message(outcome, d.t))   // names a key or a file, never a value
            }
        }
    }

    // MARK: Games

    private func enterGames() async {
        let known = library.folder.isEmpty ? model.gameDir : library.folder
        if case .found = state.games { return }
        if !known.isEmpty, FileManager.default.fileExists(atPath: known) { state.games = .scanning; await scanGames(URL(fileURLWithPath: known)) }
        else { state.games = .empty }
    }

    func scanGames(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let found = await env.scanGames(url, model.repoPath)
        guard state.exit == nil else { return }
        guard !found.isEmpty else { state.games = .none; return }
        // The same slots and folder the main UI sets: the Builds page's inputs and the library's games folder.
        let keys = model.keysPath
        model.scan(folder: url.path)
        if !keys.isEmpty { model.updateSlot("keys") { $0.paths = [keys]; $0.problem = "" } }   // the keys the player confirmed stay
        library.setFolder(url)
        if !model.running { model.outDir = url.path }
        state.games = .found(found.map { OnboardingGame(id: $0.titleID, title: $0.name, version: "",
                                                         cover: GameLibrary.artwork(for: $0, repo: model.repoPath)) })
        let ids = found.map(\.titleID)
        spawn("covers") { d in
            await d.env.fetchArtwork(ids)
            guard case .found(var games) = d.state.games else { return }
            for i in games.indices where games[i].cover == nil {
                if let g = found.first(where: { $0.titleID == games[i].id }) { games[i].cover = GameLibrary.artwork(for: g, repo: d.model.repoPath) }
            }
            d.state.games = .found(games)
        }
        // The keys against the game they will open: a mismatch sends the player back to the keys, with the reason.
        if !model.keysPath.isEmpty, !model.basePath.isEmpty {
            let outcome = await env.keyCheck(model.keysPath, model.basePath)
            switch outcome {
            case .fits, .cannotCheck: break
            default:
                state.keys = .invalid(KeyCheck.message(outcome, t))
                state.step = .keys; persistStep()
            }
        }
    }

    // MARK: Advancing

    /// Xcode with its background tasks and the keys move on by themselves after a moment; the games wait for Continue.
    func advanceIfReady() {
        guard !suppressAdvance, state.exit == nil, state.step == .xcode || state.step == .keys, state.canAdvance else { return }
        let step = state.step
        spawn("advance") { d in
            try? await Task.sleep(nanoseconds: UInt64(d.env.advanceDelay * 1_000_000_000))
            if d.state.step == step, !d.suppressAdvance { d.next() }
        }
    }
}

/// The Xcode step's states from what was probed: a pure function, so the mapping is tested without a machine.
enum OnboardingXcode {
    static func evaluate(probe: XcodeProbe, metalReady: Bool, iosReady: Bool, includesIOS: Bool)
        -> (xcode: OnboardingState.Xcode, setup: [OnboardingSetupTask: OnboardingTaskState]) {
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
