import Foundation
import XCTest
@testable import NXCore
@testable import NXModel

@MainActor final class EngineVariantBuildStoreTests: XCTestCase {
    private final class FakeRepo: RepoLocation {
        var path: String
        var isRepo = false
        var isGit = false
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
        var signingTeam = "TEAM99"
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
        var launches: [ProcessLaunch] = []
        var onStart: ((ProcessLaunch) -> Void)?
        func capture(_ launch: ProcessLaunch) -> ProcessResult { ProcessResult(status: 0, out: "") }
        func stream(_ launch: ProcessLaunch, line: @escaping (String) -> Void) -> Bool { true }
        func streamLines(_ launch: ProcessLaunch, started: @escaping (RunningProcess) -> Void, line: @escaping (String) -> Void) -> ProcessResult {
            started(FakeRunningProcess())
            return ProcessResult(status: 0, out: "")
        }
        func start(_ launch: ProcessLaunch, onOutput: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> RunningProcess {
            launches.append(launch)
            onStart?(launch)
            onExit(0)
            return FakeRunningProcess()
        }
    }

    private var temporary: URL!
    private var defaults: UserDefaults!
    private var repo: FakeRepo!
    private let deps = FakeDeps()
    private let engine = FakeEngine()
    private let devices = FakeDevices()
    private let localizer = Localizer(.en)

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("variant-store-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defaults = TestDefaults.make("nxmodel-variant-tests")
        repo = FakeRepo(path: temporary.appendingPathComponent("missing-repo").path)
        BuiltUpstreamRegistry.customStoreURL = temporary.appendingPathComponent("built-upstreams.json")
    }

    override func tearDownWithError() throws {
        BuiltUpstreamRegistry.customStoreURL = nil
        try? FileManager.default.removeItem(at: temporary)
    }

    private func makeVariantTree(name: String, flags: String) throws -> String {
        let root = temporary.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dm/tools/nx_extract"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try Data("// cs\n".utf8).write(to: root.appendingPathComponent("dm/tools/nx_extract/Program.cs"))
        try Data("# \(flags)\n".utf8).write(to: root.appendingPathComponent("scripts/build_ipa_from_nsp.py"))
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

    func testKidWithSwordIOSForcesStandaloneOneGameIPAWithTeamBundleIDAndIsolatedWorkDir() throws {
        let kwsTree = try makeVariantTree(name: "kws", flags: "\"--work-dir\" \"--bundle-id\" \"--env-file\"")
        let runner = RecordingRunner()
        let outDir = temporary.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        store.home = temporary.path
        store.kidWithSwordPath = kwsTree
        store.outDir = outDir.path
        devices.exportIPA = false
        devices.exportOneGame = false
        devices.signingTeam = "MYTEAM42"

        let oot = temporary.appendingPathComponent("Ocarina [0400486024DEC000].nsp")
        let keys = temporary.appendingPathComponent("prod.keys")
        try Data([0]).write(to: oot)
        try Data([0]).write(to: keys)
        store.updateSlot("base") { $0.paths = [oot.path] }
        store.updateSlot("keys") { $0.paths = [keys.path] }
        store.target = BuildTarget.ios

        // On general nxnative, OoT recommends Kid with Sword even for iOS target.
        XCTAssertEqual(store.recommendedTunedEngine, .kidWithSword)

        store.selectUpstream(.kidWithSword)
        XCTAssertEqual(store.buildUpstream, .kidWithSword)
        XCTAssertTrue(store.forcesStandaloneOneGameIPA)
        XCTAssertTrue(store.exportsOneGame)
        XCTAssertFalse(store.exportsFramework)
        XCTAssertTrue(store.usesExternalUpstreamRepo)
        XCTAssertTrue(store.canBuild)

        runner.onStart = { launch in
            if let idx = launch.arguments.firstIndex(of: "-o"), idx + 1 < launch.arguments.count {
                try? Data("ipa".utf8).write(to: URL(fileURLWithPath: launch.arguments[idx + 1]))
            }
        }

        store.startBuild()
        XCTAssertTrue(waitUntil { !runner.launches.isEmpty && !store.running })

        let launch = try XCTUnwrap(runner.launches.first)
        XCTAssertEqual(launch.directory, kwsTree)
        XCTAssertEqual(launch.arguments.first, kwsTree + "/scripts/build_ipa_from_nsp.py")
        // Script lacked --progress in fixture -> must gracefully omit `--progress json`.
        XCTAssertFalse(launch.arguments.contains("--progress"), "Must omit --progress when variant script lacks it")
        // Must isolate workDir with engine suffix.
        let workIdx = try XCTUnwrap(launch.arguments.firstIndex(of: "--work-dir"))
        XCTAssertEqual(launch.arguments[workIdx + 1], outDir.path + "/0400486024DEC000_kidwithsword_build")
        // Must use standalone OneGameIPA args with personal Team ID bundle ID, never --shell-framework.
        XCTAssertFalse(launch.arguments.contains("--shell-framework"))
        XCTAssertTrue(launch.arguments.contains("--platform"))
        XCTAssertTrue(launch.arguments.contains("ios"))
        let bidIdx = try XCTUnwrap(launch.arguments.firstIndex(of: "--bundle-id"))
        XCTAssertEqual(launch.arguments[bidIdx + 1], "org.nxnative.0400486024dec000.MYTEAM42")
    }

    func testNoLagKartMacOnlyIsolatedWorkDirAndRegistryAttribution() throws {
        let nlkTree = try makeVariantTree(name: "nlk", flags: "\"--progress\" \"--work-dir\" \"--fallback-icon\"")
        let runner = RecordingRunner()
        let outDir = temporary.appendingPathComponent("out-nlk", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        defaults.set(false, forKey: MacPreflight.defaultsKey)
        store.home = temporary.path
        store.noLagKartPath = nlkTree
        store.outDir = outDir.path

        let mkw = temporary.appendingPathComponent("MarioKartWorld [0400C3F00006E000].nsp")
        let keys = temporary.appendingPathComponent("prod.keys")
        try Data([0]).write(to: mkw)
        try Data([0]).write(to: keys)
        store.updateSlot("base") { $0.paths = [mkw.path] }
        store.updateSlot("keys") { $0.paths = [keys.path] }
        store.target = BuildTarget.mac

        XCTAssertEqual(store.recommendedTunedEngine, .noLagKart)
        store.selectUpstream(.noLagKart)
        XCTAssertEqual(store.buildUpstream, .noLagKart)
        XCTAssertTrue(store.isMacOnlyUpstreamSelected)

        // Switching target to iOS is coerced back to Mac for No Lag Kart.
        store.target = BuildTarget.ios
        XCTAssertEqual(store.target, BuildTarget.mac)

        runner.onStart = { launch in
            guard let idx = launch.arguments.firstIndex(of: "-o"), idx + 1 < launch.arguments.count else { return }
            let appURL = URL(fileURLWithPath: launch.arguments[idx + 1])
            let macos = appURL.appendingPathComponent("Contents/MacOS")
            try? FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
            try? FileManager.default.createSymbolicLink(at: macos.appendingPathComponent("Game"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
            try? FileManager.default.createSymbolicLink(at: macos.appendingPathComponent("dmhost"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
            let info: [String: Any] = [
                "CFBundlePackageType": "APPL",
                "CFBundleExecutable": "Game",
                "CFBundleIdentifier": "org.nxnative.0400c3f00006e000",
                "CFBundleName": "Mario Kart World",
                "DMTitleID": "0400C3F00006E000",
            ]
            if let data = try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0) {
                try? data.write(to: appURL.appendingPathComponent("Contents/Info.plist"))
            }
        }

        store.startBuild()
        XCTAssertTrue(waitUntil { store.done && !store.macAppPath.isEmpty })

        let launch = try XCTUnwrap(runner.launches.first)
        XCTAssertTrue(launch.arguments.contains("--progress"))
        let workIdx = try XCTUnwrap(launch.arguments.firstIndex(of: "--work-dir"))
        XCTAssertEqual(launch.arguments[workIdx + 1], outDir.path + "/0400C3F00006E000_nolagkart_build")

        let bundle = try MacGameBundle.read(URL(fileURLWithPath: store.macAppPath))
        XCTAssertEqual(bundle.upstream, .noLagKart)
    }

    func testAllowlistGuardsCoverSingleGameHeaderProbeAndBatchQueue() throws {
        let kwsTree = try makeVariantTree(name: "kws-guard", flags: "\"--work-dir\"")
        let nlkTree = try makeVariantTree(name: "nlk-guard", flags: "\"--work-dir\"")
        let store = BuildStore(localizer: localizer, runner: RecordingRunner(), repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        store.home = temporary.path
        store.kidWithSwordPath = kwsTree
        store.noLagKartPath = nlkTree

        let keys = temporary.appendingPathComponent("prod.keys")
        let oot = temporary.appendingPathComponent("Ocarina [0400486024DEC000].nsp")
        let mkw = temporary.appendingPathComponent("MKW [0400C3F00006E000].nsp")
        let other = temporary.appendingPathComponent("Other [0100152000022000].nsp")
        let untagged = temporary.appendingPathComponent("Renamed.nsp")
        for f in [keys, oot, mkw, other, untagged] { try Data([0]).write(to: f) }

        // Pure empty state permits selecting variants.
        store.selectUpstream(.kidWithSword)
        XCTAssertEqual(store.buildUpstream, .kidWithSword)

        // Default-Deny on untagged ROM reverts to nxnative.
        store.readPackageTitleID = { _, _ in nil }
        store.updateSlot("base") { $0.paths = [untagged.path] }
        XCTAssertTrue(store.isUpstreamBlockedByCurrentGame(.kidWithSword))
        XCTAssertTrue(store.isUpstreamBlockedByCurrentGame(.noLagKart))
        XCTAssertEqual(store.buildUpstream, .nxnative)

        // Switching to MKW unlocks No Lag Kart and blocks Kid with Sword.
        store.updateSlot("base") { $0.paths = [mkw.path] }
        XCTAssertFalse(store.isUpstreamBlockedByCurrentGame(.noLagKart))
        XCTAssertTrue(store.isUpstreamBlockedByCurrentGame(.kidWithSword))

        // Queue whitelist gate: enqueueing mixed games under Kid with Sword keeps OoT on KWS and downgrades others to nxnative.
        store.updateSlot("base") { $0.paths = [] }
        store.selectUpstream(.kidWithSword)
        let queue = BuildQueueStore(file: nil, engineID: { "main" }, busy: { store.running }, start: { _ in nil })
        store.queue = queue
        queue.enqueue([
            QueueEntry(titleID: "0400486024DEC000", name: "OoT", target: BuildTarget.ios, inputs: ["base": [oot.path], "keys": [keys.path]], outputDirectory: temporary.path, engineID: "main"),
            QueueEntry(titleID: "0100152000022000", name: "MK8D", target: BuildTarget.mac, inputs: ["base": [other.path], "keys": [keys.path]], outputDirectory: temporary.path, engineID: "main"),
        ])
        XCTAssertEqual(queue.entries.first { $0.titleID == "0400486024DEC000" }?.upstream, .kidWithSword)
        XCTAssertEqual(queue.entries.first { $0.titleID == "0100152000022000" }?.upstream, .nxnative)
    }

    func testQueuedKidWithSwordIOSDoesNotRequireDeviceOrFailDeferredPackaging() throws {
        let kwsTree = try makeVariantTree(name: "kws-queue-ios", flags: "\"--work-dir\" \"--bundle-id\"")
        let runner = RecordingRunner()
        let outDir = temporary.appendingPathComponent("out-kws-q", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let store = BuildStore(localizer: localizer, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        store.home = temporary.path
        store.kidWithSwordPath = kwsTree
        store.outDir = outDir.path
        // Simulate direct-install default with NO device paired and NO exportIPA toggle set globally.
        devices.installDevice = ""
        devices.signingTeam = "TEAM77"
        devices.exportIPA = false
        devices.exportOneGame = false

        let oot = temporary.appendingPathComponent("Ocarina [0400486024DEC000].nsp")
        let keys = temporary.appendingPathComponent("prod.keys")
        try Data([0]).write(to: oot)
        try Data([0]).write(to: keys)

        var packageBatchCalled = false
        let queue = BuildQueueStore(
            file: nil,
            engineID: { "main" },
            busy: { store.running },
            start: { store.startQueued($0) },
            packageBatch: { _ in
                packageBatchCalled = true
                return false
            }
        )
        store.queue = queue
        store.selectUpstream(.kidWithSword)

        // Enqueue an OoT iOS entry with packageAfter: true (as if queued from shared-shell mode).
        queue.enqueue([
            QueueEntry(
                titleID: "0400486024DEC000",
                name: "Ocarina of Time",
                target: BuildTarget.ios,
                inputs: ["base": [oot.path], "keys": [keys.path]],
                outputDirectory: outDir.path,
                engineID: "main",
                packageAfter: true,
                upstream: .kidWithSword
            )
        ])

        // Queue enqueue normalizes standalone-only variant to one-game export (never shared shell).
        XCTAssertEqual(queue.entries.first?.packageAfter, false)
        XCTAssertEqual(queue.entries.first?.exportIPA, true)
        XCTAssertFalse(store.queueNeedsDevice, "Standalone-only Kid with Sword iOS queue must not be blocked by missing paired device")

        // Switch form back to nxnative (with built-in repo available) before starting queue to verify
        // startQueued computes deferShellPackaging AFTER switching buildUpstream to .kidWithSword.
        repo.isRepo = true
        store.selectUpstream(.nxnative)
        runner.onStart = { launch in
            if let idx = launch.arguments.firstIndex(of: "-o"), idx + 1 < launch.arguments.count {
                try? Data("ipa".utf8).write(to: URL(fileURLWithPath: launch.arguments[idx + 1]))
            }
        }
        store.startBuildOrQueue()
        XCTAssertTrue(waitUntil { !runner.launches.isEmpty && !store.running })
        XCTAssertFalse(store.deferShellPackaging, "Kid with Sword iOS queue build must never arm deferShellPackaging")

        let outcome = store.queueOutcome
        XCTAssertTrue(outcome.succeeded)
        queue.buildEnded(succeeded: outcome.succeeded, reason: outcome.reason, stopped: outcome.stopped)
        XCTAssertFalse(packageBatchCalled, "Standalone OneGameIPA must never trigger shared-shell packageBatch")
        XCTAssertEqual(queue.entries.first?.status, .done)
    }

    func testGameFolderUsesActiveVariantEngineRootAndEnforcesAllowlist() throws {
        let kwsTree = try makeVariantTree(name: "kws-folder", flags: "\"--work-dir\"")
        // Add Switch 2 folder + profile support markers ONLY inside kwsTree (not in repo.path).
        let dmDir = URL(fileURLWithPath: kwsTree).appendingPathComponent("dm/games/0400486024DEC000", isDirectory: true)
        try FileManager.default.createDirectory(at: dmDir, withIntermediateDirectories: true)
        try Data("title_id\t0400486024DEC000\nname\tOcarina of Time\n".utf8).write(to: dmDir.appendingPathComponent("game.tsv"))
        try Data("# \"--work-dir\" \"--romfs-dir\" \"provisional\"\n".utf8)
            .write(to: URL(fileURLWithPath: kwsTree).appendingPathComponent("scripts/build_ipa_from_nsp.py"))

        let store = BuildStore(localizer: localizer, runner: RecordingRunner(), repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        store.kidWithSwordPath = kwsTree
        store.selectUpstream(.kidWithSword)

        let ootContents = GameFolder.Contents(
            folder: temporary.path,
            titleID: 0x0400486024DEC000,
            updates: [],
            dlc: [],
            nup: nil
        )
        // Negative check: without scripts/pack_dump.py in kwsTree, engineBuildsFolders fails even if repo.path differs.
        XCTAssertEqual(store.gameFolderEngineProblem(ootContents), localizer.t("folder.engineOld"))
        try Data("# pack_dump\n".utf8).write(to: URL(fileURLWithPath: kwsTree).appendingPathComponent("scripts/pack_dump.py"))
        XCTAssertNil(store.gameFolderEngineProblem(ootContents), "Variant folder check must probe active variant engine root")

        let otherContents = GameFolder.Contents(
            folder: temporary.path,
            titleID: 0x0100152000022000,
            updates: [],
            dlc: [],
            nup: nil
        )
        XCTAssertEqual(store.gameFolderEngineProblem(otherContents), localizer.t("upstream.kwsOnlyTitle"))
    }
}
