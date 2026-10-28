import Foundation

/// A scripted demo only. No detection, file reads, installs, preferences or subprocesses.
@MainActor final class MockOnboardingDriver: OnboardingDriver {
    enum Scenario: String, CaseIterable { case fresh, xcodeReady, keysInvalid, xcodeFailed, noGames }
    @Published private(set) var state: OnboardingState
    private(set) var resumeSnapshot: OnboardingState?
    let scenario: Scenario
    private let lang: Lang
    private let animated: Bool
    private var jobs: [String: Task<Void, Never>] = [:]
    private var retriedXcode = false
    private var retriedKeys = false

    /// A stored snapshot is injected; persistence belongs to the real driver. `animated: false` is for state tests.
    /// The demo's invented disk figures live here only; a real driver measures the volume.
    nonisolated static var sampleState: OnboardingState {
        var s = OnboardingState(); s.welcome = .requirements(freeGB: 64, neededGB: 24); return s
    }

    init(scenario: Scenario = .fresh, state: OnboardingState = MockOnboardingDriver.sampleState, lang: Lang = .initial(), animated: Bool = true) {
        self.scenario = scenario; self.state = state; self.lang = lang; self.animated = animated
        if animated { enterStep() }
    }
    deinit { jobs.values.forEach { $0.cancel() } }

    func start() { guard state.step == .welcome else { return }; next() }
    func choosePlatform(_ platform: OnboardingPlatform) {
        guard state.step == .platform, state.exit == nil else { return }
        let wasIOS = state.selectedPlatform?.includesIOS == true
        state.platform = .selected(platform)
        // Selecting iPhone on a return visit adds work even when Mac setup had already finished.
        if platform.includesIOS && !wasIOS && state.xcode == .ready {
            state.xcode = .needsSetup
            state.setup[.ios] = .queued
        }
    }
    func getXcode() {
        guard state.step == .xcode, state.xcode == .missing, state.exit == nil else { return }
        state.xcode = .downloading
        downloadXcode()
    }
    func finishXcodeSetup() {
        guard state.step == .xcode, state.xcode == .needsSetup, state.exit == nil else { return }
        state.xcode = .settingUp
        setupXcode()
    }
    func retry(_ step: OnboardingStep) {
        guard state.step == step, state.exit == nil else { return }
        switch step {
        case .xcode:
            if case .failed = state.xcode {
                retriedXcode = true
                state.xcode = .needsSetup
            }
            for task in OnboardingBackgroundTask.allCases {
                if case .failed = state.background[task] { state.background[task] = .queued }
            }
            enterStep()
        case .keys: state.keys = .empty
        case .games: state.games = .empty
        default: break
        }
    }
    func chooseKeys(_ url: URL) {
        guard state.step == .keys, state.exit == nil else { return }
        if case .invalid = state.keys { retriedKeys = true }
        validateKeys()
    }
    func confirmKeys() {
        guard state.step == .keys, state.exit == nil, case .found = state.keys else { return }
        validateKeys()
    }
    func chooseGames(_ url: URL) {
        guard state.step == .games, state.exit == nil else { return }
        state.games = .scanning
        run("games", after: 1.1) { driver in
            if driver.scenario == .noGames { driver.state.games = .none }
            else {
                driver.state.games = .found([
                    .init(id: "demo.mario", title: driver.t("onboarding.demo.mario"), version: "1.0.0"),
                    .init(id: "demo.balatro", title: "Balatro", version: "1.0.0")
                ])
            }
        }
    }
    func back() {
        let old = state.step
        state.back()
        if old != state.step { cancelJobs(); enterStep(allowAutomaticAdvance: false) }
    }
    func next() {
        let old = state.step
        state.next()
        if old != state.step { cancelJobs(); enterStep() }
    }
    func skipForLater() {
        guard state.exit == nil else { return }
        resumeSnapshot = state
        state.exit = .later
        cancelJobs()
    }
    func openLibrary() {
        guard state.step == .done, state.primaryEnabled else { return }
        state.exit = .library
        cancelJobs()
    }
    func resume() {
        guard state.exit == .later, let snapshot = resumeSnapshot else { return }
        state = snapshot
        enterStep()
    }

    private func t(_ key: String) -> String { L10n.string(key, lang) }
    private func cancelJobs() { jobs.values.forEach { $0.cancel() }; jobs.removeAll() }
    private func run(_ name: String, after seconds: Double, _ action: @escaping (MockOnboardingDriver) -> Void) {
        guard animated else { return }
        jobs[name]?.cancel()
        jobs[name] = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
            guard !Task.isCancelled, let self, self.state.exit == nil else { return }
            action(self)
        }
    }
    private func enterStep(allowAutomaticAdvance: Bool = true) {
        guard state.exit == nil else { return }
        switch state.step {
        case .xcode:
            prepareBackground()
            switch state.xcode {
            case .checking:
                run("check", after: 0.7) { d in
                    d.state.xcode = d.scenario == .xcodeReady ? .settingUp : .missing
                    if d.scenario == .xcodeReady { d.setupXcode() }
                }
            case .downloading: downloadXcode()
            case .settingUp: setupXcode()
            case .ready: if allowAutomaticAdvance { advanceWhenReady() }
            default: break
            }
        case .keys:
            switch state.keys {
            case .empty, .searching:
                state.keys = .searching
                run("keys", after: 0.9) { d in d.state.keys = .found(URL(fileURLWithPath: "/Demo/Switch/prod.keys")) }
            case .validating: validateKeys()
            case .valid: if allowAutomaticAdvance { advanceWhenReady() }
            default: break
            }
        case .games:
            // Only this mock synthesizes a selection; the real view still offers Choose and drop.
            if state.games == .empty || state.games == .scanning {
                chooseGames(URL(fileURLWithPath: "/Demo/Switch"))
            }
        case .done:
            if state.done == .celebrating { run("done", after: 0.35) { $0.state.done = .ready } }
        default: break
        }
    }
    private func prepareBackground() {
        for (index, task) in OnboardingBackgroundTask.allCases.enumerated() where state.background[task] != .done {
            if case .failed = state.background[task] { continue }
            state.background[task] = .queued
            run("bg.start.\(task)", after: 0.3 + Double(index) * 0.4) { d in d.state.background[task] = .running(nil) }
            run("bg.progress.\(task)", after: 1.0 + Double(index) * 0.6) { d in d.state.background[task] = .running(0.6) }
            run("bg.done.\(task)", after: 1.8 + Double(index) * 0.7) { d in
                d.state.background[task] = .done
                d.advanceWhenReady()
            }
        }
    }
    private func downloadXcode() {
        run("download", after: 3.2) { d in d.state.xcode = .needsSetup }
    }
    private func setupXcode() {
        let tasks = state.setupTasks
        for (index, task) in tasks.enumerated() {
            state.setup[task] = .queued
            run("setup.start.\(task)", after: 0.2 + Double(index) * 0.65) { d in
                d.state.setup[task] = .running(task == .metal || task == .ios ? 0.35 : nil)
            }
            run("setup.done.\(task)", after: 0.7 + Double(index) * 0.65) { d in d.state.setup[task] = .done }
        }
        run("setup.finish", after: 0.9 + Double(tasks.count) * 0.65) { d in
            if d.scenario == .xcodeFailed && !d.retriedXcode {
                d.state.xcode = .failed(.init(message: d.t("onboarding.demo.xcodeFailure"),
                                             details: "Demo: MetalToolchain download returned HTTP 503."))
            } else {
                d.state.xcode = .ready
                d.advanceWhenReady()
            }
        }
    }
    private func validateKeys() {
        state.keys = .validating
        run("keys", after: 1) { d in
            if d.scenario == .keysInvalid && !d.retriedKeys {
                d.state.keys = .invalid(d.t("onboarding.demo.keysFailure"))
            } else { d.state.keys = .valid; d.advanceWhenReady() }
        }
    }
    private func advanceWhenReady() {
        guard (state.step == .xcode || state.step == .keys), state.canAdvance else { return }
        let step = state.step
        run("advance", after: 0.7) { d in if d.state.step == step { d.next() } }
    }
}
