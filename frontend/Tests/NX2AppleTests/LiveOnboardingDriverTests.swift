import XCTest
@testable import NX2Apple
@testable import NXCore
import NXModel
@testable import NXLauncher

/// The real driver's logic over fakes: no xcodebuild, sudo, App Store, network or installs run here.
@MainActor final class LiveOnboardingDriverTests: IsolatedDefaultsTestCase {
    final class Fake {
        var probe = XcodeProbe(appPath: "/Applications/Xcode.app", selectedIsXcode: true, licenseAccepted: true, firstLaunchDone: true)
        var admin: AdminResult = .ok
        var adminCalls: [String] = []
        var commands: [[String]] = []
        var commandResult: (ok: Bool, output: String) = (true, "")
        var installed: [String] = []
        var opened: [URL] = []
        var onDetect: (DependencyStore) -> Void = { _ in }
        var keyOutcome = KeyCheck.Outcome.fits
        var games: [LibraryGame] = []
        var xcodeWorks: Bool?   // nil: follows the probe
        var os = OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 0)
    }

    func dep(_ id: String, present: Bool) -> Dep {
        Dep(id: id, name: "dep." + (id.hasPrefix("brew:") ? String(id.dropFirst(5)) : id), hint: "", present: present, installCmd: ["/usr/bin/true"])
    }

    var defaults: UserDefaults!
    var home: URL!

    override func setUp() {
        OnboardingDefaults.sessionPlatform = nil
        defaults = TestDefaults.make("onboarding.tests")
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { [home] in try? FileManager.default.removeItem(at: home!) }
    }

    func make(_ fake: Fake, deps: [Dep], step: OnboardingStep? = nil, platform: OnboardingPlatform? = nil, keysPath: String? = nil) -> (LiveOnboardingDriver, BuildStore) {
        if let platform { defaults.set(platform.rawValue, forKey: OnboardingDefaults.platform) }
        if let step { defaults.set(step.rawValue, forKey: OnboardingDefaults.step); defaults.set(true, forKey: OnboardingDefaults.inProgress) }
        let modelStores = LauncherStores(defaults: testDefaults); let model = modelStores.build
        if let keysPath { model.updateSlot("keys") { $0.paths = [keysPath] } }
        modelStores.dependencies.deps = deps; modelStores.dependencies.checked = true
        var env = OnboardingEnvironment()
        env.defaults = defaults
        env.home = home.path
        env.freeBytes = { 100_000_000_000 }
        env.osVersion = { fake.os }
        env.xcodeInstalled = { fake.xcodeWorks ?? (fake.probe.appPath != nil) }
        env.xcodeFolderExists = { fake.probe.appPath != nil }
        env.xcodeProbe = { fake.probe }
        env.runAdmin = { fake.adminCalls.append($0); return fake.admin }
        env.run = { cmd, line in fake.commands.append(cmd); line("Downloading Metal Toolchain: 45.5% (1 MB of 2 MB)"); return fake.commandResult }
        env.detectDeps = { m in fake.onDetect(m) }
        env.installDep = { dependencies, d in
            fake.installed.append(d.id)
            if let i = dependencies.deps.firstIndex(where: { $0.id == d.id }) { dependencies.deps[i].installing = true }
        }
        env.openURL = { fake.opened.append($0) }
        env.keyCheck = { _, _ in fake.keyOutcome }
        env.scanGames = { _, _, _ in fake.games }
        env.fetchArtwork = { _ in }
        env.pollInterval = 0.01; env.advanceDelay = 0
        let library = GameLibrary(file: home.appendingPathComponent("library.json"))
        return (LiveOnboardingDriver(stores: modelStores, library: library, env: env), model)
    }

    // MARK: Pure parts

    func testIOSRequirementFollowsThePlatformAndKeepsOldBehaviourWithoutAChoice() {
        XCTAssertTrue(LauncherStores.needsIOSPlatform(defaults: defaults), "no stored choice: the iOS SDK stays required")
        defaults.set("mac", forKey: OnboardingDefaults.platform)
        defaults.set("mac-app", forKey: "buildTarget")
        XCTAssertFalse(LauncherStores.needsIOSPlatform(defaults: defaults), "Mac only, Mac builds: no iOS SDK")
        defaults.set("ios", forKey: "buildTarget")
        XCTAssertTrue(LauncherStores.needsIOSPlatform(defaults: defaults), "an iPhone build still needs it")
        for value in ["iphone", "both"] {
            defaults.set(value, forKey: OnboardingDefaults.platform); defaults.set("mac-app", forKey: "buildTarget")
            XCTAssertTrue(LauncherStores.needsIOSPlatform(defaults: defaults))
        }
    }

    func testXcodeStateFromTheProbe() {
        func eval(_ p: XcodeProbe, metal: Bool = true, ios: Bool = true, includesIOS: Bool = false) -> OnboardingState.Xcode {
            OnboardingXcode.evaluate(probe: p, metalReady: metal, iosReady: ios, includesIOS: includesIOS).xcode
        }
        let ready = XcodeProbe(appPath: "/Applications/Xcode.app", selectedIsXcode: true, licenseAccepted: true, firstLaunchDone: true)
        XCTAssertEqual(eval(XcodeProbe()), .missing)
        XCTAssertEqual(eval(ready), .ready)
        var clt = ready; clt.selectedIsXcode = false
        XCTAssertEqual(eval(clt), .needsSetup, "the Command Line Tools are selected")
        var license = ready; license.licenseAccepted = false
        XCTAssertEqual(eval(license), .needsSetup)
        var first = ready; first.firstLaunchDone = false
        XCTAssertEqual(eval(first), .needsSetup)
        XCTAssertEqual(eval(ready, metal: false), .needsSetup)
        XCTAssertEqual(eval(ready, ios: false), .ready, "a Mac-only player is not held up by the iOS platform")
        XCTAssertEqual(eval(ready, ios: false, includesIOS: true), .needsSetup)
        XCTAssertNil(OnboardingXcode.evaluate(probe: ready, metalReady: true, iosReady: false, includesIOS: false).setup[.ios])
        XCTAssertNotNil(OnboardingXcode.evaluate(probe: ready, metalReady: true, iosReady: false, includesIOS: true).setup[.ios])
    }

    func testAdminScriptIsOnePromptAndQuotesThePath() {
        let source = OnboardingAdmin.source(developerDir: "/Applications/My \"X\" Xcode.app/Contents/Developer")
        XCTAssertEqual(source.components(separatedBy: "with administrator privileges").count - 1, 1)
        XCTAssertTrue(source.contains("quoted form of \"/Applications/My \\\"X\\\" Xcode.app/Contents/Developer\""))
        XCTAssertTrue(source.contains("/usr/bin/xcode-select -s "))
        XCTAssertTrue(source.contains("&& /usr/bin/xcodebuild -license accept && /usr/bin/xcodebuild -runFirstLaunch"))
    }

    func testProgressParsingAndTail() {
        XCTAssertEqual(LiveOnboardingDriver.progress(in: "Downloading Metal Toolchain: 45.5% (1 MB of 2 MB)")!, 0.455, accuracy: 0.0001)
        XCTAssertEqual(LiveOnboardingDriver.progress(in: "10%\r20%\r30%")!, 0.3, accuracy: 0.0001)
        XCTAssertNil(LiveOnboardingDriver.progress(in: "Installing"))
        XCTAssertEqual(LiveOnboardingDriver.tail(String(repeating: "x", count: 5000), limit: 100).count, 101)
    }

    func testNeededGBIsAnEstimateThatGrowsWithTheChoices() {
        let mac = LiveOnboardingDriver.neededGB(xcodeMissing: false, includesIOS: false)
        XCTAssertGreaterThan(LiveOnboardingDriver.neededGB(xcodeMissing: true, includesIOS: false), mac)
        XCTAssertGreaterThan(LiveOnboardingDriver.neededGB(xcodeMissing: false, includesIOS: true), mac)
    }

    func testDecideOpensLauncherWhenCompletedEvenWithUnfinishedFlags() async {
        defaults.set(true, forKey: OnboardingDefaults.completed)
        defaults.set(true, forKey: OnboardingDefaults.inProgress)
        defaults.set(true, forKey: OnboardingDefaults.keysSkipped)
        let result = await OnboardingLaunch.decide(defaults: defaults, force: false, keysSlotIsEmpty: true) { XCTFail("Already complete"); return false }
        XCTAssertEqual(result, .launcher)
    }

    func testDecideRecognizesSetupFinishedInMainWindowAfterStart() async {
        defaults.set(true, forKey: OnboardingDefaults.inProgress)
        let result = await OnboardingLaunch.decide(defaults: defaults, force: false, keysSlotIsEmpty: true) { true }
        XCTAssertEqual(result, .launcher)
        XCTAssertTrue(defaults.bool(forKey: OnboardingDefaults.completed))
        XCTAssertFalse(defaults.bool(forKey: OnboardingDefaults.inProgress))
    }

    func testDecideResumesExplicitKeysSkipBeforeInferringCompletion() async {
        defaults.set(true, forKey: OnboardingDefaults.inProgress)
        defaults.set(true, forKey: OnboardingDefaults.keysSkipped)
        let result = await OnboardingLaunch.decide(defaults: defaults, force: false, keysSlotIsEmpty: true) { XCTFail("Skipped discovery"); return true }
        XCTAssertEqual(result, .onboarding)
    }

    func testDecideRecognizesMainWindowSetupAfterSkippingKeys() async throws {
        let (driver, model) = make(Fake(), deps: [], step: .keys, platform: .mac)
        driver.skipKeys()
        driver.skipForLater()
        let keys = home.appendingPathComponent("prod.keys")
        try Data().write(to: keys)
        model.updateSlot("keys") { $0.paths = [keys.path] }
        let result = await OnboardingLaunch.decide(defaults: defaults, force: false, keysSlotIsEmpty: model.keysPath.isEmpty) {
            OnboardingLaunch.setupComplete(depsPresent: true, keysKnown: model.slot("keys").ok, gamesKnown: true)
        }
        XCTAssertEqual(result, .launcher)
        XCTAssertTrue(defaults.bool(forKey: OnboardingDefaults.completed))
        XCTAssertFalse(defaults.bool(forKey: OnboardingDefaults.keysSkipped))
        XCTAssertEqual(model.keysPath, keys.path)
    }

    func testDecideShowsSetupOnAnIncompleteMac() async {
        let result = await OnboardingLaunch.decide(defaults: defaults, force: false, keysSlotIsEmpty: true) { false }
        XCTAssertEqual(result, .onboarding)
        XCTAssertFalse(defaults.bool(forKey: OnboardingDefaults.completed))
    }

    func testSetupCompleteRequiresToolsKeysAndGames() {
        XCTAssertTrue(OnboardingLaunch.setupComplete(depsPresent: true, keysKnown: true, gamesKnown: true))
        for missing in 0..<3 {
            XCTAssertFalse(OnboardingLaunch.setupComplete(depsPresent: missing != 0, keysKnown: missing != 1, gamesKnown: missing != 2))
        }
    }

    func testForceShowsTheSetupWhateverTheState() async {
        defaults.set(true, forKey: OnboardingDefaults.completed)
        let result = await OnboardingLaunch.decide(defaults: defaults, force: true, keysSlotIsEmpty: true) { XCTFail("Forced"); return true }
        XCTAssertEqual(result, .forced)
        XCTAssertTrue(OnboardingLaunch.forced(["NSPB_ONBOARDING_FORCE": "1"]))
        XCTAssertFalse(OnboardingLaunch.forced(["NSPB_ONBOARDING_FORCE": "0"]))
        XCTAssertFalse(OnboardingLaunch.forced([:]))
    }

    func testForcedRunLeavesNoTraceInstallsNothingUntilAskedAndFlushesOnLater() async {
        let fake = Fake()
        defaults.set(true, forKey: OnboardingDefaults.completed)
        let (live, model) = make(fake, deps: [dep("xcode", present: true), dep("metal", present: true), dep("python", present: false)])
        _ = live
        var env = OnboardingEnvironment(); env.defaults = defaults; env.home = home.path
        env.freeBytes = { 100_000_000_000 }; env.xcodeProbe = { fake.probe }; env.xcodeInstalled = { true }; env.xcodeFolderExists = { true }
        env.detectDeps = { _ in }; env.installDep = { _, d in fake.installed.append(d.id) }
        env.advanceDelay = 0
        let driver = LiveOnboardingDriver(stores: live.stores, library: GameLibrary(file: home.appendingPathComponent("l.json")), env: env, ephemeral: true)
        XCTAssertEqual(driver.state.step, .welcome, "a forced run starts from Welcome whatever is stored")
        driver.start(); driver.choosePlatform(.mac)
        driver.next()
        driver.activate()
        await driver.settle()
        XCTAssertTrue(fake.installed.isEmpty, "nothing installs before an install action")
        XCTAssertNil(defaults.string(forKey: OnboardingDefaults.step))
        XCTAssertNil(defaults.string(forKey: OnboardingDefaults.platform))
        XCTAssertFalse(defaults.bool(forKey: OnboardingDefaults.inProgress))
        XCTAssertTrue(LauncherStores.needsIOSPlatform(defaults: defaults) == false, "the session's Mac-only choice is in effect")
        driver.retry(.xcode)
        await driver.settle()
        XCTAssertEqual(fake.installed, ["python"])
        driver.skipForLater()
        XCTAssertEqual(defaults.string(forKey: OnboardingDefaults.platform), "mac", "Set up later stores it")
        XCTAssertEqual(defaults.string(forKey: OnboardingDefaults.step), "xcode")
        XCTAssertNil(OnboardingDefaults.sessionPlatform)
    }

    // MARK: The driver

    func testWelcomeShowsMeasuredFreeSpace() {
        let (driver, _) = make(Fake(), deps: [])
        guard case let .requirements(free, needed) = driver.state.welcome else { return XCTFail() }
        XCTAssertEqual(free, 100)
        XCTAssertGreaterThan(needed, 0)
    }

    func testCancelledAdminPromptReturnsToNeedsSetup() async {
        let fake = Fake(); fake.probe.selectedIsXcode = false; fake.admin = .cancelled
        let (driver, _) = make(fake, deps: [dep("metal", present: true)], step: .xcode, platform: .mac)
        await driver.refreshXcode()
        XCTAssertEqual(driver.state.xcode, .needsSetup)
        driver.finishXcodeSetup()
        XCTAssertEqual(driver.state.xcode, .settingUp)
        await driver.settle()
        XCTAssertEqual(driver.state.xcode, .needsSetup, "saying no to the password is not an error")
        XCTAssertEqual(fake.adminCalls, ["/Applications/Xcode.app/Contents/Developer"])
        XCTAssertTrue(fake.commands.isEmpty)
    }

    func testFinishRunsAdminOnceThenTheDownloadsWithoutIt() async {
        let fake = Fake(); fake.probe.selectedIsXcode = false
        let (driver, model) = make(fake, deps: [dep("metal", present: false), dep("xcode", present: false)], step: .xcode, platform: .both)
        fake.onDetect = { m in   // what the admin step and the downloads change
            fake.probe.selectedIsXcode = true; fake.probe.licenseAccepted = true; fake.probe.firstLaunchDone = true
            if !fake.commands.isEmpty { for i in m.deps.indices { m.deps[i].present = true } }
        }
        await driver.refreshXcode()
        driver.finishXcodeSetup()
        await driver.settle()
        XCTAssertEqual(fake.adminCalls.count, 1)
        XCTAssertEqual(fake.commands, [Toolchain.metalToolchainCmd, Toolchain.iosPlatformCmd])
        XCTAssertEqual(driver.state.xcode, .ready)
        XCTAssertEqual(driver.state.setup[.ios], .done)
        _ = model
    }

    func testMacOnlyDoesNotDownloadTheIOSPlatform() async {
        let fake = Fake(); fake.probe.selectedIsXcode = false
        let (driver, _) = make(fake, deps: [dep("metal", present: false), dep("xcode", present: true)], step: .xcode, platform: .mac)
        fake.onDetect = { m in
            fake.probe.selectedIsXcode = true; fake.probe.licenseAccepted = true; fake.probe.firstLaunchDone = true
            if !fake.commands.isEmpty { for i in m.deps.indices { m.deps[i].present = true } }
        }
        await driver.refreshXcode()
        driver.finishXcodeSetup()
        await driver.settle()
        XCTAssertEqual(fake.commands, [Toolchain.metalToolchainCmd])
        XCTAssertEqual(driver.state.xcode, .ready)
    }

    func testDownloadFailureIsLocalizedWithTheOutputInDetails() async {
        let fake = Fake(); fake.commandResult = (false, "HTTP 503 from the server")
        let (driver, _) = make(fake, deps: [dep("metal", present: false)], step: .xcode, platform: .mac)
        await driver.refreshXcode()
        driver.finishXcodeSetup()
        await driver.settle()
        guard case let .failed(failure) = driver.state.xcode else { return XCTFail("\(driver.state.xcode)") }
        XCTAssertEqual(failure.message, L10n.string("onboarding.error.metal", driver.model.lang))
        XCTAssertTrue(failure.details.contains("HTTP 503"))
        XCTAssertTrue(fake.adminCalls.isEmpty, "Xcode was already set up: no prompt")
    }

    func testLauncherOnlyXcodeNeverRunsTheSystemSelectionCommandForFirstLaunch() async {
        let app = "/Volumes/External Drive/Xcode.app"
        testDefaults.set(app, forKey: XcodeSelection.key)
        let fake = Fake()
        fake.probe = XcodeProbe(appPath: app, selectedIsXcode: true, licenseAccepted: false, firstLaunchDone: false)
        let (driver, _) = make(fake, deps: [dep("metal", present: true)], step: .xcode, platform: .mac)
        await driver.refreshXcode()
        driver.finishXcodeSetup()
        await driver.settle()
        XCTAssertTrue(fake.adminCalls.isEmpty)
        guard case .failed(let failure) = driver.state.xcode else { return XCTFail("Expected first-launch instructions") }
        XCTAssertEqual(failure.details, app)
    }

    func testUnavailableSelectedXcodeOffersRetryAndDetectsTheReconnectedDrive() async {
        let fake = Fake()
        fake.probe = XcodeProbe(selectedAppUnavailable: true)
        let (driver, _) = make(fake, deps: [dep("metal", present: false)], step: .xcode, platform: .mac)
        await driver.refreshXcode()
        XCTAssertEqual(driver.state.xcode, .disconnected)
        XCTAssertEqual(driver.state.primary, .retry)
        driver.getXcode()
        XCTAssertTrue(fake.opened.isEmpty)
        fake.probe = XcodeProbe(appPath: "/Volumes/Example/Xcode.app", selectedIsXcode: true, licenseAccepted: true, firstLaunchDone: true)
        fake.onDetect = { $0.deps = [self.dep("metal", present: true)] }
        driver.retry(.xcode)
        await driver.settle()
        XCTAssertEqual(driver.state.xcode, .ready)
        XCTAssertTrue(fake.adminCalls.isEmpty)
    }

    func testGetXcodeOpensTheAppStoreAndPollsUntilItAppears() async {
        let fake = Fake(); fake.probe = XcodeProbe()
        let (driver, _) = make(fake, deps: [dep("metal", present: true)], step: .xcode, platform: .mac)
        await driver.refreshXcode()
        XCTAssertEqual(driver.state.xcode, .missing)
        driver.getXcode()
        XCTAssertEqual(driver.state.xcode, .downloading)
        XCTAssertEqual(fake.opened.map(\.absoluteString), ["macappstore://apps.apple.com/app/id497799835"])
        fake.probe = XcodeProbe(appPath: "/Applications/Xcode.app", selectedIsXcode: false)
        await driver.settle()
        XCTAssertEqual(driver.state.xcode, .needsSetup)
    }

    func testPartialXcodeFolderKeepsDownloadingUntilXcodebuildWorks() async {
        let fake = Fake(); fake.probe = XcodeProbe(); fake.xcodeWorks = false
        let (driver, _) = make(fake, deps: [dep("metal", present: true)], step: .xcode, platform: .mac)
        await driver.refreshXcode()
        driver.getXcode()
        try? await Task.sleep(nanoseconds: 100_000_000)   // several polls: the folder exists, xcodebuild -version does not work yet
        XCTAssertEqual(driver.state.xcode, .downloading)
        fake.probe = XcodeProbe(appPath: "/Applications/Xcode.app", selectedIsXcode: false)
        fake.xcodeWorks = true
        await driver.settle()
        XCTAssertEqual(driver.state.xcode, .needsSetup)
    }

    func testXcodeCountsOnlyWhereXcodebuildVersionExitsZero() throws {
        let apps = home.appendingPathComponent("apps")
        for (name, status) in [("Xcode.app", 1), ("Xcode-beta.app", 0)] {   // the first stands for a download in progress
            let bin = apps.appendingPathComponent("\(name)/Contents/Developer/usr/bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let tool = bin.appendingPathComponent("xcodebuild")
            try "#!/bin/sh\nexit \(status)\n".write(to: tool, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }
        XCTAssertEqual(OnboardingEnvironment.xcodeFolders(in: apps.path).count, 2)
        XCTAssertEqual(OnboardingEnvironment.xcodeApps(in: apps.path).map { ($0 as NSString).lastPathComponent }, ["Xcode-beta.app"])
    }

    func testOsascriptResultMapsCancelAndFailure() {
        XCTAssertEqual(OnboardingAdmin.result(status: 0, stderr: ""), .ok)
        XCTAssertEqual(OnboardingAdmin.result(status: 1, stderr: "execution error: User canceled. (-128)\n"), .cancelled)
        XCTAssertEqual(OnboardingAdmin.result(status: 1, stderr: "execution error: boom (1)"), .failed("execution error: boom (1)"))
    }

    func testBackgroundInstallsRunOneAtATimeAndToolsWaitForXcode() async {
        let fake = Fake()
        let deps = [dep("xcode", present: true), dep("metal", present: true), dep("brew", present: false),
                    dep("brew:xcodegen", present: false), dep("dotnet", present: false), dep("python", present: false)]
        let (driver, model) = make(fake, deps: deps, step: .xcode, platform: .mac)
        driver.activate()
        await driver.settle()
        XCTAssertEqual(fake.installed, ["python"])
        func finish(_ id: String) async {   // the install ended and detection ran again
            driver.stores.dependencies.checked = false
            for i in driver.stores.dependencies.deps.indices { driver.stores.dependencies.deps[i].installing = false; if driver.stores.dependencies.deps[i].id == id { driver.stores.dependencies.deps[i].present = true } }
            driver.stores.dependencies.checked = true
            await driver.settle()
        }
        await finish("python"); XCTAssertEqual(fake.installed, ["python", "dotnet"])
        XCTAssertEqual(driver.state.background[.python], .done)
        await finish("dotnet"); XCTAssertEqual(fake.installed, ["python", "dotnet", "brew"])
        await finish("brew"); XCTAssertEqual(fake.installed, ["python", "dotnet", "brew", "brew:xcodegen"])
        await finish("brew:xcodegen")
        XCTAssertTrue(driver.state.backgroundReady)
        XCTAssertEqual(driver.state.step, .keys, "Xcode and the tools are done: the step moves on by itself")
    }

    func testToolsStayQueuedUntilXcodeIsReady() async {
        let fake = Fake(); fake.probe.selectedIsXcode = false
        let deps = [dep("xcode", present: true), dep("metal", present: true), dep("brew", present: false),
                    dep("dotnet", present: true), dep("python", present: true)]
        let (driver, _) = make(fake, deps: deps, step: .xcode, platform: .mac)
        driver.activate()
        await driver.settle()
        XCTAssertEqual(driver.state.xcode, .needsSetup)
        XCTAssertEqual(driver.state.background[.tools], .queued)
        XCTAssertTrue(fake.installed.isEmpty)
    }

    func testAFailedInstallShowsFailureWithTheNameAndMovesOn() async {
        let fake = Fake()
        let (driver, model) = make(fake, deps: [dep("xcode", present: true), dep("metal", present: true),
                                                 dep("dotnet", present: false), dep("python", present: false)], step: .xcode, platform: .mac)
        driver.activate()
        await driver.settle()
        driver.stores.dependencies.checked = false
        for i in driver.stores.dependencies.deps.indices { driver.stores.dependencies.deps[i].installing = false }   // python's install ended, still missing
        driver.stores.dependencies.checked = true
        await driver.settle()
        guard case let .failed(failure) = driver.state.background[.python] else { return XCTFail("\(String(describing: driver.state.background[.python]))") }
        XCTAssertTrue(failure.message.contains(L10n.string("dep.python", model.lang)))
        XCTAssertEqual(fake.installed, ["python", "dotnet"], "a failure does not stop the others")
    }

    func testResumeKeepsTheStepOnlyWhileXcodeStillHolds() async {
        let ok = Fake()
        let (driver, _) = make(ok, deps: [dep("metal", present: true), dep("xcode", present: true)], step: .keys, platform: .mac)
        XCTAssertEqual(driver.state.step, .keys)
        XCTAssertEqual(driver.state.selectedPlatform, .mac)
        await driver.revalidate()
        XCTAssertEqual(driver.state.step, .keys)

        defaults.set(true, forKey: OnboardingDefaults.keysSkipped)
        let gone = Fake(); gone.probe = XcodeProbe()
        let (second, _) = make(gone, deps: [dep("metal", present: true)], step: .games, platform: .mac)
        XCTAssertEqual(second.state.step, .games)
        await second.revalidate()
        XCTAssertEqual(second.state.step, .xcode, "Xcode is gone: back to the Xcode step")
    }

    func testStoredStepWithoutAPlatformResumesAtThePlatformChoice() {
        defaults.set(OnboardingStep.keys.rawValue, forKey: OnboardingDefaults.step); defaults.set(true, forKey: OnboardingDefaults.inProgress)
        let (driver, _) = make(Fake(), deps: [])
        XCTAssertEqual(driver.state.step, .platform)
    }

    func testSkipForLaterStoresStepAndPlatformAndCloses() {
        let (driver, _) = make(Fake(), deps: [], step: .platform)
        var exits: [OnboardingState.Exit] = []
        driver.onExit = { exits.append($0) }
        driver.choosePlatform(.iphone)
        driver.skipForLater()
        XCTAssertEqual(exits, [.later])
        XCTAssertEqual(driver.state.exit, .later)
        XCTAssertEqual(defaults.string(forKey: OnboardingDefaults.step), "platform")
        XCTAssertEqual(defaults.string(forKey: OnboardingDefaults.platform), "iphone")
        XCTAssertTrue(defaults.bool(forKey: OnboardingDefaults.inProgress))
        XCTAssertFalse(defaults.bool(forKey: OnboardingDefaults.completed))
    }

    func testChoosingMacOnlyPointsTheBuildsPageAtTheMac() {
        let (driver, model) = make(Fake(), deps: [], step: .platform)
        driver.choosePlatform(.mac)
        XCTAssertEqual(model.target, "mac-app")
        XCTAssertEqual(defaults.string(forKey: OnboardingDefaults.platform), "mac")
    }

    func testKeysAreCheckedAndOnlyTheirPathIsKept() async throws {
        let fake = Fake()
        let keys = home.appendingPathComponent(".switch/prod.keys")
        try FileManager.default.createDirectory(at: keys.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "header_key = 00\n".write(to: keys, atomically: true, encoding: .utf8)
        let (driver, model) = make(fake, deps: [], step: .keys, platform: .mac)
        await driver.searchKeys()
        XCTAssertEqual(driver.state.keys, .found(keys))
        driver.confirmKeys()
        await driver.settle()
        XCTAssertEqual(driver.state.keys, .valid)
        XCTAssertEqual(model.keysPath, keys.path, "the same slot the Builds page uses")

        driver.back()   // the step moved on by itself; back to the keys
        fake.keyOutcome = .noHeaderKey
        driver.chooseKeys(keys)
        await driver.settle()
        guard case let .invalid(message) = driver.state.keys else { return XCTFail() }
        XCTAssertFalse(message.contains("00"), "a message never carries key material")
    }

    func testSkippingKeysKeepsEncryptedOnlyGamesGated() async throws {
        let fake = Fake()
        let (driver, model) = make(fake, deps: [], step: .keys, platform: .mac)
        driver.skipKeys()
        try Data().write(to: home.appendingPathComponent("Game [0100000000010000][v0].nsp"))
        try Data().write(to: home.appendingPathComponent("prod.keys"))
        fake.games = GameLibrary.sourceGames(in: home, repo: "")
        driver.chooseGames(home)
        await driver.settle()
        XCTAssertFalse(driver.state.canAdvance)
        XCTAssertFalse(model.inputsReady)
        XCTAssertTrue(model.keysPath.isEmpty)
    }

    func testSkippingKeysSelectsANUPForTheBuild() async throws {
        let fake = Fake()
        let (driver, model) = make(fake, deps: [], step: .keys, platform: .mac)
        let fixture = GameFolderCaptureTests.makeFolders(in: home.path)
        let folder = home.appendingPathComponent("NUP")
        driver.skipKeys()
        fake.games = GameLibrary.sourceGames(in: folder, repo: fixture.engine)
        driver.chooseGames(folder)
        await driver.settle()
        XCTAssertTrue(driver.state.canAdvance)
        XCTAssertTrue(model.inputsReady)
        XCTAssertNotNil(model.gameFolder?.nup)
    }

    func testSkippingKeysInAMixedLibraryListsEveryGameAndSelectsADecryptedBuildInput() async throws {
        let fake = Fake()
        let (driver, model) = make(fake, deps: [], step: .keys, platform: .mac)
        let fixture = GameFolderCaptureTests.makeFolders(in: home.path)
        try FileManager.default.removeItem(at: home.appendingPathComponent("NUP"))
        try Data().write(to: home.appendingPathComponent("Game [0100000000010000][v0].nsp"))
        fake.games = GameLibrary.sourceGames(in: home, repo: fixture.engine)
        driver.skipKeys()
        driver.chooseGames(home)
        await driver.settle()
        guard case let .found(list) = driver.state.games else { return XCTFail("Expected both games") }
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(driver.library.folder, home.standardizedFileURL.path)
        XCTAssertTrue(driver.state.canAdvance)
        XCTAssertTrue(model.inputsReady)
        XCTAssertNotNil(model.gameFolder)
    }

    func testBackAndResumeKeepSkippedStateUntilAnotherFileIsChosen() async {
        let fake = Fake()
        let (driver, _) = make(fake, deps: [], step: .keys, platform: .mac)
        driver.skipKeys()
        driver.back()
        await driver.settle()
        XCTAssertEqual(driver.state.keys, .skipped)
        XCTAssertTrue(driver.state.canAdvance)
        driver.skipForLater()
        let (resumed, _) = make(fake, deps: [])
        resumed.enter(resumed.state.step)
        await resumed.settle()
        XCTAssertEqual(resumed.state.step, .keys)
        XCTAssertEqual(resumed.state.keys, .skipped)
        fake.keyOutcome = .noHeaderKey
        resumed.chooseKeys(home.appendingPathComponent("other.keys"))
        await resumed.settle()
        guard case .invalid = resumed.state.keys else { return XCTFail("Chosen keys still need validation") }
        XCTAssertFalse(defaults.bool(forKey: OnboardingDefaults.keysSkipped))
    }

    func testResumeKeepsKeysSelectedInTheMainWindowAfterASkip() throws {
        let keys = home.appendingPathComponent("prod.keys")
        try Data().write(to: keys)
        defaults.set(true, forKey: OnboardingDefaults.keysSkipped)
        let (resumed, model) = make(Fake(), deps: [], step: .games, platform: .mac, keysPath: keys.path)
        XCTAssertEqual(model.keysPath, keys.path)
        XCTAssertEqual(resumed.state.keys, .valid)
        XCTAssertFalse(defaults.bool(forKey: OnboardingDefaults.keysSkipped))
    }

    func testResumeKeepsTheSelectionWhenItsKeysFileIsUnavailable() {
        let missing = home.appendingPathComponent("disconnected/prod.keys")
        defaults.set(true, forKey: OnboardingDefaults.keysSkipped)
        let (resumed, model) = make(Fake(), deps: [], step: .games, platform: .mac, keysPath: missing.path)
        XCTAssertEqual(model.keysPath, missing.path)
        XCTAssertEqual(resumed.state.step, .keys)
        XCTAssertEqual(resumed.state.keys, .empty)
        XCTAssertFalse(defaults.bool(forKey: OnboardingDefaults.keysSkipped))
    }

    func testSkippingAnExistingKeyClearsOnlyTheSlot() async throws {
        let keys = home.appendingPathComponent("prod.keys")
        try Data().write(to: keys)
        let (driver, model) = make(Fake(), deps: [], step: .keys, platform: .mac, keysPath: keys.path)
        await driver.searchKeys()
        XCTAssertEqual(driver.state.keys, .found(keys))
        driver.skipKeys()
        XCTAssertEqual(driver.state.keys, .skipped)
        XCTAssertTrue(model.keysPath.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keys.path))
    }

    /// #996: keys chosen in the setup are saved for every game, and skipping the keys never removes a saved file.
    func testChosenKeysAreSavedAndSkippingKeepsThem() async throws {
        let keys = home.appendingPathComponent("prod.keys")
        try Data().write(to: keys)
        let (driver, model) = make(Fake(), deps: [], step: .keys, platform: .mac)
        driver.chooseKeys(keys)
        await driver.settle()
        XCTAssertEqual(driver.state.keys, .valid)
        XCTAssertEqual(model.savedKeys, keys.path)

        let (again, saved) = make(Fake(), deps: [], step: .keys, platform: .mac)
        XCTAssertEqual(saved.savedKeys, keys.path, "a new launch reads them")
        again.skipKeys()
        XCTAssertEqual(again.state.keys, .skipped)
        XCTAssertEqual(saved.savedKeys, keys.path, "Skip never removes the saved keys")
        XCTAssertTrue(saved.keysRowPath.isEmpty, "skipped: the row stays empty")
        XCTAssertTrue(FileManager.default.fileExists(atPath: keys.path), "the file itself stays")
    }

    func testResumeBeyondKeysAcceptsTheKeysSavedInSettings() throws {
        let keys = home.appendingPathComponent("saved.keys")
        try Data().write(to: keys)
        testDefaults.set(keys.path, forKey: BuildStore.savedKeysKey)
        let (resumed, model) = make(Fake(), deps: [], step: .done, platform: .mac)
        XCTAssertTrue(model.keysRowPath.isEmpty)
        XCTAssertEqual(resumed.state.step, .done)
        XCTAssertEqual(resumed.state.keys, .valid)
    }

    func testResumeBeyondKeysRequiresAnExistingKeyOrASavedSkip() throws {
        let keys = home.appendingPathComponent("prod.keys")
        let (missing, _) = make(Fake(), deps: [], step: .done, platform: .mac, keysPath: keys.path)
        XCTAssertEqual(missing.state.step, .keys)
        XCTAssertEqual(missing.state.keys, .empty)
        try Data().write(to: keys)
        let (present, _) = make(Fake(), deps: [], step: .done, platform: .mac, keysPath: keys.path)
        XCTAssertEqual(present.state.step, .done)
        XCTAssertEqual(present.state.keys, .valid)
        defaults.set(true, forKey: OnboardingDefaults.keysSkipped)
        let (skipped, model) = make(Fake(), deps: [], step: .done, platform: .mac)
        XCTAssertEqual(skipped.state.step, .done)
        XCTAssertEqual(skipped.state.keys, .skipped)
        XCTAssertTrue(model.keysPath.isEmpty)
    }

    func testGamesFolderFillsTheSameSlotsAndLibrary() async throws {
        let fake = Fake()
        let folder = home.appendingPathComponent("games")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var game = LibraryGame(titleID: "0100000000010000", name: "Sample")
        game.inputs["base"] = [folder.appendingPathComponent("a.nsp").path]
        fake.games = [game]
        let keys = home.appendingPathComponent("prod.keys")
        try Data().write(to: keys)
        let (driver, model) = make(fake, deps: [], step: .games, platform: .mac, keysPath: keys.path)
        driver.chooseGames(folder)
        await driver.settle()
        guard case let .found(list) = driver.state.games else { return XCTFail("\(driver.state.games)") }
        XCTAssertEqual(list.map(\.title), ["Sample"])
        XCTAssertEqual(model.gameDir, folder.path)
        XCTAssertEqual(driver.library.folder, folder.standardizedFileURL.path)
        XCTAssertEqual(model.keysPath, keys.path, "scanning a folder keeps the confirmed keys")

        fake.games = []
        driver.chooseGames(folder)
        await driver.settle()
        XCTAssertEqual(driver.state.games, .none)
    }

    func testOpenLibraryMarksTheSetupDone() async {
        defaults.set(true, forKey: OnboardingDefaults.keysSkipped)
        let (driver, _) = make(Fake(), deps: [], step: .done, platform: .mac)
        var exits: [OnboardingState.Exit] = []
        driver.onExit = { exits.append($0) }
        driver.enter(.done)
        await driver.settle()
        driver.openLibrary()
        XCTAssertEqual(exits, [.library])
        XCTAssertTrue(defaults.bool(forKey: OnboardingDefaults.completed))
        XCTAssertFalse(defaults.bool(forKey: OnboardingDefaults.inProgress))
    }

    // MARK: NVN hints (macOS 26.6 / Xcode 27.2)

    func testOSHintFollowsMacOSVersion() {
        let fake = Fake()
        for (v, old) in [((13, 0, 0), true), ((26, 5, 9), true), ((26, 6, 0), false), ((26, 6, 1), false), ((27, 0, 0), false)] {
            fake.os = OperatingSystemVersion(majorVersion: v.0, minorVersion: v.1, patchVersion: v.2)
            let (driver, _) = make(fake, deps: [])
            XCTAssertEqual(driver.state.osTooOldForNVN, old, "\(v)")
        }
    }

    func testXcodeHintFollowsProbeVersion() async {
        let fake = Fake()
        for (version, old) in [("26.4", true), ("27.0", true), ("27", true), ("27.1", true), ("27.2", false), ("27.3", false), ("28.0", false), (nil, false)] as [(String?, Bool)] {
            fake.probe.version = version
            let (driver, _) = make(fake, deps: [dep("metal", present: true), dep("xcode", present: true)])
            await driver.refreshXcode()
            XCTAssertEqual(driver.state.xcodeTooOldForNVN, old, "\(version ?? "nil")")
        }
    }

    func testNoXcodeMeansNoXcodeHint() async {
        let fake = Fake()
        fake.probe = XcodeProbe(appPath: nil, version: "26.0")
        let (driver, _) = make(fake, deps: [])
        await driver.refreshXcode()
        XCTAssertFalse(driver.state.xcodeTooOldForNVN)
    }

    func testHintsDoNotGateSetup() {
        let fake = Fake(); fake.os = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        let (driver, _) = make(fake, deps: [])
        XCTAssertTrue(driver.state.osTooOldForNVN)
        XCTAssertTrue(driver.state.canAdvance)
    }

    func testXcodeVersionParsing() {
        XCTAssertEqual(OnboardingNVN.xcodeVersion(from: "Xcode 27.1\nBuild version 17A1\n"), "27.1")
        XCTAssertEqual(OnboardingNVN.xcodeVersion(from: "Xcode 16.4 beta 2\n"), "16.4")
        XCTAssertNil(OnboardingNVN.xcodeVersion(from: "xcode-select: error: tool 'xcodebuild' requires Xcode"))
    }
}
