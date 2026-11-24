import Foundation
import XCTest
@testable import NXModel
@testable import NXCore

@MainActor final class MNGGuardAndPEP668Tests: XCTestCase {
    private final class FakeRepo: RepoLocation {
        var path: String
        var isRepo = true
        var isGit = true
        init(path: String) { self.path = path }
    }

    private final class FakeDeps: DependencyInstalling {
        var pythonPath = "/usr/bin/python3"
        var pythonUpstream: EngineUpstreamKind? = .nxnative
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

    private final class RecordingRunner: ProcessRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var _captures: [ProcessLaunch] = []
        private var _streams: [ProcessLaunch] = []
        private var _starts: [ProcessLaunch] = []

        var captures: [ProcessLaunch] { lock.lock(); defer { lock.unlock() }; return _captures }
        var streams: [ProcessLaunch] { lock.lock(); defer { lock.unlock() }; return _streams }
        var starts: [ProcessLaunch] { lock.lock(); defer { lock.unlock() }; return _starts }

        var captureHandler: (ProcessLaunch) -> ProcessResult = { _ in ProcessResult() }
        var streamHandler: (ProcessLaunch, (String) -> Void) -> Bool = { _, _ in true }
        var onStart: ((ProcessLaunch) -> Void)?
        var exitStatus: Int32 = 0

        func capture(_ launch: ProcessLaunch) -> ProcessResult {
            lock.lock(); _captures.append(launch); lock.unlock()
            return captureHandler(launch)
        }

        func stream(_ launch: ProcessLaunch, line: @escaping (String) -> Void) -> Bool {
            lock.lock(); _streams.append(launch); lock.unlock()
            return streamHandler(launch, line)
        }

        func streamLines(_ launch: ProcessLaunch, started: @escaping (RunningProcess) -> Void, line: @escaping (String) -> Void) -> ProcessResult {
            started(FakeRunningProcess())
            return ProcessResult(status: 0)
        }

        func start(_ launch: ProcessLaunch, onOutput: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> RunningProcess {
            lock.lock(); _starts.append(launch); lock.unlock()
            onStart?(launch)
            onExit(exitStatus)
            return FakeRunningProcess()
        }
    }

    private var defaults: UserDefaults!
    private var temporary: URL!
    private var repo: FakeRepo!
    private var deps: FakeDeps!
    private var engine: FakeEngine!
    private var devices: FakeDevices!
    private var localizer: Localizer!
    private var originalFeatureEnabled = false
    private var originalCustomPy314: [String]? = nil
    private var originalCustomNszVenv: String? = nil
    private var fakePy314Path = ""

    override func setUpWithError() throws {
        originalFeatureEnabled = MacNativeGamesBuilder.featureEnabled
        originalCustomPy314 = MacNativeGamesBuilder.customPython314Candidates
        originalCustomNszVenv = Toolchain.customNszVenvDir
        MacNativeGamesBuilder.featureEnabled = true

        defaults = TestDefaults.make("nxmodel-mng-guard-pep668")
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("mng-guard-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        Toolchain.customNszVenvDir = temporary.appendingPathComponent("tools/nsz-venv").path

        repo = FakeRepo(path: temporary.appendingPathComponent("repo").path)
        deps = FakeDeps()
        engine = FakeEngine()
        devices = FakeDevices()
        localizer = Localizer(.en)

        let pyURL = temporary.appendingPathComponent("Library/Application Support/NX2Apple/tools/uv-python/cpython-3.14.0/bin/python3.14")
        try FileManager.default.createDirectory(at: pyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: pyURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pyURL.path)
        fakePy314Path = pyURL.path
        MacNativeGamesBuilder.customPython314Candidates = [fakePy314Path]
    }

    override func tearDownWithError() throws {
        MacNativeGamesBuilder.featureEnabled = originalFeatureEnabled
        MacNativeGamesBuilder.customPython314Candidates = originalCustomPy314
        Toolchain.customNszVenvDir = originalCustomNszVenv
        try? FileManager.default.removeItem(at: temporary)
    }

    private func makeFakeMNGTree(withPorts ports: [MacNativeGamesBuilder.PerGamePort] = [.dread, .odyssey]) throws -> String {
        let root = temporary.appendingPathComponent("fake-mng")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("games/totk"), withIntermediateDirectories: true)
        try Data("#!/usr/bin/env python3\n".utf8).write(to: root.appendingPathComponent("build_app.py"))
        for port in ports {
            let script = root.appendingPathComponent(port.scriptRelativePath)
            try fm.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/usr/bin/env python3\n".utf8).write(to: script)
        }
        return root.path
    }

    private func makeFakeNxnativeRepo() throws -> String {
        let root = temporary.appendingPathComponent("nxnative-repo")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("dm/tools"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("dm/tools/nx_extract"), withIntermediateDirectories: true)
        try Data("# \"--work-dir\" \"--from-seed\" \"--romfs-from\" \"--fallback-icon\"\n".utf8)
            .write(to: root.appendingPathComponent(RepoLayout.buildScript))
        try Data("# romfs_image\n".utf8).write(to: root.appendingPathComponent(RepoLayout.romfsImageTool))
        try Data("// cs\n".utf8).write(to: root.appendingPathComponent("dm/tools/nx_extract/Program.cs"))
        return root.path
    }

    private func waitUntil(timeout: TimeInterval = 3.0, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return predicate()
    }

    // MARK: 1. Default-Deny + Renamed ROM Header Probe + Check-Read-Revalidate

    func testDefaultDenyRenamedPackageProbeAndCheckReadRevalidate() throws {
        let mngTree = try makeFakeMNGTree()
        let runner = RecordingRunner()
        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        store.macNativeGamesPath = mngTree

        let keys = temporary.appendingPathComponent("prod.keys")
        let renamedTOTK = temporary.appendingPathComponent("MyBackup1.nsp")
        let renamedMK8D = temporary.appendingPathComponent("MyBackup2.nsp")
        let unknownROM = temporary.appendingPathComponent("Mystery.nsp")
        for f in [keys, renamedTOTK, renamedMK8D, unknownROM] { try Data([0]).write(to: f) }

        // Pure empty state permits selecting MNG.
        XCTAssertFalse(store.isMNGBlockedByCurrentGame)
        store.selectUpstream(.macNativeGames)
        XCTAssertEqual(store.buildUpstream, .macNativeGames)

        // Default-Deny: selecting an untagged file without readable header ID blocks MNG and reverts to nxnative.
        store.readPackageTitleID = { _, _ in nil }
        store.updateSlot("base") { $0.paths = [unknownROM.path] }
        XCTAssertTrue(store.isMNGBlockedByCurrentGame)
        XCTAssertEqual(store.buildUpstream, .nxnative)
        XCTAssertFalse(store.canSelectUpstream(.macNativeGames))

        // Renamed TOTK with valid keys probes header off main thread and unblocks MNG once identified.
        store.readPackageTitleID = { path, keysPath in
            guard !keysPath.isEmpty else { return nil }
            if path == renamedTOTK.path { return "0100F2C0115B6000" }
            if path == renamedMK8D.path { return "0100152000022000" }
            return nil
        }
        store.updateSlot("keys") { $0.paths = [keys.path] }
        store.updateSlot("base") { $0.paths = [renamedTOTK.path] }
        XCTAssertTrue(waitUntil { store.detectedGameTitleID16 == "0100F2C0115B6000" })
        XCTAssertFalse(store.isMNGBlockedByCurrentGame)
        XCTAssertTrue(store.isCurrentGameMNGSupported)
        XCTAssertTrue(store.shouldRecommendMacNativeGames)

        // Check-Read-Revalidate: a slow probe for renamedMK8D must NOT overwrite after user switches to renamedTOTK.
        let gate = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        store.readPackageTitleID = { path, _ in
            if path == renamedMK8D.path {
                entered.signal()
                _ = gate.wait(timeout: .now() + 2)
                return "0100152000022000"
            }
            return "0100F2C0115B6000"
        }
        store.updateSlot("base") { $0.paths = [renamedMK8D.path] }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        store.updateSlot("base") { $0.paths = [renamedTOTK.path] }
        gate.signal()
        XCTAssertTrue(waitUntil { store.detectedGameTitleID16 == "0100F2C0115B6000" })
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(store.detectedGameTitleID16, "0100F2C0115B6000", "Stale header probe must be discarded by Check-Read-Revalidate")
        XCTAssertFalse(store.isMNGBlockedByCurrentGame)
    }

    // MARK: 2. Batch Queue Whitelist Gate, Per-Entry Upstream Snapshot & Legacy JSON

    func testBatchQueueUpstreamSnapshotMixedQueueIsolationAndLegacyDecoding() throws {
        let mngTree = try makeFakeMNGTree(withPorts: [.dread])
        let nxRepo = try makeFakeNxnativeRepo()
        repo.path = nxRepo
        let runner = RecordingRunner()
        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        store.home = temporary.path
        store.macNativeGamesPath = mngTree
        store.buildUpstream = .macNativeGames
        XCTAssertEqual(store.buildUpstream, .macNativeGames)

        let queue = BuildQueueStore(
            file: nil,
            engineID: { "main" },
            busy: { store.running },
            start: { store.startQueued($0) }
        )
        store.queue = queue

        let keys = temporary.appendingPathComponent("prod.keys")
        let totk = temporary.appendingPathComponent("TOTK [0100F2C0115B6000].nsp")
        let mk8d = temporary.appendingPathComponent("MK8D [0100152000022000].nsp")
        let botw = temporary.appendingPathComponent("BOTW [01007EF00011E000].nsp")
        let dread = temporary.appendingPathComponent("Dread [010093801237C000].nsp")
        for f in [keys, totk, mk8d, botw, dread] { try Data([0]).write(to: f) }

        queue.enqueue([
            QueueEntry(titleID: "0100F2C0115B6000", name: "TOTK", target: BuildTarget.mac,
                       inputs: ["base": [totk.path], "keys": [keys.path]], outputDirectory: temporary.path, engineID: "main"),
            QueueEntry(titleID: "0100152000022000", name: "MK8D", target: BuildTarget.mac,
                       inputs: ["base": [mk8d.path], "keys": [keys.path]], outputDirectory: temporary.path, engineID: "main"),
            QueueEntry(titleID: "01007EF00011E000", name: "BOTW", target: BuildTarget.ios,
                       inputs: ["base": [botw.path], "keys": [keys.path]], outputDirectory: temporary.path, engineID: "main"),
            QueueEntry(titleID: "010093801237C000", name: "Dread", target: BuildTarget.mac,
                       inputs: ["base": [dread.path], "keys": [keys.path]], outputDirectory: temporary.path, engineID: "main"),
        ])

        XCTAssertEqual(queue.entries.count, 4)
        XCTAssertEqual(queue.entries[0].upstream, .macNativeGames)
        XCTAssertEqual(queue.entries[1].upstream, .nxnative, "Non-whitelist game must be coerced to nxnative on enqueue")
        XCTAssertEqual(queue.entries[2].upstream, .nxnative, "iOS target must be coerced to nxnative on enqueue")
        XCTAssertEqual(queue.entries[3].upstream, .macNativeGames, "Later eligible MNG entry must NOT be downgraded by earlier non-MNG entry")

        // Staged mixed queue blocks switching to MacNativeGames in UI and reverts active selection.
        XCTAssertTrue(store.isMNGBlockedByQueuedBuilds)
        XCTAssertTrue(store.isMNGBlockedByCurrentGame)
        XCTAssertEqual(store.mngBlockedReasonKey, "upstream.mngBlockedByQueue")
        XCTAssertEqual(store.buildUpstream, .nxnative)
        XCTAssertFalse(store.canSelectUpstream(.macNativeGames))

        // Running the non-MNG entry runs nxnative, NOT MNG.
        _ = store.startQueued(queue.entries[1])
        XCTAssertEqual(store.buildUpstream, .nxnative)
        XCTAssertFalse(store.mngRun)
        XCTAssertTrue(waitUntil { !store.running })

        // Running the subsequent Dread entry uses its snapshotted .macNativeGames upstream without collateral downgrade.
        runner.captureHandler = { launch in
            if launch.arguments.contains(where: { $0.contains("sys.version_info") }) {
                return ProcessResult(status: 0, out: "3.14\n")
            }
            return ProcessResult(status: 0, out: "")
        }
        var dreadLaunch: ProcessLaunch?
        runner.onStart = { launch in
            if launch.arguments.first?.hasSuffix("games/dread/build.py") == true {
                dreadLaunch = launch
            }
        }
        _ = store.startQueued(queue.entries[3])
        XCTAssertTrue(waitUntil { dreadLaunch != nil })
        XCTAssertEqual(dreadLaunch?.arguments.first, mngTree + "/games/dread/build.py")
        XCTAssertFalse(dreadLaunch?.arguments.contains("--platform") ?? true)

        // Legacy persisted JSON without `upstream` key must decode cleanly with `upstream == nil`.
        let legacyJSON = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "titleID": "0100F2C0115B6000",
          "name": "TOTK",
          "target": "mac-app",
          "inputs": {"base": ["/tmp/totk.nsp"]},
          "outputDirectory": "/tmp",
          "engineID": "main",
          "batch": "22222222-2222-2222-2222-222222222222",
          "status": "queued"
        }
        """
        let decoded = try JSONDecoder().decode(QueueEntry.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(decoded.upstream)
        XCTAssertEqual(decoded.titleID, "0100F2C0115B6000")
    }

    // MARK: 3. deps.pythonPath Cross-Upstream Isolation & FastRefresh Upstream Reset

    func testDependencyStoreAndResolveBuildPythonBlockCrossUpstreamContamination() async throws {
        var activeUpstream: EngineUpstreamKind = .macNativeGames
        let py314 = fakePy314Path
        let depStore = DependencyStore(
            localizer: localizer,
            runner: RecordingRunner(),
            repo: repo,
            defaults: defaults,
            upstreamContext: { (activeUpstream, "") },
            scan: { _, _ in
                if activeUpstream == .macNativeGames {
                    return DependencyCheck.Result(deps: [], python: py314, dotnet: "/fake/dotnet-mng")
                }
                return DependencyCheck.Result(deps: [], python: "/fake/nxnative/python3.13", dotnet: "/fake/dotnet-nx")
            },
            report: { _ in }
        )

        await depStore.check().value
        XCTAssertEqual(depStore.pythonUpstream, .macNativeGames)
        XCTAssertEqual(depStore.pythonPath, fakePy314Path)

        let store = BuildStore(localizer: localizer, runner: RecordingRunner(), repo: repo, deps: depStore, engine: engine, devices: devices, defaults: defaults)
        store.home = temporary.path

        // While depStore holds MNG's uv-python, resolveBuildPython MUST ignore it!
        let resolvedForNx = store.resolveBuildPython(includeS2Arm: false)
        XCTAssertNotEqual(resolvedForNx, fakePy314Path)
        XCTAssertFalse(MacNativeGamesBuilder.isManagedUVPython(resolvedForNx, home: temporary.path))

        // Switching upstream and calling check() clears stale pythonPath & dotnetPath synchronously before async scan lands.
        activeUpstream = .nxnative
        let task = depStore.check()
        XCTAssertEqual(depStore.pythonPath, "")
        XCTAssertEqual(depStore.dotnetPath, "")
        XCTAssertNil(depStore.pythonUpstream)
        await task.value
        XCTAssertEqual(depStore.pythonUpstream, .nxnative)
        XCTAssertEqual(depStore.pythonPath, "/fake/nxnative/python3.13")
        XCTAssertEqual(store.resolveBuildPython(includeS2Arm: false), "/fake/nxnative/python3.13")
        // S2Arm requires .s2arm upstream, so .nxnative cache must not leak to S2Arm.
        XCTAssertNotEqual(store.resolveBuildPython(includeS2Arm: true), "/fake/nxnative/python3.13")

        // Fast refresh started while on MacNativeGames must switch back to .nxnative and never use uv-python.
        let nxRepo = try makeFakeNxnativeRepo()
        repo.path = nxRepo
        let fastRunner = RecordingRunner()
        var fastLaunch: ProcessLaunch?
        fastRunner.onStart = { fastLaunch = $0 }
        let mngDeps = FakeDeps()
        mngDeps.pythonPath = fakePy314Path
        mngDeps.pythonUpstream = .macNativeGames
        let fastStore = BuildStore(localizer: localizer, runner: fastRunner, repo: repo, deps: mngDeps, engine: engine, devices: devices, defaults: defaults)
        fastStore.home = temporary.path
        fastStore.buildUpstream = .macNativeGames
        fastStore.startFastRefresh(titleID: "0100F2C0115B6000", targetName: BuildTarget.mac, outDir: temporary.path)
        XCTAssertEqual(fastStore.buildUpstream, .nxnative)
        XCTAssertNotNil(fastLaunch)
        XCTAssertNotEqual(fastLaunch?.executable, fakePy314Path)
        XCTAssertFalse(MacNativeGamesBuilder.isManagedUVPython(fastLaunch?.executable ?? "", home: temporary.path))
    }

    // MARK: 4. Mac PEP 668 Fix (MNG Per-Game Pre-Decompress & nxnative Managed nsz-venv)

    func testMNGPerGameNSZUsesIsolatedNszVenvNeverMutatesUVPython() throws {
        repo.isRepo = false
        let mngTree = try makeFakeMNGTree(withPorts: [.dread])
        let runner = RecordingRunner()
        let nszVenvDir = Toolchain.nszVenvDir(home: temporary.path)
        let nszVenvPy = Toolchain.nszVenvPython(venvDir: nszVenvDir)
        let nszExe = Toolchain.nszExecutable(venvDir: nszVenvDir)

        runner.captureHandler = { launch in
            if launch.arguments.contains(where: { $0.contains("sys.version_info") }) {
                return ProcessResult(status: 0, out: "3.14\n")
            }
            if launch.arguments.contains("import nsz") {
                return ProcessResult(status: FileManager.default.isExecutableFile(atPath: nszExe) ? 0 : 1, out: "")
            }
            return ProcessResult(status: 0, out: "")
        }

        let py314 = fakePy314Path
        runner.streamHandler = { launch, line in
            if launch.executable == py314 && launch.arguments.contains("-m") && launch.arguments.contains("venv") {
                try? FileManager.default.createDirectory(atPath: nszVenvDir + "/bin", withIntermediateDirectories: true)
                try? Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: nszVenvPy))
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nszVenvPy)
                return true
            }
            if launch.executable == nszVenvPy && launch.arguments.contains("pip") && launch.arguments.contains("nsz") {
                try? Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: nszExe))
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nszExe)
                line("Successfully installed nsz-5.0.0")
                return true
            }
            if launch.executable == nszExe, let oIdx = launch.arguments.firstIndex(of: "-o"), oIdx + 1 < launch.arguments.count {
                let outDir = launch.arguments[oIdx + 1]
                try? Data("unpacked-nsp".utf8).write(to: URL(fileURLWithPath: outDir + "/Dread [010093801237C000].nsp"))
                line("Decompressed Dread.nsz")
                return true
            }
            return true
        }

        var launched: ProcessLaunch?
        runner.onStart = { launched = $0 }

        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        store.home = temporary.path
        store.buildUpstream = .macNativeGames
        store.macNativeGamesPath = mngTree
        store.target = BuildTarget.mac
        store.outDir = temporary.appendingPathComponent("out").path
        try FileManager.default.createDirectory(atPath: store.outDir, withIntermediateDirectories: true)

        let baseNSZ = temporary.appendingPathComponent("Dread [010093801237C000].nsz")
        let keys = temporary.appendingPathComponent("prod.keys")
        try Data("compressed".utf8).write(to: baseNSZ)
        try Data("keys".utf8).write(to: keys)
        store.updateSlot("base") { $0.paths = [baseNSZ.path] }
        store.updateSlot("keys") { $0.paths = [keys.path] }

        store.startBuild()
        XCTAssertTrue(waitUntil { launched != nil })

        // Must NEVER run `pip install nsz` against uv-managed py314!
        let barePipOnPy314 = runner.streams.contains { $0.executable == fakePy314Path && $0.arguments.contains("pip") }
            || runner.captures.contains { $0.executable == fakePy314Path && $0.arguments.contains("pip") }
        XCTAssertFalse(barePipOnPy314, "Must never run bare pip install against uv-managed Python 3.14")

        // Must pass the unpacked .nsp (with path-hash suffix) to games/dread/build.py without --platform.
        let args = try XCTUnwrap(launched?.arguments)
        XCTAssertEqual(args.first, mngTree + "/games/dread/build.py")
        XCTAssertTrue(args[1].contains("/.nsz-unpacked/Dread [010093801237C000]-"), args[1])
        XCTAssertTrue(args[1].hasSuffix(".nsp"), args[1])
        XCTAssertFalse(args.contains("--platform"))
    }

    func testNxnativeExternallyManagedPythonUsesIsolatedNszVenvAndPrependsPath() throws {
        let nxRepo = try makeFakeNxnativeRepo()
        repo.path = nxRepo

        // Create an externally-managed Homebrew-like Python with EXTERNALLY-MANAGED marker.
        let extRoot = temporary.appendingPathComponent("homebrew-py")
        try FileManager.default.createDirectory(at: extRoot.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extRoot.appendingPathComponent("lib/python3.13"), withIntermediateDirectories: true)
        let extPy = extRoot.appendingPathComponent("bin/python3.13")
        try Data("#!/bin/sh\n".utf8).write(to: extPy)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: extPy.path)
        try Data("[externally-managed]\n".utf8).write(to: extRoot.appendingPathComponent("lib/python3.13/EXTERNALLY-MANAGED"))

        deps.pythonPath = extPy.path
        deps.pythonUpstream = .nxnative

        let nszVenvDir = Toolchain.nszVenvDir(home: temporary.path)
        let nszVenvPy = Toolchain.nszVenvPython(venvDir: nszVenvDir)
        let nszExe = Toolchain.nszExecutable(venvDir: nszVenvDir)

        let runner = RecordingRunner()
        runner.captureHandler = { launch in
            if launch.arguments.contains(where: { $0.contains("sys.version_info") }) {
                return ProcessResult(status: 0, out: "3.13\n")
            }
            if launch.arguments.contains("import nsz") {
                if launch.executable == extPy.path { return ProcessResult(status: 1, out: "") }
                if launch.executable == nszVenvPy { return ProcessResult(status: FileManager.default.isExecutableFile(atPath: nszExe) ? 0 : 1, out: "") }
            }
            return ProcessResult(status: 0, out: "")
        }
        runner.streamHandler = { launch, line in
            if launch.executable == extPy.path && launch.arguments.contains("-m") && launch.arguments.contains("venv") {
                try? FileManager.default.createDirectory(atPath: nszVenvDir + "/bin", withIntermediateDirectories: true)
                try? Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: nszVenvPy))
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nszVenvPy)
                return true
            }
            if launch.executable == nszVenvPy && launch.arguments.contains("pip") && launch.arguments.contains("nsz") {
                try? Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: nszExe))
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nszExe)
                line("Successfully installed nsz-5.0.0")
                return true
            }
            return true
        }

        var buildLaunch: ProcessLaunch?
        runner.onStart = { buildLaunch = $0 }

        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        store.home = temporary.path
        store.buildUpstream = .nxnative
        store.target = BuildTarget.mac
        store.outDir = temporary.appendingPathComponent("out").path
        try FileManager.default.createDirectory(atPath: store.outDir, withIntermediateDirectories: true)

        let baseNSZ = temporary.appendingPathComponent("Game [0100152000022000].nsz")
        let keys = temporary.appendingPathComponent("prod.keys")
        try Data("compressed".utf8).write(to: baseNSZ)
        try Data("keys".utf8).write(to: keys)
        store.updateSlot("base") { $0.paths = [baseNSZ.path] }
        store.updateSlot("keys") { $0.paths = [keys.path] }

        store.startBuild()
        XCTAssertTrue(waitUntil { buildLaunch != nil })

        // Never bare `pip install nsz` against externally-managed Homebrew Python!
        let barePipOnExt = runner.streams.contains { $0.executable == extPy.path && $0.arguments.contains("pip") }
            || runner.captures.contains { $0.executable == extPy.path && $0.arguments.contains("pip") }
        XCTAssertFalse(barePipOnExt, "Must never run bare pip install against PEP 668 externally-managed Python")

        // Build process must receive nsz-venv/bin prepended on PATH so build_ipa_from_nsp.py finds nsz CLI!
        let buildPath = try XCTUnwrap(buildLaunch?.environment?["PATH"])
        XCTAssertTrue(buildPath.hasPrefix(nszVenvDir + "/bin:"), "nsz-venv/bin must be prepended to build PATH: \(buildPath)")
    }

    func testBlockedMNGUpdateDownloadDoesNotSwitchOrAdvanceAutoSwitchRevision() throws {
        let mngTree = try makeFakeMNGTree()
        let store = BuildStore(localizer: localizer, runner: RecordingRunner(), repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        store.home = temporary.path
        store.macNativeGamesPath = mngTree

        let unsupported = temporary.appendingPathComponent("MK8D [0100152000022000].nsp")
        try Data([0]).write(to: unsupported)
        store.updateSlot("base") { $0.paths = [unsupported.path] }
        XCTAssertTrue(store.isMNGBlockedByCurrentGame)
        XCTAssertFalse(store.canSelectUpstream(.macNativeGames))
        XCTAssertEqual(store.buildUpstream, .nxnative)

        let revBefore = store.upstreamAutoSwitchRevision
        store.selectUpstream(.macNativeGames)
        XCTAssertEqual(store.buildUpstream, .nxnative)
        XCTAssertEqual(store.upstreamAutoSwitchRevision, revBefore)
    }

    func testMNGFirstBuildSeparatesOutFromWorkAndCleansEmptyStageDir() throws {
        repo.isRepo = false
        let mngTree = try makeFakeMNGTree(withPorts: [.tmnt])
        let runner = RecordingRunner()
        runner.captureHandler = { launch in
            if launch.arguments.contains(where: { $0.contains("sys.version_info") }) {
                return ProcessResult(status: 0, out: "3.14\n")
            }
            return ProcessResult(status: 0, out: "")
        }

        var launchedArgs: [String] = []
        runner.onStart = { launch in
            launchedArgs = launch.arguments
            guard let oIdx = launch.arguments.firstIndex(of: "-o"), oIdx + 1 < launch.arguments.count else { return }
            let appURL = URL(fileURLWithPath: launch.arguments[oIdx + 1])
            let macos = appURL.appendingPathComponent("Contents/MacOS")
            try? FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
            let exe = macos.appendingPathComponent("tmnt")
            try? Data("#!/bin/sh\n".utf8).write(to: exe)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
            let plist: [String: Any] = [
                "CFBundleIdentifier": "org.macnativegames.tmnt.private",
                "CFBundleExecutable": "tmnt",
                "CFBundleName": "TMNT",
            ]
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) {
                try? data.write(to: appURL.appendingPathComponent("Contents/Info.plist"))
            }
        }

        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        defaults.set(false, forKey: MacPreflight.defaultsKey)
        store.home = temporary.path
        store.buildUpstream = .macNativeGames
        store.macNativeGamesPath = mngTree
        store.target = BuildTarget.mac
        let outDir = temporary.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        store.outDir = outDir.path

        let tmntBase = temporary.appendingPathComponent("TMNT [0100FE701475A000].nsp")
        let keys = temporary.appendingPathComponent("prod.keys")
        try Data([0]).write(to: tmntBase)
        try Data([0]).write(to: keys)
        store.updateSlot("base") { $0.paths = [tmntBase.path] }
        store.updateSlot("keys") { $0.paths = [keys.path] }

        store.startBuild()
        XCTAssertTrue(waitUntil { store.done && !launchedArgs.isEmpty })

        let outIdx = try XCTUnwrap(launchedArgs.firstIndex(of: "-o"))
        let workIdx = try XCTUnwrap(launchedArgs.firstIndex(of: "--work"))
        let outPath = URL(fileURLWithPath: launchedArgs[outIdx + 1]).standardized.path
        let workPath = URL(fileURLWithPath: launchedArgs[workIdx + 1]).standardized.path
        XCTAssertNotEqual(outPath, workPath)
        XCTAssertFalse(outPath.hasPrefix(workPath + "/"), "MNG -o (\(outPath)) must not live inside --work (\(workPath))")
        XCTAssertFalse(workPath.hasPrefix(outPath + "/"), "MNG --work (\(workPath)) must not live inside -o (\(outPath))")
        XCTAssertTrue(store.macAppPath.hasSuffix("/TMNT [MacNativeGames].app"), store.macAppPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outDir.appendingPathComponent("0100FE701475A000_mng_stage").path))
    }

    func testApplyKnownTitleIDInvalidatesInFlightHeaderProbe() throws {
        let mngTree = try makeFakeMNGTree()
        let store = BuildStore(localizer: localizer, runner: RecordingRunner(), repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        store.macNativeGamesPath = mngTree

        let keys = temporary.appendingPathComponent("prod.keys")
        let renamed = temporary.appendingPathComponent("Untagged.nsp")
        try Data([0]).write(to: keys)
        try Data([0]).write(to: renamed)

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        store.readPackageTitleID = { _, _ in
            entered.signal()
            _ = release.wait(timeout: .now() + 2)
            return "0100F2C0115B6000"
        }

        store.updateSlot("keys") { $0.paths = [keys.path] }
        store.updateSlot("base") { $0.paths = [renamed.path] }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)

        store.applyKnownTitleID("0100152000022000")
        release.signal()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))

        XCTAssertEqual(store.detectedGameTitleID16, "0100152000022000", "Delayed probe must not overwrite explicit applyKnownTitleID")
        XCTAssertTrue(store.isMNGBlockedByCurrentGame)
    }

    func testNxnativeSiblingStagedNSZTriggersCleanNszVenvProbe() throws {
        let nxRepo = try makeFakeNxnativeRepo()
        repo.path = nxRepo

        let extRoot = temporary.appendingPathComponent("ext-py")
        try FileManager.default.createDirectory(at: extRoot.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extRoot.appendingPathComponent("lib/python3.13"), withIntermediateDirectories: true)
        let extPy = extRoot.appendingPathComponent("bin/python3.13")
        try Data("#!/bin/sh\n".utf8).write(to: extPy)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: extPy.path)
        try Data("[externally-managed]\n".utf8).write(to: extRoot.appendingPathComponent("lib/python3.13/EXTERNALLY-MANAGED"))
        deps.pythonPath = extPy.path
        deps.pythonUpstream = .nxnative

        let nszVenvDir = Toolchain.nszVenvDir(home: temporary.path)
        let nszVenvPy = Toolchain.nszVenvPython(venvDir: nszVenvDir)
        let nszExe = Toolchain.nszExecutable(venvDir: nszVenvDir)
        try FileManager.default.createDirectory(atPath: nszVenvDir + "/bin", withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: nszVenvPy))
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: nszExe))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nszVenvPy)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nszExe)

        var readyProbeEnv: [String: String]?
        let runner = RecordingRunner()
        runner.captureHandler = { launch in
            if launch.arguments.contains("import nsz") {
                if launch.executable == extPy.path { return ProcessResult(status: 1, out: "") }
                if launch.executable == nszVenvPy {
                    readyProbeEnv = launch.environment
                    return ProcessResult(status: 0, out: "")
                }
            }
            return ProcessResult(status: 0, out: "")
        }
        var buildLaunch: ProcessLaunch?
        runner.onStart = { buildLaunch = $0 }

        let romsDir = temporary.appendingPathComponent("roms")
        try FileManager.default.createDirectory(at: romsDir, withIntermediateDirectories: true)
        let baseNSP = romsDir.appendingPathComponent("Game [0100152000022000].nsp")
        let siblingUpdateNSZ = romsDir.appendingPathComponent("Game Update [0100152000022800].nsz")
        let keys = temporary.appendingPathComponent("prod.keys")
        try Data([0]).write(to: baseNSP)
        try Data([0]).write(to: siblingUpdateNSZ)
        try Data([0]).write(to: keys)

        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        store.home = temporary.path
        store.buildUpstream = .nxnative
        store.target = BuildTarget.mac
        store.outDir = temporary.appendingPathComponent("out").path
        try FileManager.default.createDirectory(atPath: store.outDir, withIntermediateDirectories: true)
        store.updateSlot("base") { $0.paths = [baseNSP.path] }
        store.updateSlot("keys") { $0.paths = [keys.path] }

        store.startBuild()
        XCTAssertTrue(waitUntil { buildLaunch != nil })

        let probedEnv = try XCTUnwrap(readyProbeEnv, "Sibling auto-staged .nsz must trigger managed nsz-venv probe")
        XCTAssertNil(probedEnv["PYTHONHOME"])
        XCTAssertNil(probedEnv["PYTHONPATH"])
        let buildPath = try XCTUnwrap(buildLaunch?.environment?["PATH"])
        XCTAssertTrue(buildPath.hasPrefix(nszVenvDir + "/bin:"), buildPath)
    }

    func testPokopiaNUPBlockedOnLegacyMNGAndUnlocksWhenGenericNUPPresent() throws {
        let mngTree = try makeFakeMNGTree()
        let runner = RecordingRunner()
        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        store.home = temporary.path
        store.macNativeGamesPath = mngTree
        store.target = BuildTarget.mac
        store.selectUpstream(.macNativeGames)
        XCTAssertEqual(store.buildUpstream, .macNativeGames)

        let pokopiaNUP = temporary.appendingPathComponent("Pokemon Pokopia [0400A3A01EE4C000].nup")
        let ootNUP = temporary.appendingPathComponent("Ocarina of Time [0400486024DEC000].nup")
        let bananzaDump = temporary.appendingPathComponent("BananzaDump")
        try Data([0]).write(to: pokopiaNUP)
        try Data([0]).write(to: ootNUP)
        try FileManager.default.createDirectory(at: bananzaDump, withIntermediateDirectories: true)

        // Legacy MNG (without tools/nup_input.py) blocks Pokopia .nup, reverts to nxnative, hides recommendation,
        // and reports the dump-folder reason key.
        store.updateSlot("base") { $0.paths = [pokopiaNUP.path] }
        XCTAssertEqual(store.buildUpstream, .nxnative)
        XCTAssertTrue(store.isMNGBlockedByCurrentGame)
        XCTAssertTrue(store.isCurrentGameNUPBlockedForMNG)
        XCTAssertFalse(store.shouldRecommendMacNativeGames)
        XCTAssertEqual(store.mngBlockedReasonKey, "upstream.mngNeedsDumpFolder")

        // Ocarina of Time .nup remains allowed on legacy MNG.
        store.updateSlot("base") { $0.paths = [ootNUP.path] }
        XCTAssertFalse(store.isMNGBlockedByCurrentGame)
        XCTAssertFalse(store.isCurrentGameNUPBlockedForMNG)
        XCTAssertTrue(store.shouldRecommendMacNativeGames)

        // Batch queue coerces Pokopia .nup to nxnative on legacy MNG while preserving OOT .nup and Bananza dump folder on MNG.
        let queue = BuildQueueStore(file: nil, engineID: { "main" }, busy: { store.running }, start: { store.startQueued($0) })
        store.queue = queue
        store.selectUpstream(.macNativeGames)
        XCTAssertEqual(store.buildUpstream, .macNativeGames)
        queue.enqueue([
            QueueEntry(titleID: "0400A3A01EE4C000", name: "Pokopia NUP", target: BuildTarget.mac,
                       inputs: ["base": [pokopiaNUP.path]], gameFolder: pokopiaNUP.path, outputDirectory: temporary.path, engineID: "main"),
            QueueEntry(titleID: "0400486024DEC000", name: "OOT NUP", target: BuildTarget.mac,
                       inputs: ["base": [ootNUP.path]], gameFolder: ootNUP.path, outputDirectory: temporary.path, engineID: "main"),
            QueueEntry(titleID: "040074A01BF12000", name: "Bananza Dump", target: BuildTarget.mac,
                       inputs: ["base": [bananzaDump.path]], gameFolder: bananzaDump.path, outputDirectory: temporary.path, engineID: "main"),
        ])
        XCTAssertEqual(queue.entries.count, 3)
        XCTAssertEqual(queue.entries[0].upstream, .nxnative)
        XCTAssertEqual(queue.entries[1].upstream, .macNativeGames)
        XCTAssertEqual(queue.entries[2].upstream, .macNativeGames)
        XCTAssertTrue(store.isMNGBlockedByQueuedBuilds)

        // Once MNG is updated with tools/nup_input.py, re-assigning macNativeGamesPath immediately unlocks single-game and queue MNG eligibility.
        let toolsDir = URL(fileURLWithPath: mngTree).appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: toolsDir, withIntermediateDirectories: true)
        try Data("# nup_input\n".utf8).write(to: toolsDir.appendingPathComponent("nup_input.py"))
        store.updateSlot("base") { $0.paths = [pokopiaNUP.path] }
        store.macNativeGamesPath = mngTree
        XCTAssertFalse(store.isMNGBlockedByQueuedBuilds)
        XCTAssertFalse(store.isMNGBlockedByCurrentGame)
        XCTAssertFalse(store.isCurrentGameNUPBlockedForMNG)
        XCTAssertTrue(store.shouldRecommendMacNativeGames)
    }
}
