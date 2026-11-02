import XCTest
@testable import NXModel
@testable import NXCore

/// `BuildStore` without SwiftUI: the other stores are fakes behind the narrow protocols (`RepoLocation`, `DependencyInstalling`,
/// `EngineSyncing`, `InstallTarget`), the panels and the alert are closures that record, the defaults are a suite of their own and
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
        var devices: [AppleDevice] = []
        var xcrun = "/usr/bin/true"
        var readTeams: @Sendable () -> [SigningTeam] = { [] }
        func deviceName(_ udid: String) -> String { devices.first { $0.id == udid }?.name ?? "iPhone" }
        nonisolated func askCopy(_ plan: ShellCopyPlan) -> ShellCopyDecision { .skip }
        nonisolated func setWaiting(_ on: Bool) {}
        nonisolated var waitCancelled: Bool { false }
        func copyEnded() {}
    }

    private var suite: String!
    private var defaults: UserDefaults!
    private var temporary: URL!
    private let repo = FakeRepo()
    private let deps = FakeDeps()
    private let engine = FakeEngine()
    private let devices = FakeDevices()
    private let localizer = Localizer(.en)

    override func setUpWithError() throws {
        suite = "nxmodel-build-tests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
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

    // MARK: The script's events

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

    func testAChunkThatEndsInTheMiddleOfALineWaitsForTheRest() {
        let store = makeStore()
        store.ingest("{\"ev\":\"stage\",\"k\":2,\"n\":3,\"na")
        XCTAssertTrue(store.stages.isEmpty)
        store.ingest("me\":\"pack\"}\nplain line from a tool\n")
        XCTAssertEqual(store.stages.map(\.id), [2])
        XCTAssertTrue(store.log.text.contains("plain line from a tool\n"), "what is not an event is log text")
    }

    func testTheShaderChainNoticeShowsOncePerBuild() {
        let store = makeStore()
        var notices: [String] = []
        store.showNotice = { notices.append($0) }
        store.ingest("{\"ev\":\"say\",\"msg\":\"[NOTE] chain-changed: recompiling\"}\n")
        store.ingest("[NOTE] chain-changed again\n")
        XCTAssertEqual(notices, [store.t("msg.chainChanged")])
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
        localizer.lang = .de
        XCTAssertEqual(store.lang, .de)
        XCTAssertEqual(store.t("shell.needsDevice"), L10n.string("shell.needsDevice", .de))
    }

    func testAStoppedBuildWithNothingRunningDoesNothing() {
        let store = makeStore()
        store.stop()
        XCTAssertFalse(store.stopping)
    }
}
