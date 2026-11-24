import AppKit
import Combine
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher
@testable import NXModel

/// Regression tests covering PR2 fixes:
/// 1) Per-entry `.img` update & transfer attribution (no cross-game `Balatro.img` leakage onto pure fast refresh).
/// 2) Shader rebuild (including same-chain rebuild and fallback `archivePath` / `msl/` Tier 2 staging) always updates `.img` or `msl/`.
/// 3) Connected-device transfer attempt before manual replacement fallback (even when `.skip` mode is set for unchanged data).
/// 4) Refresh completion in-app sheet & notification formatting with per-game status in EN/ZH.
@MainActor final class BatchRefreshImgAndNotifyTests: IsolatedDefaultsTestCase {
    private var temporary: URL!
    private let fm = FileManager.default
    private let balatroTID = "0100CD401DA32000"
    private let stardewTID = "0100E65002BB8000"
    private let deviceID = "00008150-TESTDEV"
    private let teamID = "TEAM998877"
    private let chainHex = "108c5f92c3c4"

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private var stateDir: String { path("state") }
    private var deviceContainer: String { path("device") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporary = fm.temporaryDirectory.appendingPathComponent("nx-batch-img-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporary { try? fm.removeItem(at: temporary) }
        try super.tearDownWithError()
    }

    private func path(_ parts: String...) -> String {
        parts.reduce(temporary.path) { $0 + "/" + $1 }
    }

    @discardableResult
    private func write(_ file: String, _ text: String, executable: Bool = false) throws -> String {
        try fm.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: file, atomically: true, encoding: .utf8)
        if executable { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file) }
        return file
    }

    private func waitUntil(timeout: TimeInterval = 20, _ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }

    private func runPython(_ args: [String]) throws -> String {
        let result = SystemProcessRunner().capture(ProcessLaunch(executable: "/usr/bin/python3", arguments: args))
        guard result.ok else {
            throw NSError(domain: "BatchRefreshImgTests", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: result.out])
        }
        return result.out
    }

    /// Creates a real `DMROMFS1` `.img` using `engine/dm/tools/romfs_image.py`, optionally appending a `DMMSLTR1` shader trailer.
    private func makeRealRomfsImage(
        at imgPath: String,
        romfsContent: String,
        shaderTag: String?,
        chain: String,
        romfsImageTool: String
    ) throws {
        let srcDir = path("romfs-src-" + UUID().uuidString)
        try write(srcDir + "/data.txt", romfsContent)
        try fm.createDirectory(atPath: (imgPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        _ = try runPython(["-I", romfsImageTool, srcDir, imgPath])
        if let shaderTag {
            let mslDir = path("msl-src-" + UUID().uuidString)
            try write(mslDir + "/\(chain)_b.metallib", shaderTag)
            try write(mslDir + "/inputs.tsv", "key\tval\n1\t\(shaderTag)\n")
            _ = try runPython(["-I", romfsImageTool, "--append-msl", imgPath, mslDir, "--gfx-api", "nvn", "--chain", "b-" + chain])
        }
    }

    private func makeStandIns() throws -> (repo: String, xcrun: String, seedRoot: String, shellRoot: String, outDir: String, romfsImageTool: String) {
        guard fm.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("System Python is required for real DMROMFS1 fixtures")
        }
        let realRomfsTool = repoRoot.appendingPathComponent("engine/dm/tools/romfs_image.py").path
        guard fm.fileExists(atPath: realRomfsTool) else {
            throw XCTSkip("Synced engine/dm/tools/romfs_image.py is required")
        }

        try fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        let repo = path("repo")
        let repoRomfsTool = repo + "/dm/tools/romfs_image.py"
        try fm.createDirectory(atPath: (repoRomfsTool as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try fm.copyItem(atPath: realRomfsTool, toPath: repoRomfsTool)
        try write(repo + "/dm/tools/nx_extract/Program.cs", "// marker\n")
        try write(repo + "/dm/gfx/nvn/dmsh_chain.h", "#define DMSH_CHAIN \"\(chainHex)\"\n")
        try write(repo + "/frontend-ios/Package.swift", "// swift-tools-version: 5.9\n")
        try fm.createDirectory(atPath: repo + "/frontend-ios/Shell/App", withIntermediateDirectories: true)

        let devicesJSON: [String: Any] = [
            "info": ["outcome": "success"],
            "result": ["devices": [[
                "hardwareProperties": ["udid": deviceID, "reality": "physical", "platform": "iOS", "marketingName": "iPhone 17 Pro"],
                "deviceProperties": ["name": "Player iPhone", "osVersionNumber": "27.0"],
                "connectionProperties": ["pairingState": "paired", "tunnelState": "connected", "transportType": "wired"],
            ]]],
        ]
        try JSONSerialization.data(withJSONObject: devicesJSON).write(to: URL(fileURLWithPath: stateDir + "/devices.json"))

        let xcrun = try write(path("bin/xcrun"), """
        #!/usr/bin/python3
        import json, os, plistlib, shutil, sys
        a = sys.argv[1:]
        STATE = '\(stateDir)'
        CONT = '\(deviceContainer)'
        open(STATE + '/xcrun-calls.txt', 'a').write(' '.join(a) + '\\n')
        def val(flag): return a[a.index(flag) + 1] if flag in a else None
        if a[0] == 'xcodebuild':
            bundle = [x.split('=', 1)[1] for x in a if x.startswith('PRODUCT_BUNDLE_IDENTIFIER=')][0]
            app = val('-derivedDataPath') + '/Build/Products/Release-iphoneos/DmShell.app'
            os.makedirs(app + '/Frameworks', exist_ok=True)
            fwlist = os.path.dirname(val('-project')) + '/frameworks.txt'
            if os.path.exists(fwlist):
                for line in open(fwlist).read().splitlines():
                    if not line.strip(): continue
                    fw = line.split('\\t')[1] if '\\t' in line else line.strip()
                    os.makedirs(app + '/Frameworks/' + os.path.basename(fw), exist_ok=True)
            with open(app + '/Info.plist', 'wb') as f:
                plistlib.dump({'CFBundleIdentifier': bundle, 'CFBundleDisplayName': 'NX2Apple', 'CFBundleExecutable': 'DmShell'}, f)
            open(app + '/embedded.mobileprovision', 'w').write('signed-profile')
            open(app + '/bundle.txt', 'w').write(bundle)
            print('CodeSign ' + app, flush=True)
        elif a[:3] == ['devicectl', 'list', 'devices']:
            shutil.copyfile(STATE + '/devices.json', val('--json-output'))
        elif a[:3] == ['devicectl', 'device', 'install']:
            app = a[-1]
            bundle = open(app + '/bundle.txt').read().strip()
            os.makedirs(CONT + '/' + bundle + '/Documents', exist_ok=True)
            print('100%', flush=True)
        elif a[:4] == ['devicectl', 'device', 'info', 'files']:
            base = CONT + '/' + val('--domain-identifier') + '/' + val('--subdirectory')
            out = val('--json-output')
            if not os.path.isdir(base):
                json.dump({'error': {'code': 6}, 'info': {'outcome': 'failed'}}, open(out, 'w'))
                sys.exit(1)
            files = []
            for root, dirs, names in os.walk(base):
                for n in dirs + names:
                    full = root + '/' + n
                    rel = os.path.relpath(full, base)
                    files.append({'name': rel, 'relativePath': rel, 'metadata': {'size': os.path.getsize(full)},
                                  'resources': {'isDirectory': os.path.isdir(full)}})
            json.dump({'info': {'outcome': 'success'}, 'result': {'files': files}}, open(out, 'w'))
        elif a[:4] == ['devicectl', 'device', 'copy', 'from']:
            sys.exit(1)
        elif a[:4] == ['devicectl', 'device', 'copy', 'to']:
            dest = CONT + '/' + val('--domain-identifier') + '/' + val('--destination')
            src = val('--source')
            if os.path.exists(STATE + '/fail-copy'):
                print('ERROR: Transfer failed in test.', flush=True)
                sys.exit(1)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            shutil.copyfile(src, dest)
            print('100%', flush=True)
        """, executable: true)

        let balatroStaticMSL = path("static-balatro-msl")
        try write(balatroStaticMSL + "/\(chainHex)_b.metallib", "balatro-unchanged-metallib")
        try write(balatroStaticMSL + "/inputs.tsv", "key\tval\n1\tbalatro-unchanged\n")
        let oldEpoch = Date().addingTimeInterval(-3600)
        try fm.setAttributes([.modificationDate: oldEpoch], ofItemAtPath: balatroStaticMSL + "/\(chainHex)_b.metallib")
        try fm.setAttributes([.modificationDate: oldEpoch], ofItemAtPath: balatroStaticMSL + "/inputs.tsv")

        let outDir = path("output")
        try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        // Pre-populate Balatro (reuses unchanged shaders) and Stardew Valley (stale trailer / rebuilds shaders)
        let balatroArchive = outDir + "/games/Balatro"
        let balatroImg = balatroArchive + "/Balatro.img"
        try makeRealRomfsImage(
            at: balatroImg,
            romfsContent: "balatro-romfs-payload",
            shaderTag: "balatro-unchanged-metallib",
            chain: chainHex,
            romfsImageTool: repoRomfsTool
        )
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: balatroImg)

        let stardewArchive = outDir + "/games/Stardew Valley"
        let stardewImg = stardewArchive + "/Stardew Valley.img"
        try makeRealRomfsImage(
            at: stardewImg,
            romfsContent: "stardew-romfs-payload",
            shaderTag: "stardew-old-metallib",
            chain: "000000000000",
            romfsImageTool: repoRomfsTool
        )
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: stardewImg)

        try write(repo + "/scripts/build_ipa_from_nsp.py", """
        #!/usr/bin/python3
        # argparse marker: '--work-dir' '--from-seed'
        import json, os, sys
        a = sys.argv[1:]
        def val(flag): return a[a.index(flag) + 1] if flag in a else None
        tid = (val('--title-id') or '').upper()
        work_dir = val('--work-dir')
        fw_parent = val('--shell-framework')
        if os.path.exists('\(stateDir)/emit-6of7'):
            for k, name in enumerate(['extract', 'check files', 'rewrite', 'shader split', 'iOS shaders', 'game framework'], 1):
                print(json.dumps({'ev': 'stage', 'k': k, 'n': 7, 'name': name, 'step': ''}), flush=True)
                print(json.dumps({'ev': 'stage_end', 'k': k, 'ok': True, 'summary': 'ok', 'elapsed': 0.1}), flush=True)
        os.makedirs(fw_parent, exist_ok=True)
        fw = fw_parent + '/DmGame' + tid + '.framework'
        os.makedirs(fw, exist_ok=True)
        name = 'Balatro' if tid == '\(balatroTID)' else 'Stardew Valley'
        with open(fw + '/game.manifest.json', 'w') as f:
            json.dump({'title_id': tid, 'name': name, 'gfx_api': 'nvn', 'chain': 'b-\(chainHex)'}, f)
        open(fw + '/DmGame' + tid, 'w').write('bin-' + tid)
        msl_cache = fw_parent + '/.msl-cache'
        os.makedirs(msl_cache, exist_ok=True)
        if tid == '\(balatroTID)':
            msl_src = '\(balatroStaticMSL)'
        else:
            msl_src = work_dir + '/shader/ios/b-\(chainHex)'
            os.makedirs(msl_src, exist_ok=True)
            open(msl_src + '/\(chainHex)_b.metallib', 'w').write('stardew-rebuilt-metallib-new')
            open(msl_src + '/inputs.tsv', 'w').write('key\\tval\\n1\\tstardew-rebuilt-new\\n')
        with open(msl_cache + '/' + tid + '.json', 'w') as f:
            json.dump({'lib_path': msl_src, 'gfx_api': 'nvn', 'chain': 'b-\(chainHex)', 'multi_program': False}, f)
        """, executable: true)

        try write(repo + "/frontend-ios/Shell/build_shell.sh", """
        #!/bin/bash
        mkdir -p "$SHELL_DIR/DmShell.xcodeproj" "$SHELL_DIR/Gen"
        : > "$SHELL_DIR/frameworks.txt"
        while IFS= read -r fw; do
          [ -n "$fw" ] || continue
          tid=$(basename "$fw" .framework); tid=${tid#DmGame}
          printf '%s\\t%s\\t%s\\n' "$tid" "$fw" "$tid" >> "$SHELL_DIR/frameworks.txt"
        done <<< "$DM_SHELL_FRAMEWORKS"
        """, executable: true)

        let seedRoot = path("seeds")
        for (tid, name, chain) in [(balatroTID, "Balatro", chainHex), (stardewTID, "Stardew Valley", "000000000000")] {
            let sdir = BuildSeedCache.seedDirectory(for: tid, seedRoot: seedRoot)
            try fm.createDirectory(atPath: sdir + "/ExeFS", withIntermediateDirectories: true)
            try fm.createDirectory(atPath: sdir + "/shader/pkg", withIntermediateDirectories: true)
            try fm.createDirectory(atPath: sdir + "/shader/tables", withIntermediateDirectories: true)
            try fm.createDirectory(atPath: sdir + "/shader/ios", withIntermediateDirectories: true)
            try write(sdir + "/ExeFS/main", "bin-" + tid)
            try write(sdir + "/shader/tables/c1_full.tsv", "c1")
            try write(sdir + "/shader/tables/cb_extent.tsv", "cb")
            try JSONEncoder().encode(BuildSeedRecord(titleID: tid, baseTitleID: tid, appName: name, gfxAPI: "nvn", chain: chain, profileID: tid.lowercased()))
                .write(to: URL(fileURLWithPath: sdir + "/seed.json"))
        }

        let shellRoot = path("shell-root")
        testDefaults.set(shellRoot, forKey: "shellRoot")
        return (repo, xcrun, seedRoot, shellRoot, outDir, repoRomfsTool)
    }

    private func setupMixedBatchStores(
        env: (repo: String, xcrun: String, seedRoot: String, shellRoot: String, outDir: String, romfsImageTool: String)
    ) throws -> (stores: LauncherStores, library: GameLibrary, recorder: BuildRecorder, balatro: LibraryGame, stardew: LibraryGame, batchID: UUID) {
        let stores = LauncherStores(xcrun: env.xcrun, defaults: testDefaults)
        let library = GameLibrary(file: temporary.appendingPathComponent("library-\(UUID().uuidString).json"))
        let recorder = BuildRecorder(stores: stores, library: library)

        stores.repo.path = env.repo
        stores.dependencies.pythonPath = "/usr/bin/python3"
        stores.dependencies.deps = [Dep(id: "xcode", name: "dep.xcode", hint: "dep.xcode.hint", present: true, installCmd: [])]
        stores.dependencies.checked = true
        stores.deviceStore.devices = [AppleDevice(id: deviceID, name: "Player iPhone", model: "iPhone 17 Pro", os: "27.0",
                                                  reachable: true, transport: "wired")]
        stores.deviceStore.teams = [SigningTeam(id: teamID, identity: "Apple Development: Player")]
        stores.deviceStore.checked = true
        stores.deviceStore.installDevice = deviceID
        stores.deviceStore.signingTeam = teamID
        stores.deviceStore.exportIPA = false
        stores.build.outDir = env.outDir
        stores.build.launcherEnvironment = ["DM_SEED_CACHE_DIR": env.seedRoot]

        var balatro = LibraryGame(titleID: balatroTID, name: "Balatro")
        balatro.archivePath = env.outDir + "/games/Balatro"
        balatro.outputDirectory = env.outDir
        library.upsert(balatro)

        var stardew = LibraryGame(titleID: stardewTID, name: "Stardew Valley")
        stardew.archivePath = env.outDir + "/games/Stardew Valley"
        stardew.outputDirectory = env.outDir
        library.upsert(stardew)

        let batch = UUID()
        let e1 = RefreshQueueBuilder.makeEntry(
            game: balatro, target: BuildTarget.ios, fastRefresh: true, rebuildsShaders: false,
            batch: batch, stores: stores, libraryFolder: env.outDir
        )
        let e2 = RefreshQueueBuilder.makeEntry(
            game: stardew, target: BuildTarget.ios, fastRefresh: true, rebuildsShaders: true,
            batch: batch, stores: stores, libraryFolder: env.outDir
        )
        stores.queue.enqueue([e1, e2])
        return (stores, library, recorder, balatro, stardew, batch)
    }

    func testMixedBatchTransfersRebuiltStardewImgWithoutFalseBalatroWarning() throws {
        let env = try makeStandIns()
        let ctx = try setupMixedBatchStores(env: env)
        defer { withExtendedLifetime(ctx.recorder) {} }

        var promptCount = 0
        let copySub = ctx.stores.deviceStore.$shellCopy.compactMap { $0 }.sink { _ in
            promptCount += 1
            DispatchQueue.main.async { ctx.stores.deviceStore.answerCopy(.copy) }
        }
        defer { copySub.cancel() }

        ctx.stores.build.startBuildOrQueue()
        waitUntil { !ctx.stores.build.running && !ctx.stores.queue.hasWaiting && ctx.stores.queue.running == nil && ctx.stores.queue.packaging.isEmpty }
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))

        XCTAssertTrue(ctx.stores.build.done, ctx.stores.build.doneNote)
        XCTAssertEqual(ctx.stores.queue.entries.map(\.status), [.done, .done])

        // Balatro was pure fast refresh -> unchanged, never blamed for Balatro.img
        XCTAssertEqual(ctx.stores.queue.entries[0].imgStatus, .unchanged)
        // Stardew rebuilt shaders -> updated Stardew Valley.img and transferred to device
        XCTAssertEqual(ctx.stores.queue.entries[1].imgStatus, .transferred(imgName: "Stardew Valley.img", deviceName: "Player iPhone"))

        // Global single-game reminder must NOT bleed into batch result
        XCTAssertFalse(ctx.stores.build.needsReplaceOldImgReminder)
        XCTAssertEqual(ctx.stores.build.updatedImgPath, "")

        // Verify Stardew's device romfs.img actually received the updated DMMSLTR1 trailer for b-<chainHex>
        let bundle = ShellLibrary.load(root: env.shellRoot).bundleID
        let deviceStardewImg = "\(deviceContainer)/\(bundle)/Documents/games/\(stardewTID)/romfs.img"
        XCTAssertTrue(fm.fileExists(atPath: deviceStardewImg), "Updated Stardew .img must be copied to device")
        let inspectOut = try runPython(["-I", env.romfsImageTool, "--inspect-msl", deviceStardewImg])
        let status = try XCTUnwrap(BuildSeedCache.parseTrailerStatus(from: inspectOut))
        XCTAssertTrue(status.hasTrailer)
        XCTAssertEqual(status.chain, "b-" + chainHex)

        // Completion modal & system notification payload both emitted once with per-game statuses
        let summary = try XCTUnwrap(ctx.stores.build.refreshCompletionSummary)
        XCTAssertEqual(summary.id, ctx.stores.queue.entries.first?.batch)
        XCTAssertEqual(summary.items.count, 2)
        XCTAssertEqual(summary.items[0].imgStatus, .unchanged)
        XCTAssertEqual(summary.items[1].imgStatus, .transferred(imgName: "Stardew Valley.img", deviceName: "Player iPhone"))
        XCTAssertEqual(ctx.stores.build.pendingRefreshNotice, summary)
        XCTAssertEqual(promptCount, 1)
    }

    func testMixedBatchFallsBackToManualReplaceForStardewOnlyWhenTransferSkippedEvenInSkipMode() throws {
        let env = try makeStandIns()
        let ctx = try setupMixedBatchStores(env: env)
        defer { withExtendedLifetime(ctx.recorder) {} }

        // Even if the user previously selected `.skip`, updating an `.img` still prompts/attempts transfer first.
        ctx.stores.deviceStore.postBuildTransferMode = .skip
        var promptedPlans: [ShellCopyPlan] = []
        let copySub = ctx.stores.deviceStore.$shellCopy.compactMap { $0 }.sink { plan in
            promptedPlans.append(plan)
            DispatchQueue.main.async { ctx.stores.deviceStore.answerCopy(.skip) }
        }
        defer { copySub.cancel() }

        ctx.stores.build.startBuildOrQueue()
        waitUntil { !ctx.stores.build.running && !ctx.stores.queue.hasWaiting && ctx.stores.queue.running == nil && ctx.stores.queue.packaging.isEmpty }
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))

        XCTAssertEqual(promptedPlans.count, 1, "Must attempt transfer for newly updated Stardew .img even under .skip mode")
        XCTAssertEqual(ctx.stores.queue.entries[0].imgStatus, .unchanged, "Pure fast Balatro must never be flagged")
        XCTAssertEqual(
            ctx.stores.queue.entries[1].imgStatus,
            .manualReplace(
                imgPath: env.outDir + "/games/Stardew Valley/Stardew Valley.img",
                reason: String(format: ctx.stores.build.t("dev.copySkipped"), "Player iPhone")
            )
        )
        XCTAssertFalse(ctx.stores.build.needsReplaceOldImgReminder)

        // Check EN & ZH notification formatting
        for lang in [Lang.en, Lang.zh] {
            let formatted = RefreshCompletionFormatter.notificationText(
                for: try XCTUnwrap(ctx.stores.build.refreshCompletionSummary),
                t: { L10n.string($0, lang) }
            )
            XCTAssertTrue(formatted.body.contains("Balatro"))
            XCTAssertTrue(formatted.body.contains("Stardew Valley.img"))
            XCTAssertFalse(formatted.body.contains("Balatro.img"))
            XCTAssertFalse(formatted.title.contains(";"))
            XCTAssertFalse(formatted.body.contains(";"))
        }
    }

    func testSameChainShaderRebuildForcesTrailerReplacementAndFindsFallbackArchiveOrMSL() throws {
        let env = try makeStandIns()
        let extraRoot = path("other-root")
        let fallbackArchive = extraRoot + "/games/Stardew Valley"
        let fallbackImg = fallbackArchive + "/Stardew Valley.img"

        // Create an image that ALREADY has `chainHex`, then generate newer shader payload in workDir
        try makeRealRomfsImage(
            at: fallbackImg,
            romfsContent: "stardew-same-chain",
            shaderTag: "old-same-chain-metallib",
            chain: chainHex,
            romfsImageTool: env.romfsImageTool
        )
        let beforeData = try Data(contentsOf: URL(fileURLWithPath: fallbackImg))

        let workDir = path("work-same-chain")
        let mslDir = workDir + "/shader/ios/b-\(chainHex)"
        try write(mslDir + "/\(chainHex)_b.metallib", "rebuilt-same-chain-metallib-v2")
        try write(mslDir + "/inputs.tsv", "key\tval\n1\trebuilt-v2\n")

        let found = BuildStore.findFallbackLocalArchive(
            tid: stardewTID,
            knownArchivePath: fallbackArchive,
            outDir: path("unrelated-outdir"),
            refreshBuildsRoot: path("unrelated-refresh"),
            prefillCandidates: []
        )
        XCTAssertEqual(found?.archiveDir, fallbackArchive)
        XCTAssertEqual(found?.imgPath, fallbackImg)

        let res = BuildStore.injectIOSShaderTrailer(
            targetImg: fallbackImg,
            workDir: workDir,
            tid: stardewTID,
            isIOSBuild: true,
            repoPath: env.repo,
            pythonPath: "/usr/bin/python3",
            runner: SystemProcessRunner(),
            forceReplace: true
        )
        let outcome = try res.get()
        XCTAssertTrue(outcome.didWriteTrailer, "Rebuilt shaders on same chain must not 0-I/O skip trailer update")
        let afterData = try Data(contentsOf: URL(fileURLWithPath: fallbackImg))
        XCTAssertNotEqual(beforeData, afterData, "Updated .img bytes must differ after shader rebuild")

        // When no local .img exists at all, stageMSLFallbackDirectory exports `msl/` so Tier 2 transfer still fixes device data
        let mslDest = path("no-img-games/Stardew Valley")
        let staged = BuildStore.stageMSLFallbackDirectory(shaderSourcePath: mslDir, dest: mslDest, tid: stardewTID)
        let stagedPath = try XCTUnwrap(staged)
        XCTAssertTrue(fm.fileExists(atPath: stagedPath + "/\(chainHex)_b.metallib"))
        XCTAssertTrue(fm.fileExists(atPath: mslDest + "/.titleid"))
    }

    func testCaptureAndLayoutAfterBatchCompletionAndSheet() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let captureDir = ProcessInfo.processInfo.environment["NX_BATCH_REFRESH_AFTER_DIR"].map { URL(fileURLWithPath: $0) }
        if let captureDir {
            try fm.createDirectory(at: captureDir, withIntermediateDirectories: true)
        }

        for lang in [Lang.en, Lang.zh] {
            let tmp = path("after-\(lang.code)")
            let stores = LauncherStores(defaults: testDefaults)
            stores.localizer.lang = lang
            let library = GameLibrary(file: URL(fileURLWithPath: tmp + "/library.json"))
            let balatro = LibraryGame(titleID: balatroTID, name: "Balatro")
            let stardew = LibraryGame(titleID: stardewTID, name: "Stardew Valley")
            library.upsert(balatro)
            library.upsert(stardew)

            let batch = UUID()
            let stardewImgPath = tmp + "/games/Stardew Valley/Stardew Valley.img"
            var e1 = QueueEntry(
                gameID: balatro.id, titleID: balatroTID, name: "Balatro",
                target: BuildTarget.ios, inputs: [:], outputDirectory: tmp,
                engineID: stores.engineSync.selection.engineID, batch: batch,
                packageAfter: true, exportIPA: false, status: .done, fastRefresh: true, rebuildsShaders: false,
                imgStatus: .unchanged
            )
            e1.locksTarget = true
            var e2 = QueueEntry(
                gameID: stardew.id, titleID: stardewTID, name: "Stardew Valley",
                target: BuildTarget.ios, inputs: [:], outputDirectory: tmp,
                engineID: stores.engineSync.selection.engineID, batch: batch,
                packageAfter: true, exportIPA: false, status: .done, fastRefresh: true, rebuildsShaders: true,
                imgStatus: .manualReplace(imgPath: stardewImgPath, reason: nil)
            )
            e2.locksTarget = true
            stores.queue.showForGallery([e1, e2])

            let b = stores.build
            b.running = false
            b.done = true
            b.runningTarget = BuildTarget.ios
            b.needsReplaceOldImgReminder = false
            b.updatedImgPath = ""

            let page = BuildPage(
                library: library,
                fetchMetadata: false,
                step: .constant(0),
                build: b,
                running: false,
                repo: stores.repo,
                dependencies: stores.dependencies,
                devices: stores.deviceStore,
                queue: stores.queue,
                transfers: stores.transfers,
                extrasOpen: .constant(false),
                logOpen: .constant(false),
                confirmingCancel: .constant(false)
            )
            .environmentObject(stores.localizer)
            .environmentObject(PadFocus())
            .frame(width: 920, height: 760)
            .background(Color(white: 0.09))
            .environment(\.colorScheme, .dark)

            let host = NSHostingView(rootView: page)
            host.frame = NSRect(origin: .zero, size: NSSize(width: 920, height: 760))
            let window = OffscreenWindow(size: NSSize(width: 920, height: 760))
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.bounds.width, 800)
            if let captureDir {
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let suffix = lang == .zh ? "zh" : "en"
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: captureDir.appendingPathComponent("after-queue-\(suffix).png"))
            }
            window.orderOut(nil)

            let summary = RefreshCompletionSummary(
                id: batch,
                isBatch: true,
                items: [
                    RefreshNoticeItem(id: e1.id, gameID: balatro.id, titleID: balatroTID, name: "Balatro", target: BuildTarget.ios, succeeded: true, imgStatus: .unchanged),
                    RefreshNoticeItem(id: e2.id, gameID: stardew.id, titleID: stardewTID, name: "Stardew Valley", target: BuildTarget.ios, succeeded: true, imgStatus: .manualReplace(imgPath: stardewImgPath, reason: nil)),
                ],
                deviceName: "Player iPhone"
            )
            let sheetView = RefreshCompletionSheet(summary: summary, revealItem: { _ in }, onViewQueue: {}, close: {})
                .environmentObject(stores.localizer)
                .environmentObject(PadFocus())
                .environment(\.colorScheme, .dark)
            let sheetHost = NSHostingView(rootView: sheetView)
            sheetHost.frame = NSRect(origin: .zero, size: sheetHost.fittingSize)
            let sheetWin = OffscreenWindow(size: sheetHost.frame.size, styleMask: [.borderless])
            sheetWin.contentView = sheetHost
            sheetWin.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            sheetHost.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(sheetHost.bounds.height, 220)
            if let captureDir {
                let rep = try XCTUnwrap(sheetHost.bitmapImageRepForCachingDisplay(in: sheetHost.bounds))
                sheetHost.cacheDisplay(in: sheetHost.bounds, to: rep)
                let suffix = lang == .zh ? "zh" : "en"
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: captureDir.appendingPathComponent("after-sheet-\(suffix).png"))
            }
            sheetWin.orderOut(nil)
        }
    }

    func testAutoTransferModeWithRebuiltShadersReachesDeviceAndAdvancesPastSixOfSeven() throws {
        let env = try makeStandIns()
        try write(stateDir + "/emit-6of7", "1")
        let stores = LauncherStores(xcrun: env.xcrun, defaults: testDefaults)
        let library = GameLibrary(file: temporary.appendingPathComponent("library-\(UUID().uuidString).json"))
        let recorder = BuildRecorder(stores: stores, library: library)
        defer { withExtendedLifetime(recorder) {} }

        stores.repo.path = env.repo
        stores.dependencies.pythonPath = "/usr/bin/python3"
        stores.dependencies.deps = [Dep(id: "xcode", name: "dep.xcode", hint: "dep.xcode.hint", present: true, installCmd: [])]
        stores.dependencies.checked = true
        stores.deviceStore.devices = [AppleDevice(id: deviceID, name: "Andy's iPhone", model: "iPhone 17 Pro", os: "27.0",
                                                  reachable: true, transport: "wired")]
        stores.deviceStore.teams = [SigningTeam(id: teamID, identity: "Apple Development: Player")]
        stores.deviceStore.checked = true
        stores.deviceStore.installDevice = deviceID
        stores.deviceStore.signingTeam = teamID
        stores.deviceStore.exportIPA = false
        stores.deviceStore.postBuildTransferMode = .auto
        stores.build.outDir = env.outDir
        stores.build.launcherEnvironment = ["DM_SEED_CACHE_DIR": env.seedRoot]

        var stardew = LibraryGame(titleID: stardewTID, name: "Stardew Valley")
        stardew.archivePath = env.outDir + "/games/Stardew Valley"
        stardew.outputDirectory = env.outDir
        library.upsert(stardew)

        let batch = UUID()
        let entry = RefreshQueueBuilder.makeEntry(
            game: stardew, target: BuildTarget.ios, fastRefresh: true, rebuildsShaders: true,
            batch: batch, stores: stores, libraryFolder: env.outDir
        )
        stores.queue.enqueue([entry])

        var promptCount = 0
        let copySub = stores.deviceStore.$shellCopy.compactMap { $0 }.sink { _ in
            promptCount += 1
            DispatchQueue.main.async { stores.deviceStore.answerCopy(.copy) }
        }
        defer { copySub.cancel() }

        stores.build.startBuildOrQueue()
        waitUntil { !stores.build.running && !stores.queue.hasWaiting && stores.queue.running == nil && stores.queue.packaging.isEmpty }
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))

        XCTAssertEqual(promptCount, 0, "postBuildTransferMode = .auto must transfer directly without prompting")
        XCTAssertTrue(stores.build.done, stores.build.doneNote)
        XCTAssertEqual(stores.build.overallProgress, 1.0)
        let pos = try XCTUnwrap(stores.build.currentStagePosition)
        XCTAssertGreaterThanOrEqual(pos.total, 7)
        XCTAssertEqual(pos.current, pos.total)
        XCTAssertEqual(pos.total, stores.build.stages.count)

        let xcrunCalls = try String(contentsOfFile: stateDir + "/xcrun-calls.txt", encoding: .utf8)
        XCTAssertTrue(xcrunCalls.contains("devicectl device copy to"))
        XCTAssertEqual(stores.queue.entries.first?.status, .done)
        XCTAssertEqual(
            stores.queue.entries.first?.imgStatus,
            .transferred(imgName: "Stardew Valley.img", deviceName: "Andy's iPhone")
        )
        XCTAssertFalse(stores.build.needsReplaceOldImgReminder)

        let bundle = ShellLibrary.load(root: env.shellRoot).bundleID
        let deviceImg = "\(deviceContainer)/\(bundle)/Documents/games/\(stardewTID)/romfs.img"
        XCTAssertTrue(fm.fileExists(atPath: deviceImg))
        let inspectOut = try runPython(["-I", env.romfsImageTool, "--inspect-msl", deviceImg])
        let status = try XCTUnwrap(BuildSeedCache.parseTrailerStatus(from: inspectOut))
        XCTAssertTrue(status.hasTrailer)
        XCTAssertEqual(status.chain, "b-" + chainHex)
    }

    func testAutoTransferFailureAndMissingDeviceSettleAsManualReplaceWithoutHanging() throws {
        // 1) Copy failure under .auto marks copy stage failed, ends running, and sets .manualReplace
        do {
            let env = try makeStandIns()
            try write(stateDir + "/emit-6of7", "1")
            try write(stateDir + "/fail-copy", "1")
            let stores = LauncherStores(xcrun: env.xcrun, defaults: testDefaults)
            let library = GameLibrary(file: temporary.appendingPathComponent("library-fail-\(UUID().uuidString).json"))
            let recorder = BuildRecorder(stores: stores, library: library)
            defer { withExtendedLifetime(recorder) {} }

            stores.repo.path = env.repo
            stores.dependencies.pythonPath = "/usr/bin/python3"
            stores.dependencies.deps = [Dep(id: "xcode", name: "dep.xcode", hint: "dep.xcode.hint", present: true, installCmd: [])]
            stores.dependencies.checked = true
            stores.deviceStore.devices = [AppleDevice(id: deviceID, name: "Andy's iPhone", model: "iPhone 17 Pro", os: "27.0",
                                                      reachable: true, transport: "wired")]
            stores.deviceStore.teams = [SigningTeam(id: teamID, identity: "Apple Development: Player")]
            stores.deviceStore.checked = true
            stores.deviceStore.installDevice = deviceID
            stores.deviceStore.signingTeam = teamID
            stores.deviceStore.postBuildTransferMode = .auto
            stores.build.outDir = env.outDir
            stores.build.launcherEnvironment = ["DM_SEED_CACHE_DIR": env.seedRoot]

            var stardew = LibraryGame(titleID: stardewTID, name: "Stardew Valley")
            stardew.archivePath = env.outDir + "/games/Stardew Valley"
            stardew.outputDirectory = env.outDir
            library.upsert(stardew)

            let entry = RefreshQueueBuilder.makeEntry(
                game: stardew, target: BuildTarget.ios, fastRefresh: true, rebuildsShaders: true,
                batch: UUID(), stores: stores, libraryFolder: env.outDir
            )
            stores.queue.enqueue([entry])

            stores.build.startBuildOrQueue()
            waitUntil { !stores.build.running && !stores.queue.hasWaiting && stores.queue.running == nil && stores.queue.packaging.isEmpty }
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))

            XCTAssertFalse(stores.build.running)
            XCTAssertFalse(stores.build.done)
            XCTAssertEqual(stores.build.stages.first(where: { $0.id == ShellInstaller.copyStageID })?.state, .failed)
            XCTAssertEqual(stores.queue.entries.first?.status, .failed)
            guard case .manualReplace(let imgPath, let reason)? = stores.queue.entries.first?.imgStatus else {
                return XCTFail("Expected .manualReplace when copy fails")
            }
            XCTAssertTrue(imgPath.hasSuffix("Stardew Valley.img"))
            XCTAssertFalse((reason ?? "").isEmpty)

            let summary = try XCTUnwrap(stores.build.refreshCompletionSummary)
            for lang in [Lang.en, Lang.zh] {
                let text = RefreshCompletionFormatter.notificationText(for: summary, t: { L10n.string($0, lang) })
                XCTAssertTrue(text.body.contains("Stardew Valley.img"))
                XCTAssertFalse(text.body.contains(";"))
            }
        }

        // 2) Device disappears during build -> post-build install/transfer settles cleanly as .manualReplace without hanging
        do {
            try fm.removeItem(atPath: temporary.path)
            try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
            let env = try makeStandIns()
            try write(stateDir + "/emit-6of7", "1")

            let stores = LauncherStores(xcrun: env.xcrun, defaults: testDefaults)
            let library = GameLibrary(file: temporary.appendingPathComponent("library-nodev-\(UUID().uuidString).json"))
            let recorder = BuildRecorder(stores: stores, library: library)
            defer { withExtendedLifetime(recorder) {} }

            stores.repo.path = env.repo
            stores.dependencies.pythonPath = "/usr/bin/python3"
            stores.dependencies.deps = [Dep(id: "xcode", name: "dep.xcode", hint: "dep.xcode.hint", present: true, installCmd: [])]
            stores.dependencies.checked = true
            stores.deviceStore.devices = [AppleDevice(id: deviceID, name: "Andy's iPhone", model: "iPhone 17 Pro", os: "27.0",
                                                      reachable: true, transport: "wired")]
            stores.deviceStore.teams = [SigningTeam(id: teamID, identity: "Apple Development: Player")]
            stores.deviceStore.checked = true
            stores.deviceStore.installDevice = deviceID
            stores.deviceStore.signingTeam = teamID
            stores.deviceStore.postBuildTransferMode = .auto
            stores.build.outDir = env.outDir
            stores.build.launcherEnvironment = ["DM_SEED_CACHE_DIR": env.seedRoot]

            var stardew = LibraryGame(titleID: stardewTID, name: "Stardew Valley")
            stardew.archivePath = env.outDir + "/games/Stardew Valley"
            stardew.outputDirectory = env.outDir
            library.upsert(stardew)

            let entry = RefreshQueueBuilder.makeEntry(
                game: stardew, target: BuildTarget.ios, fastRefresh: true, rebuildsShaders: true,
                batch: UUID(), stores: stores, libraryFolder: env.outDir
            )
            stores.queue.enqueue([entry])

            // Drop the device from devicectl once the build process starts so post-build install hits no-device cleanly.
            let stageSub = stores.build.$stages.sink { stages in
                if !stages.isEmpty {
                    let emptyDevicesJSON: [String: Any] = ["info": ["outcome": "success"], "result": ["devices": []]]
                    if let data = try? JSONSerialization.data(withJSONObject: emptyDevicesJSON) {
                        try? data.write(to: URL(fileURLWithPath: self.stateDir + "/devices.json"))
                    }
                }
            }
            defer { stageSub.cancel() }

            stores.build.startBuildOrQueue()
            waitUntil { !stores.build.running && !stores.queue.hasWaiting && stores.queue.running == nil && stores.queue.packaging.isEmpty }
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))

            XCTAssertFalse(stores.build.running)
            XCTAssertEqual(stores.queue.entries.first?.status, .failed)
            guard case .manualReplace(let imgPath, _)? = stores.queue.entries.first?.imgStatus else {
                return XCTFail("Expected .manualReplace when device is absent")
            }
            XCTAssertTrue(imgPath.hasSuffix("Stardew Valley.img"))
        }
    }
}
