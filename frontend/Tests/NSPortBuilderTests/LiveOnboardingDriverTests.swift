import XCTest
@testable import NSPortBuilder

/// The real driver's logic over fakes: no xcodebuild, sudo, App Store, network or installs run here.
@MainActor final class LiveOnboardingDriverTests: XCTestCase {
    final class Fake {
        var probe = XcodeProbe(appPath: "/Applications/Xcode.app", selectedIsXcode: true, licenseAccepted: true, firstLaunchDone: true)
        var admin: AdminResult = .ok
        var adminCalls: [String] = []
        var commands: [[String]] = []
        var commandResult: (ok: Bool, output: String) = (true, "")
        var installed: [String] = []
        var opened: [URL] = []
        var onDetect: (BuildModel) -> Void = { _ in }
        var keyOutcome = KeyCheck.Outcome.fits
        var games: [LibraryGame] = []
        var xcodeWorks: Bool?   // nil: follows the probe
    }

    func dep(_ id: String, present: Bool) -> BuildModel.Dep {
        BuildModel.Dep(id: id, name: "dep." + (id.hasPrefix("brew:") ? String(id.dropFirst(5)) : id), hint: "", present: present, installCmd: ["/usr/bin/true"])
    }

    var defaults: UserDefaults!
    var home: URL!

    override func setUp() {
        OnboardingDefaults.sessionPlatform = nil
        let target = UserDefaults.standard.object(forKey: "buildTarget")   // choosePlatform sets the Builds page's target
        addTeardownBlock { UserDefaults.standard.set(target, forKey: "buildTarget") }
        let suite = "onboarding.tests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { [home] in try? FileManager.default.removeItem(at: home!) }
    }

    func make(_ fake: Fake, deps: [BuildModel.Dep], step: OnboardingStep? = nil, platform: OnboardingPlatform? = nil) -> (LiveOnboardingDriver, BuildModel) {
        if let platform { defaults.set(platform.rawValue, forKey: OnboardingDefaults.platform) }
        if let step { defaults.set(step.rawValue, forKey: OnboardingDefaults.step); defaults.set(true, forKey: OnboardingDefaults.inProgress) }
        let model = BuildModel()
        model.deps = deps; model.depsChecked = true
        var env = OnboardingEnvironment()
        env.defaults = defaults
        env.home = home.path
        env.freeBytes = { 100_000_000_000 }
        env.xcodeInstalled = { fake.xcodeWorks ?? (fake.probe.appPath != nil) }
        env.xcodeFolderExists = { fake.probe.appPath != nil }
        env.xcodeProbe = { fake.probe }
        env.runAdmin = { fake.adminCalls.append($0); return fake.admin }
        env.run = { cmd, line in fake.commands.append(cmd); line("Downloading Metal Toolchain: 45.5% (1 MB of 2 MB)"); return fake.commandResult }
        env.detectDeps = { m in fake.onDetect(m) }
        env.installDep = { m, d in
            fake.installed.append(d.id)
            if let i = m.deps.firstIndex(where: { $0.id == d.id }) { m.deps[i].installing = true }
        }
        env.openURL = { fake.opened.append($0) }
        env.keyCheck = { _, _ in fake.keyOutcome }
        env.scanGames = { _, _ in fake.games }
        env.fetchArtwork = { _ in }
        env.pollInterval = 0.01; env.advanceDelay = 0
        let library = GameLibrary(file: home.appendingPathComponent("library.json"))
        return (LiveOnboardingDriver(model: model, library: library, env: env), model)
    }

    // MARK: Pure parts

    func testIOSRequirementFollowsThePlatformAndKeepsOldBehaviourWithoutAChoice() {
        XCTAssertTrue(BuildModel.needsIOSPlatform(defaults: defaults), "no stored choice: the iOS SDK stays required")
        defaults.set("mac", forKey: OnboardingDefaults.platform)
        defaults.set("mac-app", forKey: "buildTarget")
        XCTAssertFalse(BuildModel.needsIOSPlatform(defaults: defaults), "Mac only, Mac builds: no iOS SDK")
        defaults.set("ios", forKey: "buildTarget")
        XCTAssertTrue(BuildModel.needsIOSPlatform(defaults: defaults), "an iPhone build still needs it")
        for value in ["iphone", "both"] {
            defaults.set(value, forKey: OnboardingDefaults.platform); defaults.set("mac-app", forKey: "buildTarget")
            XCTAssertTrue(BuildModel.needsIOSPlatform(defaults: defaults))
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

    func testAnAlreadyCompleteSetupIsNeverShown() {
        XCTAssertFalse(OnboardingLaunch.shouldShow(completed: true, setupComplete: false))
        XCTAssertFalse(OnboardingLaunch.shouldShow(completed: false, setupComplete: true), "complete: marked done, not shown")
        XCTAssertTrue(OnboardingLaunch.shouldShow(completed: false, setupComplete: false))
        XCTAssertTrue(OnboardingLaunch.setupComplete(depsPresent: true, keysKnown: true, gamesKnown: true))
        for missing in 0..<3 {
            XCTAssertFalse(OnboardingLaunch.setupComplete(depsPresent: missing != 0, keysKnown: missing != 1, gamesKnown: missing != 2))
        }
    }

    func testForceShowsTheSetupWhateverTheState() {
        XCTAssertTrue(OnboardingLaunch.shouldShow(completed: true, setupComplete: true, force: true))
        XCTAssertFalse(OnboardingLaunch.shouldShow(completed: true, setupComplete: true, force: false))
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
        let driver = LiveOnboardingDriver(model: model, library: GameLibrary(file: home.appendingPathComponent("l.json")), env: env, ephemeral: true)
        XCTAssertEqual(driver.state.step, .welcome, "a forced run starts from Welcome whatever is stored")
        driver.start(); driver.choosePlatform(.mac)
        driver.next()
        driver.activate()
        await driver.settle()
        XCTAssertTrue(fake.installed.isEmpty, "nothing installs before an install action")
        XCTAssertNil(defaults.string(forKey: OnboardingDefaults.step))
        XCTAssertNil(defaults.string(forKey: OnboardingDefaults.platform))
        XCTAssertFalse(defaults.bool(forKey: OnboardingDefaults.inProgress))
        XCTAssertTrue(BuildModel.needsIOSPlatform(defaults: defaults) == false, "the session's Mac-only choice is in effect")
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
        XCTAssertEqual(fake.commands, [BuildModel.metalToolchainCmd, BuildModel.iosPlatformCmd])
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
        XCTAssertEqual(fake.commands, [BuildModel.metalToolchainCmd])
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
            model.depsChecked = false
            for i in model.deps.indices { model.deps[i].installing = false; if model.deps[i].id == id { model.deps[i].present = true } }
            model.depsChecked = true
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
        model.depsChecked = false
        for i in model.deps.indices { model.deps[i].installing = false }   // python's install ended, still missing
        model.depsChecked = true
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

    func testGamesFolderFillsTheSameSlotsAndLibrary() async throws {
        let fake = Fake()
        let folder = home.appendingPathComponent("games")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var game = LibraryGame(titleID: "0100000000010000", name: "Sample")
        game.inputs["base"] = [folder.appendingPathComponent("a.nsp").path]
        fake.games = [game]
        let (driver, model) = make(fake, deps: [], step: .games, platform: .mac)
        model.updateSlot("keys") { $0.paths = ["/keys/prod.keys"] }
        driver.chooseGames(folder)
        await driver.settle()
        guard case let .found(list) = driver.state.games else { return XCTFail("\(driver.state.games)") }
        XCTAssertEqual(list.map(\.title), ["Sample"])
        XCTAssertEqual(model.gameDir, folder.path)
        XCTAssertEqual(driver.library.folder, folder.standardizedFileURL.path)
        XCTAssertEqual(model.keysPath, "/keys/prod.keys", "scanning a folder keeps the confirmed keys")

        fake.games = []
        driver.chooseGames(folder)
        await driver.settle()
        XCTAssertEqual(driver.state.games, .none)
    }

    func testOpenLibraryMarksTheSetupDone() async {
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
}
