import XCTest
@testable import NXCore

final class BuildPlanTests: XCTestCase {
    func testBalatroMacPlanPredictsGLCaptureAndWeightedProgressNeverJumpsTo95Early() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("nx-buildplan-\(UUID().uuidString)")
        try fm.createDirectory(at: tempRoot.appendingPathComponent("dm/games/0100CD801CE5E000"), withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: tempRoot) }
        try Data("# capture\n".utf8).write(to: tempRoot.appendingPathComponent("dm/games/0100CD801CE5E000/gl_capture.tsv"))
        try Data("title_id\t0100CD801CE5E000\nname\tBalatro\n".utf8)
            .write(to: tempRoot.appendingPathComponent("dm/games/0100CD801CE5E000/game.tsv"))

        let input = BuildPlanInput(
            upstream: .nxnative,
            target: BuildTarget.mac,
            preflightEnabled: true,
            titleID: "0100CD801CE5E000",
            engineRoot: tempRoot.path
        )
        var stages = BuildPlan.initialStages(for: input)
        XCTAssertEqual(
            stages.map(\.name),
            ["extract", "rewrite", "GL shader capture", "GL shaders", "Mac host", "Mac app", "preflight"]
        )
        XCTAssertTrue(stages.allSatisfy { $0.state == .pending })

        // Simulate Extract + Rewrite done, and GL shader capture just started (0%):
        // Previously overallFraction hit 0.95 when script total was absent; with full weighted plan it stays ~31%.
        BuildPlan.upsertScriptStage(k: 1, name: "extract v851968", state: .running, detail: "", percent: nil, started: Date(), into: &stages)
        BuildPlan.upsertScriptStage(k: 1, name: "extract v851968", state: .done, detail: "40 files", percent: 100, started: nil, into: &stages)
        BuildPlan.upsertScriptStage(k: 2, name: "rewrite", state: .running, detail: "", percent: nil, started: Date(), into: &stages)
        BuildPlan.upsertScriptStage(k: 2, name: "rewrite", state: .done, detail: "main", percent: 100, started: nil, into: &stages)
        BuildPlan.upsertScriptStage(k: 3, name: "GL shader capture", state: .running, detail: "booting the game", percent: nil, started: Date(), into: &stages)

        XCTAssertEqual(
            stages.map(\.name),
            ["extract v851968", "rewrite", "GL shader capture", "GL shaders", "Mac host", "Mac app", "preflight"]
        )
        XCTAssertEqual(stages.map(\.state), [.done, .done, .running, .pending, .pending, .pending, .pending])

        let total = stages.filter { $0.id > 0 && $0.id < 1000 }.count
        let fraction = try XCTUnwrap(BuildProgress.overallFraction(stages: stages, totalStages: total, floor: 0))
        XCTAssertLessThan(fraction, 0.40)
        XCTAssertGreaterThan(fraction, 0.25)

        let segments = BuildProgress.segments(stages: stages, totalStages: total)
        XCTAssertEqual(segments.count, 7)
        XCTAssertEqual(segments.map(\.state), [.done, .done, .running, .pending, .pending, .pending, .pending])
        // GL shaders (weight 5.0) must have a wider segment than Mac app (weight 1.5).
        XCTAssertGreaterThan(segments[3].weight, segments[5].weight)
    }

    func testProvisionalPlanAdaptsWhenGLCaptureArrivesDynamically() {
        let input = BuildPlanInput(
            upstream: .nxnative,
            target: BuildTarget.mac,
            preflightEnabled: true,
            titleID: nil,
            engineRoot: ""
        )
        var stages = BuildPlan.initialStages(for: input)
        XCTAssertEqual(stages.map(\.name), ["extract", "rewrite", "shader split", "Mac shaders", "Mac host", "Mac app", "preflight"])

        BuildPlan.upsertScriptStage(k: 1, name: "extract v0", state: .done, detail: "", percent: 100, started: nil, into: &stages)
        BuildPlan.upsertScriptStage(k: 2, name: "rewrite", state: .done, detail: "", percent: 100, started: nil, into: &stages)
        BuildPlan.upsertScriptStage(k: 3, name: "GL shader capture", state: .running, detail: "", percent: nil, started: Date(), into: &stages)

        XCTAssertEqual(
            stages.map(\.name),
            ["extract v0", "rewrite", "GL shader capture", "GL shaders", "Mac host", "Mac app", "preflight"]
        )
        XCTAssertEqual(stages.map(\.state), [.done, .done, .running, .pending, .pending, .pending, .pending])
    }

    func testIOSDirectInstallPlanIncludesAllPostBuildStagesAndPreservesPendingAcrossScriptCompletion() {
        let input = BuildPlanInput(
            upstream: .nxnative,
            target: BuildTarget.ios,
            exportsOneGame: false,
            exportsFramework: false,
            exportsShell: false,
            deviceName: "iPhone",
            hasDLC: true
        )
        var stages = BuildPlan.initialStages(for: input)
        XCTAssertEqual(
            stages.map(\.nameKey),
            [nil, nil, nil, nil, nil, nil,
             "shell.projectStage", "dev.signStage", "dev.installStage", "shell.checkStage", "dev.copyStage"]
        )
        XCTAssertEqual(stages.filter { $0.id < 1000 }.map(\.name), [
            "extract", "extract DLC", "rewrite", "shader split", "iOS shaders", "game framework"
        ])

        BuildPlan.markScriptStagesDone(in: &stages)
        XCTAssertEqual(stages.filter { $0.id < 1000 }.allSatisfy { $0.state == .done }, true)
        XCTAssertEqual(stages.filter { $0.id >= 1000 }.allSatisfy { $0.state == .pending }, true)

        BuildPlan.pruneUnrunPendingStages(in: &stages)
        XCTAssertEqual(stages.filter { $0.state == .pending }.count, 0)
    }

    func testPrepStageResettingK1ArchivesPrepAndAlignsMainStages() {
        var stages = BuildPlan.initialStages(for: BuildPlanInput(upstream: .nxnative, target: BuildTarget.mac, preflightEnabled: false))
        BuildPlan.upsertScriptStage(k: 1, name: "decompress NSZ", state: .running, detail: "", percent: 50, started: Date(), into: &stages)
        BuildPlan.upsertScriptStage(k: 1, name: "decompress NSZ", state: .done, detail: "1 file", percent: 100, started: nil, into: &stages)
        BuildPlan.upsertScriptStage(k: 1, name: "extract v0", state: .running, detail: "", percent: nil, started: Date(), into: &stages)

        XCTAssertEqual(stages.map(\.name), ["decompress NSZ", "extract v0", "rewrite", "shader split", "Mac shaders", "Mac host", "Mac app"])
        XCTAssertEqual(stages.map(\.state), [.done, .running, .pending, .pending, .pending, .pending, .pending])
    }

    func testApplyScriptPlanEventReplacesPendingScriptStagesAndKeepsPostStages() {
        var stages = BuildPlan.initialStages(for: BuildPlanInput(upstream: .nxnative, target: BuildTarget.mac, preflightEnabled: true))
        BuildPlan.upsertScriptStage(k: 1, name: "extract v0", state: .done, detail: "", percent: 100, started: nil, into: &stages)
        BuildPlan.applyScriptPlan(["extract v0", "rewrite", "NRO capture", "rewrite", "shader split", "Mac shaders", "Mac host", "Mac app"], to: &stages)
        XCTAssertEqual(
            stages.map(\.name),
            ["extract v0", "rewrite", "NRO capture", "rewrite", "shader split", "Mac shaders", "Mac host", "Mac app", "preflight"]
        )
        XCTAssertEqual(stages.first?.state, .done)
        XCTAssertEqual(stages.last?.state, .pending)
    }
}
