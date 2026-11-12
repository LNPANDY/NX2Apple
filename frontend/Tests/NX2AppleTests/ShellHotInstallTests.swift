import XCTest
@testable import NXCore

@MainActor final class ShellHotInstallTests: IsolatedDefaultsTestCase {
    private var temporary: URL!
    private let fm = FileManager.default
    private let firstID = "0100000000010000"
    private let secondID = "01007EF00011E000"
    private let thirdID = "0100535012974000"
    private let device = "00008150-BBBB"
    private let team = "TEAM123456"

    override func setUpWithError() throws {
        temporary = fm.temporaryDirectory.appendingPathComponent("nspb-hot-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: temporary)
    }

    private func path(_ parts: String...) -> String {
        parts.reduce(temporary.path) { $0 + "/" + $1 }
    }

    private func write(_ file: String, _ text: String) throws {
        try fm.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: file, atomically: true, encoding: .utf8)
    }

    private var container: String { path("device") }
    private var state: String { path("state") }
    private var calls: [String] {
        ((try? String(contentsOfFile: state + "/calls.txt", encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    private func makeXcrun() throws -> String {
        try fm.createDirectory(atPath: state, withIntermediateDirectories: true)
        let xcrun = path("xcrun")
        try """
        #!/usr/bin/python3
        import sys, os, json, shutil
        a = sys.argv[1:]
        CONT, STATE = '\(container)', '\(state)'
        open(STATE + '/calls.txt', 'a').write(' '.join(a) + '\\n')
        def val(flag): return a[a.index(flag) + 1] if flag in a else None
        if a[0] == 'xcodebuild':
            bundle = [x.split('=', 1)[1] for x in a if x.startswith('PRODUCT_BUNDLE_IDENTIFIER=')][0]
            app = val('-derivedDataPath') + '/Build/Products/Release-iphoneos/DmShell.app'
            os.makedirs(app + '/Frameworks', exist_ok=True)
            open(app + '/bundle.txt', 'w').write(bundle)
            print('CodeSign ' + app, flush=True)
        elif a[:3] == ['devicectl', 'list', 'devices']:
            devices = [{'hardwareProperties': {'udid': '\(device)', 'reality': 'physical', 'platform': 'iOS', 'marketingName': 'iPhone 17 Pro'},
                        'deviceProperties': {'name': 'HotPhone', 'osVersionNumber': '27.0'},
                        'connectionProperties': {'pairingState': 'paired', 'tunnelState': 'connected', 'transportType': 'wired'}}]
            json.dump({'info': {'outcome': 'success'}, 'result': {'devices': devices}}, open(val('--json-output'), 'w'))
        elif a[:4] == ['devicectl', 'device', 'copy', 'from']:
            src = CONT + '/' + val('--domain-identifier') + '/' + val('--source')
            if not os.path.exists(src):
                print('ERROR: no such file', flush=True)
                sys.exit(1)
            shutil.copyfile(src, val('--destination'))
        elif a[:3] == ['devicectl', 'device', 'install']:
            app = a[-1]
            bundle = open(app + '/bundle.txt').read()
            os.makedirs(CONT + '/' + bundle + '/Documents', exist_ok=True)
            print('100%', flush=True)
        elif a[:4] == ['devicectl', 'device', 'copy', 'to']:
            dest = CONT + '/' + val('--domain-identifier') + '/' + val('--destination')
            src = val('--source')
            if os.path.exists(STATE + '/fail-hot-copy') and '/Documents/Frameworks/.staging-' in dest:
                print('ERROR: simulated hot copy failure', flush=True)
                sys.exit(1)
            if os.path.isdir(src):
                os.makedirs(dest, exist_ok=True)
                shutil.copytree(src, dest, dirs_exist_ok=True)
            else:
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                shutil.copyfile(src, dest)
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
                    full = root + '/' + n; rel = os.path.relpath(full, base)
                    files.append({'name': rel, 'relativePath': rel, 'metadata': {'size': os.path.getsize(full)},
                                  'resources': {'isDirectory': os.path.isdir(full)}})
            json.dump({'info': {'outcome': 'success'}, 'result': {'files': files}}, open(out, 'w'))
        """.write(toFile: xcrun, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xcrun)
        return xcrun
    }

    private func makeRepo() throws -> String {
        let repo = path("repo")
        try write(repo + "/frontend-ios/Shell/build_shell.sh", """
        #!/bin/bash
        mkdir -p "$SHELL_DIR/DmShell.xcodeproj"
        : > "$SHELL_DIR/frameworks.txt"
        while IFS= read -r fw; do
          [ -n "$fw" ] || continue
          tid=$(basename "$fw" .framework); tid=${tid#DmGame}
          printf '%s\\t%s\\t%s\\n' "$tid" "$fw" "$tid" >> "$SHELL_DIR/frameworks.txt"
        done <<< "$DM_SHELL_FRAMEWORKS"
        echo '// pbx' > "$SHELL_DIR/DmShell.xcodeproj/project.pbxproj"
        """)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo + "/frontend-ios/Shell/build_shell.sh")
        try write(repo + "/frontend-ios/Package.swift", "// swift-tools-version: 5.9\n")
        try fm.createDirectory(atPath: repo + "/frontend-ios/Shell/App", withIntermediateDirectories: true)
        return repo
    }

    private func makeSignableFramework(id: String, name: String, loader: String = "FH") throws -> String {
        let fw = path("work", id, "DmGame\(id).framework")
        try fm.createDirectory(atPath: fw, withIntermediateDirectories: true)
        let cSrc = path("work", id, "stub.c")
        try "int dm_game_\(id)(void) { return 1; }\n".write(toFile: cSrc, atomically: true, encoding: .utf8)
        let exe = fw + "/DmGame\(id)"
        let clang = Process()
        clang.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        clang.arguments = ["-dynamiclib", cSrc, "-o", exe]
        try clang.run()
        clang.waitUntilExit()
        XCTAssertEqual(clang.terminationStatus, 0)

        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>CFBundleExecutable</key><string>DmGame\(id)</string>
          <key>CFBundleIdentifier</key><string>org.nxnative.game.\(id)</string>
          <key>CFBundleName</key><string>DmGame\(id)</string>
          <key>CFBundlePackageType</key><string>FMWK</string>
          <key>CFBundleVersion</key><string>1</string>
        </dict>
        </plist>
        """.write(toFile: fw + "/Info.plist", atomically: true, encoding: .utf8)

        try """
        {
          "schema": 1,
          "title_id": "\(id)",
          "name": "\(name)",
          "display_version": "1.0.0",
          "package_version": "0",
          "modules": ["main"],
          "nro_count": 0,
          "chain": "b-3f9a2c",
          "loader": "\(loader)",
          "framework": "DmGame\(id).framework",
          "framework_executable": "DmGame\(id)",
          "image_marker": "dm_game_\(id)",
          "profile": "dm/profile.json",
          "shader_map": "dm/shaders.json",
          "launcher": "launcher.json",
          "romfs_marker": "main.npdm",
          "romfs_identity": "",
          "min_os": "26.0",
          "built_at": "2026-11-12T12:00:00Z"
        }
        """.write(toFile: fw + "/game.manifest.json", atomically: true, encoding: .utf8)
        try #"{"schema":1,"game":"\#(id)","settings":[]}"#.write(toFile: fw + "/launcher.json", atomically: true, encoding: .utf8)
        return fw
    }

    private func writeDeviceBeacon(bundleID: String = ShellLibrary.defaultBundleID, teamID: String, expiresIn: Int64?, nowEpoch: Int64) throws {
        let beacon = ShellHotInstall.HostBeacon(
            schema: 1, glueVersion: 1, bundleID: bundleID, teamID: teamID,
            chain: "b-3f9a2c", version: "1.4.0", expiresAtEpoch: expiresIn.map { nowEpoch + $0 }
        )
        let dest = container + "/\(bundleID)/" + ShellHotInstall.beaconRemotePath
        try fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try JSONEncoder().encode(beacon).write(to: URL(fileURLWithPath: dest), options: .atomic)
    }

    func testHotInstallSignsFrameworkSkipsXcodebuildAndWritesReadyMarkerLast() throws {
        let xcrun = try makeXcrun()
        let repo = try makeRepo()
        let root = path("shell-root")
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let nowEpoch = Int64(fixedNow.timeIntervalSince1970)

        let fw1 = try makeSignableFramework(id: firstID, name: "First Game")
        let arch1 = path("archives", firstID)
        try write(arch1 + "/romfs.img", "romfs-one")

        var inst = ShellInstaller(xcrun: xcrun, repo: repo, python: "/usr/bin/python3", root: root, device: device, team: team)
        inst.resources = nil
        inst.defaults = testDefaults
        inst.now = { fixedNow }
        // Real ad-hoc signing (`-`) exercises actual `/usr/bin/codesign` sealing `_CodeSignature/CodeResources` on macOS.
        inst.signingIdentity = { _, _ in "-" }

        // 1. First install has no shell.json yet -> runs full xcodebuild + devicectl device install app.
        let firstOut = inst.install(framework: fw1, titleID: firstID, name: "First Game", archive: arch1)
        XCTAssertTrue(firstOut.ok, firstOut.message)
        XCTAssertEqual(calls.filter { $0.hasPrefix("xcodebuild") }.count, 1)
        XCTAssertEqual(calls.filter { $0.hasPrefix("devicectl device install app") }.count, 1)

        // Device app starts once and writes Documents/.shell-host.json with 5 days left on its profile.
        try writeDeviceBeacon(teamID: team, expiresIn: 5 * 86400, nowEpoch: nowEpoch)
        try "".write(toFile: state + "/calls.txt", atomically: true, encoding: .utf8)

        // 2. Second game installs via ~2s hot framework push: 0 xcodebuild, 0 devicectl install app!
        let fw2 = try makeSignableFramework(id: secondID, name: "Second Hot Game")
        let arch2 = path("archives", secondID)
        try write(arch2 + "/romfs.img", "romfs-two-bytes")

        let secondOut = inst.install(framework: fw2, titleID: secondID, name: "Second Hot Game", archive: arch2)
        XCTAssertTrue(secondOut.ok, secondOut.message)
        XCTAssertEqual(calls.filter { $0.hasPrefix("xcodebuild") }.count, 0, "hot push must skip xcodebuild completely")
        XCTAssertEqual(calls.filter { $0.hasPrefix("devicectl device install app") }.count, 0, "hot push must skip full app reinstall")
        XCTAssertFalse(calls.contains { $0.contains("--remove-existing-content") })

        let stagingCopies = calls.filter { $0.hasPrefix("devicectl device copy to") && $0.contains("Documents/Frameworks/.staging-\(secondID)-") }
        XCTAssertEqual(stagingCopies.count, 2, "must copy framework directory first and .ready marker second: \(stagingCopies)")
        guard stagingCopies.count == 2 else { return }
        XCTAssertTrue(stagingCopies[0].contains("/DmGame\(secondID).framework"))
        XCTAssertTrue(stagingCopies[1].contains("/.ready"))

        // Verify staged files on the fake device container match the signed footprint and carry _CodeSignature.
        let hotParent = container + "/\(ShellLibrary.defaultBundleID)/Documents/Frameworks"
        let stagingFolder = try XCTUnwrap(try fm.contentsOfDirectory(atPath: hotParent).first { $0.hasPrefix(".staging-\(secondID)-") })
        let pushedFW = hotParent + "/" + stagingFolder + "/DmGame\(secondID).framework"
        let pushedReady = hotParent + "/" + stagingFolder + "/.ready"
        XCTAssertTrue(fm.fileExists(atPath: pushedFW + "/_CodeSignature/CodeResources"), "codesign must seal bundle resources")
        let ready = try JSONDecoder().decode(ShellHotInstall.ReadyMarker.self, from: Data(contentsOf: URL(fileURLWithPath: pushedReady)))
        let actualFootprint = try XCTUnwrap(ShellHotInstall.frameworkFootprint(atPath: pushedFW))
        XCTAssertEqual(ready.titleID, secondID)
        XCTAssertEqual(ready.files, actualFootprint.files)
        XCTAssertEqual(ready.bytes, actualFootprint.bytes)

        // Verify shell.json, mirror, installed receipt, and game data transfer all closed the loop.
        let lib = ShellLibrary.load(root: root)
        XCTAssertEqual(Set(lib.games.map(\.titleID)), [firstID, secondID])
        XCTAssertTrue(ShellLibrary.installedReceipt(root: root).contains(secondID))
        XCTAssertEqual(try String(contentsOfFile: container + "/\(ShellLibrary.defaultBundleID)/Documents/games/\(secondID)/romfs.img", encoding: .utf8),
                       "romfs-two-bytes")
    }

    func testInstallBuiltAndInstallBatchBothUseHotPushAndFiveBoundariesFallBackToXcodebuild() throws {
        let xcrun = try makeXcrun()
        let repo = try makeRepo()
        let root = path("shell-root")
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let nowEpoch = Int64(fixedNow.timeIntervalSince1970)

        let fw1 = try makeSignableFramework(id: firstID, name: "Game One")
        let fw2 = try makeSignableFramework(id: secondID, name: "Game Two")
        let fw3 = try makeSignableFramework(id: thirdID, name: "Game Three")
        let arch1 = path("archives", firstID)
        try write(arch1 + "/romfs.img", "one")

        var inst = ShellInstaller(xcrun: xcrun, repo: repo, python: "/usr/bin/python3", root: root, device: device, team: team)
        inst.resources = nil
        inst.defaults = testDefaults
        inst.now = { fixedNow }
        inst.signingIdentity = { _, _ in "-" }

        XCTAssertTrue(inst.install(framework: fw1, titleID: firstID, name: "Game One", archive: arch1).ok)
        try writeDeviceBeacon(teamID: team, expiresIn: 4 * 86400, nowEpoch: nowEpoch)
        try "".write(toFile: state + "/calls.txt", atomically: true, encoding: .utf8)

        // Parallel entry 2: installBuilt uses hot push (0 xcodebuild).
        XCTAssertTrue(inst.installBuilt(framework: fw2, titleID: secondID, name: "Game Two").ok)
        XCTAssertEqual(calls.filter { $0.hasPrefix("xcodebuild") }.count, 0)

        // Parallel entry 3: multi-game installBatch uses hot push (0 xcodebuild).
        let arch2 = path("archives", secondID), arch3 = path("archives", thirdID)
        try write(arch2 + "/romfs.img", "two")
        try write(arch3 + "/romfs.img", "three")
        let batchOut = inst.installBatch([
            .init(framework: fw2, titleID: secondID, name: "Game Two", archive: arch2),
            .init(framework: fw3, titleID: thirdID, name: "Game Three", archive: arch3),
        ])
        XCTAssertTrue(batchOut.ok, batchOut.message)
        XCTAssertEqual(calls.filter { $0.hasPrefix("xcodebuild") }.count, 0)
        XCTAssertEqual(try String(contentsOfFile: container + "/\(ShellLibrary.defaultBundleID)/Documents/games/\(thirdID)/romfs.img", encoding: .utf8), "three")

        // Fallback Boundary 1: < 24h left on 7-day profile -> falls back to xcodebuild so profile is renewed.
        try writeDeviceBeacon(teamID: team, expiresIn: 12 * 3600, nowEpoch: nowEpoch)
        try "".write(toFile: state + "/calls.txt", atomically: true, encoding: .utf8)
        XCTAssertTrue(inst.installBuilt(framework: fw2, titleID: secondID, name: "Game Two").ok)
        XCTAssertEqual(calls.filter { $0.hasPrefix("xcodebuild") }.count, 1, "expiring profile must trigger full xcodebuild renewal")

        // Fallback Boundary 2: mismatched team ID in beacon -> falls back to xcodebuild.
        try writeDeviceBeacon(teamID: "OTHER99999", expiresIn: 5 * 86400, nowEpoch: nowEpoch)
        try "".write(toFile: state + "/calls.txt", atomically: true, encoding: .utf8)
        XCTAssertTrue(inst.installBuilt(framework: fw2, titleID: secondID, name: "Game Two").ok)
        XCTAssertEqual(calls.filter { $0.hasPrefix("xcodebuild") }.count, 1)

        // Fallback Boundary 3: no local certificate in keychain -> falls back to xcodebuild.
        try writeDeviceBeacon(teamID: team, expiresIn: 5 * 86400, nowEpoch: nowEpoch)
        var noCertInst = inst
        noCertInst.signingIdentity = { _, _ in nil }
        try "".write(toFile: state + "/calls.txt", atomically: true, encoding: .utf8)
        XCTAssertTrue(noCertInst.installBuilt(framework: fw2, titleID: secondID, name: "Game Two").ok)
        XCTAssertEqual(calls.filter { $0.hasPrefix("xcodebuild") }.count, 1)

        // Fallback Boundary 4: hot copy error -> rolls back cleanly and succeeds via full xcodebuild.
        try write(state + "/fail-hot-copy", "1")
        try "".write(toFile: state + "/calls.txt", atomically: true, encoding: .utf8)
        let recovered = inst.installBuilt(framework: fw2, titleID: secondID, name: "Game Two")
        XCTAssertTrue(recovered.ok, recovered.message)
        XCTAssertEqual(calls.filter { $0.hasPrefix("xcodebuild") }.count, 1, "failed hot push must automatically recover via xcodebuild")
    }
}
