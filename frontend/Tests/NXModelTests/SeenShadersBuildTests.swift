import Foundation
import XCTest
@testable import NXModel
@testable import NXCore

@MainActor final class SeenShadersBuildTests: XCTestCase {
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
        var installed: [String] = []
        var busy: Set<String> = []
        func isInstalling(_ id: String) -> Bool { busy.contains(id) }
        func install(_ dep: Dep) -> Task<Void, Never> { Task {} }
    }

    private final class FakeEngine: EngineSyncing {
        func syncEngine(then: ((Bool) -> Void)?) -> Task<Void, Never> {
            then?(true)
            return Task {}
        }
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
        func deviceName(_ udid: String) -> String { "iPhone" }
        nonisolated func askCopy(_ plan: ShellCopyPlan) -> ShellCopyDecision { .skip }
        nonisolated func setWaiting(_ on: Bool) {}
        nonisolated var waitCancelled: Bool { false }
        func copyEnded() {}
    }

    private final class RecordingRunner: ProcessRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [ProcessLaunch] = []
        var launches: [ProcessLaunch] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }
        func capture(_ launch: ProcessLaunch) -> ProcessResult {
            lock.lock(); recorded.append(launch); lock.unlock()
            return ProcessResult()
        }
        func stream(_ launch: ProcessLaunch, line: @escaping (String) -> Void) -> Bool {
            lock.lock(); recorded.append(launch); lock.unlock()
            return true
        }
        func streamLines(_ launch: ProcessLaunch, started: @escaping (RunningProcess) -> Void, line: @escaping (String) -> Void) -> ProcessResult {
            lock.lock(); recorded.append(launch); lock.unlock()
            started(FakeRunningProcess())
            return ProcessResult(status: 0)
        }
        func start(_ launch: ProcessLaunch, onOutput: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> RunningProcess {
            lock.lock(); recorded.append(launch); lock.unlock()
            onExit(0)
            return FakeRunningProcess()
        }
    }

    private func makeFixtureRepo(withSeenOption: Bool = true) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("seen-shaders-model-" + UUID().uuidString)
        let fm = FileManager.default
        let scriptURL = root.appendingPathComponent("scripts/build_ipa_from_nsp.py")
        try fm.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let scriptText = withSeenOption
            ? "# stub\n'--work-dir'\n'--from-seed'\n'--seen-shaders'\n"
            : "# stub\n'--work-dir'\n'--from-seed'\n"
        try scriptText.write(to: scriptURL, atomically: true, encoding: .utf8)
        let romfsTool = root.appendingPathComponent("dm/tools/romfs_image.py")
        try fm.createDirectory(at: romfsTool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# stub\n".write(to: romfsTool, atomically: true, encoding: .utf8)
        let marker = root.appendingPathComponent("dm/tools/nx_extract/Program.cs")
        try fm.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "// stub\n".write(to: marker, atomically: true, encoding: .utf8)

        // Game A: has shader_seen.tsv (2 of 5 shaders)
        let gA = root.appendingPathComponent("dm/games/0400A3A01EE4C000", isDirectory: true)
        try fm.createDirectory(at: gA, withIntermediateDirectories: true)
        try "title_id\t0400A3A01EE4C000\n".write(to: gA.appendingPathComponent("game.tsv"), atomically: true, encoding: .utf8)
        try "0123456789abcdef\tpixel\nfedcba9876543210\tvertex\n".write(to: gA.appendingPathComponent("shader_seen.tsv"), atomically: true, encoding: .utf8)
        try "1\n2\n3\n4\n5\n".write(to: gA.appendingPathComponent("shader_map.tsv"), atomically: true, encoding: .utf8)

        // Game B: no shader_seen.tsv
        let gB = root.appendingPathComponent("dm/games/0100000000010000", isDirectory: true)
        try fm.createDirectory(at: gB, withIntermediateDirectories: true)
        try "title_id\t0100000000010000\n".write(to: gB.appendingPathComponent("game.tsv"), atomically: true, encoding: .utf8)
        try "1\n2\n3\n".write(to: gB.appendingPathComponent("shader_map.tsv"), atomically: true, encoding: .utf8)
        return root
    }

    func testShouldPassSeenShadersEnforcesTargetUpstreamEngineAndPerGameGuards() throws {
        let repo = try makeFixtureRepo(withSeenOption: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        let defaults = TestDefaults.make("seen-shaders-guards")
        let store = BuildStore(
            localizer: Localizer(),
            runner: RecordingRunner(),
            repo: FakeRepo(path: repo.path),
            deps: FakeDeps(),
            engine: FakeEngine(),
            devices: FakeDevices(),
            defaults: defaults
        )
        store.target = BuildTarget.mac
        store.buildUpstream = EngineUpstreamKind.nxnative

        // Default off: never passes --seen-shaders.
        XCTAssertFalse(store.seenShadersOnly)
        XCTAssertFalse(store.shouldPassSeenShaders(forTitleID: "0400A3A01EE4C000"))

        // Turn on: passes for Game A (has shader_seen.tsv), but NEVER for Game B (no shader_seen.tsv) in a mixed queue.
        store.seenShadersOnly = true
        XCTAssertTrue(store.shouldPassSeenShaders(forTitleID: "0400A3A01EE4C000"))
        XCTAssertFalse(store.shouldPassSeenShaders(forTitleID: "0100000000010000"))

        // iOS target: never passes --seen-shaders.
        store.target = BuildTarget.ios
        XCTAssertFalse(store.shouldPassSeenShaders(forTitleID: "0400A3A01EE4C000"))

        // Older engine without --seen-shaders: never passes.
        let oldRepo = try makeFixtureRepo(withSeenOption: false)
        defer { try? FileManager.default.removeItem(at: oldRepo) }
        let oldStore = BuildStore(
            localizer: Localizer(),
            runner: RecordingRunner(),
            repo: FakeRepo(path: oldRepo.path),
            deps: FakeDeps(),
            engine: FakeEngine(),
            devices: FakeDevices(),
            defaults: defaults
        )
        oldStore.target = BuildTarget.mac
        oldStore.seenShadersOnly = true
        XCTAssertFalse(oldStore.shouldPassSeenShaders(forTitleID: "0400A3A01EE4C000"))
    }

    func testStartBuildPassesSeenShadersFlagOnlyWhenEnabledAndEligible() throws {
        let repo = try makeFixtureRepo(withSeenOption: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        let gameDir = repo.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        let nspA = gameDir.appendingPathComponent("Pokopia [0400A3A01EE4C000].nsp")
        let nspB = gameDir.appendingPathComponent("Odyssey [0100000000010000].nsp")
        let keys = gameDir.appendingPathComponent("prod.keys")
        try Data([0]).write(to: nspA)
        try Data([0]).write(to: nspB)
        try Data("master_key_00 = 00\n".utf8).write(to: keys)

        let defaults = TestDefaults.make("seen-shaders-run")
        let runner = RecordingRunner()
        let store = BuildStore(
            localizer: Localizer(),
            runner: runner,
            repo: FakeRepo(path: repo.path),
            deps: FakeDeps(),
            engine: FakeEngine(),
            devices: FakeDevices(),
            defaults: defaults
        )
        store.target = BuildTarget.mac
        store.buildUpstream = EngineUpstreamKind.nxnative
        store.updateSlot("keys") { $0.paths = [keys.path] }
        store.outDir = gameDir.path

        // 1. Toggle OFF for Game A -> no --seen-shaders
        store.updateSlot("base") { $0.paths = [nspA.path] }
        store.seenShadersOnly = false
        store.startBuild()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let launchOff = try XCTUnwrap(runner.launches.last)
        XCTAssertFalse(launchOff.arguments.contains("--seen-shaders"))

        // 2. Toggle ON for Game A -> passes --seen-shaders
        store.seenShadersOnly = true
        store.startBuild()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let launchOnA = try XCTUnwrap(runner.launches.last)
        XCTAssertTrue(launchOnA.arguments.contains("--seen-shaders"))

        // 3. Toggle still ON, switched to Game B (no shader_seen.tsv) -> omits --seen-shaders
        store.updateSlot("base") { $0.paths = [nspB.path] }
        store.startBuild()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let launchOnB = try XCTUnwrap(runner.launches.last)
        XCTAssertFalse(launchOnB.arguments.contains("--seen-shaders"))
    }

    func testIOSBuildUsesHintedTitleIDForSeenShadersAndCheatDirWhenFilenameLacksTitleID() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ios-seen-hinted-" + UUID().uuidString)
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        SeenShadersProfile.clearCacheForTesting()

        let scriptURL = root.appendingPathComponent("scripts/build_ipa_from_nsp.py")
        try fm.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# stub\n'--work-dir'\n'--from-seed'\n'--seen-shaders'\n'--cheat-dir'\n# ios_seen_shaders DM_PARTIAL_SHADERS\n"
            .write(to: scriptURL, atomically: true, encoding: .utf8)
        let romfsTool = root.appendingPathComponent("dm/tools/romfs_image.py")
        try fm.createDirectory(at: romfsTool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# stub\n".write(to: romfsTool, atomically: true, encoding: .utf8)
        let marker = root.appendingPathComponent("dm/tools/nx_extract/Program.cs")
        try fm.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "// stub\n".write(to: marker, atomically: true, encoding: .utf8)

        let tid = "0400A3A01EE4C000"
        let gDir = root.appendingPathComponent("dm/games/\(tid)", isDirectory: true)
        try fm.createDirectory(at: gDir, withIntermediateDirectories: true)
        try "title_id\t\(tid)\nios_seen_shaders\t1\n".write(to: gDir.appendingPathComponent("game.tsv"), atomically: true, encoding: .utf8)
        try "0123456789abcdef\tpixel\n".write(to: gDir.appendingPathComponent("shader_seen.tsv"), atomically: true, encoding: .utf8)
        try "package\tindex\tstage\tkey\tsource\np.bin\t0\tvs\t0123456789abcdef\tsrc\np.bin\t1\tvs\tfedcba9876543210\tsrc\n"
            .write(to: gDir.appendingPathComponent("shader_map.tsv"), atomically: true, encoding: .utf8)

        let fakeHome = root.appendingPathComponent("home", isDirectory: true)
        let cheatsDir = fakeHome.appendingPathComponent("Library/Application Support/nxnative/\(tid)/cheats", isDirectory: true)
        try fm.createDirectory(at: cheatsDir, withIntermediateDirectories: true)
        try "[Infinite HP]\n04000000 00000000 00000001\n"
            .write(to: cheatsDir.appendingPathComponent("0123456789ABCDEF.txt"), atomically: true, encoding: .utf8)

        // Base NSP filename intentionally has NO [TitleID] bracket; title ID comes only from hintedTitleID.
        let inputsDir = root.appendingPathComponent("inputs", isDirectory: true)
        try fm.createDirectory(at: inputsDir, withIntermediateDirectories: true)
        let unnamedNSP = inputsDir.appendingPathComponent("pokopia_dump.nsp")
        let keys = inputsDir.appendingPathComponent("prod.keys")
        try Data([0]).write(to: unnamedNSP)
        try Data("master_key_00 = 00\n".utf8).write(to: keys)

        let devices = FakeDevices()
        devices.exportIPA = true
        devices.exportOneGame = true
        let runner = RecordingRunner()
        let store = BuildStore(
            localizer: Localizer(),
            runner: runner,
            repo: FakeRepo(path: root.path),
            deps: FakeDeps(),
            engine: FakeEngine(),
            devices: devices,
            defaults: TestDefaults.make("ios-seen-hinted")
        )
        store.home = fakeHome.path
        store.target = BuildTarget.ios
        store.buildUpstream = EngineUpstreamKind.nxnative
        store.iosSeenShadersOnly = true
        store.updateSlot("base") { $0.paths = [unnamedNSP.path] }
        store.updateSlot("keys") { $0.paths = [keys.path] }
        store.outDir = inputsDir.path
        store.applyKnownTitleID(tid)

        store.startBuild()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let launch = try XCTUnwrap(runner.launches.last)
        XCTAssertTrue(launch.arguments.contains("--seen-shaders"), "Expected --seen-shaders via hintedTitleID when filename omits [TitleID]")
        XCTAssertTrue(launch.arguments.contains("--cheat-dir"), "Expected --cheat-dir via hintedTitleID when filename omits [TitleID]")
        XCTAssertTrue(launch.arguments.contains(cheatsDir.path))
    }

    func testQueuedIOSSeenShadersAndUpstreamSurviveTransientRunningDrop() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ios-seen-reentry-" + UUID().uuidString)
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        SeenShadersProfile.clearCacheForTesting()

        let scriptURL = root.appendingPathComponent("scripts/build_ipa_from_nsp.py")
        try fm.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# stub\n'--work-dir'\n'--from-seed'\n'--seen-shaders'\n# ios_seen_shaders DM_PARTIAL_SHADERS\n"
            .write(to: scriptURL, atomically: true, encoding: .utf8)
        let romfsTool = root.appendingPathComponent("dm/tools/romfs_image.py")
        try fm.createDirectory(at: romfsTool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# stub\n".write(to: romfsTool, atomically: true, encoding: .utf8)
        let marker = root.appendingPathComponent("dm/tools/nx_extract/Program.cs")
        try fm.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "// stub\n".write(to: marker, atomically: true, encoding: .utf8)

        let tid = "0400A3A01EE4C000"
        let gDir = root.appendingPathComponent("dm/games/\(tid)", isDirectory: true)
        try fm.createDirectory(at: gDir, withIntermediateDirectories: true)
        try "title_id\t\(tid)\nios_seen_shaders\t1\n".write(to: gDir.appendingPathComponent("game.tsv"), atomically: true, encoding: .utf8)
        try "0123456789abcdef\tpixel\n".write(to: gDir.appendingPathComponent("shader_seen.tsv"), atomically: true, encoding: .utf8)
        try "package\tindex\tstage\tkey\tsource\np.bin\t0\tvs\t0123456789abcdef\tsrc\np.bin\t1\tvs\tfedcba9876543210\tsrc\n"
            .write(to: gDir.appendingPathComponent("shader_map.tsv"), atomically: true, encoding: .utf8)

        let store = BuildStore(
            localizer: Localizer(),
            runner: RecordingRunner(),
            repo: FakeRepo(path: root.path),
            deps: FakeDeps(),
            engine: FakeEngine(),
            devices: FakeDevices(),
            defaults: TestDefaults.make("ios-seen-reentry")
        )
        store.target = BuildTarget.ios
        store.buildUpstream = .nxnative
        // Form toggle is ON, while queued entry explicitly snapped OFF (false).
        store.iosSeenShadersOnly = true
        store.queuedIOSSeenShaders = false
        store.activeQueueEntryUpstream = .s2arm

        // Simulate transient `running = true -> false` transition during verifyShellDevice / syncEngine re-entry.
        store.running = true
        store.running = false

        XCTAssertEqual(store.queuedIOSSeenShaders, false, "Transient running=false must not wipe queuedIOSSeenShaders before re-entry")
        XCTAssertEqual(store.activeQueueEntryUpstream, .s2arm, "Transient running=false must not wipe activeQueueEntryUpstream before re-entry")
        XCTAssertFalse(store.shouldPassIOSSeenShaders(forTitleID: tid, requested: store.queuedIOSSeenShaders))

        // Reverse: form toggle OFF, queued entry snapped ON (true).
        store.iosSeenShadersOnly = false
        store.queuedIOSSeenShaders = true
        store.running = true
        store.running = false
        XCTAssertTrue(store.shouldPassIOSSeenShaders(forTitleID: tid, requested: store.queuedIOSSeenShaders))
    }
}
