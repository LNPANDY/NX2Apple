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

    func testStrippingNotCachedRemovesRedundantMissesAcrossFormatsWhileKeepingCacheHitsAndErrors() throws {
        // Exact variants: thousands commas, plain integers, non-breaking spaces/dots, parentheses, mixed cached + not cached.
        XCTAssertEqual(BuildProgress.strippingNotCached("11,201 not cached"), "")
        XCTAssertEqual(BuildProgress.strippingNotCached("4 not cached"), "")
        XCTAssertEqual(BuildProgress.strippingNotCached("1,234,567 not cached"), "")
        XCTAssertEqual(BuildProgress.strippingNotCached("11\u{202F}201 not cached"), "")
        XCTAssertEqual(BuildProgress.strippingNotCached("11\u{00A0}201 not cached"), "")
        XCTAssertEqual(BuildProgress.strippingNotCached("11.201 not cached"), "")
        XCTAssertEqual(BuildProgress.strippingNotCached("(11,201 not cached)"), "")
        XCTAssertEqual(BuildProgress.strippingNotCached("compiling · 679 / 11,201 shaders · 11,201 not cached"),
                       "compiling · 679 / 11,201 shaders")
        XCTAssertEqual(BuildProgress.strippingNotCached("679/11,201 shaders, 11,201 not cached, 0:50 · ETA 12:54"),
                       "679/11,201 shaders, 0:50 · ETA 12:54")
        XCTAssertEqual(BuildProgress.strippingNotCached("679/11,201 shaders, 4 not cached, 0:12"),
                       "679/11,201 shaders, 0:12")
        XCTAssertEqual(BuildProgress.strippingNotCached("6,000 cached, 5,201 not cached"), "6,000 cached")
        XCTAssertEqual(BuildProgress.strippingNotCached("5,201 not cached, 6,000 cached"), "6,000 cached")
        XCTAssertEqual(BuildProgress.strippingNotCached("(5,201 not cached, 6,000 cached)"), "(6,000 cached)")
        XCTAssertEqual(BuildProgress.strippingNotCached("(6,000 cached, 5,201 not cached)"), "(6,000 cached)")

        // Must preserve cache hit notes, stage_end summaries, and error messages without a leading count.
        XCTAssertEqual(BuildProgress.strippingNotCached("2,410 cached"), "2,410 cached")
        XCTAssertEqual(BuildProgress.strippingNotCached("11,201 of 11,201 shaders ready (0 from the cache)"),
                       "11,201 of 11,201 shaders ready (0 from the cache)")
        XCTAssertEqual(BuildProgress.strippingNotCached("a failed key was not cached as zero"),
                       "a failed key was not cached as zero")

        // Generated from engine/dm/gfx/tools/dmsh_build.py + engine/scripts/build_ipa_from_nsp.py (ShaderWatch + Progress):
        //   payload = {"step": "compiling", "done": 679, "total": 11201, "cached": 0, "misses": 11201}
        let expectedDetail = "compiling · "
            + NumberFormatter.localizedString(from: 679, number: .decimal) + " / "
            + NumberFormatter.localizedString(from: 11201, number: .decimal) + " shaders"
        XCTAssertEqual(
            BuildProgress.progressDetail([
                "step": "compiling",
                "done": 679,
                "total": 11201,
                "unit": "shaders",
                "est": false,
                "note": "11,201 not cached",
                "frac": 679.0 / 11201.0,
                "eta": 774.0,
            ]),
            expectedDetail
        )
        let cacheCheckDetail = "cache check · "
            + NumberFormatter.localizedString(from: 2410, number: .decimal) + " / "
            + NumberFormatter.localizedString(from: 11201, number: .decimal) + " shaders · 2,410 cached"
        XCTAssertEqual(
            BuildProgress.progressDetail([
                "step": "cache check",
                "done": 2410,
                "total": 11201,
                "unit": "shaders",
                "note": "2,410 cached",
            ]),
            cacheCheckDetail
        )

        let parsedLine = try XCTUnwrap(
            BuildProgress.parseStageWithTotal("[12:00:50] [6/8] Mac shaders · compiling: 6%, 679/11,201 shaders, 11,201 not cached, 0:50 · ETA 12:54")
        )
        XCTAssertEqual(parsedLine.k, 6)
        XCTAssertEqual(parsedLine.n, 8)
        XCTAssertEqual(parsedLine.name, "Mac shaders")
        XCTAssertEqual(parsedLine.state, .running)
        XCTAssertEqual(parsedLine.percent, 6)
        XCTAssertEqual(parsedLine.detail, "679/11,201 shaders, 0:50 · ETA 12:54")

        // When the synced engine tree is present, execute the real `Progress` + `ShaderWatch` classes in
        // `engine/scripts/build_ipa_from_nsp.py` to verify the fixture above matches the live emitter byte-for-byte.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptPath = repoRoot.appendingPathComponent("engine/scripts/build_ipa_from_nsp.py").path
        if FileManager.default.fileExists(atPath: scriptPath) {
            let py = """
            import ast, collections, io, json, os, pathlib, shutil, sys, tempfile, threading, time, types
            src = open(sys.argv[1], encoding="utf-8").read()
            mod = ast.parse(src, filename=sys.argv[1])
            wanted = {"BEAT", "clock", "hms", "size_unit", "amount", "Progress", "ShaderWatch"}
            nodes = [
                n for n in mod.body
                if (isinstance(n, (ast.FunctionDef, ast.ClassDef)) and n.name in wanted)
                or (isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id in wanted for t in n.targets))
            ]
            ns = {
                "collections": collections,
                "json": json,
                "shutil": shutil,
                "sys": sys,
                "threading": threading,
                "time": time,
                "types": types,
                "in_ipython": lambda: False,
            }
            exec(compile(ast.Module(body=nodes, type_ignores=[]), sys.argv[1], "exec"), ns)
            ProgressCls = ns["Progress"]
            ShaderWatchCls = ns["ShaderWatch"]
            clock_fn = ns["clock"]
            payload = {"step": "compiling", "done": 679, "total": 11201, "cached": 0, "misses": 11201}
            with tempfile.NamedTemporaryFile("w", delete=False, encoding="utf-8") as tf:
                json.dump(payload, tf)
                p = tf.name
            try:
                polled = ShaderWatchCls(pathlib.Path(p))()
                buf = io.StringIO()
                orig_stdout = sys.stdout
                sys.stdout = buf
                prog_j = ProgressCls("json")
                try:
                    prog_j.plan(8)
                    prog_j.k = 5
                    prog_j.stage("Mac shaders", step="compiling")
                    if prog_j.tstop:
                        prog_j.tstop.set()
                    with prog_j.lock:
                        prog_j.cur.t0 -= 50.0
                        now = time.time()
                        prog_j.cur.hist.append((now - 50.0, 0))
                        prog_j.cur.jlast = 0.0
                    prog_j.set(**polled)
                finally:
                    prog_j.close()
                    sys.stdout = orig_stdout
                json_lines = [ln for ln in buf.getvalue().splitlines() if ln.strip()]

                text_lines = []
                prog_l = ProgressCls("lines")
                prog_l._out = text_lines.append
                try:
                    prog_l.plan(8)
                    prog_l.k = 5
                    prog_l.stage("Mac shaders", step="compiling")
                    if prog_l.tstop:
                        prog_l.tstop.set()
                    prog_l.set(**polled)
                    with prog_l.lock:
                        st = prog_l.cur
                        st.t0 -= 50.0
                        st.hist.clear()
                        now = time.time()
                        st.hist.append((now - 50.0, 0))
                        st.hist.append((now, 679))
                        head, frac, count, note, times = prog_l._fields(st)
                        prog_l._out(
                            f"[{clock_fn()}] {head}: "
                            + ", ".join(x for x in (f"{frac * 100:.0f}%" if frac is not None else "", count, note, times) if x)
                        )
                finally:
                    prog_l.close()
            finally:
                os.unlink(p)
            print(json.dumps({"json": json_lines, "lines": text_lines}))
            """
            let res = SystemProcessRunner().capture(ProcessLaunch(
                executable: "/usr/bin/python3",
                arguments: ["-c", py, scriptPath],
                mergesErrors: true
            ))
            XCTAssertEqual(res.status, 0, "python emitter check failed: \(res.out)")
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(res.out.utf8)) as? [String: [String]])
            let jsonLines = try XCTUnwrap(root["json"])
            let progressEvents = jsonLines.compactMap { line in
                (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            }.filter { $0["ev"] as? String == "progress" }
            let event = try XCTUnwrap(progressEvents.last)
            XCTAssertEqual(event["ev"] as? String, "progress")
            XCTAssertEqual(event["note"] as? String, "11,201 not cached")
            XCTAssertEqual(BuildProgress.progressDetail(event), expectedDetail)
            XCTAssertNotNil((event["eta"] as? NSNumber)?.doubleValue)

            let textLines = try XCTUnwrap(root["lines"])
            let progressLine = try XCTUnwrap(textLines.first(where: { $0.contains("6%") }))
            let liveParsed = try XCTUnwrap(BuildProgress.parseStageWithTotal(progressLine))
            XCTAssertEqual(liveParsed.percent, 6)
            XCTAssertFalse(liveParsed.detail.contains("not cached"), "live line detail still contained not cached: \(liveParsed.detail)")
            XCTAssertTrue(liveParsed.detail.contains("679/11,201 shaders"))
            XCTAssertTrue(liveParsed.detail.contains("ETA "))
        }
    }

    /// The stage's clock runs on while the count stands still, and a defensible estimate counts down from when it came, then goes.
    func testStageClockCountsOnAndTheEstimateRunsOut() {
        let t0 = Date()
        // 50 % after 40 s projects 40 s more, the script says 71 s from t0 + 10 s: the same order of size, so it is shown.
        let stage = Stage(id: 1, name: "shader split", percent: 50, started: t0, eta: 71, etaAt: t0.addingTimeInterval(10))
        XCTAssertEqual(stage.clock(at: t0.addingTimeInterval(40), left: "%@ left"), "0:40 · " + BuildProgress.duration(41) + " left")
        XCTAssertEqual(stage.clock(at: t0.addingTimeInterval(125), left: "%@ left"), "2:05")   // the estimate ran out: no stale "1 min 11 s left"
        XCTAssertEqual(stage.clock(at: t0.addingTimeInterval(3725), left: "%@ left"), "1:02:05")
    }

    /// #934: an estimate of 18 hours for a stage that is 60 % done after ten minutes is not shown, nor one before the stage reports a share.
    func testAnEstimateThatDisagreesWithTheStagesOwnProgressIsNotShown() {
        let t0 = Date()
        let now = t0.addingTimeInterval(600)
        XCTAssertNil(Stage(id: 1, name: "shaders", percent: 60, started: t0, eta: 18 * 3600, etaAt: now).remaining(at: now))
        XCTAssertNil(Stage(id: 1, name: "shaders", started: t0, eta: 120, etaAt: now).remaining(at: now))   // no share of the stage
        XCTAssertNil(Stage(id: 1, name: "shaders", percent: 2, started: t0, eta: 120, etaAt: now).remaining(at: now))   // too early to project
        XCTAssertNil(Stage(id: 1, name: "shaders", percent: 50, started: t0, eta: 600, etaAt: t0.addingTimeInterval(10)).remaining(at: t0.addingTimeInterval(20)))   // 20 s in
        XCTAssertEqual(Stage(id: 1, name: "shaders", percent: 60, started: t0, eta: 400, etaAt: now).remaining(at: now), 400)
        XCTAssertEqual(Stage(id: 1, name: "shaders", percent: 60, started: t0, eta: 18 * 3600, etaAt: now).clock(at: now, left: "%@ left"), "10:00")
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

    /// Issue #1131: Xcode 27.2 SDK emits `static Foundation.Date.>=(_:_:)` (`_$s10Foundation4DateV2geoiySbAC_ACtFZ`) as a
    /// weak-imported symbol under `-O`, and early macOS 27.2 betas pass the version check while binding the symbol to NULL (`pc = 0`).
    /// Compiling the affected sources under `-O` must never emit any weak-imported `Foundation.Date` symbol, while preserving `>=`
    /// boundary timestamps at `rootMtime - 2`.
    func testOptimizedDateComparisonsEmitNoWeakImportedFoundationDateSymbols() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("pso-date-weak-" + UUID().uuidString)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // Verify exact `cutoff = rootMtime - 2` inclusive boundary in psoArchiveProgress.
        let rootDate = Date(timeIntervalSince1970: 1_700_000_100)
        let exactCutoff = rootDate.addingTimeInterval(-2)
        let staleDate = rootDate.addingTimeInterval(-3)
        let iosWork = tmp.appendingPathComponent("ipa/build/ios/pso/work")
        let arch = "applegpu_g14g"
        let b1 = iosWork.appendingPathComponent("batches.\(arch)/00001")
        let b2 = iosWork.appendingPathComponent("batches.\(arch)/00002")
        try fm.createDirectory(at: b1, withIntermediateDirectories: true)
        try fm.createDirectory(at: b2, withIntermediateDirectories: true)
        let entry = #"{"vertex_function_descriptor":"v"}"#
        let jsText = "{\"pipelines\":[" + Array(repeating: entry, count: 1500).joined(separator: ",") + "]}\n"
        let rootJS = iosWork.appendingPathComponent("bases.mtl4-json")
        try Data(jsText.utf8).write(to: rootJS)
        try fm.setAttributes([.modificationDate: rootDate], ofItemAtPath: rootJS.path)
        for (dir, date) in [(b1, exactCutoff), (b2, staleDate)] {
            let bjs = dir.appendingPathComponent("bases.mtl4-json")
            try Data("{}".utf8).write(to: bjs)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: bjs.path)
            try Data("archive".utf8).write(to: dir.appendingPathComponent("\(arch).mtl4a"))
            try Data("k\n".utf8).write(to: dir.appendingPathComponent("key.\(arch)"))
        }
        XCTAssertEqual(BuildProgress.psoArchiveProgress(workDir: tmp.path),
                       PSOArchiveProgress(done: 1, total: 2, merging: false))

        let frontend = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let stub = tmp.appendingPathComponent("ConsoleGlyphsStub.swift")
        try Data("enum ConsoleGlyphs { struct Glyph: Equatable {} }\n".utf8).write(to: stub)

        let units: [(name: String, sources: [String])] = [
            ("BuildProgressCheck", [frontend.appendingPathComponent("Sources/NXCore/BuildProgress.swift").path]),
            ("PlaySessionsCheck", [frontend.appendingPathComponent("Sources/NXCore/PlaySessions.swift").path]),
            ("ConsoleNoticesCheck", [
                frontend.appendingPathComponent("Sources/NX2Apple/ConsoleNotices.swift").path,
                stub.path,
            ]),
        ]

        let runner = SystemProcessRunner()
        for unit in units {
            let obj = tmp.appendingPathComponent(unit.name + ".o").path
            let compile = runner.capture(ProcessLaunch(
                executable: "/usr/bin/xcrun",
                arguments: ["swiftc", "-O", "-wmo", "-parse-as-library", "-module-name", unit.name, "-package-name", "frontend", "-c"]
                    + unit.sources + ["-o", obj],
                mergesErrors: true
            ))
            XCTAssertEqual(compile.status, 0, "swiftc failed for \(unit.name): \(compile.out)")
            let symbols = runner.capture(ProcessLaunch(executable: "/usr/bin/xcrun", arguments: ["nm", "-m", obj], mergesErrors: true))
            XCTAssertEqual(symbols.status, 0, "nm failed for \(unit.name): \(symbols.out)")
            let weakDateSymbols: [String] = symbols.out
                .split(separator: "\n")
                .map(String.init)
                .filter { $0.contains("(undefined) weak") && $0.contains("Foundation4DateV") }
            XCTAssertEqual(weakDateSymbols, [String](), "\(unit.name) emitted weak-imported Foundation.Date symbol(s)")
        }
    }
}
