import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher
@testable import NXModel

@MainActor final class ShaderProgressLayoutTests: IsolatedDefaultsTestCase {
    private final class StageSamples {
        var all: [ProgressStageSample] = []
    }

    func testBuildStoreStripsNotCachedWhilePreservingPercentAndETACountdown() throws {
        let stores = LauncherStores(localizer: Localizer(.zh), defaults: testDefaults)
        let build = stores.build
        build.running = true

        // 1. `--progress json` stream from `build_ipa_from_nsp.py` (`ShaderWatch` during `Mac shaders` / `iOS shaders`).
        build.ingest("""
        {"ev":"stage","k":6,"n":8,"name":"Mac shaders","step":"compiling"}
        {"ev":"progress","k":6,"name":"Mac shaders","step":"compiling","done":679,"total":11201,"unit":"shaders","est":false,"note":"11,201 not cached","frac":0.0606195875,"eta":774.0,"elapsed":50.0}

        """)
        XCTAssertEqual(build.stages.count, 1)
        let idx = try XCTUnwrap(build.stages.firstIndex(where: { $0.id == 6 }))
        XCTAssertFalse(build.stages[idx].detail.contains("not cached"), "detail kept 'not cached': \(build.stages[idx].detail)")
        XCTAssertTrue(build.stages[idx].detail.hasPrefix("compiling · "))
        XCTAssertEqual(try XCTUnwrap(build.stages[idx].percent), 6.06195875, accuracy: 0.001)
        XCTAssertEqual(build.stages[idx].eta, 774.0)

        let now = Date()
        build.stages[idx].started = now.addingTimeInterval(-50)
        build.stages[idx].etaAt = now
        XCTAssertEqual(try XCTUnwrap(build.stages[idx].remaining(at: now)), 774.0, accuracy: 0.01)
        let clock = build.stages[idx].clock(at: now, left: stores.localizer.t("prog.etaEstimate"))
        XCTAssertTrue(clock.hasPrefix("0:50 · "))
        XCTAssertTrue(clock.contains("12m 54s"), "clock lost ETA duration: \(clock)")

        // 2. `--progress lines` fallback stream.
        build.ingest("[12:01:20] [7/8] iOS shaders · compiling: 12%, 1,345/11,201 shaders, 11,201 not cached, 1:20 · ETA 9:46\n")
        let iosStage = try XCTUnwrap(build.stages.first(where: { $0.id == 7 }))
        XCTAssertEqual(iosStage.percent, 12)
        XCTAssertEqual(iosStage.detail, "1,345/11,201 shaders, 1:20 · ETA 9:46")
    }

    /// Renders the real `ProgressCard` at the minimum 900 pt page width (`820 pt` card width inside `LauncherPageScroll`'s
    /// 40 pt horizontal margins) across every launcher language (`Lang.all`) with 5-digit shader counts (`10,842 / 28,669 shaders`)
    /// and a multi-hour elapsed clock + ETA, verifying neither the shader count nor the trailing ETA is truncated.
    func testProgressCardFitsFiveDigitShaderCountAndETAAt900PtAcrossAllLanguages() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        for lang in Lang.all {
            let stores = LauncherStores(localizer: Localizer(lang), defaults: testDefaults)
            let build = stores.build
            build.running = true
            build.handleEvent("stage", ["k": 6, "n": 8, "name": "Mac shaders", "step": "compiling"])
            build.handleEvent("progress", [
                "k": 6,
                "name": "Mac shaders",
                "step": "compiling",
                "done": 10_842,
                "total": 28_669,
                "unit": "shaders",
                "est": false,
                "note": "28,669 not cached",
                "frac": 10_842.0 / 28_669.0,
                "eta": 4_125.0,
                "elapsed": 3_942.0,
            ])
            let now = Date()
            let idx = try XCTUnwrap(build.stages.firstIndex(where: { $0.id == 6 }))
            build.stages[idx].started = now.addingTimeInterval(-3_942) // 1:05:42
            build.stages[idx].etaAt = now

            let captured = StageSamples()
            let view = VStack(alignment: .leading, spacing: 0) {
                ProgressCard(build: build)
            }
            .padding(.horizontal, 40)
            .frame(width: 900, alignment: .leading)
            .environmentObject(stores.localizer)
            .environment(\.measuresProgressStages, true)
            .onPreferenceChange(ProgressStageSamples.self) { captured.all = $0 }
            .font(.manrope(13))

            let host = NSHostingView(rootView: view)
            let window = OffscreenWindow(size: NSSize(width: 900, height: 260))
            window.contentView = host
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            host.layoutSubtreeIfNeeded()

            let detailSample = try XCTUnwrap(captured.all.last(where: { $0.stageID == 6 && $0.part == .detail }), "\(lang.code): missing detail sample")
            let clockSample = try XCTUnwrap(captured.all.last(where: { $0.stageID == 6 && $0.part == .clock }), "\(lang.code): missing clock sample")
            XCTAssertGreaterThanOrEqual(
                detailSample.room + 0.5,
                detailSample.labelWidth,
                "\(lang.code): shader detail truncated (room \(detailSample.room) < ideal \(detailSample.labelWidth))"
            )
            XCTAssertGreaterThanOrEqual(
                clockSample.room + 0.5,
                clockSample.labelWidth,
                "\(lang.code): ETA clock truncated (room \(clockSample.room) < ideal \(clockSample.labelWidth))"
            )
        }
    }

    /// Even when a stage reports an unusually long path/note in `detail`, `ProgressCard` middle-truncates `detail` first and keeps
    /// the trailing elapsed time + ETA completely untruncated at priority 1.
    func testProgressCardKeepsETAUntruncatedWhenDetailIsOverlong() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let stores = LauncherStores(localizer: Localizer(.en), defaults: testDefaults)
        let build = stores.build
        build.running = true
        let now = Date()
        build.stages = [
            Stage(
                id: 1,
                name: "extract v131072",
                state: .running,
                detail: "unpacking /Volumes/ExternalGameDrive/NintendoSwitchLibrary/SuperMarioPartyJamboree/Contents/Resources/dm/romfs_archive_chunk_00042.bin",
                percent: 45,
                started: now.addingTimeInterval(-95),
                eta: 115,
                etaAt: now
            )
        ]

        let captured = StageSamples()
        let view = VStack(alignment: .leading, spacing: 0) {
            ProgressCard(build: build)
        }
        .padding(.horizontal, 40)
        .frame(width: 900, alignment: .leading)
        .environmentObject(stores.localizer)
        .environment(\.measuresProgressStages, true)
        .onPreferenceChange(ProgressStageSamples.self) { captured.all = $0 }
        .font(.manrope(13))

        let host = NSHostingView(rootView: view)
        let window = OffscreenWindow(size: NSSize(width: 900, height: 240))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        host.layoutSubtreeIfNeeded()

        let detailSample = try XCTUnwrap(captured.all.last(where: { $0.stageID == 1 && $0.part == .detail }))
        let clockSample = try XCTUnwrap(captured.all.last(where: { $0.stageID == 1 && $0.part == .clock }))
        XCTAssertLessThan(detailSample.room, detailSample.labelWidth, "overlong detail should compress to fit the card")
        XCTAssertGreaterThanOrEqual(
            clockSample.room + 0.5,
            clockSample.labelWidth,
            "trailing clock + ETA must never be truncated even when detail compresses (room \(clockSample.room) < ideal \(clockSample.labelWidth))"
        )
    }
}
