import AppKit
import Combine
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
@testable import NXLauncher

/// End-to-end coverage for staged batch builds, target/install selection on queued batches, single final shell signing/install
/// at the end of an iPhone/iPad queue batch, and installing built games directly without rebuilding or copying `romfs.img`.
@MainActor final class BatchBuildAndInstallBuiltTests: IsolatedDefaultsTestCase {
    private var temporary: URL!
    private let fm = FileManager.default
    private let idA = "0100535012974000"
    private let idB = "01007EF00011E000"
    private let deviceID = "00008150-AAAA"
    private let teamID = "TEAM123456"

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporary = fm.temporaryDirectory.appendingPathComponent("nx-batch-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporary { try? fm.removeItem(at: temporary) }
        try super.tearDownWithError()
    }

    private func path(_ parts: String...) -> String { parts.reduce(temporary.path) { $0 + "/" + $1 } }

    @discardableResult
    private func write(_ file: String, _ text: String, executable: Bool = false) throws -> String {
        try fm.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: file, atomically: true, encoding: .utf8)
        if executable { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file) }
        return file
    }

    private func addLibraryGame(_ library: GameLibrary, titleID: String, name: String, target: String,
                                inputs: [String: [String]] = [:], archivePath: String = "") -> LibraryGame {
        var g = LibraryGame(titleID: titleID, name: name)
        g.lastTarget = target
        g.inputs = inputs
        g.archivePath = archivePath
        library.upsert(g)
        return g
    }

    private var stateDir: String { path("state") }
    private var deviceContainer: String { path("device") }

    private func lines(in name: String) -> [String] {
        ((try? String(contentsOfFile: stateDir + "/" + name, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    private func makeStandIns() throws -> (repo: String, xcrun: String, keys: String, shellRoot: String) {
        guard fm.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("System Python is required for the process stand-ins")
        }
        try fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true)

        let devicesJSON: [String: Any] = [
            "info": ["outcome": "success"],
            "result": ["devices": [[
                "hardwareProperties": ["udid": deviceID, "reality": "physical", "platform": "iOS", "marketingName": "iPhone 17 Pro"],
                "deviceProperties": ["name": "Player iPhone", "osVersionNumber": "27.0"],
                "connectionProperties": ["pairingState": "paired", "tunnelState": "connected", "transportType": "wired"]
            ]]]
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
            if os.path.exists(STATE + '/fail-xcodebuild'):
                print('error: Signing failed while offline.', flush=True)
                sys.exit(65)
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
            if os.path.exists(STATE + '/fail-copy-on') and open(STATE + '/fail-copy-on').read().strip() in dest:
                print('ERROR: The device is locked. (com.apple.dt.CoreDeviceError error 1)', flush=True)
                sys.exit(1)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            shutil.copyfile(src, dest)
            print('100%', flush=True)
        """, executable: true)

        let repo = path("repo")
        try write(repo + "/dm/tools/nx_extract/Program.cs", "// marker\n")
        try write(repo + "/dm/tools/romfs_image.py", "# placeholder\n")
        try write(repo + "/frontend-ios/Package.swift", "// swift-tools-version: 5.9\n")
        try fm.createDirectory(atPath: repo + "/frontend-ios/Shell/App", withIntermediateDirectories: true)

        try write(repo + "/scripts/build_ipa_from_nsp.py", """
        #!/usr/bin/python3
        # argparse marker: '--work-dir'
        import os, re, sys
        a = sys.argv[1:]
        STATE = '\(stateDir)'
        open(STATE + '/build-calls.txt', 'a').write(' '.join(a) + '\\n')
        def val(flag): return a[a.index(flag) + 1] if flag in a else None
        in_dir = a[0]
        work_dir = val('--work-dir')
        tid = None
        for f in sorted(os.listdir(in_dir)):
            m = re.search(r'([0-9A-Fa-f]{16})', f)
            if m:
                tid = m.group(1).upper()
                break
        tid = tid or '0100000000000000'
        os.makedirs(work_dir + '/extract/v0', exist_ok=True)
        open(work_dir + '/extract/v0/RomFS.img', 'w').write('romfs-for-' + tid)
        open(work_dir + '/extract/v0/RomFS.img.id', 'w').write('{"title":"' + tid.lower() + '"}\\n')
        fw_parent = val('--shell-framework')
        if fw_parent:
            fw = fw_parent + '/DmGame' + tid + '.framework'
            os.makedirs(fw, exist_ok=True)
            open(fw + '/game.manifest.json', 'w').write('{"title_id":"' + tid + '"}')
            open(fw + '/DmGame' + tid, 'w').write('bin-' + tid)
        else:
            out_app = val('-o')
            if out_app:
                os.makedirs(out_app + '/Contents/MacOS', exist_ok=True)
                open(out_app + '/Contents/Info.plist', 'w').write('<plist/>')
        """, executable: true)

        try write(repo + "/frontend-ios/Shell/build_shell.sh", """
        #!/bin/bash
        echo "$*" >> "\(stateDir)/shell-calls.txt"
        mkdir -p "$SHELL_DIR/DmShell.xcodeproj" "$SHELL_DIR/Gen"
        : > "$SHELL_DIR/frameworks.txt"
        while IFS= read -r fw; do
          [ -n "$fw" ] || continue
          [ -d "$fw" ] || { echo "[RED] missing $fw"; exit 1; }
          tid=$(basename "$fw" .framework); tid=${tid#DmGame}
          printf '%s\\t%s\\t%s\\n' "$tid" "$fw" "$tid" >> "$SHELL_DIR/frameworks.txt"
        done <<< "$DM_SHELL_FRAMEWORKS"
        """, executable: true)

        let keys = try write(path("keys/prod.keys"), "header_key = 00\n")
        let shellRoot = path("shell-root")
        testDefaults.set(shellRoot, forKey: "shellRoot")
        return (repo, xcrun, keys, shellRoot)
    }

    private func waitUntil(timeout: TimeInterval = 15, _ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }

    func testQueueWaitsForManualStartAppliesChosenIOSTargetAndSignsShellOnceAtTheEnd() throws {
        let env = try makeStandIns()
        let nspA = try write(path("romsA/Hades [\(idA)].nsp"), String(repeating: "a", count: 64))
        let nspB = try write(path("romsB/BotW [\(idB)].nsp"), String(repeating: "b", count: 64))
        let outDir = path("output")
        try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let stores = LauncherStores(xcrun: env.xcrun, defaults: testDefaults)
        let library = GameLibrary(file: temporary.appendingPathComponent("library.json"))
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
        stores.build.outDir = outDir
        stores.build.slots[3].paths = [env.keys]
        var copyPromptCount = 0
        let copyPromptSub = stores.deviceStore.$shellCopy.compactMap { $0 }.sink { _ in
            copyPromptCount += 1
            DispatchQueue.main.async { stores.deviceStore.answerCopy(.copy) }
        }
        defer { copyPromptSub.cancel() }

        let gameA = addLibraryGame(library, titleID: idA, name: "Hades", target: BuildTarget.mac,
                                   inputs: ["base": [nspA], "keys": [env.keys]])
        let gameB = addLibraryGame(library, titleID: idB, name: "BotW", target: BuildTarget.mac,
                                   inputs: ["base": [nspB], "keys": [env.keys]])

        // 1. Adding selected games to the queue stages them as waiting and does NOT start building automatically.
        let initialBatch = UUID()
        stores.queue.enqueue([
            QueueEntry(gameID: gameA.id, titleID: idA, name: "Hades", target: BuildTarget.mac,
                       inputs: ["base": [nspA], "keys": [env.keys]], outputDirectory: outDir,
                       engineID: stores.engineSync.selection.engineID, batch: initialBatch, packageAfter: false),
            QueueEntry(gameID: gameB.id, titleID: idB, name: "BotW", target: BuildTarget.mac,
                       inputs: ["base": [nspB], "keys": [env.keys]], outputDirectory: outDir,
                       engineID: stores.engineSync.selection.engineID, batch: initialBatch, packageAfter: false),
        ])
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertFalse(stores.build.running, "Selecting games must show the waiting queue without starting")
        let initialStatuses: [QueueEntry.Status] = stores.queue.entries.map { $0.status }
        XCTAssertEqual(initialStatuses, [.queued, .queued])
        XCTAssertEqual(lines(in: "build-calls.txt"), [])

        // 2. Choose iPhone/iPad + Install on a device on the Build page (with no single-game file chosen), then press Start build.
        stores.build.slots[0].paths = []
        stores.build.target = BuildTarget.ios
        stores.deviceStore.exportIPA = false
        stores.deviceStore.installDevice = ""
        stores.deviceStore.signingTeam = ""
        XCTAssertTrue(stores.build.queueNeedsDevice)
        XCTAssertFalse(stores.build.canStartBuildOrQueue, "Direct iOS batch install requires a device and signing team")

        stores.deviceStore.installDevice = deviceID
        stores.deviceStore.signingTeam = teamID
        XCTAssertFalse(stores.build.queueNeedsDevice)
        XCTAssertTrue(stores.build.canStartBuildOrQueue)

        stores.build.startBuildOrQueue()
        waitUntil { !stores.build.running && !stores.queue.hasWaiting && stores.queue.running == nil }

        // 3. Both games built for iOS (--shell-framework), and the shared app was prepared, signed and installed ONLY ONCE at the end.
        let finalStatuses: [QueueEntry.Status] = stores.queue.entries.map { $0.status }
        XCTAssertEqual(finalStatuses, [.done, .done], stores.build.doneNote)
        XCTAssertTrue(stores.build.done, stores.build.doneNote)

        let buildCalls = lines(in: "build-calls.txt")
        XCTAssertEqual(buildCalls.count, 2, "Both queued games must run the build pipeline")
        XCTAssertTrue(buildCalls.allSatisfy { $0.contains("--shell-framework") && $0.contains("--team-id " + teamID) },
                      "Both games must follow the chosen iPhone/iPad target rather than their old Mac target: \(buildCalls)")

        let shellCalls = lines(in: "shell-calls.txt")
        XCTAssertEqual(shellCalls.count, 1, "build_shell.sh --prepare-xcode must run once at the end of the batch")

        let xcrunCalls = lines(in: "xcrun-calls.txt")
        XCTAssertEqual(xcrunCalls.filter { $0.hasPrefix("xcodebuild ") }.count, 1, "xcodebuild signing must run once for the batch")
        XCTAssertEqual(xcrunCalls.filter { $0.hasPrefix("devicectl device install app") }.count, 1,
                       "DmShell.app must be installed once at the end of the batch")
        XCTAssertEqual(copyPromptCount, 1, "Game-data copy confirmation must be asked once for the whole batch")

        let appPath = ShellInstall.appPath(root: env.shellRoot)
        XCTAssertTrue(fm.fileExists(atPath: appPath + "/Frameworks/DmGame\(idA).framework"))
        XCTAssertTrue(fm.fileExists(atPath: appPath + "/Frameworks/DmGame\(idB).framework"))
        let bundle = ShellLibrary.load(root: env.shellRoot).bundleID
        XCTAssertEqual(try String(contentsOfFile: "\(deviceContainer)/\(bundle)/Documents/games/\(idA)/romfs.img", encoding: .utf8),
                       "romfs-for-\(idA)")
        XCTAssertEqual(try String(contentsOfFile: "\(deviceContainer)/\(bundle)/Documents/games/\(idB)/romfs.img", encoding: .utf8),
                       "romfs-for-\(idB)")

        let libA = try XCTUnwrap(library.games.first { $0.titleID == idA })
        let libB = try XCTUnwrap(library.games.first { $0.titleID == idB })
        XCTAssertEqual(libA.archivePath, "\(outDir)/games/\(idA)")
        XCTAssertEqual(libB.archivePath, "\(outDir)/games/\(idB)")
        XCTAssertEqual(libA.iosAppPath, appPath)
        XCTAssertEqual(libB.iosAppPath, appPath)
        XCTAssertEqual(libA.installedDevice, deviceID)
        XCTAssertEqual(libB.installedDevice, deviceID)
    }

    func testBatchInstallRollsBackShellJsonOnSigningFailureAndRetriesIncompleteGameData() throws {
        let env = try makeStandIns()
        let stores = LauncherStores(xcrun: env.xcrun, defaults: testDefaults)
        let library = GameLibrary(file: temporary.appendingPathComponent("library.json"))
        let recorder = BuildRecorder(stores: stores, library: library)
        defer { withExtendedLifetime(recorder) {} }

        stores.repo.path = env.repo
        stores.dependencies.pythonPath = "/usr/bin/python3"
        stores.deviceStore.devices = [AppleDevice(id: deviceID, name: "Player iPhone", model: "iPhone 17 Pro", os: "27.0",
                                                  reachable: true, transport: "wired")]
        stores.deviceStore.teams = [SigningTeam(id: teamID, identity: "Apple Development: Player")]
        stores.deviceStore.installDevice = deviceID
        stores.deviceStore.signingTeam = teamID
        stores.deviceStore.exportIPA = false
        stores.build.target = BuildTarget.ios

        let copySub = stores.deviceStore.$shellCopy.compactMap { $0 }.sink { _ in
            DispatchQueue.main.async { stores.deviceStore.answerCopy(.copy) }
        }
        defer { copySub.cancel() }

        let fwA = path("workA/shell-framework/DmGame\(idA).framework")
        let fwB = path("workB/shell-framework/DmGame\(idB).framework")
        for (id, fw) in [(idA, fwA), (idB, fwB)] {
            try write(fw + "/game.manifest.json", "{}")
            try write(fw + "/DmGame\(id)", "bin")
        }
        let archA = path("out/games/\(idA)"), archB = path("out/games/\(idB)")
        try write(archA + "/romfs.img", "data-A")
        try write(archB + "/romfs.img", "data-B")

        let gA = addLibraryGame(library, titleID: idA, name: "Hades", target: BuildTarget.ios, archivePath: archA)
        let gB = addLibraryGame(library, titleID: idB, name: "BotW", target: BuildTarget.ios, archivePath: archB)

        try write(stateDir + "/fail-xcodebuild", "1")
        let batch = [
            DeferredShellGame(gameID: gA.id, framework: fwA, titleID: idA, name: "Hades", archive: archA),
            DeferredShellGame(gameID: gB.id, framework: fwB, titleID: idB, name: "BotW", archive: archB),
        ]
        stores.build.installShellBatch(batch)
        waitUntil { !stores.build.running }
        XCTAssertFalse(stores.build.done)
        XCTAssertTrue(ShellLibrary.load(root: env.shellRoot).games.isEmpty, "Failed batch sign must roll back shell.json")
        try fm.removeItem(atPath: stateDir + "/fail-xcodebuild")

        try write(stateDir + "/fail-copy-on", idB)
        stores.build.installShellBatch(batch)
        waitUntil { !stores.build.running }
        XCTAssertFalse(stores.build.done)
        let failureKind: BuildFailureKind? = stores.build.failure?.kind
        XCTAssertEqual(failureKind, BuildFailureKind.shellDataIncomplete)
        XCTAssertEqual(try XCTUnwrap(library.games.first { $0.id == gA.id }).iosAppPath, ShellInstall.appPath(root: env.shellRoot))

        try fm.removeItem(atPath: stateDir + "/fail-copy-on")
        try? fm.removeItem(atPath: stateDir + "/xcrun-calls.txt")
        stores.build.retryShellData()
        waitUntil { !stores.build.running }
        XCTAssertTrue(stores.build.done, stores.build.doneNote)
        let retryCalls = lines(in: "xcrun-calls.txt")
        XCTAssertEqual(retryCalls.filter { $0.hasPrefix("xcodebuild ") }.count, 0, "Retry must not re-sign the app")
        XCTAssertEqual(retryCalls.filter { $0.hasPrefix("devicectl device copy to") }.count, 1,
                       "Retry must copy only game B's missing romfs.img")
    }

    func testInstallBuiltGamesSignsAndInstallsAppWithoutRebuildingOrCopyingRomFS() throws {
        let env = try makeStandIns()
        let stores = LauncherStores(xcrun: env.xcrun, defaults: testDefaults)
        let library = GameLibrary(file: temporary.appendingPathComponent("library.json"))
        let recorder = BuildRecorder(stores: stores, library: library)
        defer { withExtendedLifetime(recorder) {} }

        let fwA = ShellInstall.mirroredFramework(root: env.shellRoot, titleID: idA)
        let fwB = ShellInstall.mirroredFramework(root: env.shellRoot, titleID: idB)
        for (id, fw) in [(idA, fwA), (idB, fwB)] {
            try write(fw + "/game.manifest.json", "{}")
            try write(fw + "/DmGame\(id)", "bin")
        }
        var shell = ShellLibrary()
        shell.add(.init(titleID: idA, name: "Hades", framework: fwA))
        shell.add(.init(titleID: idB, name: "BotW", framework: fwB))
        try shell.save(root: env.shellRoot)

        let archA = path("out/games/\(idA)"), archB = path("out/games/\(idB)")
        try write(archA + "/romfs.img", "romfs-A")
        try write(archB + "/romfs.img", "romfs-B")
        _ = addLibraryGame(library, titleID: idA, name: "Hades", target: BuildTarget.ios, archivePath: archA)
        _ = addLibraryGame(library, titleID: idB, name: "BotW", target: BuildTarget.ios, archivePath: archB)

        stores.repo.path = env.repo
        stores.dependencies.pythonPath = "/usr/bin/python3"
        stores.deviceStore.devices = [AppleDevice(id: deviceID, name: "Player iPhone", model: "iPhone 17 Pro", os: "27.0",
                                                  reachable: true, transport: "wired")]
        stores.deviceStore.teams = [SigningTeam(id: teamID, identity: "Apple Development: Player")]
        stores.deviceStore.checked = true
        stores.build.target = BuildTarget.ios
        stores.deviceStore.exportIPA = false

        XCTAssertFalse(stores.build.canInstallBuiltGames)
        stores.deviceStore.installDevice = deviceID
        stores.deviceStore.signingTeam = teamID
        XCTAssertTrue(stores.build.canInstallBuiltGames)

        stores.build.installBuiltGames()
        waitUntil { !stores.build.running }

        XCTAssertTrue(stores.build.done, stores.build.doneNote)
        XCTAssertEqual(lines(in: "build-calls.txt"), [], "Install built games must not rebuild any game")
        XCTAssertEqual(lines(in: "shell-calls.txt").count, 1)
        let xcrunCalls = lines(in: "xcrun-calls.txt")
        XCTAssertEqual(xcrunCalls.filter { $0.hasPrefix("xcodebuild ") }.count, 1)
        XCTAssertEqual(xcrunCalls.filter { $0.hasPrefix("devicectl device install app") }.count, 1)
        XCTAssertEqual(xcrunCalls.filter { $0.hasPrefix("devicectl device info files") }.count, 0,
                       "Mode B must not inspect device romfs.img files during app-only install")
        XCTAssertEqual(xcrunCalls.filter { $0.hasPrefix("devicectl device copy to") }.count, 0,
                       "Mode B must not transfer romfs.img game data during app-only install")

        let appPath = ShellInstall.appPath(root: env.shellRoot)
        for game in library.games {
            XCTAssertEqual(game.iosAppPath, appPath)
            XCTAssertEqual(game.installedDevice, deviceID)
        }
    }

    func testRenderBatchAndInstallBuiltViewsForVisualQA() throws {
        guard let captureDir = ProcessInfo.processInfo.environment["NX_BATCH_CAPTURE_DIR"] else {
            throw XCTSkip("Set NX_BATCH_CAPTURE_DIR to render native visual QA screenshots")
        }
        let out = URL(fileURLWithPath: captureDir)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)

        let shellEmpty = path("shell-empty")
        let shellPopulated = path("shell-populated")
        let fwA = ShellInstall.mirroredFramework(root: shellPopulated, titleID: idA)
        let fwB = ShellInstall.mirroredFramework(root: shellPopulated, titleID: idB)
        for (id, fw) in [(idA, fwA), (idB, fwB)] {
            try write(fw + "/game.manifest.json", "{}")
            try write(fw + "/DmGame\(id)", "bin")
        }
        var shell = ShellLibrary()
        shell.add(.init(titleID: idA, name: "Super Mario Odyssey", framework: fwA))
        shell.add(.init(titleID: idB, name: "Hades", framework: fwB))
        try shell.save(root: shellPopulated)
        let archA = path("archives/\(idA)")
        try write(archA + "/romfs.img", "romfs")

        let fakeRepo = path("fake-repo")
        try write(fakeRepo + "/dm/tools/nx_extract/Program.cs", "// marker\n")

        func render<V: View>(_ fileName: String, width: CGFloat = 760, localizer: Localizer, _ view: V) throws {
            let framed = view
                .environmentObject(localizer)
                .environmentObject(PadFocus())
                .launcherRowControls()
                .padding(24)
                .frame(width: width)
                .background(LauncherPalette.background)
                .environment(\.colorScheme, .light)
            NSApplication.shared.setActivationPolicy(.accessory)
            let host = NSHostingView(rootView: framed)
            host.appearance = NSAppearance(named: .aqua)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.wantsLayer = true
            host.layer?.backgroundColor = LauncherPalette.backgroundNSColor(light: true).cgColor
            let window = OffscreenWindow(size: host.frame.size)
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            host.layoutSubtreeIfNeeded()
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            window.setContentSize(host.frame.size)
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent(fileName))
            window.orderOut(nil)
        }

        let stores = LauncherStores(defaults: testDefaults)
        stores.repo.path = fakeRepo
        stores.dependencies.deps = [Dep(id: "xcode", name: "dep.xcode", hint: "dep.xcode.hint", present: true, installCmd: [])]
        stores.dependencies.checked = true
        stores.deviceStore.devices = [
            AppleDevice(id: deviceID, name: "Jie’s iPhone", model: "iPhone 17 Pro", os: "27.0", reachable: true, transport: "wired")
        ]
        stores.deviceStore.teams = [SigningTeam(id: teamID, identity: "Apple Development: Jie (TEAM123456)")]
        stores.deviceStore.checked = true
        stores.deviceStore.installDevice = deviceID
        stores.deviceStore.signingTeam = teamID
        stores.build.target = BuildTarget.ios

        for lang in Lang.all {
            stores.localizer.lang = lang
            // Before (no built-games install or send-all rows on direct install)
            testDefaults.set(shellEmpty, forKey: "shellRoot")
            stores.build.sharedAppDataSources = { [] }
            stores.deviceStore.exportIPA = false
            try render("install-card-before-\(lang.code).png", localizer: stores.localizer,
                       InstallCard(devices: stores.deviceStore, build: stores.build))

            // After (direct install with Install built games + Send all game data)
            testDefaults.set(shellPopulated, forKey: "shellRoot")
            stores.build.sharedAppDataSources = {
                [TransferSource(titleID: self.idA, name: "Super Mario Odyssey", archive: archA)]
            }
            stores.deviceStore.exportIPA = false
            try render("install-card-after-\(lang.code).png", localizer: stores.localizer,
                       InstallCard(devices: stores.deviceStore, build: stores.build))
        }

        // Full staged BuildPage (queue waiting for manual Start + Where to play + Install on device + Start build) in all 10 languages
        stores.queue.enqueue([
            QueueEntry(titleID: idA, name: "Super Mario Odyssey", target: BuildTarget.mac,
                       inputs: ["base": ["/Games/Super Mario Odyssey.nsp"], "update": ["/Games/Update.nsp"]],
                       outputDirectory: "/Users/player/Games", engineID: stores.engineSync.selection.engineID),
            QueueEntry(titleID: idB, name: "Hades", target: BuildTarget.mac,
                       inputs: ["base": ["/Games/Hades.nsp"], "dlc": ["/Games/DLC1.nsp"]],
                       outputDirectory: "/Users/player/Games", engineID: stores.engineSync.selection.engineID),
        ])
        for lang in Lang.all {
            stores.localizer.lang = lang
            stores.build.target = BuildTarget.ios
            stores.deviceStore.exportIPA = false
            try render("build-page-staged-queue-ios-\(lang.code).png", width: 820, localizer: stores.localizer,
                       VStack(alignment: .leading, spacing: 20) {
                           BuildPage(build: stores.build, running: false, repo: stores.repo,
                                     dependencies: stores.dependencies, devices: stores.deviceStore,
                                     queue: stores.queue, transfers: stores.transfers, onSelectGames: {},
                                     extrasOpen: .constant(false), logOpen: .constant(false))
                       })
        }

        // Before BuildPage (rc4 behavior: adding games immediately auto-started entry 1 on Mac, hiding target/install setup)
        let beforeStores = LauncherStores(defaults: testDefaults)
        beforeStores.repo.path = fakeRepo
        beforeStores.dependencies.deps = stores.dependencies.deps
        beforeStores.dependencies.checked = true
        beforeStores.build.target = BuildTarget.mac
        beforeStores.build.runningTarget = BuildTarget.mac
        beforeStores.build.running = true
        let runningQueue = BuildQueueStore(
            file: nil, engineID: { "pin" }, busy: { false }, start: { _ in nil }
        )
        runningQueue.enqueue([
            QueueEntry(titleID: idA, name: "Super Mario Odyssey", target: BuildTarget.mac,
                       inputs: ["base": ["/Games/Super Mario Odyssey.nsp"], "update": ["/Games/Update.nsp"]],
                       outputDirectory: "/Users/player/Games", engineID: "pin"),
            QueueEntry(titleID: idB, name: "Hades", target: BuildTarget.mac,
                       inputs: ["base": ["/Games/Hades.nsp"], "dlc": ["/Games/DLC1.nsp"]],
                       outputDirectory: "/Users/player/Games", engineID: "pin"),
        ])
        runningQueue.start()
        for lang in Lang.all {
            beforeStores.localizer.lang = lang
            beforeStores.build.stages = [Stage(id: 1, name: String(format: beforeStores.localizer.t("stage.extract"), "NSP"), state: .running, started: Date())]
            beforeStores.build.beginOperation(.building, game: "Super Mario Odyssey", titleID: idA, destination: .target)
            try render("build-page-before-\(lang.code).png", width: 820, localizer: beforeStores.localizer,
                       VStack(alignment: .leading, spacing: 20) {
                           BuildPage(build: beforeStores.build, running: true, repo: beforeStores.repo,
                                     dependencies: beforeStores.dependencies, devices: beforeStores.deviceStore,
                                     queue: runningQueue, transfers: beforeStores.transfers, onSelectGames: {},
                                     extrasOpen: .constant(false), logOpen: .constant(false))
                       })
        }
    }
}
