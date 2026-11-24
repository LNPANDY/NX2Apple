import Darwin
import Foundation
import XCTest
@testable import NXCore
@testable import NXModel

@MainActor final class SeedCompressionTests: XCTestCase {
    private final class FakeRepo: RepoLocation {
        var path: String
        var isRepo = true
        var isGit = true
        init(path: String) { self.path = path }
    }

    private final class FakePython: PythonLocation {
        var pythonPath: String
        init(pythonPath: String = "/usr/bin/python3") { self.pythonPath = pythonPath }
    }

    private final class LiveRunningProcess: RunningProcess {
        let processIdentifier: Int32
        var isRunning: Bool
        init(pid: Int32, isRunning: Bool = true) {
            self.processIdentifier = pid
            self.isRunning = isRunning
        }
    }

    private final class ScriptedRunner: ProcessRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var recordedCaptures: [ProcessLaunch] = []
        private var recordedStreams: [ProcessLaunch] = []

        var captureHandler: (ProcessLaunch) -> ProcessResult = { _ in ProcessResult() }
        var streamHandler: (ProcessLaunch, @escaping (RunningProcess) -> Void, @escaping (String) -> Void) -> ProcessResult = { _, started, _ in
            started(FakeRunningProcess())
            return ProcessResult()
        }

        var captures: [ProcessLaunch] { lock.withLock { recordedCaptures } }
        var streams: [ProcessLaunch] { lock.withLock { recordedStreams } }

        func capture(_ launch: ProcessLaunch) -> ProcessResult {
            lock.withLock { recordedCaptures.append(launch) }
            return captureHandler(launch)
        }

        func stream(_ launch: ProcessLaunch, line: @escaping (String) -> Void) -> Bool { true }

        func streamLines(
            _ launch: ProcessLaunch,
            started: @escaping (RunningProcess) -> Void,
            line: @escaping (String) -> Void
        ) -> ProcessResult {
            lock.withLock { recordedStreams.append(launch) }
            return streamHandler(launch, started, line)
        }

        func start(_ launch: ProcessLaunch, onOutput: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> RunningProcess {
            throw CocoaError(.fileNoSuchFile)
        }
    }

    private var tempDir: URL!
    private var defaults: UserDefaults!
    private let fm = FileManager.default

    override func setUp() async throws {
        try await super.setUp()
        tempDir = fm.temporaryDirectory.appendingPathComponent("seed-compression-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defaults = TestDefaults.make("nxmodel-seed-compression")
    }

    override func tearDown() async throws {
        try? fm.removeItem(at: tempDir)
        tempDir = nil
        defaults = nil
        try await super.tearDown()
    }

    private func makeRepoWithBuildSeedTool(supportsCompression: Bool = true) throws -> String {
        let repo = tempDir.appendingPathComponent("repo-\(UUID().uuidString)", isDirectory: true)
        let toolURL = repo.appendingPathComponent(RepoLayout.buildSeedTool)
        try fm.createDirectory(at: toolURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body = supportsCompression ? "#!/usr/bin/env python3\n# scan-uncompressed compress-seeds\n" : "#!/usr/bin/env python3\n# legacy\n"
        try body.write(to: toolURL, atomically: true, encoding: .utf8)
        let marker = repo.appendingPathComponent(EngineLayout.marker)
        try fm.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: marker)
        return repo.path
    }

    private func createUncompressedSeed(
        root: URL,
        tid: String,
        appName: String,
        chain: String = "108c5f92c3c4",
        payloadBytes: Int = 4096
    ) throws {
        let seedDir = root.appendingPathComponent(tid, isDirectory: true)
        let metalDir = seedDir.appendingPathComponent("metal-sources", isDirectory: true)
        try fm.createDirectory(at: metalDir, withIntermediateDirectories: true)
        let record = ["schema": 1, "title_id": tid, "app_name": appName] as [String: Any]
        let jsonData = try JSONSerialization.data(withJSONObject: record)
        try jsonData.write(to: seedDir.appendingPathComponent("seed.json"))
        let img = Data("DMROMFS1".utf8) + Data(repeating: 0x41, count: max(0, payloadBytes - 8))
        try img.write(to: metalDir.appendingPathComponent("b-\(chain).img"))
    }

    // MARK: - BuildSeedCache .img.zst & .img compatibility

    func testBuildSeedCachePrefersCompressedImgZstOverLegacyImgAndFolder() throws {
        let seedDir = tempDir.appendingPathComponent("seed-compat", isDirectory: true)
        let metalDir = seedDir.appendingPathComponent("metal-sources", isDirectory: true)
        try fm.createDirectory(at: metalDir, withIntermediateDirectories: true)

        let chain = "108c5f92c3c4"
        let folder = metalDir.appendingPathComponent("b-\(chain)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let img = metalDir.appendingPathComponent("b-\(chain).img")
        try Data("legacy-img".utf8).write(to: img)

        // With folder + .img (no .img.zst), .img wins over loose folder.
        let resolvedBefore = try XCTUnwrap(BuildSeedCache.resolveMetalSource(in: seedDir.path, chain: chain, fm: fm))
        XCTAssertEqual(resolvedBefore.kind, .archive)
        XCTAssertEqual(resolvedBefore.relativePath, "b-\(chain).img")

        // Once .img.zst exists, .img.zst wins over .img and folder.
        let zst = metalDir.appendingPathComponent("b-\(chain).img.zst")
        try Data("zstd-img".utf8).write(to: zst)
        let resolvedAfter = try XCTUnwrap(BuildSeedCache.resolveMetalSource(in: seedDir.path, chain: chain, fm: fm))
        XCTAssertEqual(resolvedAfter.kind, .compressedArchive)
        XCTAssertEqual(resolvedAfter.relativePath, "b-\(chain).img.zst")
        XCTAssertEqual(resolvedAfter.sizeBytes, 8)

        let listed = BuildSeedCache.metalSourceEntries(in: seedDir.path, fm: fm)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.kind, .compressedArchive)
        XCTAssertTrue(BuildSeedCache.hasMetalSources(in: seedDir.path, fm: fm))
    }

    func testBuildSeedCacheIgnoresTempFilesAndSymlinksInMetalSources() throws {
        let seedDir = tempDir.appendingPathComponent("seed-unsafe", isDirectory: true)
        let metalDir = seedDir.appendingPathComponent("metal-sources", isDirectory: true)
        try fm.createDirectory(at: metalDir, withIntermediateDirectories: true)

        let chain = "abcdef012345"
        try Data("tmp".utf8).write(to: metalDir.appendingPathComponent("b-\(chain).img.zst.tmp"))
        try Data("part".utf8).write(to: metalDir.appendingPathComponent("b-\(chain).img.part"))
        let outside = tempDir.appendingPathComponent("outside.img")
        try Data("outside".utf8).write(to: outside)
        try fm.createSymbolicLink(atPath: metalDir.appendingPathComponent("b-\(chain).img").path, withDestinationPath: outside.path)

        XCTAssertNil(BuildSeedCache.resolveMetalSource(in: seedDir.path, chain: chain, fm: fm))
        XCTAssertTrue(BuildSeedCache.metalSourceEntries(in: seedDir.path, fm: fm).isEmpty)
        XCTAssertFalse(BuildSeedCache.hasMetalSources(in: seedDir.path, fm: fm))
    }

    // MARK: - SeedCompression parsing & local scan

    func testNDJSONEventParsingAndScanJSON() throws {
        let scanJSON = """
        {
          "seed_root": "/tmp/seeds",
          "zstd_available": true,
          "total_games": 1,
          "total_files": 2,
          "uncompressed_bytes": 1000000,
          "estimated_compressed_bytes": 80000,
          "estimated_saved_bytes": 920000,
          "games": [
            {
              "title_id": "0100000000010000",
              "app_name": "Sample",
              "files": ["b-108c5f92c3c4.img", "p0/b-108c5f92c3c4.img"],
              "uncompressed_bytes": 1000000,
              "estimated_compressed_bytes": 80000
            }
          ]
        }
        """
        let scan = try XCTUnwrap(SeedCompression.parseScanJSON(scanJSON))
        XCTAssertTrue(scan.zstdAvailable)
        XCTAssertTrue(scan.hasUncompressed)
        XCTAssertEqual(scan.games.first?.estimatedSavedBytes, 920_000)

        XCTAssertEqual(
            SeedCompression.parseEvent(line: #"{"event":"start","total_games":2,"total_files":3,"total_bytes":5000}"#),
            .start(totalGames: 2, totalFiles: 3, totalBytes: 5000)
        )
        XCTAssertEqual(
            SeedCompression.parseEvent(line: #"{"event":"item_start","index":1,"total_games":2,"title_id":"0100000000010000","before_bytes":3000}"#),
            .itemStart(index: 1, totalGames: 2, titleID: "0100000000010000", beforeBytes: 3000)
        )
        XCTAssertEqual(
            SeedCompression.parseEvent(line: #"{"event":"item_done","index":1,"total_games":2,"title_id":"0100000000010000","before_bytes":3000,"after_bytes":240,"saved_bytes":2760,"files_compressed":1}"#),
            .itemDone(index: 1, totalGames: 2, titleID: "0100000000010000", beforeBytes: 3000, afterBytes: 240, savedBytes: 2760, filesCompressed: 1)
        )
        XCTAssertEqual(
            SeedCompression.parseEvent(line: #"{"event":"item_error","index":2,"total_games":2,"title_id":"0100000000020000","before_bytes":2000,"error":"disk full"}"#),
            .itemError(index: 2, totalGames: 2, titleID: "0100000000020000", beforeBytes: 2000, error: "disk full")
        )
        let doneLine = #"{"event":"done","status":"stopped","completed_games":1,"failed_games":0,"before_bytes":3000,"after_bytes":240,"saved_bytes":2760,"elapsed_sec":1.5,"results":[]}"#
        if case .done(let summary) = SeedCompression.parseEvent(line: doneLine) {
            XCTAssertEqual(summary.status, .stopped)
            XCTAssertEqual(summary.savedBytes, 2760)
        } else {
            XCTFail("Expected .done event")
        }
        XCTAssertEqual(
            SeedCompression.parseEvent(line: #"{"event":"error","error":"zstd missing"}"#),
            .error("zstd missing")
        )
        XCTAssertNil(SeedCompression.parseEvent(line: "not-json"))
    }

    func testQuickScanLocalSkipsSymlinksAndTempFiles() throws {
        let seedRoot = tempDir.appendingPathComponent("seeds-local", isDirectory: true)
        try createUncompressedSeed(root: seedRoot, tid: "0100000000010000", appName: "Alpha", payloadBytes: 2048)
        let p0 = seedRoot.appendingPathComponent("0100000000010000/metal-sources/p0", isDirectory: true)
        try fm.createDirectory(at: p0, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 1024).write(to: p0.appendingPathComponent("b-108c5f92c3c4.img"))
        try Data("tmp".utf8).write(to: p0.appendingPathComponent("b-108c5f92c3c4.img.tmp"))

        let compressedOnly = seedRoot.appendingPathComponent("0100000000020000/metal-sources", isDirectory: true)
        try fm.createDirectory(at: compressedOnly, withIntermediateDirectories: true)
        try Data("zst".utf8).write(to: compressedOnly.appendingPathComponent("b-108c5f92c3c4.img.zst"))

        XCTAssertTrue(SeedCompression.hasAnySeedDirectory(in: seedRoot.path, fm: fm))
        let scan = SeedCompression.quickScanLocal(seedRoot: seedRoot.path, zstdAvailable: true, fm: fm)
        XCTAssertEqual(scan.totalGames, 1)
        XCTAssertEqual(scan.totalFiles, 2)
        XCTAssertEqual(scan.uncompressedBytes, 3072)
        XCTAssertEqual(scan.games.first?.appName, "Alpha")
    }

    // MARK: - SeedCompressionStore state machine

    func testStoreThreePhaseFlowAndDontAskAgainPersistence() async throws {
        let seedRoot = tempDir.appendingPathComponent("seeds-store", isDirectory: true)
        try createUncompressedSeed(root: seedRoot, tid: "0100000000010000", appName: "Marble", payloadBytes: 4096)
        let repoPath = try makeRepoWithBuildSeedTool()
        let runner = ScriptedRunner()

        let scanPayload = """
        {"seed_root":"\(seedRoot.path)","zstd_available":true,"total_games":1,"total_files":1,"uncompressed_bytes":4096,"estimated_compressed_bytes":328,"estimated_saved_bytes":3768,"games":[{"title_id":"0100000000010000","app_name":"Marble","files":["b-108c5f92c3c4.img"],"uncompressed_bytes":4096,"estimated_compressed_bytes":328}]}
        """
        runner.captureHandler = { _ in ProcessResult(status: 0, out: scanPayload) }
        runner.streamHandler = { _, started, emit in
            started(FakeRunningProcess())
            emit(#"{"event":"start","total_games":1,"total_files":1,"total_bytes":4096}"#)
            emit(#"{"event":"item_start","index":1,"total_games":1,"title_id":"0100000000010000","before_bytes":4096}"#)
            emit(#"{"event":"item_done","index":1,"total_games":1,"title_id":"0100000000010000","before_bytes":4096,"after_bytes":320,"saved_bytes":3776,"files_compressed":1}"#)
            emit(#"{"event":"done","status":"completed","completed_games":1,"failed_games":0,"before_bytes":4096,"after_bytes":320,"saved_bytes":3776,"elapsed_sec":0.25,"results":[{"title_id":"0100000000010000","status":"completed","before_bytes":4096,"after_bytes":320,"saved_bytes":3776,"files_compressed":1}]}"#)
            return ProcessResult(status: 0)
        }

        let store = SeedCompressionStore(
            runner: runner,
            repo: FakeRepo(path: repoPath),
            python: FakePython(pythonPath: "/opt/homebrew/bin/python3"),
            defaults: defaults,
            seedRoot: { seedRoot.path },
            seedEnvironment: { ["DM_SEED_CACHE_DIR": seedRoot.path] }
        )

        // Startup scan pops .prompt
        await store.scan(autoPromptOnFind: true).value
        guard case .prompt(let prompted) = store.phase else {
            return XCTFail("Expected .prompt phase after startup scan")
        }
        XCTAssertEqual(prompted.totalGames, 1)

        // Start compression -> transitions to .done
        await store.startCompression().value
        guard case .done(let summary) = store.phase else {
            return XCTFail("Expected .done phase after compression")
        }
        XCTAssertEqual(summary.status, .completed)
        XCTAssertEqual(summary.savedBytes, 3776)

        // Check env passed DM_SEED_CACHE_DIR
        XCTAssertEqual(runner.streams.first?.environment?["DM_SEED_CACHE_DIR"], seedRoot.path)

        // Dismiss with dontAskAgain persists flag; subsequent startup scan does NOT auto-prompt, but manual open DOES.
        store.finishDone()
        XCTAssertNil(store.phase)
        await store.scan(autoPromptOnFind: true).value
        if case .prompt = store.phase {
            store.dismissPrompt(dontAskAgain: true)
        }
        XCTAssertTrue(defaults.bool(forKey: SeedCompressionStore.promptDismissedKey))

        await store.scan(autoPromptOnFind: true).value
        XCTAssertNil(store.phase, "Auto-prompt must stay suppressed when dontAskAgain is set")

        _ = store.openManualPrompt()
        if case .prompt = store.phase {
            // Expected
        } else {
            XCTFail("Manual open from Settings must still open prompt even when dontAskAgain is true")
        }
    }

    func testStopCompressionSetsStoppingAndSendsSIGTERMAndEntersStoppedDone() async throws {
        let seedRoot = tempDir.appendingPathComponent("seeds-stop", isDirectory: true)
        try createUncompressedSeed(root: seedRoot, tid: "0100000000010000", appName: "One", payloadBytes: 2048)
        try createUncompressedSeed(root: seedRoot, tid: "0100000000020000", appName: "Two", payloadBytes: 2048)
        let repoPath = try makeRepoWithBuildSeedTool()

        let runner = ScriptedRunner()
        let sigLock = NSLock()
        var receivedSignals: [(pid_t, Int32)] = []
        let startedSem = DispatchSemaphore(value: 0)
        let resumeSem = DispatchSemaphore(value: 0)

        runner.captureHandler = { _ in
            let json = """
            {"seed_root":"\(seedRoot.path)","zstd_available":true,"total_games":2,"total_files":2,"uncompressed_bytes":4096,"estimated_compressed_bytes":328,"estimated_saved_bytes":3768,"games":[{"title_id":"0100000000010000","app_name":"One","files":["b-108c5f92c3c4.img"],"uncompressed_bytes":2048,"estimated_compressed_bytes":164},{"title_id":"0100000000020000","app_name":"Two","files":["b-108c5f92c3c4.img"],"uncompressed_bytes":2048,"estimated_compressed_bytes":164}]}
            """
            return ProcessResult(status: 0, out: json)
        }
        runner.streamHandler = { _, started, emit in
            started(LiveRunningProcess(pid: 4242, isRunning: true))
            emit(#"{"event":"start","total_games":2,"total_files":2,"total_bytes":4096}"#)
            emit(#"{"event":"item_start","index":1,"total_games":2,"title_id":"0100000000010000","before_bytes":2048}"#)
            emit(#"{"event":"item_done","index":1,"total_games":2,"title_id":"0100000000010000","before_bytes":2048,"after_bytes":160,"saved_bytes":1888,"files_compressed":1}"#)
            startedSem.signal()
            _ = resumeSem.wait(timeout: .now() + 5)
            emit(#"{"event":"done","status":"stopped","completed_games":1,"failed_games":0,"before_bytes":2048,"after_bytes":160,"saved_bytes":1888,"elapsed_sec":0.5,"results":[{"title_id":"0100000000010000","status":"completed","before_bytes":2048,"after_bytes":160,"saved_bytes":1888,"files_compressed":1}]}"#)
            return ProcessResult(status: 0)
        }

        let store = SeedCompressionStore(
            runner: runner,
            repo: FakeRepo(path: repoPath),
            python: FakePython(),
            defaults: defaults,
            seedRoot: { seedRoot.path },
            sendSignal: { pid, sig in
                sigLock.withLock { receivedSignals.append((pid, sig)) }
                resumeSem.signal()
            }
        )

        await store.scan(autoPromptOnFind: true).value
        let runTask = store.startCompression()
        await Task.detached { _ = startedSem.wait(timeout: .now() + 5) }.value
        // Allow started callback to deliver activeProcess on main queue.
        await Task.yield()

        store.stopCompression()
        guard case .running(let running) = store.phase else {
            return XCTFail("Expected .running while stopping")
        }
        XCTAssertTrue(running.stopping)

        await runTask.value
        guard case .done(let summary) = store.phase else {
            return XCTFail("Expected .done after stop")
        }
        XCTAssertEqual(summary.status, .stopped)
        XCTAssertEqual(summary.completedGames, 1)
        XCTAssertEqual(sigLock.withLock { receivedSignals.first?.0 }, 4242)
        XCTAssertEqual(sigLock.withLock { receivedSignals.first?.1 }, SIGTERM)
    }

    func testScanGenerationDropsStaleResultAndFiltersMNGPython() async throws {
        let seedRoot = tempDir.appendingPathComponent("seeds-gen", isDirectory: true)
        try createUncompressedSeed(root: seedRoot, tid: "0100000000010000", appName: "One", payloadBytes: 2048)
        let repoPath = try makeRepoWithBuildSeedTool()
        let homeDir = tempDir.appendingPathComponent("home", isDirectory: true).path
        let mngPython = homeDir + "/Library/Application Support/NX2Apple/MacNativeGames/uv-python/3.12/bin/python3"

        let runner = ScriptedRunner()
        let firstStarted = DispatchSemaphore(value: 0)
        let firstRelease = DispatchSemaphore(value: 0)
        let callLock = NSLock()
        var callCount = 0

        runner.captureHandler = { _ in
            let idx = callLock.withLock { () -> Int in
                callCount += 1
                return callCount
            }
            if idx == 1 {
                firstStarted.signal()
                _ = firstRelease.wait(timeout: .now() + 5)
                return ProcessResult(status: 0, out: """
                {"seed_root":"\(seedRoot.path)","zstd_available":true,"total_games":1,"total_files":1,"uncompressed_bytes":9999,"estimated_compressed_bytes":100,"estimated_saved_bytes":9899,"games":[]}
                """)
            }
            return ProcessResult(status: 0, out: """
            {"seed_root":"\(seedRoot.path)","zstd_available":true,"total_games":1,"total_files":1,"uncompressed_bytes":2048,"estimated_compressed_bytes":164,"estimated_saved_bytes":1884,"games":[{"title_id":"0100000000010000","app_name":"One","files":["b-108c5f92c3c4.img"],"uncompressed_bytes":2048,"estimated_compressed_bytes":164}]}
            """)
        }

        let store = SeedCompressionStore(
            runner: runner,
            repo: FakeRepo(path: repoPath),
            python: FakePython(pythonPath: mngPython),
            defaults: defaults,
            seedRoot: { seedRoot.path },
            home: homeDir,
            findPython: { "/usr/bin/python3" }
        )

        let first = store.scan(autoPromptOnFind: false)
        await Task.detached { _ = firstStarted.wait(timeout: .now() + 5) }.value
        let second = store.scan(autoPromptOnFind: false)
        await second.value
        firstRelease.signal()
        await first.value

        XCTAssertEqual(store.currentScan?.uncompressedBytes, 2048, "Stale scan result must not overwrite newer generation")
        XCTAssertTrue(runner.captures.allSatisfy { !MacNativeGamesBuilder.isManagedUVPython($0.executable, home: homeDir) })
    }

    func testAutoPromptSuppressedWhileBuildRunning() async throws {
        let seedRoot = tempDir.appendingPathComponent("seeds-busy", isDirectory: true)
        try createUncompressedSeed(root: seedRoot, tid: "0100000000010000", appName: "Busy", payloadBytes: 2048)
        let repoPath = try makeRepoWithBuildSeedTool()
        let runner = ScriptedRunner()
        runner.captureHandler = { _ in
            ProcessResult(status: 0, out: """
            {"seed_root":"\(seedRoot.path)","zstd_available":true,"total_games":1,"total_files":1,"uncompressed_bytes":2048,"estimated_compressed_bytes":164,"estimated_saved_bytes":1884,"games":[{"title_id":"0100000000010000","app_name":"Busy","files":["b-108c5f92c3c4.img"],"uncompressed_bytes":2048,"estimated_compressed_bytes":164}]}
            """)
        }

        let store = SeedCompressionStore(
            runner: runner,
            repo: FakeRepo(path: repoPath),
            python: FakePython(),
            defaults: defaults,
            seedRoot: { seedRoot.path },
            buildRunning: { true }
        )
        await store.scan(autoPromptOnFind: true).value
        XCTAssertNil(store.phase)
    }

    func testRealEngineBuildSeedScanAndCompressEndToEnd() async throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let engineTool = repoRoot.appendingPathComponent("engine/dm/tools/build_seed.py")
        guard fm.fileExists(atPath: engineTool.path) else {
            throw XCTSkip("engine/ not synced")
        }
        let py = Toolchain.findPython().path
        guard !py.isEmpty else {
            throw XCTSkip("python3 unavailable")
        }

        // Probe real zstd availability using SystemProcessRunner
        let realRunner = SystemProcessRunner(defaults: defaults)
        let probe = realRunner.capture(ProcessLaunch(
            executable: py,
            arguments: SeedCompression.scanArguments(toolPath: engineTool.path, seedRoot: tempDir.path),
            environment: ["PATH": BuildCommands.toolPath("/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", python: py)]
        ))
        let probeScan = try XCTUnwrap(SeedCompression.parseScanJSON(probe.out))
        guard probeScan.zstdAvailable else {
            throw XCTSkip("zstd backend unavailable in current test environment")
        }

        let seedRoot = tempDir.appendingPathComponent("real-seeds", isDirectory: true)
        try createUncompressedSeed(root: seedRoot, tid: "0100000000010000", appName: "RealFixture", payloadBytes: 65536)

        let store = SeedCompressionStore(
            runner: realRunner,
            repo: FakeRepo(path: repoRoot.path),
            python: FakePython(pythonPath: py),
            defaults: defaults,
            seedRoot: { seedRoot.path }
        )

        await store.scan(autoPromptOnFind: true).value
        guard case .prompt(let prompted) = store.phase else {
            return XCTFail("Expected .prompt for real build_seed.py fixture")
        }
        XCTAssertEqual(prompted.totalGames, 1)

        await store.startCompression().value
        guard case .done(let summary) = store.phase else {
            return XCTFail("Expected .done after real compression")
        }
        XCTAssertEqual(summary.status, .completed)
        XCTAssertEqual(summary.completedGames, 1)
        XCTAssertEqual(summary.failedGames, 0)
        XCTAssertLessThan(summary.afterBytes, summary.beforeBytes)

        let seedDir = seedRoot.appendingPathComponent("0100000000010000").path
        let resolved = try XCTUnwrap(BuildSeedCache.resolveMetalSource(in: seedDir, chain: "108c5f92c3c4", fm: fm))
        XCTAssertEqual(resolved.kind, .compressedArchive)
        XCTAssertFalse(fm.fileExists(atPath: seedDir + "/metal-sources/b-108c5f92c3c4.img"))
    }
}
