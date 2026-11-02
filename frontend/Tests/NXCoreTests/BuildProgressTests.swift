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
}
