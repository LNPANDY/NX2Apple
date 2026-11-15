import XCTest
@testable import NXModel
@testable import NXCore

/// `BuildStore` without SwiftUI: the other stores are fakes behind the narrow protocols (`RepoLocation`, `DependencyInstalling`,
/// `EngineSyncing`, `InstallTarget`), the panels are closures that record, the defaults are a suite of their own and
/// the files are in a temporary folder. No process starts and nothing is built: these tests drive the inputs, the script's events,
/// the failure, "Build anyway" and the conditions that stop a build before it starts.
@MainActor final class BuildStoreTests: XCTestCase {
    private final class FakeRepo: RepoLocation {
        var path = "/repo"
        var isRepo = true
        var isGit = true
    }

    private final class FakeDeps: DependencyInstalling {
        var pythonPath = "/usr/bin/python3"
        var dotnetPath = "/usr/bin/true"
        var checked = true
        var allPresent = true
        var deps: [Dep] = []
        var installed: [String] = []
        var busy: Set<String> = []
        func isInstalling(_ id: String) -> Bool { busy.contains(id) }
        func install(_ dep: Dep) -> Task<Void, Never> { installed.append(dep.id); return Task {} }
    }

    private final class FakeEngine: EngineSyncing {
        var syncs = 0
        func syncEngine(then: ((Bool) -> Void)?) -> Task<Void, Never> { syncs += 1; then?(true); return Task {} }
    }

    private final class FakeDevices: InstallTarget {
        var installDevice = ""
        var signingTeam = ""
        var exportIPA = false
        var exportOneGame = false
        var driveFolder = ""
        var devices: [AppleDevice] = []
        var xcrun = "/usr/bin/true"
        var readTeams: @Sendable () -> [SigningTeam] = { [] }
        func deviceName(_ udid: String) -> String { devices.first { $0.id == udid }?.name ?? "iPhone" }
        nonisolated func askCopy(_ plan: ShellCopyPlan) -> ShellCopyDecision { .skip }
        nonisolated func setWaiting(_ on: Bool) {}
        nonisolated var waitCancelled: Bool { false }
        func copyEnded() {}
    }

    private var defaults: UserDefaults!
    private var temporary: URL!
    private let repo = FakeRepo()
    private let deps = FakeDeps()
    private let engine = FakeEngine()
    private let devices = FakeDevices()
    private let localizer = Localizer(.en)

    override func setUpWithError() throws {
        ExperimentalBuilder.featureEnabled = true   // the toggle is off in the app for now, these tests are about the builder
        defaults = TestDefaults.make("nxmodel-build-tests")
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        ExperimentalBuilder.featureEnabled = false
        try? FileManager.default.removeItem(at: temporary)
    }

    private func makeStore(targetChanged: @escaping () -> Void = {}) -> BuildStore {
        BuildStore(localizer: localizer, runner: FakeProcessRunner(), repo: repo, deps: deps, engine: engine, devices: devices,
                   defaults: defaults, targetChanged: targetChanged)
    }

    private func file(_ name: String) throws -> String {
        let url = temporary.appendingPathComponent(name)
        try Data([0]).write(to: url)
        return url.path
    }

    // MARK: The conditions to start

    func testABuildMayStartOnlyWithARepositoryTheBaseGameTheKeysAndTheToolsAndNoRunningBuild() throws {
        let store = makeStore()
        XCTAssertFalse(store.canBuild, "no files yet")
        store.updateSlot("base") { $0.paths = [try! file("Game [0100000000001000].nsp")] }
        store.updateSlot("keys") { $0.paths = [try! file("prod.keys")] }
        XCTAssertTrue(store.canBuild)
        repo.isRepo = false
        XCTAssertFalse(store.canBuild, "the repository is not usable")
        repo.isRepo = true; deps.allPresent = false
        XCTAssertFalse(store.canBuild, "a tool is missing")
        deps.allPresent = true; store.running = true
        XCTAssertFalse(store.canBuild, "a build runs")
    }

    // MARK: The keys saved in Settings (#996)

    func testAnEmptyKeysRowTakesTheSavedKeysAndANewStoreReadsThem() throws {
        let store = makeStore()
        let keys = try file("prod.keys")
        store.updateSlot("base") { $0.paths = [try! file("Game [0100000000001000].nsp")] }
        XCTAssertFalse(store.canBuild, "no keys yet")
        store.saveKeys(keys)
        XCTAssertTrue(store.keysRowPath.isEmpty)
        XCTAssertTrue(store.keysFromSettings)
        XCTAssertEqual(store.keysPath, keys)
        XCTAssertTrue(store.canBuild, "the saved keys stand in for the empty row")
        XCTAssertEqual(makeStore().savedKeys, keys, "kept in the defaults")
    }

    func testARowWhoseFileIsGoneTakesTheSavedKeysAndARowWithAFileKeepsIt() throws {
        let store = makeStore()
        let saved = try file("saved.keys"), own = try file("prod.keys")
        store.saveKeys(saved)
        store.updateSlot("keys") { $0.paths = [own] }
        XCTAssertFalse(store.keysFromSettings)
        XCTAssertEqual(store.keysPath, own, "the row's own file wins")
        try FileManager.default.removeItem(atPath: own)
        XCTAssertTrue(store.keysFromSettings)
        XCTAssertEqual(store.keysPath, saved, "the library entry's keys were moved: the saved ones stand in")
        try FileManager.default.removeItem(atPath: saved)
        XCTAssertFalse(store.keysFromSettings)
        XCTAssertFalse(store.savedKeysExist)
        XCTAssertEqual(store.keysPath, own, "nothing to stand in: the row's missing file, which the build reports")
        XCTAssertFalse(store.keysReady)
    }

    func testRemoveEmptiesTheSettingAndKeepsTheRow() throws {
        let store = makeStore()
        let keys = try file("prod.keys")
        store.take(picked: [keys], kind: .keys)
        XCTAssertEqual(store.savedKeys, keys, "a keys file chosen for the row is saved")
        store.forgetSavedKeys()
        XCTAssertEqual(store.savedKeys, "")
        XCTAssertNil(defaults.string(forKey: BuildStore.savedKeysKey))
        XCTAssertEqual(store.keysRowPath, keys)
        store.clear("keys")
        XCTAssertTrue(store.keysPath.isEmpty)
    }

    func testSettingsChooseSavesThePickedFileAndACancelChangesNothing() throws {
        let store = makeStore()
        let keys = try file("prod.keys")
        var asked: [FilePick] = []
        store.choosePaths = { asked.append($0); return [] }
        store.chooseSavedKeys()
        XCTAssertEqual(store.savedKeys, "")
        store.choosePaths = { asked.append($0); return [keys] }
        store.chooseSavedKeys()
        XCTAssertEqual(store.savedKeys, keys)
        XCTAssertEqual(asked.last?.fileTypes, GameInputs.allowedFileTypes(for: .keys))
        XCTAssertEqual(asked.last?.allowsMultiple, false)
    }

    func testOnlyAChosenKeysFileIsSavedNeverOneAScanFinds() throws {
        let store = makeStore()
        let folder = temporary.appendingPathComponent("Game").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let inside = folder + "/prod.keys"
        try Data([0]).write(to: URL(fileURLWithPath: inside))
        try Data([0]).write(to: URL(fileURLWithPath: folder + "/Game [0100000000001000][v0].nsp"))
        store.scan(folder: folder)
        XCTAssertEqual(store.keysRowPath, inside)
        XCTAssertEqual(store.savedKeys, "", "a folder scan fills the row and saves nothing")
        store.take(dropped: [folder])
        XCTAssertEqual(store.savedKeys, "", "nor does a dropped folder")
        let dropped = try file("dropped.keys")
        store.take(dropped: [dropped])
        XCTAssertEqual(store.savedKeys, dropped, "a keys file dropped itself is a choice")
    }

    /// #416: the export choice is not an install, so the stop for a missing device and team does not apply to it.
    func testTheExportChoiceNeedsNoDeviceAndNoTeam() {
        let store = makeStore()
        store.target = "ios"
        devices.exportIPA = true
        XCTAssertTrue(store.exportsShell)
        XCTAssertFalse(store.installsDirectly)
        store.startBuild()
        XCTAssertNotEqual(store.doneNote, store.t("shell.needsDevice"))
        store.target = BuildTarget.mac
        XCTAssertFalse(store.exportsShell, "a Mac app is never an IPA")
    }

    func testAnIPhoneBuildWithoutADeviceStopsBeforeTheLongSteps() {
        let store = makeStore()
        store.target = "ios"
        store.startBuild()
        XCTAssertFalse(store.running)
        XCTAssertEqual(store.doneNote, store.t("shell.needsDevice"))
        XCTAssertFalse(store.installsDirectly)
        devices.installDevice = "UDID"; devices.signingTeam = "TEAM"
        XCTAssertTrue(store.installsDirectly)
        store.target = "mac-app"
        XCTAssertFalse(store.installsDirectly, "a Mac app is not installed on a device")
    }

    func testABuildWithoutARepositoryEndsWithTheMessageAndRunsNothing() {
        let store = makeStore()
        store.target = "mac-app"
        repo.isRepo = false; repo.path = ""
        store.startBuild()
        XCTAssertFalse(store.running)
        XCTAssertEqual(store.doneNote, store.t("msg.repoInvalidEmpty"))
        XCTAssertTrue(store.log.text.contains("✗"), "the log says it too")
    }

    // MARK: The inputs

    func testTheTargetTheOutputFolderAndTheCompatibilitySwitchAreSavedAndTheTargetTellsTheApp() {
        var changes = 0
        let store = makeStore { changes += 1 }
        store.target = "mac-app"; store.outDir = "/out"; store.bcOnCPU = true
        XCTAssertEqual(defaults.string(forKey: BuildStore.targetKey), "mac-app")
        XCTAssertEqual(defaults.string(forKey: BuildStore.outputKey), "/out")
        XCTAssertTrue(defaults.bool(forKey: BuildStore.bcOnCPUKey))
        XCTAssertEqual(changes, 1)
        store.target = "mac-app"
        XCTAssertEqual(changes, 1, "the same target is no change")
        XCTAssertEqual(makeStore().outDir, "/out", "a new store starts from what was saved")
    }

    // MARK: The experimental builder (#749)

    func testTheExperimentalBuilderIsOffByDefaultAndItsSettingIsSaved() {
        let store = makeStore()
        XCTAssertFalse(store.experimentalBuilder)
        XCTAssertNil(store.experimentalBuilderProblem(), "off: nothing to say")
        store.experimentalBuilder = true; store.experimentalBuilderPath = "/opt/nxbuild"
        XCTAssertTrue(defaults.bool(forKey: BuildStore.experimentalBuilderKey))
        XCTAssertEqual(defaults.string(forKey: BuildStore.experimentalBuilderPathKey), "/opt/nxbuild")
        let again = makeStore()
        XCTAssertTrue(again.experimentalBuilder)
        XCTAssertEqual(again.experimentalBuilderPath, "/opt/nxbuild")
    }

    func testWithTheToggleOffASavedExperimentalBuilderIsIgnoredAndComesBackWhenItIsOn() {
        let store = makeStore()
        store.experimentalBuilder = true; store.experimentalBuilderPath = "/opt/nxbuild"
        ExperimentalBuilder.featureEnabled = false
        let off = makeStore()
        XCTAssertFalse(off.experimentalBuilder, "toggle off: the saved choice does not apply")
        XCTAssertNil(off.experimentalBuilderProblem())
        XCTAssertTrue(defaults.bool(forKey: BuildStore.experimentalBuilderKey), "and it stays saved")
        ExperimentalBuilder.featureEnabled = true
        XCTAssertTrue(makeStore().experimentalBuilder, "toggle on again: the choice is back")
    }

    func testTheExperimentalBuilderStopsWithoutANewEnoughNxbAndNeverRunsTheScript() throws {
        let runner = FakeProcessRunner()
        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults, targetChanged: {})
        store.bundledBuilder = nil
        XCTAssertNil(store.experimentalBuilderProblem(), "off: nothing to say")
        store.experimentalBuilder = true
        store.experimentalBuilderPath = temporary.path + "/gone/nxb"
        XCTAssertNil(store.experimentalBuilderBinary)
        XCTAssertEqual(store.experimentalBuilderProblem(), store.t("msg.builderMissingError"), "no nxb is an error, not a build by the script")
        let nxb = try file("nxb")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nxb)
        store.experimentalBuilderPath = temporary.path   // the folder that holds it
        XCTAssertEqual(store.experimentalBuilderBinary, nxb)
        runner.answer = { _ in ProcessResult(status: 0, out: "nxb 0.4.0\n") }
        XCTAssertEqual(store.experimentalBuilderProblem(), String(format: store.t("nxb.tooOld"), "nxb 0.4.0", ExperimentalBuilder.minimumVersion))
        runner.answer = { _ in ProcessResult(status: 0, out: "nxb 0.6.3\n") }
        XCTAssertNil(store.experimentalBuilderProblem(), "a game or a step nxb does not take ends with its own exit code 4")
        XCTAssertTrue(runner.commands.contains("nxb version"))
        store.experimentalBuilder = false
        XCTAssertNil(store.experimentalBuilderProblem())
    }

    func testAFailedNxbBuildSaysItsExitCodeAndItsLastErrorLine() {
        let store = makeStore()
        store.append("{\"ev\": \"say\", \"msg\": \"[RED] no key master_key_0f in prod.keys\", \"severity\": \"error\"}\n")
        XCTAssertEqual(store.experimentalFailureNote(status: 6), String(format: store.t("nxb.exit.6"), 6) + " no key master_key_0f in prod.keys")
        XCTAssertTrue(store.experimentalFailureNote(status: 4).contains("exit code 4"))
    }

    func testTakingFilesFillsTheRowAndNamesTheFirstFileThatDoesNotFit() {
        let store = makeStore()
        store.take(picked: ["/g/Game [0100000000001000].nsp"], kind: .base)
        XCTAssertEqual(store.basePath, "/g/Game [0100000000001000].nsp")
        XCTAssertEqual(store.gameDir, "/g")
        store.take(picked: ["/g/Other [0100000000002800].nsp", "/g/Game update [0100000000001800].nsp"], kind: .update)
        XCTAssertEqual(store.updatePath, "/g/Game update [0100000000001800].nsp", "the file that fits is taken")
        XCTAssertFalse(store.slot("update").problem.isEmpty, "the other one is named on the row")
        store.clear("update")
        XCTAssertEqual(store.updatePath, "")
        XCTAssertEqual(store.slot("update").problem, "")
    }

    func testThePickerIsTheAppsAndGetsTheRowsWordsAndFileTypes() {
        let store = makeStore()
        var asked: [FilePick] = []
        store.choosePaths = { asked.append($0); return ["/g/Game dlc [0100000000001001].nsp"] }
        store.pickFiles(kind: .dlc)
        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(asked[0].allowsMultiple)
        XCTAssertEqual(asked[0].fileTypes, GameInputs.allowedFileTypes(for: .dlc))
        XCTAssertEqual(asked[0].message, store.t("data.dlcPanelMessage"))
        store.choosePaths = { _ in [] }
        store.pickFiles(kind: .update)
        XCTAssertEqual(store.updatePath, "", "a cancelled panel changes nothing")
    }

    /// #708: an image a previous build left is named to the script with --romfs-from, for each target. The experimental builder
    /// gets the script's arguments, and `nxb build` has no such option: with it on, the option is left out.
    func testAReusableImageIsNamedToTheScriptButNotToNxbBuild() throws {
        let runner = FakeProcessRunner()
        runner.answer = { _ in ProcessResult(status: 0, out: "nxb 0.6.3\n") }
        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        for path in [EngineLayout.marker] + RepoLayout.requiredTools {
            let url = temporary.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "'--work-dir' '--romfs-from'".write(to: url, atomically: true, encoding: .utf8)
        }
        repo.path = temporary.path
        let key = "0100000000010000"
        store.take(picked: [try file("Cartridge [\(key)].xci")], kind: .base)
        store.take(picked: [try file("test.keys")], kind: .keys)
        store.outDir = temporary.path
        defaults.set(temporary.appendingPathComponent("shell").path, forKey: "shellRoot")
        devices.exportIPA = true
        let image = temporary.path + "/games/\(key)/romfs.img"
        try FileManager.default.createDirectory(atPath: (image as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        for path in [image, image + ".id"] { try Data([0]).write(to: URL(fileURLWithPath: path)) }
        let nxb = temporary.path + "/nxbuild/nxb"
        try FileManager.default.createDirectory(atPath: (nxb as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data([0]).write(to: URL(fileURLWithPath: nxb))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nxb)
        store.experimentalBuilderPath = nxb
        for target in [BuildTarget.mac, BuildTarget.ios] {
            store.target = target
            store.experimentalBuilder = false
            store.startBuild()
            var args = store.lastBuildCommand
            XCTAssertEqual(args.first, deps.pythonPath, "the script runs (\(target))")
            XCTAssertEqual(args.firstIndex(of: "--romfs-from").map { args[$0 + 1] }, image, "the script is offered the image (\(target))")
            store.experimentalBuilder = true
            store.startBuild()
            args = store.lastBuildCommand
            XCTAssertEqual(Array(args.prefix(2)), [nxb, "build"], "nxb build runs (\(target))")
            XCTAssertFalse(args.contains("--romfs-from"), "nxb build is not given an option it rejects (\(target))")
        }
    }

    func testFallbackIconArgumentsGoToMacScriptBuildsOnly() throws {
        let runner = FakeProcessRunner()
        runner.answer = { _ in ProcessResult(status: 0, out: "nxb 0.6.4\n") }
        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        let iconPath = temporary.appendingPathComponent("fallback-icon.jpg").path
        store.macFallbackIconArguments = { ["--fallback-icon", "\(iconPath)-\($0)"] }
        let scriptURL = temporary.appendingPathComponent(RepoLayout.buildScript)
        for path in [EngineLayout.marker] + RepoLayout.requiredTools {
            let url = temporary.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "'--work-dir'".write(to: url, atomically: true, encoding: .utf8)
        }
        repo.path = temporary.path
        let key = "0100000000010000"
        store.take(picked: [try file("Cartridge [\(key)].xci")], kind: .base)
        store.take(picked: [try file("test.keys")], kind: .keys)
        store.outDir = temporary.path
        defaults.set(temporary.appendingPathComponent("shell").path, forKey: "shellRoot")
        devices.exportIPA = true
        let nxb = temporary.path + "/nxbuild/nxb"
        try FileManager.default.createDirectory(atPath: (nxb as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data([0]).write(to: URL(fileURLWithPath: nxb))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nxb)
        store.experimentalBuilderPath = nxb

        store.target = BuildTarget.mac
        store.experimentalBuilder = false
        store.startBuild()
        XCTAssertFalse(store.lastBuildCommand.contains("--fallback-icon"), "older scripts without --fallback-icon do not receive it")

        try "'--work-dir' '--fallback-icon'".write(to: scriptURL, atomically: true, encoding: .utf8)
        store.startBuild()
        var args = store.lastBuildCommand
        XCTAssertEqual(args.firstIndex(of: "--fallback-icon").map { args[$0 + 1] }, "\(iconPath)-\(key)")

        store.experimentalBuilder = true
        store.startBuild()
        XCTAssertFalse(store.lastBuildCommand.contains("--fallback-icon"), "nxb build rejects unknown script options")

        store.experimentalBuilder = false
        store.target = BuildTarget.ios
        store.startBuild()
        args = store.lastBuildCommand
        XCTAssertFalse(args.contains("--fallback-icon"), "the iOS app and shared shell never take the Mac stand-in icon")
    }

    func testRetryBuildsTheChosenTitleAndKeepsItsOutputsSeparate() throws {
        let store = makeStore()
        for path in [EngineLayout.marker] + RepoLayout.requiredTools {
            let url = temporary.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "'--work-dir'".write(to: url, atomically: true, encoding: .utf8)
        }
        repo.path = temporary.path
        store.take(picked: [try file("Cartridge [0100000000010000].xci")], kind: .base)
        store.take(picked: [try file("test.keys")], kind: .keys)
        store.outDir = temporary.path
        defaults.set(temporary.appendingPathComponent("shell").path, forKey: "shellRoot")
        devices.exportIPA = true
        let second = "01006F8002326000"
        let diagnostic = "[RED] more than one game in the folder: 0100000000010000, \(second); keep one game per folder, or name the one to pack with --title-id / TITLE_ID (a cartridge dump that holds two games)"
        for target in [BuildTarget.mac, BuildTarget.ios] {
            store.target = target
            store.startBuild()
            XCTAssertFalse(store.lastBuildCommand.contains("--title-id"))
            store.logTail = diagnostic
            store.noteFailure()
            store.buildTitle("0100000000090000")  // not in the engine's list
            XCTAssertFalse(store.lastBuildCommand.contains("--title-id"))
            store.buildTitle(second)
            let args = store.lastBuildCommand
            XCTAssertEqual(args.firstIndex(of: "--title-id").map { args[$0 + 1] }, second)
            let work = temporary.path + "/" + second + "_build"
            XCTAssertEqual(args.firstIndex(of: "--work-dir").map { args[$0 + 1] }, work)
            XCTAssertEqual(store.gameTitleID, second, "the library remembers the selected game")
            if target == BuildTarget.mac {
                XCTAssertEqual(args.firstIndex(of: "-o").map { args[$0 + 1] }, work + "/" + second + ".app")
            } else {
                XCTAssertEqual(args.firstIndex(of: "--shell-framework").map { args[$0 + 1] }, work + "/shell-framework")
            }
        }
        store.logTail = diagnostic
        store.noteFailure()
        store.take(picked: [try file("Another.xci")], kind: .base)
        XCTAssertNil(store.failure, "choices from the previous input no longer apply")
        XCTAssertNil(store.gameTitleID)
    }

    // MARK: The script's events

    func testLastShaderFileHintFollowsTheReportedBatch() {
        let store = makeStore()
        func progress(_ done: Int, _ total: Int, name: String = "shader split", step: String = "splitting",
                      unit: String = "files", estimated: Bool = false) {
            store.handleEvent("progress", ["k": 2, "name": name, "step": step, "unit": unit,
                                           "done": done, "total": total, "est": estimated, "frac": 0.99])
        }

        progress(304_227, 304_243)
        XCTAssertTrue(store.stages[0].isScanningLastShaderFiles)
        XCTAssertEqual(store.stages[0].percent, 99)
        XCTAssertEqual(store.stages[0].detail, BuildProgress.progressDetail(["step": "splitting", "unit": "files",
                                                                             "done": 304_227, "total": 304_243]))
        progress(48_145, 48_146)
        XCTAssertTrue(store.stages[0].isScanningLastShaderFiles)
        store.handleEvent("step", ["k": 2, "name": "shader split", "step": "checking the outputs"])
        XCTAssertFalse(store.stages[0].isScanningLastShaderFiles)
        for done in [0, 48_129, 48_146] {
            progress(done, 48_146)
            XCTAssertFalse(store.stages[0].isScanningLastShaderFiles)
        }
        progress(48_130, 48_146, name: "extract")
        XCTAssertFalse(store.stages[0].isScanningLastShaderFiles)
        progress(48_130, 48_146, step: "checking the inputs")
        XCTAssertFalse(store.stages[0].isScanningLastShaderFiles)
        progress(48_130, 48_146, unit: "B")
        XCTAssertFalse(store.stages[0].isScanningLastShaderFiles)
        progress(48_130, 48_146, estimated: true)
        XCTAssertFalse(store.stages[0].isScanningLastShaderFiles)
        progress(48_130, 48_146)
        store.handleEvent("stage_end", ["k": 2, "name": "shader split", "ok": false])
        XCTAssertFalse(store.stages[0].isScanningLastShaderFiles)
    }

    func testTheScriptsJSONEventsBecomeStagesAndLogLines() {
        let store = makeStore()
        store.ingest("{\"ev\":\"stage\",\"k\":1,\"n\":3,\"name\":\"extract\",\"step\":\"keys\"}\n")
        XCTAssertEqual(store.stages.map(\.id), [1])
        XCTAssertEqual(store.stages[0].state, .running)
        XCTAssertEqual(store.stages[0].detail, "keys")
        store.ingest("{\"ev\":\"progress\",\"k\":1,\"frac\":0.5,\"done\":5,\"total\":10}\n{\"ev\":\"stage_end\",\"k\":1,\"name\":\"extract\",\"ok\":true,\"elapsed\":3,\"summary\":\"10 files\"}\n")
        XCTAssertEqual(store.stages[0].state, .done)
        XCTAssertEqual(store.stages[0].detail, "10 files")
        XCTAssertEqual(store.stages[0].percent, 100)
        XCTAssertTrue(store.log.text.contains("[1/3] extract · keys …"))
        XCTAssertTrue(store.log.text.contains("✓ extract (\(BuildProgress.duration(3))): 10 files"))
    }

    func testPipelineArchiveStageFallsBackToWorkDirAndYieldsToNativeJSONProgress() throws {
        let fm = FileManager.default
        let macWork = temporary.appendingPathComponent("pso/mac-work")
        try fm.createDirectory(at: macWork, withIntermediateDirectories: true)
        let entry = #"{"vertex_function_descriptor":"v"}"#
        let jsText = "{\"pipelines\":[" + Array(repeating: entry, count: 2500).joined(separator: ",") + "]}\n"
        try Data(jsText.utf8).write(to: macWork.appendingPathComponent("bases.mtl4-json"))
        let arch = "applegpu_g13s"
        let b1 = macWork.appendingPathComponent("batches.\(arch)/00001")
        try fm.createDirectory(at: b1, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: b1.appendingPathComponent("bases.mtl4-json"))
        try Data("archive".utf8).write(to: b1.appendingPathComponent("\(arch).mtl4a"))
        try Data("k\n".utf8).write(to: b1.appendingPathComponent("key.\(arch)"))

        let store = makeStore()
        store.effectiveWorkDir = temporary.path
        store.handleEvent("stage", ["k": 6, "n": 7, "name": "Pipeline archive", "step": "applegpu_g13s (metal-tt)"])
        store.pollPSOArchive()
        XCTAssertEqual(store.stages[0].percent ?? 0, 100.0 / 3.0, accuracy: 0.1)
        XCTAssertTrue(store.stages[0].detail.contains("1 / 3 batches"))

        // Verify localized unit and merging note in Chinese
        store.lang = .zh
        store.stages[0].detail = ""
        store.pollPSOArchive()
        XCTAssertTrue(store.stages[0].detail.contains("1 / 3 批"), store.stages[0].detail)
        store.lang = .en

        // Once the script sends native progress, polling stops overriding it
        store.handleEvent("progress", ["k": 6, "name": "Pipeline archive", "step": "applegpu_g13s (metal-tt)",
                                       "done": 2, "total": 3, "unit": "batches", "frac": 0.66])
        store.pollPSOArchive()
        XCTAssertEqual(store.stages[0].percent ?? 0, 66.0, accuracy: 0.1)
        XCTAssertTrue(store.stages[0].detail.contains("2 / 3 batches"))
    }

    func testNonJSONGameFrameworkStageLinesPollPSOArchiveProgressFromFrameworkLogAndStopAtStageEnd() throws {
        // Aligns with build_ipa_from_nsp.py (--shell-framework): W=<work>/ipa writes ipa/build/ios/pso/work/bases.mtl4-json
        // while pso_offline.py batch lines stream to <work>/logs/build_framework.log.
        let psoWorkDir = temporary.appendingPathComponent("ipa/build/ios/pso/work")
        let logsDir = temporary.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: psoWorkDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try Data("{\"bases\":[]}\n".utf8).write(to: psoWorkDir.appendingPathComponent("bases.mtl4-json"))
        let frameworkLog = logsDir.appendingPathComponent("build_framework.log")
        try Data("pso_offline: arm64: batch 2/4: ready\n".utf8).write(to: frameworkLog)

        let store = makeStore()
        store.effectiveWorkDir = temporary.path

        // Non-JSON stage start line from --shell-framework mode.
        store.ingest("[12:00:01] [7/8] game framework …\n")
        XCTAssertEqual(store.stages.count, 1)
        XCTAssertEqual(store.stages[0].id, 7)
        XCTAssertEqual(store.stages[0].state, .running)

        store.pollPSOArchive()
        XCTAssertEqual(store.stages[0].percent ?? 0, 50.0, accuracy: 0.1)
        XCTAssertTrue(store.stages[0].detail.contains("2 / 4 batches"), store.stages[0].detail)

        // Heartbeat running line without native percent must preserve polled PSO progress.
        store.ingest("[12:00:05] [7/8] game framework …\n")
        XCTAssertEqual(store.stages[0].percent ?? 0, 50.0, accuracy: 0.1)
        XCTAssertTrue(store.stages[0].detail.contains("2 / 4 batches"), store.stages[0].detail)

        // Merging line in build_framework.log updates detail and caps percent at 99%.
        try Data("pso_offline: arm64: batch 2/4: ready\npso_offline: arm64: merging 4 batches\n".utf8).write(to: frameworkLog)
        store.pollPSOArchive()
        XCTAssertEqual(store.stages[0].percent ?? 0, 99.0, accuracy: 0.1)
        XCTAssertTrue(store.stages[0].detail.contains("4 / 4 batches"), store.stages[0].detail)
        XCTAssertTrue(store.stages[0].detail.contains(store.t("prog.note.merging")), store.stages[0].detail)

        // Non-JSON stage completion line stops PSO polling and records final detail.
        store.ingest("[12:00:10] ✓ [7/8] game framework (0:09): DmGame0100CD801CE5E000.framework\n")
        XCTAssertEqual(store.stages[0].state, .done)
        XCTAssertEqual(store.stages[0].detail, "DmGame0100CD801CE5E000.framework")
        store.pollPSOArchive()
        XCTAssertEqual(store.stages[0].detail, "DmGame0100CD801CE5E000.framework")
    }

    func testAChunkThatEndsInTheMiddleOfALineWaitsForTheRest() {
        let store = makeStore()
        store.ingest("{\"ev\":\"stage\",\"k\":2,\"n\":3,\"na")
        XCTAssertTrue(store.stages.isEmpty)
        store.ingest("me\":\"pack\"}\nplain line from a tool\n")
        XCTAssertEqual(store.stages.map(\.id), [2])
        XCTAssertTrue(store.log.text.contains("plain line from a tool\n"), "what is not an event is log text")
    }

    func testStaleShaderEventsDoNotAskForAcknowledgementBeforeTheNextProgressEvent() {
        let store = makeStore()
        store.ingest("{\"ev\":\"shaders_stale\",\"reason\":\"chain\"}\n{\"ev\":\"progress\",\"k\":2,\"name\":\"mac shaders\",\"frac\":0.5,\"done\":5,\"total\":10}\n")
        XCTAssertEqual(store.staleShadersMessageKey.map(store.t), store.t("msg.shadersStale.chain"))
        XCTAssertEqual(store.stages.first?.percent, 50)
    }

    func testTheStaleShadersNoticeShowsOncePerBuildForEachReason() {
        for (reason, text) in [("chain", "msg.shadersStale.chain"), ("inputs", "msg.shadersStale.inputs")] {
            let store = makeStore()
            let event = "{\"ev\":\"shaders_stale\",\"reason\":\"\(reason)\",\"old\":\"b-4e0dd2535996\",\"new\":\"b-b7cd656abd7c\",\"count\":65}\n"
            store.ingest(event)
            store.ingest(event)   // the next shader step of the same build
            store.noteStaleShaders(reason: reason == "chain" ? "inputs" : "chain")
            XCTAssertEqual(store.staleShadersMessageKey.map(store.t), store.t(text), reason)
        }
    }

    func testTheNoteLineAndAnUnknownReasonShowNoNotice() {
        let store = makeStore()
        store.ingest("{\"ev\":\"say\",\"msg\":\"[NOTE] cached shader libraries cannot be reused (a -> b): the translation chain changed\"}\n")
        XCTAssertNil(store.staleShadersMessageKey, "the event shows the notice, the note that follows it is a log line")
        store.ingest("{\"ev\":\"shaders_stale\",\"reason\":\"newer\",\"old\":\"a\",\"new\":\"b\",\"count\":1}\n")
        XCTAssertNil(store.staleShadersMessageKey, "no text explains a reason a newer script adds")
        store.noteStaleShaders(reason: "chain")
        XCTAssertNotNil(store.staleShadersMessageKey, "an unknown reason does not hide a later known reason")
    }

    func testANewBuildClearsThePreviousShaderRebuildNotice() {
        let store = makeStore()
        store.noteStaleShaders(reason: "chain")
        store.target = BuildTarget.mac
        repo.isRepo = false   // stop before starting any external tools
        store.startBuild()
        XCTAssertNil(store.staleShadersMessageKey)
        store.noteStaleShaders(reason: "inputs")
        XCTAssertEqual(store.staleShadersMessageKey.map(store.t), store.t("msg.shadersStale.inputs"))
    }

    // MARK: The failure

    func testAFailedBuildsLogIsClassifiedAndAnUnknownStopLeavesTheNote() {
        let store = makeStore()
        store.logTail = "[RED] the iOS SDK is not installed\n"
        store.noteFailure()
        XCTAssertEqual(store.failure?.kind, .iosSDK)
        XCTAssertEqual(store.doneNote, store.t(BuildFailureKind.iosSDK.whatKey))
        store.doneNote = "Build failed: something else"
        store.logTail = "nothing the table knows"
        store.noteFailure()
        XCTAssertNil(store.failure)
        XCTAssertEqual(store.doneNote, "Build failed: something else")
    }

    func testBuildAnywayAsksFirstAndArmsTheFlagForOneBuildOnly() {
        let store = makeStore()
        store.target = "mac-app"
        repo.isRepo = false   // the build that follows ends at once, which is all this test needs
        store.failure = BuildFailure(kind: .iosSDK, gameName: nil)
        store.requestBuildAnyway()
        XCTAssertNil(store.confirmingOverride, "this stop has no override")
        store.failure = BuildFailure(kind: .otherMetal, gameName: nil)
        store.running = true
        store.requestBuildAnyway()
        XCTAssertNil(store.confirmingOverride, "not while a build runs")
        store.running = false
        store.requestBuildAnyway()
        XCTAssertEqual(store.confirmingOverride, .otherMetal)
        XCTAssertNil(store.armedOverride, "nothing is armed before the confirmation")
        store.cancelBuildAnyway()
        XCTAssertNil(store.confirmingOverride)
        store.requestBuildAnyway()
        store.confirmBuildAnyway()
        XCTAssertNil(store.confirmingOverride)
        XCTAssertNil(store.armedOverride, "the build took the flag: the next one asks again")
        XCTAssertNil(store.takeOverrideFlag())
        store.armedOverride = .damagedNSP
        XCTAssertEqual(store.takeOverrideFlag(), "--allow-damaged")
        XCTAssertNil(store.takeOverrideFlag())
    }

    func testTheFixButtonsRunTheDependencyRowsOwnInstall() {
        let store = makeStore()
        deps.deps = [Dep(id: "dotnet", name: "dep.dotnet", hint: "", present: false, installCmd: ["/usr/bin/true"]),
                     Dep(id: "python", name: "dep.python", hint: "", present: false, installCmd: ["/usr/bin/true"])]
        store.fixBuildFailure(.translator)
        store.fixBuildFailure(.zbic)
        store.fixBuildFailure(.iosSDK)
        XCTAssertEqual(deps.installed, ["dotnet", "python", "xcode"])
        XCTAssertFalse(store.fixBusy(.translator))
        deps.busy = ["dotnet"]
        XCTAssertTrue(store.fixBusy(.translator))
        XCTAssertFalse(store.fixBusy(.zbic))
        XCTAssertFalse(store.fixBusy(.keys), "a fix that is no install is never busy")
    }

    func testTheKeysFixUsesTheKeysPickerAndTheCloudFixTheFolderPanel() {
        let store = makeStore()
        var keysAsked = 0
        store.chooseKeys = { keysAsked += 1 }
        store.fixBuildFailure(.keys)
        XCTAssertEqual(keysAsked, 1)
        store.failure = BuildFailure(kind: .cloudFolder, gameName: nil, detail: "/iCloud/x")
        store.doneNote = "stopped"
        store.chooseFolder = { nil }
        store.fixBuildFailure(.cloudFolder)
        XCTAssertEqual(store.failure?.kind, .cloudFolder, "a cancelled panel keeps the stop")
        store.chooseFolder = { "/Users/x/Games" }
        store.fixBuildFailure(.cloudFolder)
        XCTAssertEqual(store.outDir, "/Users/x/Games")
        XCTAssertNil(store.failure, "the next build looks at the new folder")
        XCTAssertEqual(store.doneNote, "")
    }

    func testTheFailureFolderOpensInTheFinderForAFullDisk() throws {
        let store = makeStore()
        let built = temporary.appendingPathComponent("0100_build")
        try FileManager.default.createDirectory(at: built, withIntermediateDirectories: true)
        store.gameDir = temporary.path
        store.failure = BuildFailure(kind: .diskFull, gameName: nil, detail: "40")
        var shown: [URL] = []
        store.revealFolder = { shown.append($0) }
        store.showFailureFolder()
        XCTAssertEqual(shown.map(\.path), [built.path])
    }

    // MARK: The install on a device

    func testReinstallAndResignSayWhyTheyCannotRunInsteadOfStartingATool() {
        let store = makeStore()
        store.reinstallOnDevice()
        XCTAssertFalse(store.running, "nothing was installed: nothing to reinstall")
        store.installedOn = "UDID"; store.installedAppPath = temporary.path + "/gone/DmIOS.app"
        store.reinstallOnDevice()
        XCTAssertFalse(store.running)
        XCTAssertEqual(store.doneNote, String(format: store.t("dev.reinstallMissing"), store.shortPath(store.installedAppPath)))
        store.resignOnDevice(app: store.installedAppPath, device: "UDID")
        XCTAssertEqual(store.doneNote, store.t("dev.resignNoTeam"))
        devices.signingTeam = "TEAM"
        store.resignOnDevice(app: store.installedAppPath, device: "UDID")
        XCTAssertEqual(store.doneNote, store.t("dev.resignOlder"))
        XCTAssertFalse(store.running)
    }

    func testTheSavePanelIsTheAppsAndACancelWritesNothing() {
        let store = makeStore()
        var asked: [(String, String)] = []
        store.chooseSaveLocation = { asked.append(($0, $1)); return nil }
        store.saveIPAPanel()
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.0, store.t("dev.saveIPATitle"))
        XCTAssertEqual(asked.first?.1, "DmIOS.ipa")
        XCTAssertFalse(store.running)
    }

    func testTheRetryOfTheGameDataNeedsAnInstallThatLeftOneToRetry() {
        let store = makeStore()
        store.retryShellData()
        XCTAssertFalse(store.running, "no install ran: nothing to retry")
    }

    func testWhatTheStoreWritesItselfIsInTheLanguageOfTheLocalizer() {
        let store = makeStore()
        localizer.lang = Lang("de")
        XCTAssertEqual(store.lang, Lang("de"))
        XCTAssertEqual(store.t("shell.needsDevice"), L10n.string("shell.needsDevice", Lang("de")))
    }

    func testAStoppedBuildWithNothingRunningDoesNothing() {
        let store = makeStore()
        store.stop()
        XCTAssertFalse(store.stopping)
    }

    // MARK: Move cache folder (#427)

    /// A store whose home is the temporary folder, so the default cache place is never the real Application Support.
    private func moveStore() throws -> (BuildStore, cache: String) {
        let store = makeStore()
        store.home = temporary.path + "/home"
        let cache = store.home + "/Library/Application Support/NX2Apple/shell"
        try FileManager.default.createDirectory(atPath: cache + "/frameworks/DmGame0100AAAA.framework", withIntermediateDirectories: true)
        try Data("shader".utf8).write(to: URL(fileURLWithPath: cache + "/frameworks/DmGame0100AAAA.framework/game.manifest.json"))
        let json: [String: Any] = ["bundleID": "org.nxnative.shell.TEAM", "team": "TEAM", "games": [["titleID": "0100AAAA", "name": "A", "framework": cache + "/frameworks/DmGame0100AAAA.framework"]]]
        try JSONSerialization.data(withJSONObject: json).write(to: URL(fileURLWithPath: cache + "/shell.json"))
        XCTAssertEqual(store.shellCachePath, cache)
        XCTAssertTrue(store.shellCacheIsDefault)
        return (store, cache)
    }

    /// The build guard: no move starts while a build, an install or an export runs, and nothing on disk changes.
    func testTheCacheDoesNotMoveWhileABuildRuns() throws {
        let (store, cache) = try moveStore()
        let picked = temporary.path + "/Drive"
        try FileManager.default.createDirectory(atPath: picked, withIntermediateDirectories: true)
        store.prepareShellMove(into: picked)
        guard case .confirm(let plan) = store.shellMove else { return XCTFail("the confirmation shows") }
        XCTAssertEqual(plan.destination, picked + "/NX2Apple-shell")
        store.running = true
        XCTAssertNil(store.confirmShellMove(), "refused while a build runs")
        XCTAssertEqual(store.shellMove, .confirm(plan), "the confirmation stays, with its note")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache + "/shell.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination))
        XCTAssertNil(defaults.string(forKey: "shellRoot"), "the saved place is unchanged")
    }

    /// While the cache moves the build store's `running` flag is set, so no build can start, and the saved place, shell.json and the
    /// way back follow the move.
    func testAMoveSavesTheNewPlaceAndTheWayBackClearsThePick() async throws {
        let (store, cache) = try moveStore()
        let picked = temporary.path + "/Drive"
        try FileManager.default.createDirectory(atPath: picked, withIntermediateDirectories: true)
        store.prepareShellMove(into: picked)
        let task = try XCTUnwrap(store.confirmShellMove())
        XCTAssertTrue(store.running, "builds, installs and exports are off while the cache moves")
        XCTAssertFalse(store.canBuild)
        await task.value
        let moved = picked + "/NX2Apple-shell"
        XCTAssertEqual(store.shellMove, .moved(moved))
        XCTAssertFalse(store.running)
        XCTAssertEqual(defaults.string(forKey: "shellRoot"), moved)
        XCTAssertTrue(defaults.bool(forKey: ShellRootMove.pickedKey))
        XCTAssertEqual(store.shellCachePath, moved)
        XCTAssertEqual(store.shellRoot, moved, "the launch migration leaves a picked folder where it is")
        XCTAssertFalse(store.shellCacheIsDefault)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache))
        XCTAssertEqual(ShellLibrary.load(root: moved).games.first?.framework, moved + "/frameworks/DmGame0100AAAA.framework")

        store.dismissShellMove()
        store.prepareShellMoveToDefault()
        await store.confirmShellMove()?.value
        XCTAssertEqual(store.shellMove, .moved(cache))
        XCTAssertEqual(defaults.string(forKey: "shellRoot"), cache)
        XCTAssertFalse(defaults.bool(forKey: ShellRootMove.pickedKey))
        XCTAssertTrue(store.shellCacheIsDefault)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: picked), [], "the picked folder stays, empty as it was")
    }

    /// A move that fails on the disk says why and where the cache stays, keeps the old folder and the saved place.
    func testAFailedMoveKeepsTheCacheAndTheSavedPlace() async throws {
        let (store, cache) = try moveStore()
        let picked = temporary.path + "/Locked"
        try FileManager.default.createDirectory(atPath: picked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: picked)   // nothing can be made inside it
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: picked) }
        store.prepareShellMove(into: picked)
        await store.confirmShellMove()?.value
        guard case .failed(let why, let stays) = store.shellMove else { return XCTFail("expected a failure, got \(store.shellMove)") }
        XCTAssertFalse(why.isEmpty)
        XCTAssertFalse(why.hasSuffix("."), "the text goes on after the reason, so the system's full stop is dropped")
        XCTAssertEqual(stays, cache)
        XCTAssertFalse(store.running)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache + "/frameworks/DmGame0100AAAA.framework/game.manifest.json"))
        XCTAssertNil(defaults.string(forKey: "shellRoot"))
        XCTAssertFalse(defaults.bool(forKey: ShellRootMove.pickedKey))
    }

    func testAMoveThatCannotStartKeepsTheSavedPlace() throws {
        let (store, cache) = try moveStore()
        store.prepareShellMove(into: cache + "/frameworks")
        guard case .confirm(let plan) = store.shellMove else { return XCTFail("the confirmation shows") }
        XCTAssertEqual(plan.problem, .insideCache)
        XCTAssertNil(store.confirmShellMove())
        XCTAssertFalse(store.running)
        XCTAssertNil(defaults.string(forKey: "shellRoot"))
    }

    // MARK: The check of a new Mac app's first start (#1005)

    /// A Mac app build that has run its stages and packed its app, as the script's exit leaves it: `finishMacApp` comes next.
    /// Each call packs into a folder of its own in the temporary folder, which tearDown removes with everything in it.
    private func packedMacApp(_ store: BuildStore) throws -> MacAppOutput {
        let id = "0100000000010000"
        let folder = temporary.appendingPathComponent(UUID().uuidString)
        let output = MacAppOutput(workDir: folder.appendingPathComponent(id + "_build"), key: id, titleID: id, preferred: "")
        let macOS = output.builderURL.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        for (name, content) in [("game", "DM_PREFLIGHT"), ("dmhost", "")] {   // MacGameBundle.read wants both executable
            let file = macOS.appendingPathComponent(name)
            try Data(content.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let info: [String: Any] = ["DMTitleID": id, "CFBundleExecutable": "game", "CFBundleName": "Journey"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: output.builderURL.appendingPathComponent("Contents/Info.plist"))
        store.running = true
        store.stages = [Stage(id: 6, name: "Shaders", state: .done), Stage(id: 7, name: Stage.localizedName("mac app", store.t), state: .done)]
        return output
    }

    func testAMacAppBuildEndsWithTheCheckOfItsFirstStart() async throws {
        let store = makeStore()
        let output = try packedMacApp(store)
        var opened: [URL] = []
        store.preflightApp = { app, done in
            opened.append(app)
            XCTAssertTrue(store.running, "the build runs until macOS has checked the app")
            XCTAssertFalse(store.done)
            DispatchQueue.main.async { done(nil) }
        }
        await store.finishMacApp(output).value
        XCTAssertTrue(store.macAppPath.hasPrefix(temporary.path), store.doneNote)
        XCTAssertEqual(opened.map(\.path), [store.macAppPath])
        let last = try XCTUnwrap(store.stages.last)
        XCTAssertEqual(last.id, 8)
        XCTAssertEqual(last.name, "Verify first start")
        XCTAssertEqual(last.state, .done)
        XCTAssertFalse(store.running)
        XCTAssertTrue(store.done)
        XCTAssertEqual(store.doneNote, store.t("msg.macAppDone"))
        XCTAssertTrue(store.log.text.contains(store.t("msg.preflight")), store.log.text)
    }

    func testNoCheckWhenSwitchedOffOrWhenTheLauncherWouldStartTheGame() async throws {
        for switchedOff in [true, false] {
            let store = makeStore()
            let output = try packedMacApp(store)
            defaults.set(!switchedOff, forKey: MacPreflight.defaultsKey)
            store.preflightSupported = { _ in switchedOff }   // off: the switch alone; on: a launcher without DM_PREFLIGHT
            store.preflightApp = { _, _ in XCTFail("the app was opened") }
            await store.finishMacApp(output).value
            XCTAssertEqual(store.stages.map(\.id), [6, 7])
            XCTAssertFalse(store.running)
            XCTAssertTrue(store.done, store.doneNote)
        }
        defaults.removeObject(forKey: MacPreflight.defaultsKey)
        XCTAssertTrue(MacPreflight.enabled(defaults), "on unless switched off")
    }

    func testAFailedCheckLeavesTheBuildDone() async throws {
        let store = makeStore()
        let output = try packedMacApp(store)
        store.preflightApp = { _, done in done(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "no launch"])) }
        await store.finishMacApp(output).value
        let last = try XCTUnwrap(store.stages.last)
        XCTAssertEqual(last.state, .failed)
        XCTAssertEqual(last.detail, "no launch")
        XCTAssertFalse(store.running)
        XCTAssertTrue(store.done)
        XCTAssertEqual(store.doneNote, store.t("msg.macAppDone"))
        XCTAssertTrue(store.log.text.contains(String(format: store.t("msg.preflightFailed"), "no launch")), store.log.text)
    }

    func testTheCheckEndsAtItsTimeoutOrAtStop() async throws {
        for stop in [false, true] {
            let store = makeStore()
            let output = try packedMacApp(store)
            store.preflightTimeout = stop ? 60 : 0.05
            store.preflightApp = { _, _ in if stop { DispatchQueue.main.async { store.stop() } } }   // the app never quits
            await store.finishMacApp(output).value
            let last = try XCTUnwrap(store.stages.last)
            XCTAssertEqual(last.state, .failed)
            XCTAssertEqual(last.detail, stop ? store.t("msg.stopped") : String(format: store.t("msg.preflightTimedOut"), 0))
            XCTAssertNil(store.endPreflight)
            XCTAssertFalse(store.running)
            XCTAssertTrue(store.done, store.doneNote)
        }
    }

    // MARK: Space and the operation (#966, #676, #1059)

    func testABuildDoesNotStartWhenTheVolumeHasLessThanTheGameFilesAndSaysWhatIsKept() throws {
        let store = makeStore()
        store.target = BuildTarget.mac
        store.updateSlot("base") { $0.paths = [try! file("Game [0100000000001000].nsp")] }
        store.updateSlot("keys") { $0.paths = [try! file("prod.keys")] }
        store.outDir = temporary.path
        store.spaceAvailable = { _ in 0 }
        store.startBuild()
        XCTAssertFalse(store.running)
        XCTAssertTrue(store.doneNote.contains("Not enough free space"), store.doneNote)
        XCTAssertNil(store.operation)
    }

    func testTheOperationNamesItsGameAndDestinationAndFollowsNeitherTheFormNorTheTarget() {
        let store = makeStore()
        store.target = BuildTarget.mac
        store.runningTarget = BuildTarget.ios
        store.beginOperation(.renewingSignature, game: nil, titleID: nil, destination: .none)
        XCTAssertEqual(store.operation, ActiveOperation(kind: .renewingSignature))
        store.beginOperation(.building, game: "Game A", titleID: "0100000000001000", destination: .target)
        store.runningTarget = BuildTarget.mac
        store.beginOperation(.building, game: "Game A", titleID: "0100000000001000", destination: .target)
        XCTAssertEqual(store.operation?.destination, .thisMac)
        XCTAssertEqual(store.operation?.title { $0 }, "op.building · Game A · op.thisMac")
        store.running = true; store.running = false
        XCTAssertNil(store.operation, "it ends with the work")
        XCTAssertTrue(ActiveOperation.Kind.building.buildsGame)
        XCTAssertFalse(ActiveOperation.Kind.renewingSignature.buildsGame, "a re-sign never marks a game as building")
    }
}
