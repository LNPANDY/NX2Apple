import Combine
import XCTest
@testable import NXModel
@testable import NXCore

@MainActor final class MacNativeGamesBuildStoreTests: XCTestCase {
    private final class FakeRepo: RepoLocation {
        var path: String
        var isRepo = true
        var isGit = true
        init(path: String) { self.path = path }
    }

    private final class FakeDeps: DependencyInstalling {
        var pythonPath = "/usr/bin/python3"
        var dotnetPath = "/usr/bin/true"
        var checked = true
        var allPresent = true
        var deps: [Dep] = []
        func isInstalling(_ id: String) -> Bool { false }
        func install(_ dep: Dep) -> Task<Void, Never> { Task {} }
    }

    private final class FakeEngine: EngineSyncing {
        func syncEngine(then: ((Bool) -> Void)?) -> Task<Void, Never> {
            then?(true)
            return Task {}
        }
    }

    private final class FakeDevices: InstallTarget {
        var installDevice = "device-1"
        var signingTeam = "TEAM1"
        var exportIPA = false
        var exportOneGame = false
        var driveFolder = ""
        var devices: [AppleDevice] = []
        var xcrun = "/usr/bin/true"
        var readTeams: @Sendable () -> [SigningTeam] = { [] }
        func deviceName(_ udid: String) -> String { "iPhone" }
        nonisolated func askCopy(_ plan: ShellCopyPlan) -> ShellCopyDecision { .skip }
        nonisolated func setWaiting(_ on: Bool) {}
        nonisolated var waitCancelled: Bool { false }
        func copyEnded() {}
    }

    private final class ChunkedRunner: ProcessRunner, @unchecked Sendable {
        var chunks: [Data] = []
        var exitStatus: Int32 = 0
        var shouldThrowOnStart = false
        var onStartInspect: ((ProcessLaunch) -> Void)?
        var captureAnswer: (ProcessLaunch) -> ProcessResult = { _ in ProcessResult() }
        var streamLinesHandler: ((ProcessLaunch, (RunningProcess) -> Void, (String) -> Void) -> ProcessResult)?

        func capture(_ launch: ProcessLaunch) -> ProcessResult { captureAnswer(launch) }
        func stream(_ launch: ProcessLaunch, line: @escaping (String) -> Void) -> Bool { true }
        func streamLines(_ launch: ProcessLaunch, started: @escaping (RunningProcess) -> Void, line: @escaping (String) -> Void) -> ProcessResult {
            if let handler = streamLinesHandler { return handler(launch, started, line) }
            started(FakeRunningProcess())
            return ProcessResult(status: 0)
        }
        func start(_ launch: ProcessLaunch, onOutput: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> RunningProcess {
            onStartInspect?(launch)
            if shouldThrowOnStart { throw CocoaError(.fileNoSuchFile) }
            for chunk in chunks { onOutput(chunk) }
            onExit(exitStatus)
            return FakeRunningProcess()
        }
    }

    private var defaults: UserDefaults!
    private var temporary: URL!
    private var repo: FakeRepo!
    private let deps = FakeDeps()
    private let engine = FakeEngine()
    private let devices = FakeDevices()
    private let localizer = Localizer(.en)
    private var originalFeatureEnabled = false

    override func setUpWithError() throws {
        originalFeatureEnabled = MacNativeGamesBuilder.featureEnabled
        MacNativeGamesBuilder.featureEnabled = true
        defaults = TestDefaults.make("nxmodel-mng-build-tests")
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("mng-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        repo = FakeRepo(path: temporary.appendingPathComponent("repo").path)
    }

    override func tearDownWithError() throws {
        MacNativeGamesBuilder.featureEnabled = originalFeatureEnabled
        try? FileManager.default.removeItem(at: temporary)
    }

    private func makeFakeMNGTree() throws -> String {
        let root = temporary.appendingPathComponent("fake-mng")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("games/totk"), withIntermediateDirectories: true)
        try Data("#!/usr/bin/env python3\n".utf8).write(to: root.appendingPathComponent("build_app.py"))
        return root.path
    }

    func testPersistenceAndFeatureDisabledFallback() throws {
        let runner = ChunkedRunner()
        let mngTree = try makeFakeMNGTree()
        let store1 = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        store1.buildUpstream = .macNativeGames
        store1.macNativeGamesPath = mngTree

        let store2 = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        XCTAssertEqual(store2.buildUpstream, .macNativeGames)
        XCTAssertEqual(store2.macNativeGamesPath, mngTree)

        MacNativeGamesBuilder.featureEnabled = false
        let store3 = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        XCTAssertEqual(store3.buildUpstream, .nxnative)
    }

    func testMacOnlyGate() throws {
        let runner = ChunkedRunner()
        var runnerStarted = false
        runner.onStartInspect = { _ in runnerStarted = true }
        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        store.buildUpstream = .macNativeGames
        store.target = BuildTarget.ios

        let base = temporary.appendingPathComponent("Game [0100F2C0115B6000].nsp")
        let keys = temporary.appendingPathComponent("prod.keys")
        try Data([0]).write(to: base)
        try Data([0]).write(to: keys)
        store.updateSlot("base") { $0.paths = [base.path] }
        store.updateSlot("keys") { $0.paths = [keys.path] }

        store.startBuild()

        XCTAssertFalse(runnerStarted)
        XCTAssertFalse(store.running)
        XCTAssertEqual(store.doneNote, localizer.t("upstream.mngMacOnly"))
    }

    func testTreeAndGameValidation() throws {
        let runner = ChunkedRunner()
        var runnerStarted = false
        runner.onStartInspect = { _ in runnerStarted = true }
        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        store.buildUpstream = .macNativeGames
        store.target = BuildTarget.mac
        let base = temporary.appendingPathComponent("Game [0100F2C0115B6000].nsp")
        let keys = temporary.appendingPathComponent("prod.keys")
        try Data([0]).write(to: base)
        try Data([0]).write(to: keys)
        store.updateSlot("base") { $0.paths = [base.path] }
        store.updateSlot("keys") { $0.paths = [keys.path] }

        store.macNativeGamesPath = ""
        store.startBuild()
        XCTAssertFalse(runnerStarted)
        XCTAssertEqual(store.doneNote, localizer.t("upstream.mngMissing"))

        store.macNativeGamesPath = temporary.appendingPathComponent("invalid").path
        store.startBuild()
        XCTAssertFalse(runnerStarted)
        XCTAssertTrue(store.doneNote.contains("not a MacNativeGames folder"))

        let validTree = try makeFakeMNGTree()
        store.macNativeGamesPath = validTree
        let unsupportedBase = temporary.appendingPathComponent("Unsupported [0100000000010000].nsp")
        try Data([0]).write(to: unsupportedBase)
        store.updateSlot("base") { $0.paths = [unsupportedBase.path] }

        store.startBuild()
        XCTAssertFalse(runnerStarted)
        XCTAssertEqual(store.doneNote, String(format: localizer.t("upstream.mngUnsupportedGame"), "0100000000010000"))
    }

    func testBuildWithoutNxnativeRepoAndPreservesWorkDir() throws {
        repo.isRepo = false
        let validTree = try makeFakeMNGTree()
        let runner = ChunkedRunner()
        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        defaults.set(false, forKey: MacPreflight.defaultsKey)
        store.buildUpstream = .macNativeGames
        store.macNativeGamesPath = validTree
        store.target = BuildTarget.mac

        let tid = "0100F2C0115B6000"
        let base = temporary.appendingPathComponent("Zelda [\(tid)].nsp")
        let keys = temporary.appendingPathComponent("prod.keys")
        try Data([0]).write(to: base)
        try Data([0]).write(to: keys)
        store.updateSlot("base") { $0.paths = [base.path] }
        store.updateSlot("keys") { $0.paths = [keys.path] }
        store.outDir = temporary.appendingPathComponent("out").path
        try FileManager.default.createDirectory(atPath: store.outDir, withIntermediateDirectories: true)

        XCTAssertTrue(store.canBuild)

        var launchedCommand: [String] = []
        runner.onStartInspect = { launch in
            launchedCommand = [launch.executable] + launch.arguments
            guard let outFlagIndex = launch.arguments.firstIndex(of: "-o"),
                  outFlagIndex + 1 < launch.arguments.count else { return }
            let builderApp = URL(fileURLWithPath: launch.arguments[outFlagIndex + 1])
            let workDirURL = builderApp.deletingLastPathComponent()
            let romfsDir = workDirURL.appendingPathComponent("extract/v1/RomFS")
            let aocDir = workDirURL.appendingPathComponent("aoc")
            try? FileManager.default.createDirectory(at: romfsDir, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: aocDir, withIntermediateDirectories: true)
            try? Data("extracted-romfs".utf8).write(to: romfsDir.appendingPathComponent("data.bin"))
            try? Data("extracted-aoc".utf8).write(to: aocDir.appendingPathComponent("pack.bin"))

            let macosDir = builderApp.appendingPathComponent("Contents/MacOS")
            try? FileManager.default.createDirectory(at: macosDir, withIntermediateDirectories: true)
            let exeURL = macosDir.appendingPathComponent("totk")
            try? Data([0xCF, 0xFA, 0xED, 0xFE]).write(to: exeURL)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exeURL.path)

            let info: [String: Any] = [
                "CFBundleIdentifier": "org.macnativegames.totk",
                "CFBundleExecutable": "totk",
                "CFBundleName": "TOTK"
            ]
            if let plistData = try? PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0) {
                try? plistData.write(to: builderApp.appendingPathComponent("Contents/Info.plist"))
            }
        }

        store.startBuild()

        XCTAssertFalse(launchedCommand.isEmpty)
        XCTAssertEqual(launchedCommand[1], "\(validTree)/build_app.py")
        XCTAssertTrue(launchedCommand.contains("--platform"))
        XCTAssertTrue(launchedCommand.contains("macos"))

        let deadline = Date().addingTimeInterval(3)
        while !store.done && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertTrue(store.done)
        XCTAssertFalse(store.macAppPath.isEmpty)
        XCTAssertTrue(store.macAppPath.hasSuffix("TOTK.app"))

        let preservedRomFS = URL(fileURLWithPath: store.effectiveWorkDir).appendingPathComponent("extract/v1/RomFS/data.bin")
        let preservedAOC = URL(fileURLWithPath: store.effectiveWorkDir).appendingPathComponent("aoc/pack.bin")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: preservedRomFS.path),
            "MacNativeGames extract/v1/RomFS must not be wiped by PostBuildCleanup"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: preservedAOC.path),
            "MacNativeGames aoc must not be wiped by PostBuildCleanup"
        )
    }

    func testBuildFailureSurfacesMacNativeGamesErrorLine() throws {
        repo.isRepo = false
        let validTree = try makeFakeMNGTree()
        let runner = ChunkedRunner()
        runner.chunks = [Data("checking files\nERROR: missing shared fonts\n".utf8)]
        runner.exitStatus = 1

        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        store.buildUpstream = .macNativeGames
        store.macNativeGamesPath = validTree
        store.target = BuildTarget.mac

        let base = temporary.appendingPathComponent("Zelda [0100F2C0115B6000].nsp")
        let keys = temporary.appendingPathComponent("prod.keys")
        try Data([0]).write(to: base)
        try Data([0]).write(to: keys)
        store.updateSlot("base") { $0.paths = [base.path] }
        store.updateSlot("keys") { $0.paths = [keys.path] }

        store.startBuild()
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))

        XCTAssertFalse(store.running)
        XCTAssertFalse(store.done)
        XCTAssertNil(store.failure)
        XCTAssertTrue(store.doneNote.contains("ERROR: missing shared fonts"))
    }

    func testSelectingOrRestoringMacNativeGamesAutoSwitchesTargetToMacAndTriggersUpstreamChanged() throws {
        let runner = ChunkedRunner()
        let mngTree = try makeFakeMNGTree()
        var upstreamChangeCount = 0
        let store = BuildStore(
            localizer: localizer,
            runner: runner,
            repo: repo,
            deps: deps,
            engine: engine,
            devices: devices,
            defaults: defaults
        )
        store.macNativeGamesPath = mngTree
        store.upstreamChanged = { upstreamChangeCount += 1 }
        store.target = BuildTarget.ios
        XCTAssertEqual(store.target, BuildTarget.ios)

        store.selectUpstream(.macNativeGames)
        XCTAssertEqual(store.buildUpstream, EngineUpstreamKind.macNativeGames)
        XCTAssertEqual(store.target, BuildTarget.mac)
        XCTAssertEqual(upstreamChangeCount, 1)

        // Simulate persisted iOS target alongside MacNativeGames in UserDefaults; init must normalize to Mac.
        defaults.set(BuildTarget.ios, forKey: BuildStore.targetKey)
        defaults.set(EngineUpstreamKind.macNativeGames.rawValue, forKey: BuildStore.buildUpstreamKey)
        let restored = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        XCTAssertEqual(restored.buildUpstream, EngineUpstreamKind.macNativeGames)
        XCTAssertEqual(restored.target, BuildTarget.mac)
    }

    func testSharedFontsFailureClassifiesAndFixButtonSwitchesBackToNxnative() throws {
        repo.isRepo = false
        let validTree = try makeFakeMNGTree()
        let runner = ChunkedRunner()
        runner.chunks = [
            Data("checking files\nERROR: Standard NSP packages do not include system shared fonts; pass --firmware <dir> or --shared-fonts <dir>\n".utf8)
        ]
        runner.exitStatus = 1

        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        store.buildUpstream = .macNativeGames
        store.macNativeGamesPath = validTree
        store.target = BuildTarget.mac

        let base = temporary.appendingPathComponent("Zelda [0100F2C0115B6000].nsp")
        let keys = temporary.appendingPathComponent("prod.keys")
        try Data([0]).write(to: base)
        try Data([0]).write(to: keys)
        store.updateSlot("base") { $0.paths = [base.path] }
        store.updateSlot("keys") { $0.paths = [keys.path] }

        store.startBuild()
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))

        XCTAssertFalse(store.running)
        XCTAssertFalse(store.done)
        XCTAssertEqual(store.failure?.kind, .mngSharedFonts)
        XCTAssertEqual(store.doneNote, localizer.t("macFail.mngSharedFonts.what"))

        store.fixBuildFailure(.mngSharedFonts)
        XCTAssertEqual(store.buildUpstream, .nxnative)
        XCTAssertNil(store.failure)
    }

    private func syntheticNPDM(programID: UInt64) -> Data {
        var d = [UInt8](repeating: 0, count: 0x100)
        d.replaceSubrange(0..<4, with: Array("META".utf8))
        d[0x70] = 0x80
        d[0x74] = 0x40
        d.replaceSubrange(0x80..<0x84, with: Array("ACI0".utf8))
        for i in 0..<8 {
            d[0x90 + i] = UInt8((programID >> (8 * UInt64(i))) & 0xFF)
        }
        return Data(d)
    }

    private func syntheticNUP(baseTID: UInt64, updateTID: UInt64, updateVersion: UInt32, dlcTID: UInt64) -> Data {
        func put(_ d: inout [UInt8], _ o: Int, _ v: UInt64, _ n: Int) {
            for i in 0..<n {
                d[o + i] = UInt8((v >> (8 * UInt64(i))) & 0xFF)
            }
        }
        let count = 3
        let tableSize = 0x30 + count * 0x40
        var d = [UInt8](repeating: 0, count: 0x80 + tableSize)
        d.replaceSubrange(0..<4, with: [0x4E, 0x55, 0x50, 0x01])
        put(&d, 0x08, 0x80, 8)
        put(&d, 0x10, UInt64(tableSize), 8)
        put(&d, 0x40, UInt64(d.count), 8)
        put(&d, 0x48, UInt64(count), 4)
        d.replaceSubrange(0x80..<0x84, with: [0x54, 0x4F, 0x43, 0x01])
        put(&d, 0x80 + 0x30, baseTID, 8)
        put(&d, 0x80 + 0x30 + 0x40, updateTID, 8)
        put(&d, 0x80 + 0x30 + 0x40 + 20, UInt64(updateVersion), 4)
        d[0x80 + 0x30 + 0x40 + 24] = 1
        put(&d, 0x80 + 0x30 + 0x80, dlcTID, 8)
        d[0x80 + 0x30 + 0x80 + 24] = 2
        return Data(d)
    }

    func testUnencryptedNUPAndDumpFolderOmitKeysUpdateAndDLCArguments() throws {
        repo.isRepo = false
        let validTree = try makeFakeMNGTree()
        let runner = ChunkedRunner()
        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        defaults.set(false, forKey: MacPreflight.defaultsKey)
        store.buildUpstream = .macNativeGames
        store.macNativeGamesPath = validTree
        store.target = BuildTarget.mac
        store.outDir = temporary.appendingPathComponent("out").path
        try FileManager.default.createDirectory(atPath: store.outDir, withIntermediateDirectories: true)

        var launchedArgs: [String] = []
        runner.onStartInspect = { launch in
            launchedArgs = launch.arguments
        }

        // 1. Single .nup filling base, update, and dlc slots (Issue #1450: 0400486024DEC000).
        let nupURL = temporary.appendingPathComponent("Ocarina [0400486024DEC000][v131072].nup")
        try syntheticNUP(
            baseTID: 0x0400486024DEC000,
            updateTID: 0x0400486024DEC800,
            updateVersion: 131072,
            dlcTID: 0x0400486024DED001
        ).write(to: nupURL)
        store.scan(folder: nupURL.path)
        XCTAssertEqual(store.gameFolder?.nup, nupURL.path)
        XCTAssertEqual(store.updatePath, nupURL.path)
        XCTAssertEqual(store.dlcPaths, [nupURL.path])

        store.startBuild()
        XCTAssertFalse(launchedArgs.isEmpty)
        XCTAssertEqual(launchedArgs[1], nupURL.path)
        XCTAssertFalse(launchedArgs.contains("-k"))
        XCTAssertFalse(launchedArgs.contains("--update"))
        XCTAssertFalse(launchedArgs.contains("--dlc"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        // 2. Switch 2 unpacked dump folder where updatePath != gameInput (<folder>/updates/131072).
        launchedArgs = []
        let dumpDir = temporary.appendingPathComponent("OOT_Dump")
        let fm = FileManager.default
        try fm.createDirectory(at: dumpDir.appendingPathComponent("base/exefs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dumpDir.appendingPathComponent("base/romfs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dumpDir.appendingPathComponent("updates/131072/romfs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dumpDir.appendingPathComponent("dlc/0400486024ded001/0/romfs"), withIntermediateDirectories: true)
        try syntheticNPDM(programID: 0x0400486024DEC000).write(to: dumpDir.appendingPathComponent("base/exefs/main.npdm"))
        store.scan(folder: dumpDir.path)
        XCTAssertEqual(store.gameFolder?.folder, dumpDir.path)
        XCTAssertEqual(store.updatePath, dumpDir.appendingPathComponent("updates/131072").path)
        XCTAssertEqual(store.dlcPaths, [dumpDir.appendingPathComponent("dlc/0400486024ded001").path])

        store.startBuild()
        XCTAssertFalse(launchedArgs.isEmpty)
        XCTAssertEqual(launchedArgs[1], dumpDir.path)
        XCTAssertFalse(launchedArgs.contains("-k"))
        XCTAssertFalse(launchedArgs.contains("--update"))
        XCTAssertFalse(launchedArgs.contains("--dlc"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func testEncryptedNSPWithSeparateUpdateAndDLCKeepsKeysUpdateAndDLCArguments() throws {
        repo.isRepo = false
        let validTree = try makeFakeMNGTree()
        let runner = ChunkedRunner()
        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        defaults.set(false, forKey: MacPreflight.defaultsKey)
        store.buildUpstream = .macNativeGames
        store.macNativeGamesPath = validTree
        store.target = BuildTarget.mac
        store.outDir = temporary.appendingPathComponent("out").path
        try FileManager.default.createDirectory(atPath: store.outDir, withIntermediateDirectories: true)

        let base = temporary.appendingPathComponent("Zelda [0100F2C0115B6000].nsp")
        let update = temporary.appendingPathComponent("Zelda Update [0100F2C0115B6800].nsp")
        let dlc = temporary.appendingPathComponent("Zelda DLC [0100F2C0115B7001].nsp")
        let keys = temporary.appendingPathComponent("prod.keys")
        try Data([0]).write(to: base)
        try Data([0]).write(to: update)
        try Data([0]).write(to: dlc)
        try Data([0]).write(to: keys)
        store.updateSlot("base") { $0.paths = [base.path] }
        store.updateSlot("update") { $0.paths = [update.path] }
        store.updateSlot("dlc") { $0.paths = [dlc.path] }
        store.updateSlot("keys") { $0.paths = [keys.path] }

        var launchedArgs: [String] = []
        runner.onStartInspect = { launch in
            launchedArgs = launch.arguments
        }

        store.startBuild()
        XCTAssertEqual(launchedArgs.firstIndex(of: "-k").map { launchedArgs[$0 + 1] }, keys.path)
        XCTAssertEqual(launchedArgs.firstIndex(of: "--update").map { launchedArgs[$0 + 1] }, update.path)
        XCTAssertEqual(launchedArgs.firstIndex(of: "--dlc").map { launchedArgs[$0 + 1] }, dlc.path)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}
