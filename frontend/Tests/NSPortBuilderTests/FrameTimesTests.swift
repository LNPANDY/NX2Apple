import XCTest
import SwiftUI
@testable import NSPortBuilder

/// Frame-time recordings (DM_NVN_TSV): reading the host's timing rows and summing them up as scripts/bench.py does.
final class FrameTimesTests: XCTestCase {
    /// Rows as the host writes them (dm/gfx/nvn/hle_nvn.c): frame, @metric, value; call-count rows and junk in between.
    private let tsv = """
    1\t@t_s\t0.000
    1\t@frame_ms\t16.6
    1\t@presented_ms\t16.7
    1\t@gpu_ms\t4.0
    1\tnvnQueueSubmitCommands\t3
    2\t@t_s\t0.017
    2\t@frame_ms\t16.8
    2\t@presented_ms\t-1
    2\t@gpu_ms\t4.2
    3\t@t_s\t0.100
    3\t@frame_ms\t83.0
    3\t@presented_ms\t83.3
    3\t@gpu_ms\t30.0
    not a row
    4\t@t_s\t0.117
    4\t@frame_ms\t16.7
    4\t@presented_ms\t16.6
    5\t@t_s
    """

    func testReadsTheTimingRowsInFrameOrder() {
        let frames = FrameTimes.parse(tsv)
        XCTAssertEqual(frames.map(\.number), [1, 2, 3, 4])
        XCTAssertEqual(frames[2], FrameTimes.Frame(number: 3, time: 0.100, frameMs: 83.0, presentedMs: 83.3, gpuMs: 30.0))
        XCTAssertNil(frames[3].gpuMs, "a frame without a GPU row")
        XCTAssertTrue(FrameTimes.parse("").isEmpty)
    }

    func testTheSummaryCountsLikeBenchPy() throws {
        let s = try XCTUnwrap(FrameTimes.Summary(FrameTimes.parse(tsv)))
        XCTAssertEqual(s.frames, 4)
        XCTAssertEqual(s.dropped, 1, "@presented_ms -1 is a frame never shown")
        XCTAssertEqual(s.frameP50, 16.7, accuracy: 0.001)   // nearest rank: sorted 16.6 16.7 16.8 83.0
        XCTAssertEqual(s.frameP95, 83.0, accuracy: 0.001)
        XCTAssertEqual(s.frameMax, 83.0, accuracy: 0.001)
        XCTAssertEqual(s.hitches, 1, "frames over 50 ms")
        XCTAssertEqual(s.seconds, 0.117, accuracy: 0.001)
        XCTAssertNil(FrameTimes.Summary([]))
    }

    func testNearestRankPercentile() {
        XCTAssertEqual(FrameTimes.percentile([5, 1, 3, 2, 4], 50), 3)
        XCTAssertEqual(FrameTimes.percentile([5, 1, 3, 2, 4], 99), 5)
        XCTAssertEqual(FrameTimes.percentile([7], 1), 7)
        XCTAssertNil(FrameTimes.percentile([], 50))
    }

    func testTheEnvironmentAsksForTimingRowsOnly() {
        let file = URL(fileURLWithPath: "/tmp/lib/frame-times/0100A/2026-10-28 03-30-00.tsv")
        XCTAssertEqual(FrameTimes.environment(recordTo: file), ["DM_NVN_TSV": file.path, "DM_NVN_TSV_CALLS": "0"])
        XCTAssertEqual(FrameTimes.environment(recordTo: nil), [:])
    }

    func testRecordingsLiveBesideTheModsAndAreListedNewestFirst() throws {
        let lib = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString)")
        let folder = FrameTimes.folder(titleID: "010015100B514000", library: lib.path)
        XCTAssertEqual(folder.path, lib.appendingPathComponent("frame-times/010015100B514000").path)
        let a = try FrameTimes.newRecording(in: folder, at: Date(timeIntervalSince1970: 1_800_000_000))
        let b = try FrameTimes.newRecording(in: folder, at: Date(timeIntervalSince1970: 1_800_000_100))
        XCTAssertEqual(a.pathExtension, "tsv")
        for f in [a, b] { try Data("1\t@t_s\t0\n".utf8).write(to: f) }
        XCTAssertEqual(FrameTimes.recordings(in: folder).map(\.lastPathComponent), [b.lastPathComponent, a.lastPathComponent])
        XCTAssertTrue(FrameTimes.recordings(in: lib.appendingPathComponent("none")).isEmpty)
    }

    func testRecordingIsOffUntilSwitchedOnPerGame() {
        let key = FrameTimes.defaultsKey(titleID: "0100TEST")
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(FrameTimes.enabled(titleID: "0100TEST"))
        FrameTimes.setEnabled(true, titleID: "0100TEST")
        XCTAssertTrue(FrameTimes.enabled(titleID: "0100TEST"))
        XCTAssertFalse(FrameTimes.enabled(titleID: "0100OTHER"))
    }

    func testTheStringsAreInEveryLanguage() {
        for key in ["launch.frameTimes", "launch.frameTimesRecord", "launch.frameTimesNote", "launch.frameTimesNone",
                    "launch.frameTimesEmpty", "launch.frameTimesOpen", "launch.frameTimesSummary"] {
            XCTAssertNotEqual(L10n.string(key, .en), key, key)
            XCTAssertNotEqual(L10n.string(key, .zh), key, key)
            XCTAssertNotEqual(L10n.string(key, .sv), L10n.string(key, .en), "\(key): a Swedish entry, not the English fallback")
        }
        XCTAssertEqual(String(format: L10n.string("launch.frameTimesSummary", .sv), 10, 60.0, 16.7, 20.0, 50.0, 1, 0).contains("10 bildrutor"), true)
    }

    /// The desktop Play and console mode add the same recording: nothing while off, a new file in the game's folder while on.
    func testBothWaysOfStartingAGameRecordTheSame() throws {
        let lib = FileManager.default.temporaryDirectory.appendingPathComponent("frametimes-start-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: lib) }
        let game = LibraryGame(titleID: "0100TESTSTART", name: "Demo")
        let key = FrameTimes.defaultsKey(titleID: game.titleID)
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        FrameTimes.setEnabled(false, titleID: game.titleID)
        XCTAssertEqual(FrameTimes.recordingEnvironment(for: game, library: lib.path), [:])
        FrameTimes.setEnabled(true, titleID: game.titleID)
        let env = FrameTimes.recordingEnvironment(for: game, library: lib.path)
        let file = try XCTUnwrap(env["DM_NVN_TSV"])
        XCTAssertEqual(env["DM_NVN_TSV_CALLS"], "0")
        XCTAssertTrue(file.hasPrefix(FrameTimes.folder(titleID: game.titleID, library: lib.path).path), file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: FrameTimes.folder(titleID: game.titleID, library: lib.path).path), "the folder is made")
    }

    /// The launch options with the Frame times section and two recordings, for visual QA (NX_LAUNCHER_CAPTURE_DIR).
    func testCaptureLaunchOptionsWithFrameTimes() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-frametimes-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let titleID = "010015100B514000"
        let app = temporary.appendingPathComponent("Game.app")
        let dm = app.appendingPathComponent("Contents/Resources/dm")
        try FileManager.default.createDirectory(at: dm, withIntermediateDirectories: true)
        let fps = #"{"env": "DM_FPS_TARGET", "kind": "choice", "label": "Frame rate", "note": "", "default": "60", "section": "Game", "options": [["30", "30"], ["60", "60"]]}"#
        try #"{"game": "\#(titleID)", "settings": [\#(fps)]}"#.write(to: dm.appendingPathComponent("launcher.json"), atomically: true, encoding: .utf8)
        let libraryFolder = temporary.appendingPathComponent("Library")
        let folder = FrameTimes.folder(titleID: titleID, library: libraryFolder.path)
        for (i, start) in [1_800_000_000.0, 1_800_000_600.0].enumerated() {
            var rows = ""
            var t = 0.0
            for n in 1...3600 {   // a minute at 60 fps, a hitch every ten seconds, the second run slower
                let ms = n % 600 == 0 ? 95.0 : (i == 0 ? 16.7 : 21.0) + Double(n % 7) * 0.3
                rows += "\(n)\t@t_s\t\(t)\n\(n)\t@frame_ms\t\(ms)\n\(n)\t@presented_ms\t\(ms)\n"
                t += ms / 1000
            }
            try rows.write(to: try FrameTimes.newRecording(in: folder, at: Date(timeIntervalSince1970: start)), atomically: true, encoding: .utf8)
        }
        var game = LibraryGame(titleID: titleID, name: "Super Mario Bros. Wonder")
        game.appPath = app.path
        struct Snapshot: Codable { let games: [LibraryGame]; let folder: String }
        let file = temporary.appendingPathComponent("library.json")
        try JSONEncoder().encode(Snapshot(games: [game], folder: libraryFolder.path)).write(to: file)
        let library = GameLibrary(file: file)
        XCTAssertEqual(library.games.count, 1)
        let key = FrameTimes.defaultsKey(titleID: titleID)
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        FrameTimes.setEnabled(true, titleID: titleID)
        let model = BuildModel()
        model.lang = .en
        let host = NSHostingView(rootView: LaunchOptionsView(m: model, library: library, gameID: library.games[0].id).environmentObject(PadFocus()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 1300), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("launch-options-frame-times.png"))
        window.orderOut(nil)
        // The section's rows below the fold: the two recordings as the sheet draws them
        let rows = NSHostingView(rootView: VStack(spacing: 0) {
            ForEach(FrameTimes.recordings(in: folder), id: \.self) { FrameTimesRecordingView(file: $0, t: model.t) }
        }.frame(width: 760).background(Color(white: 0.09)))
        let rowsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        rowsWindow.contentView = rows
        rowsWindow.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        rowsWindow.setContentSize(rows.fittingSize)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        rows.layoutSubtreeIfNeeded()
        let rowsRep = try XCTUnwrap(rows.bitmapImageRepForCachingDisplay(in: rows.bounds))
        rows.cacheDisplay(in: rows.bounds, to: rowsRep)
        try XCTUnwrap(rowsRep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("launch-options-frame-times-rows.png"))
        rowsWindow.orderOut(nil)
    }
}
