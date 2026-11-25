import Combine
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher
@testable import NXModel

/// Regression suite for the RomFS image overwrite guard & device pull/msl fallback closure:
/// 1) Shader library images (`b-<hex>.img`) and build work directories (`shader/`, `extract/`, `pso/`) are never treated as primary `.img`.
/// 2) `ShellInstaller.prepareDeviceDiff` refuses non-`DMROMFS1` and `b-<hex>.img` files so device `romfs.img` cannot be overwritten.
/// 3) Same-chain fast refresh without a local `.img` leaves `archiveDir == ""` and `didUpdateImg == false`, never touching device `romfs.img`.
/// 4) Rebuilt-shader iOS refresh without a local `.img` pulls `romfs.img` from a connected device, injects the new `DMMSLTR1` trailer, and pushes it back.
/// 5) When device pull fails (or is offline), fallback stages `msl/b-<chain>.img`, keeps device `romfs.img` intact, and formats distinct `msl/` UI/notification copy.
@MainActor final class RefreshImgGuardAndPullTests: IsolatedDefaultsTestCase {
    private var temporary: URL!
    private let fm = FileManager.default
    private let stardewTID = "0100E65002BB8000"
    private let deviceID = "00008150-PULLDEV"
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
        temporary = fm.temporaryDirectory.appendingPathComponent("nx-img-guard-" + UUID().uuidString)
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

    private func runPython(_ args: [String]) throws -> String {
        let result = SystemProcessRunner().capture(ProcessLaunch(executable: "/usr/bin/python3", arguments: args))
        guard result.ok else {
            throw NSError(domain: "RefreshImgGuardAndPullTests", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: result.out])
        }
        return result.out
    }

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

    private func waitUntil(timeout: TimeInterval = 20, _ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }

    private func makeStandIns(
        rebuiltShaderAsPackedImg: Bool = true,
        emitShadersStaleEvent: Bool = true,
        allowCopyFrom: Bool = true
    ) throws -> (repo: String, xcrun: String, seedRoot: String, shellRoot: String, outDir: String, romfsImageTool: String) {
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
        if '--timeout' in a:
            idx = a.index('--timeout')
            a = a[:idx] + a[idx + 2:]
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
            if not \(allowCopyFrom ? "True" : "False"):
                print('ERROR: pull disabled in test', flush=True)
                sys.exit(1)
            src = CONT + '/' + val('--domain-identifier') + '/' + val('--source')
            dst = val('--destination')
            if not os.path.exists(src):
                print('ERROR: file not found on device', flush=True)
                sys.exit(1)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(src, dst)
        elif a[:4] == ['devicectl', 'device', 'copy', 'to']:
            dest = CONT + '/' + val('--domain-identifier') + '/' + val('--destination')
            src = val('--source')
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            shutil.copyfile(src, dest)
            print('100%', flush=True)
        """, executable: true)

        try write(repo + "/scripts/build_ipa_from_nsp.py", """
        #!/usr/bin/python3
        # argparse marker: '--work-dir' '--from-seed'
        import json, os, subprocess, sys
        a = sys.argv[1:]
        def val(flag): return a[a.index(flag) + 1] if flag in a else None
        tid = (val('--title-id') or '').upper()
        work_dir = val('--work-dir')
        fw_parent = val('--shell-framework')
        if \(emitShadersStaleEvent ? "True" : "False"):
            print(json.dumps({'ev': 'shaders_stale', 'reason': 'chain', 'old': '000000000000', 'new': '\(chainHex)', 'count': 1}), flush=True)
        os.makedirs(fw_parent, exist_ok=True)
        fw = fw_parent + '/DmGame' + tid + '.framework'
        os.makedirs(fw, exist_ok=True)
        with open(fw + '/game.manifest.json', 'w') as f:
            json.dump({'title_id': tid, 'name': 'Stardew Valley', 'gfx_api': 'nvn', 'chain': 'b-\(chainHex)'}, f)
        open(fw + '/DmGame' + tid, 'w').write('bin-' + tid)
        msl_dir = work_dir + '/shader/ios/b-\(chainHex)'
        os.makedirs(msl_dir, exist_ok=True)
        open(msl_dir + '/\(chainHex)_b.metallib', 'w').write('stardew-rebuilt-metallib-v2')
        open(msl_dir + '/inputs.tsv', 'w').write('key\\tval\\n1\\trebuilt-v2\\n')
        lib_path = msl_dir
        if \(rebuiltShaderAsPackedImg ? "True" : "False"):
            lib_img = work_dir + '/shader/ios/b-\(chainHex).img'
            subprocess.check_call(['/usr/bin/python3', '-I', '\(repoRomfsTool)', msl_dir, lib_img])
            lib_path = lib_img
        msl_cache = fw_parent + '/.msl-cache'
        os.makedirs(msl_cache, exist_ok=True)
        with open(msl_cache + '/' + tid + '.json', 'w') as f:
            json.dump({'lib_path': lib_path, 'gfx_api': 'nvn', 'chain': 'b-\(chainHex)', 'multi_program': False}, f)
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
        let sdir = BuildSeedCache.seedDirectory(for: stardewTID, seedRoot: seedRoot)
        try fm.createDirectory(atPath: sdir + "/ExeFS", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: sdir + "/shader/pkg", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: sdir + "/shader/tables", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: sdir + "/shader/ios", withIntermediateDirectories: true)
        try write(sdir + "/ExeFS/main", "bin-" + stardewTID)
        try write(sdir + "/shader/tables/c1_full.tsv", "c1")
        try write(sdir + "/shader/tables/cb_extent.tsv", "cb")
        let seedChain = emitShadersStaleEvent ? "000000000000" : chainHex
        try JSONEncoder().encode(BuildSeedRecord(titleID: stardewTID, baseTitleID: stardewTID, appName: "Stardew Valley", gfxAPI: "nvn", chain: seedChain, profileID: stardewTID.lowercased()))
            .write(to: URL(fileURLWithPath: sdir + "/seed.json"))

        let outDir = path("output")
        try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let shellRoot = path("shell-root")
        testDefaults.set(shellRoot, forKey: "shellRoot")
        return (repo, xcrun, seedRoot, shellRoot, outDir, repoRomfsTool)
    }

    // MARK: - Case 1 & 2: Shader image / workDir / non-DMROMFS1 guardrails

    func testShaderLibraryImageAndBuildWorkDirsNeverSelectedAsPrimaryOrModified() throws {
        let env = try makeStandIns()
        let workDir = path("output/\(stardewTID)_build")
        let shaderIOS = workDir + "/shader/ios"
        let shaderImg = shaderIOS + "/b-\(chainHex).img"
        try makeRealRomfsImage(at: shaderImg, romfsContent: "shader-lib-only", shaderTag: nil, chain: chainHex, romfsImageTool: env.romfsImageTool)
        let beforeShaderImg = try Data(contentsOf: URL(fileURLWithPath: shaderImg))

        // 1. Even though b-<chain>.img has DMROMFS1 magic and is the sole .img in shader/ios, RomFSArchive must reject it.
        XCTAssertTrue(RomFSArchive.isShaderLibraryImageFileName("b-\(chainHex).img"))
        XCTAssertFalse(RomFSArchive.isValidPrimaryRomFSImage(atPath: shaderImg))
        XCTAssertNil(RomFSArchive.primaryImageName(in: shaderIOS))
        XCTAssertNil(RomFSArchive.primaryImagePath(in: shaderIOS))
        XCTAssertNil(RomFSArchive.primaryImageName(inFiles: ["b-\(chainHex).img", "inputs.tsv"]))

        // 2. findFallbackLocalArchive rejects workDir/shader/ios even if explicitly passed as knownArchivePath or prefillCandidates.
        XCTAssertNil(BuildStore.findFallbackLocalArchive(
            tid: stardewTID,
            knownArchivePath: shaderIOS,
            outDir: env.outDir,
            refreshBuildsRoot: env.outDir,
            prefillCandidates: [shaderIOS, shaderImg, workDir + "/extract", workDir + "/pso"]
        ))
        XCTAssertNil(BuildStore.findFallbackLocalArchive(
            tid: stardewTID,
            knownArchivePath: shaderImg,
            outDir: env.outDir,
            refreshBuildsRoot: env.outDir,
            prefillCandidates: []
        ))

        // 3. injectIOSShaderTrailer refuses b-<chain>.img and non-DMROMFS1 files without mutating them.
        let injectShaderRes = BuildStore.injectIOSShaderTrailer(
            targetImg: shaderImg,
            workDir: workDir,
            tid: stardewTID,
            isIOSBuild: true,
            repoPath: env.repo,
            pythonPath: "/usr/bin/python3",
            runner: SystemProcessRunner(),
            forceReplace: true
        )
        switch injectShaderRes {
        case .success:
            XCTFail("injectIOSShaderTrailer must refuse shader library image b-<hex>.img")
        case .failure:
            break
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: shaderImg)), beforeShaderImg)
        XCTAssertFalse(fm.fileExists(atPath: shaderIOS + "/.titleid"), "Must never write .titleid into workDir/shader/ios")

        let junkImg = path("junk/FakeGame.img")
        try write(junkImg, "not-a-romfs-image")
        if case .success = BuildStore.injectIOSShaderTrailer(
            targetImg: junkImg,
            workDir: workDir,
            tid: stardewTID,
            isIOSBuild: true,
            repoPath: env.repo,
            pythonPath: "/usr/bin/python3",
            runner: SystemProcessRunner(),
            forceReplace: true
        ) {
            XCTFail("injectIOSShaderTrailer must refuse non-DMROMFS1 files")
        }

        // 4. ShellInstaller.prepareDeviceDiff refuses non-DMROMFS1 and b-*.img from mapping to romfs.img.
        let installer = ShellInstaller(xcrun: env.xcrun, repo: env.repo, python: "/usr/bin/python3", root: env.shellRoot, device: deviceID, team: teamID)
        let shaderOnlyArchive = path("bad-archive-shader")
        try fm.createDirectory(atPath: shaderOnlyArchive, withIntermediateDirectories: true)
        try fm.copyItem(atPath: shaderImg, toPath: shaderOnlyArchive + "/b-\(chainHex).img")
        let diffShaderOnly = installer.prepareDeviceDiff(titleID: stardewTID, archive: shaderOnlyArchive, bundleID: ShellInstall.bundleID, onDevice: [:])
        XCTAssertNil(diffShaderOnly.primaryImage)
        XCTAssertNil(diffShaderOnly.local["romfs.img"])

        let corruptArchive = path("bad-archive-corrupt")
        try write(corruptArchive + "/Stardew Valley.img", "corrupted-text-bytes")
        let diffCorrupt = installer.prepareDeviceDiff(titleID: stardewTID, archive: corruptArchive, bundleID: ShellInstall.bundleID, onDevice: [:])
        XCTAssertNil(diffCorrupt.primaryImage)
        XCTAssertNil(diffCorrupt.local["romfs.img"])
    }

    // MARK: - Case 3: Same-chain fast refresh without local .img leaves device romfs.img untouched

    func testSameChainFastRefreshWithoutLocalImgSkipsPullAndMSLFallbackLeavingDeviceImgIntact() throws {
        let env = try makeStandIns(rebuiltShaderAsPackedImg: true, emitShadersStaleEvent: false, allowCopyFrom: true)
        let stores = LauncherStores(xcrun: env.xcrun, defaults: testDefaults)
        let library = GameLibrary(file: temporary.appendingPathComponent("library-samechain-\(UUID().uuidString).json"))
        let recorder = BuildRecorder(stores: stores, library: library)
        defer { withExtendedLifetime(recorder) {} }

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
        stores.deviceStore.postBuildTransferMode = .auto
        stores.build.outDir = env.outDir
        stores.build.launcherEnvironment = ["DM_SEED_CACHE_DIR": env.seedRoot]

        // Device already holds a valid game romfs.img; local PC has NO games/<Game>/<Game>.img.
        let deviceGameDir = "\(deviceContainer)/\(ShellInstall.bundleID)/Documents/games/\(stardewTID)"
        let deviceImg = deviceGameDir + "/romfs.img"
        try makeRealRomfsImage(at: deviceImg, romfsContent: "intact-stardew-romfs-v1", shaderTag: "matched-v1", chain: chainHex, romfsImageTool: env.romfsImageTool)
        let beforeDeviceBytes = try Data(contentsOf: URL(fileURLWithPath: deviceImg))

        let stardew = LibraryGame(titleID: stardewTID, name: "Stardew Valley")
        library.upsert(stardew)
        let entry = RefreshQueueBuilder.makeEntry(
            game: stardew, target: BuildTarget.ios, fastRefresh: true, rebuildsShaders: false,
            batch: UUID(), stores: stores, libraryFolder: env.outDir
        )
        stores.queue.enqueue([entry])

        stores.build.startBuildOrQueue()
        waitUntil { !stores.build.running && !stores.queue.hasWaiting && stores.queue.running == nil && stores.queue.packaging.isEmpty }
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))

        XCTAssertTrue(stores.build.done, stores.build.doneNote)
        XCTAssertEqual(stores.queue.entries.first?.status, .done)
        XCTAssertEqual(stores.queue.entries.first?.imgStatus, .unchanged)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: deviceImg)), beforeDeviceBytes, "Same-chain fast refresh must not touch device romfs.img")
        XCTAssertFalse(fm.fileExists(atPath: env.outDir + "/games/Stardew Valley/msl"))
        XCTAssertFalse(fm.fileExists(atPath: env.outDir + "/\(stardewTID)_build/shader/ios/.titleid"))

        let xcrunCalls = (try? String(contentsOfFile: stateDir + "/xcrun-calls.txt", encoding: .utf8)) ?? ""
        XCTAssertFalse(xcrunCalls.contains("devicectl device copy from"), "Same-chain fast refresh must not pull romfs.img from device")
        XCTAssertFalse(xcrunCalls.contains("devicectl device copy to"), "Same-chain fast refresh must not push data when local .img is absent")
    }

    // MARK: - Case 4: Rebuilt shaders without local .img auto-pulls from device, injects trailer, and pushes back

    func testShaderRebuildWithoutLocalImgAutoPullsFromDeviceInjectsTrailerAndPushesBack() throws {
        let env = try makeStandIns(rebuiltShaderAsPackedImg: true, emitShadersStaleEvent: true, allowCopyFrom: true)
        let stores = LauncherStores(xcrun: env.xcrun, defaults: testDefaults)
        let library = GameLibrary(file: temporary.appendingPathComponent("library-autopull-\(UUID().uuidString).json"))
        let recorder = BuildRecorder(stores: stores, library: library)
        defer { withExtendedLifetime(recorder) {} }

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
        stores.deviceStore.postBuildTransferMode = .auto
        stores.build.outDir = env.outDir
        stores.build.launcherEnvironment = ["DM_SEED_CACHE_DIR": env.seedRoot]

        // Device holds the full game DMROMFS1 image with an old trailer; Mac has NO local games/Stardew Valley/Stardew Valley.img.
        let deviceGameDir = "\(deviceContainer)/\(ShellInstall.bundleID)/Documents/games/\(stardewTID)"
        let deviceImg = deviceGameDir + "/romfs.img"
        try makeRealRomfsImage(at: deviceImg, romfsContent: "full-stardew-game-assets", shaderTag: "old-metallib", chain: "000000000000", romfsImageTool: env.romfsImageTool)
        let deviceBaseIdentity = try XCTUnwrap(RomfsImageIdentity.computeIdentity(of: deviceImg))

        // Record matching DMROMFSID1 in seed.json so pullImage verifies base identity too.
        let seedDir = BuildSeedCache.seedDirectory(for: stardewTID, seedRoot: env.seedRoot)
        let idLine = "DMROMFSID1 title=\(stardewTID.lowercased()) version=1.0 build=1 size=\(deviceBaseIdentity.size) index=\(String(format: "%016llx", deviceBaseIdentity.index))"
        try JSONEncoder().encode(BuildSeedRecord(
            titleID: stardewTID, baseTitleID: stardewTID, appName: "Stardew Valley",
            gfxAPI: "nvn", chain: "000000000000", profileID: stardewTID.lowercased(), romfsIdentity: idLine
        )).write(to: URL(fileURLWithPath: seedDir + "/seed.json"))

        let stardew = LibraryGame(titleID: stardewTID, name: "Stardew Valley")
        library.upsert(stardew)
        let entry = RefreshQueueBuilder.makeEntry(
            game: stardew, target: BuildTarget.ios, fastRefresh: true, rebuildsShaders: true,
            batch: UUID(), stores: stores, libraryFolder: env.outDir
        )
        stores.queue.enqueue([entry])

        var observedPullingStage = false
        let stageSub = stores.build.$stages.sink { stages in
            let expectedPrefix = String(format: stores.build.t("prog.pullingDeviceImg"), "Player iPhone")
            if stages.contains(where: { $0.id == 1000 && $0.detail == expectedPrefix }) {
                observedPullingStage = true
            }
        }
        defer { stageSub.cancel() }

        stores.build.startBuildOrQueue()
        waitUntil { !stores.build.running && !stores.queue.hasWaiting && stores.queue.running == nil && stores.queue.packaging.isEmpty }
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))

        XCTAssertTrue(stores.build.done, stores.build.doneNote)
        XCTAssertTrue(observedPullingStage, "Archive stage must report pulling game data from device")
        XCTAssertEqual(stores.queue.entries.first?.status, .done)
        XCTAssertEqual(stores.queue.entries.first?.imgStatus, .transferred(imgName: "Stardew Valley.img", deviceName: "Player iPhone"))

        // Local canonical archive got pulled + injected, and device romfs.img now carries the same base identity + updated trailer.
        let localPulledImg = env.outDir + "/games/Stardew Valley/Stardew Valley.img"
        XCTAssertTrue(fm.fileExists(atPath: localPulledImg))
        XCTAssertTrue(RomFSArchive.isValidPrimaryRomFSImage(atPath: localPulledImg))
        XCTAssertEqual(RomfsImageIdentity.computeIdentity(of: deviceImg)?.index, deviceBaseIdentity.index)
        XCTAssertEqual(RomfsImageIdentity.computeIdentity(of: deviceImg)?.size, deviceBaseIdentity.size)

        let inspectOut = try runPython(["-I", env.romfsImageTool, "--inspect-msl", deviceImg])
        let trailer = try XCTUnwrap(BuildSeedCache.parseTrailerStatus(from: inspectOut))
        XCTAssertTrue(trailer.hasTrailer)
        XCTAssertEqual(trailer.chain, "b-" + chainHex)

        let xcrunCalls = try String(contentsOfFile: stateDir + "/xcrun-calls.txt", encoding: .utf8)
        XCTAssertTrue(xcrunCalls.contains("devicectl device copy from"))
        XCTAssertTrue(xcrunCalls.contains("devicectl device copy to"))
    }

    // MARK: - Case 5: Pull failure falls back to msl/b-<chain>.img without overwriting device romfs.img

    func testPullFailureFallsBackToMSLSubdirectoryKeepsDeviceRomfsIntactAndShowsDistinctCopy() throws {
        let env = try makeStandIns(rebuiltShaderAsPackedImg: true, emitShadersStaleEvent: true, allowCopyFrom: false)
        let stores = LauncherStores(xcrun: env.xcrun, defaults: testDefaults)
        let library = GameLibrary(file: temporary.appendingPathComponent("library-mslfallback-\(UUID().uuidString).json"))
        let recorder = BuildRecorder(stores: stores, library: library)
        defer { withExtendedLifetime(recorder) {} }

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
        stores.deviceStore.postBuildTransferMode = .auto
        stores.build.outDir = env.outDir
        stores.build.launcherEnvironment = ["DM_SEED_CACHE_DIR": env.seedRoot]

        // Device has its full romfs.img, and pull (`copy from`) fails.
        let deviceGameDir = "\(deviceContainer)/\(ShellInstall.bundleID)/Documents/games/\(stardewTID)"
        let deviceImg = deviceGameDir + "/romfs.img"
        try makeRealRomfsImage(at: deviceImg, romfsContent: "intact-device-romfs-must-survive", shaderTag: "old", chain: "000000000000", romfsImageTool: env.romfsImageTool)
        let originalDeviceBytes = try Data(contentsOf: URL(fileURLWithPath: deviceImg))

        let stardew = LibraryGame(titleID: stardewTID, name: "Stardew Valley")
        library.upsert(stardew)
        let entry = RefreshQueueBuilder.makeEntry(
            game: stardew, target: BuildTarget.ios, fastRefresh: true, rebuildsShaders: true,
            batch: UUID(), stores: stores, libraryFolder: env.outDir
        )
        stores.queue.enqueue([entry])

        stores.build.startBuildOrQueue()
        waitUntil { !stores.build.running && !stores.queue.hasWaiting && stores.queue.running == nil && stores.queue.packaging.isEmpty }
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))

        XCTAssertTrue(stores.build.done, stores.build.doneNote)
        XCTAssertEqual(stores.queue.entries.first?.status, .done)
        XCTAssertEqual(stores.queue.entries.first?.imgStatus, .transferred(imgName: "msl", deviceName: "Player iPhone"))

        // Crucial safety invariant: device's top-level romfs.img is byte-for-byte untouched, while msl/b-<chain>.img was transferred!
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: deviceImg)), originalDeviceBytes, "Fallback msl/ transfer must never overwrite device romfs.img")
        XCTAssertTrue(fm.fileExists(atPath: deviceGameDir + "/msl/b-\(chainHex).img"), "Updated shaders must land in Documents/games/<TID>/msl/b-<chain>.img")

        let summary = try XCTUnwrap(stores.build.refreshCompletionSummary)
        for lang in [Lang.en, Lang.zh] {
            let formatted = RefreshCompletionFormatter.notificationText(for: summary, t: { L10n.string($0, lang) })
            XCTAssertTrue(formatted.body.contains("msl/"), "Notification must clearly indicate msl/ update in \(lang.code): \(formatted.body)")
            XCTAssertFalse(formatted.body.contains(";"))
            XCTAssertFalse(formatted.body.contains("；"))
        }

        // Manual msl/ fallback formatting also stays distinct from main .img replacement and free of semicolons.
        let manualItem = RefreshNoticeItem(titleID: stardewTID, name: "Stardew Valley", target: BuildTarget.ios, succeeded: true, imgStatus: .manualReplace(imgPath: env.outDir + "/games/Stardew Valley/msl", reason: nil))
        for lang in [Lang.en, Lang.zh] {
            let line = RefreshCompletionFormatter.itemLineStatus(manualItem, t: { L10n.string($0, lang) })
            XCTAssertTrue(line.contains("msl/"), line)
            XCTAssertFalse(line.contains(".img"), "Manual msl/ status should not tell the user a new .img was generated: \(line)")
        }
    }
}
