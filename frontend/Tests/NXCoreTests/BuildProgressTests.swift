import XCTest
@testable import NXCore

/// Reading what a build prints: stage lines, progress counts, durations and the steps of Xcode and the install.
/// Runs on NXCore alone, without SwiftUI.
final class BuildProgressTests: XCTestCase {
    func testProgressDetailReadsTheScriptsCounts() {
        XCTAssertEqual(BuildProgress.progressDetail(["step": "splitting", "done": 1203, "total": 19592, "unit": "shaders", "eta": 130]),
                       "splitting · " + NumberFormatter.localizedString(from: 1203, number: .decimal) + " / "
                       + NumberFormatter.localizedString(from: 19592, number: .decimal) + " shaders")
        XCTAssertEqual(BuildProgress.progressDetail(["done": 2301, "unit": "files"]), NumberFormatter.localizedString(from: 2301, number: .decimal) + " files")
        XCTAssertTrue(BuildProgress.progressDetail(["done": 1_000_000_000, "total": 3_000_000_000, "unit": "B", "est": true]).contains(" / ~"))
        XCTAssertEqual(BuildProgress.progressDetail(["step": "booting the game"]), "booting the game")
    }

    /// The stage's clock runs on while the count stands still, and the script's estimate counts down from when it came, then goes.
    func testStageClockCountsOnAndTheEstimateRunsOut() {
        let t0 = Date()
        let stage = Stage(id: 1, name: "shader split", started: t0, eta: 71, etaAt: t0.addingTimeInterval(10))
        XCTAssertEqual(stage.clock(at: t0.addingTimeInterval(42), left: "%@ left"), "0:42 · " + BuildProgress.duration(39) + " left")
        XCTAssertEqual(stage.clock(at: t0.addingTimeInterval(125), left: "%@ left"), "2:05")   // the estimate ran out: no stale "1 min 11 s left"
        XCTAssertEqual(stage.clock(at: t0.addingTimeInterval(3725), left: "%@ left"), "1:02:05")
    }

    /// Issue #52: the failure note names the last real line, not just the exit code.
    func testLastMeaningfulLineSkipsProgressEventsAndBlankLines() {
        let log = """
        [1/7] extract
        {"event":"progress","frac":0.4}

        RuntimeError: no prod.keys in the game folder

        """
        XCTAssertEqual(BuildProgress.lastMeaningfulLine(log), "RuntimeError: no prod.keys in the game folder")
        XCTAssertNil(BuildProgress.lastMeaningfulLine("\n\n"))
        XCTAssertNil(BuildProgress.lastMeaningfulLine("{\"event\":\"stage_end\"}\n"))
    }

    func testDurationIsWrittenByHandInEnglish() {
        XCTAssertEqual(BuildProgress.duration(0), "1s", "never below one second")
        XCTAssertEqual(BuildProgress.duration(3.2), "4s", "rounded up")
        XCTAssertEqual(BuildProgress.duration(60), "1m")
        XCTAssertEqual(BuildProgress.duration(125), "2m 5s")
        XCTAssertEqual(BuildProgress.duration(3600), "1h")
        XCTAssertEqual(BuildProgress.duration(3600 + 120), "1h 2m")
    }

    func testParseStageReadsTheScriptsLineForm() throws {
        let start = try XCTUnwrap(BuildProgress.parseStage("[12:00:01] [2/7] extract v720896 …"))
        XCTAssertEqual(start.k, 2)
        XCTAssertEqual(start.name, "extract v720896")
        XCTAssertEqual(start.state, .running)
        XCTAssertNil(start.percent)
        let done = try XCTUnwrap(BuildProgress.parseStage("[12:00:20] ✓ [2/7] extract v720896 (0:19): 30,000 files, 3.4 GB"))
        XCTAssertEqual(done.name, "extract v720896")
        XCTAssertEqual(done.state, .done)
        XCTAssertEqual(done.detail, "30,000 files, 3.4 GB")
        XCTAssertEqual(done.percent, 100)
        let failed = try XCTUnwrap(BuildProgress.parseStage("✗ [3/7] rewrite (0:02)"))
        XCTAssertEqual(failed.state, .failed)
        let warned = try XCTUnwrap(BuildProgress.parseStage("[12:00:45] ⚠ [6/7] Pipeline archive (0:00): skipped"))
        XCTAssertEqual(warned.k, 6)
        XCTAssertEqual(warned.name, "Pipeline archive")
        XCTAssertEqual(warned.state, .done)
        XCTAssertEqual(warned.detail, "skipped")
        let heartbeat = try XCTUnwrap(BuildProgress.parseStage("[12:00:30] [6/7] Pipeline archive: 0:30"))
        XCTAssertEqual(heartbeat.k, 6)
        XCTAssertEqual(heartbeat.name, "Pipeline archive")
        XCTAssertEqual(heartbeat.state, .running)
        XCTAssertEqual(heartbeat.detail, "0:30")
        XCTAssertNil(heartbeat.percent)
        let counting = try XCTUnwrap(BuildProgress.parseStage("[4/7] shader split · 26%, 10,577 / 41,062 files"))
        XCTAssertEqual(counting.name, "shader split")
        XCTAssertEqual(counting.percent, 26)
        XCTAssertNil(BuildProgress.parseStage("no stage in this line"))
    }

    func testXcodeAndInstallStepsNameWhatIsHappening() {
        XCTAssertEqual(BuildProgress.xcodeStep("CompileC build/x.o")?.detail, "compiling")
        XCTAssertEqual(BuildProgress.xcodeStep("Ld build/x")?.detail, "linking")
        XCTAssertEqual(BuildProgress.xcodeStep("CodeSign build/x.app")?.detail, "signing")
        XCTAssertNil(BuildProgress.xcodeStep("note: something else"))
        XCTAssertEqual(BuildProgress.installStep("Installing … 45%")?.percent, 45)
        XCTAssertEqual(BuildProgress.installStep("Installing … 45%")?.detail, "installing")
        XCTAssertEqual(BuildProgress.installStep("done 250%")?.percent, 100, "capped")
        XCTAssertNil(BuildProgress.installStep("no number here"))
    }

    func testPSOArchiveProgressReadsBatchesAndMergingFromWorkDir() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("pso-prog-" + UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        let macWork = tmp.appendingPathComponent("pso/mac-work")
        try fm.createDirectory(at: macWork, withIntermediateDirectories: true)

        // Generate a bases.mtl4-json with 2,500 vertex_function_descriptor entries -> 3 batches (batchSize 1000)
        let entry = #"{"vertex_function_descriptor":"v"}"#
        let jsText = "{\"pipelines\":[" + Array(repeating: entry, count: 2500).joined(separator: ",") + "]}\n"
        try Data(jsText.utf8).write(to: macWork.appendingPathComponent("bases.mtl4-json"))

        // Without a `batches.<arch>` directory (or batch log lines), return nil so single-invocation metal-tt shows no stuck "0 / N"
        XCTAssertNil(BuildProgress.psoArchiveProgress(workDir: tmp.path))

        let arch = "applegpu_g13s"
        let b1 = macWork.appendingPathComponent("batches.\(arch)/00001")
        let b2 = macWork.appendingPathComponent("batches.\(arch)/00002")
        let b3 = macWork.appendingPathComponent("batches.\(arch)/00003")
        for b in [b1, b2, b3] { try fm.createDirectory(at: b, withIntermediateDirectories: true) }

        // Batch 1 completed, Batch 2 compiling (no key file yet)
        try Data("{}".utf8).write(to: b1.appendingPathComponent("bases.mtl4-json"))
        try Data("archive".utf8).write(to: b1.appendingPathComponent("\(arch).mtl4a"))
        try Data("key1\n".utf8).write(to: b1.appendingPathComponent("key.\(arch)"))
        try Data("{}".utf8).write(to: b2.appendingPathComponent("bases.mtl4-json"))

        XCTAssertEqual(BuildProgress.psoArchiveProgress(workDir: tmp.path),
                       PSOArchiveProgress(done: 1, total: 3, merging: false))

        // All 3 batches completed and metal-pack started
        for b in [b2, b3] {
            try Data("{}".utf8).write(to: b.appendingPathComponent("bases.mtl4-json"))
            try Data("archive".utf8).write(to: b.appendingPathComponent("\(arch).mtl4a"))
            try Data("key\n".utf8).write(to: b.appendingPathComponent("key.\(arch)"))
        }
        try Data().write(to: macWork.appendingPathComponent("metal-pack.\(arch).log"))
        XCTAssertEqual(BuildProgress.psoArchiveProgress(workDir: tmp.path),
                       PSOArchiveProgress(done: 3, total: 3, merging: true))

        // Log lines written by `pso_offline.py` provide exact batch counts independent of batchSize
        let logsDir = tmp.appendingPathComponent("logs")
        try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let logContent = """
        pso_offline: applegpu_g13s: batch 1/5: 500 bases, compiling or checking cache
        pso_offline: applegpu_g13s: batch 1/5: ready (compiled)
        pso_offline: applegpu_g13s: batch 2/5: ready (reused)
        pso_offline: applegpu_g13s: batch 3/5: 500 bases, compiling or checking cache
        """
        try Data(logContent.utf8).write(to: logsDir.appendingPathComponent("pso_offline_mac.log"))
        XCTAssertEqual(BuildProgress.psoArchiveProgress(workDir: tmp.path),
                       PSOArchiveProgress(done: 2, total: 5, merging: false))
    }
}
