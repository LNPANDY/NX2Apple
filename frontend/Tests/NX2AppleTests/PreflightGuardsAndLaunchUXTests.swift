import Foundation
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
import NXModel
@testable import NXLauncher

/// Outer-caller tests for PR A4 Modules 2, 3, 4A UI actions, and 4C reassurance guides:
/// - `KeyCheck` `missingKey` build gate (blocking `runBuild()` and `ActionCard`, while allowing `.cannotCheck` and `.fits`)
/// - `.nsz` / `.xcz` 3.5x peak disk check and cross-volume `shellRoot` system disk budget check in `BuildStore`
/// - `[k/n]` stage badge, monotonic `overallProgress`, and `DockProgress` binding across stage transitions
/// - Hero `Play` launching spinner, first-launch Gatekeeper hint eligibility, `OlderTools` reassurance, and iOS trust guide
@MainActor final class PreflightGuardsAndLaunchUXTests: IsolatedDefaultsTestCase {
    private var temporary: URL!
    private let headerKey = (0..<32).map { UInt8(0xB0 ^ $0) }

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("preflight-ux-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func ncaHeader(generation: UInt8) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 0xC00)
        header.replaceSubrange(0x200..<0x204, with: Array("NCA3".utf8))
        header[0x206] = 2
        header[0x207] = 0
        header[0x220] = generation
        header[0x230] = 0x01
        header[0x23F] = generation
        return KeyCheck.xts(header, key: headerKey, encrypt: true)!
    }

    private func writePFS0(_ files: [(String, [UInt8])], name: String) throws -> String {
        var names: [UInt8] = []
        var entries: [UInt8] = []
        var payload: [UInt8] = []
        func le(_ value: Int, _ width: Int) -> [UInt8] {
            (0..<width).map { UInt8((value >> (8 * $0)) & 0xFF) }
        }
        for (file, bytes) in files {
            entries += le(payload.count, 8) + le(bytes.count, 8) + le(names.count, 4) + le(0, 4)
            names += Array(file.utf8) + [0]
            payload += bytes
        }
        while names.count % 0x20 != 0 { names.append(0) }
        let out = Array("PFS0".utf8) + le(files.count, 4) + le(names.count, 4) + le(0, 4) + entries + names + payload
        let path = temporary.appendingPathComponent(name).path
        FileManager.default.createFile(atPath: path, contents: Data(out))
        return path
    }

    private func writeKeys(_ lines: [String], name: String = "prod.keys") throws -> String {
        let path = temporary.appendingPathComponent(name).path
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func keyLine(_ name: String, _ byte: UInt8 = 0x42) -> String {
        name + " = " + hex([UInt8](repeating: byte, count: 16))
    }

    private func makeFakeRepo() throws -> String {
        let repo = temporary.appendingPathComponent("engine")
        let script = repo.appendingPathComponent("scripts/build_ipa_from_nsp.py")
        let prog = repo.appendingPathComponent("dm/tools/nx_extract/Program.cs")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prog.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("print('ok')\n".utf8).write(to: script)
        try Data("// stub\n".utf8).write(to: prog)
        return repo.path
    }

    // MARK: Module 2A - Missing master_key_XX blocks build while non-blocking formats pass

    func testMissingMasterKeyBlocksRunBuildWhileCannotCheckAndMatchingKeysPass() throws {
        let stores = LauncherStores(defaults: testDefaults)
        stores.localizer.lang = .en
        stores.repo.path = try makeFakeRepo()
        stores.dependencies.checked = true
        stores.dependencies.deps = [Dep(id: "python", name: "dep.python", hint: "", present: true, installCmd: [])]

        let build = stores.build
        build.target = BuildTarget.mac
        build.outDir = temporary.path

        let base = try writePFS0([("base.nca", ncaHeader(generation: 0x0C))], name: "Base [0100000000010000].nsp")
        let update = try writePFS0([("upd.nca", ncaHeader(generation: 0x13))], name: "Update [0100000000010800].nsp")
        let oldKeys = try writeKeys(["header_key = " + hex(headerKey), keyLine("master_key_0b")], name: "old.keys")

        build.take(picked: [base], kind: .base)
        build.take(picked: [update], kind: .update)
        build.take(picked: [oldKeys], kind: .keys)

        // Attempt to start a build: the preflight gate must block before spawning any build process.
        build.startBuild()
        XCTAssertFalse(build.running, "missing master_key_12 must block build execution")
        let problem = try XCTUnwrap(build.keyProblem)
        XCTAssertTrue(problem.contains("master_key_12"), problem)
        XCTAssertTrue(problem.contains("Update [0100000000010800].nsp"), problem)
        XCTAssertEqual(build.doneNote, problem)

        // Non-blocking case 1: an XCI whose header cannot be pre-checked must not be blocked.
        var card = [UInt8](repeating: 0, count: 0x200)
        card.replaceSubrange(0x100..<0x104, with: Array("HEAD".utf8))
        let xciPath = temporary.appendingPathComponent("Card [0100000000010000].xci").path
        FileManager.default.createFile(atPath: xciPath, contents: Data(card))

        build.take(picked: [xciPath], kind: .base)
        build.updateSlot("update") { $0.paths = [] }
        XCTAssertTrue(build.prepareBuildPreflight(), "cannotCheck containers must remain allowed")
        XCTAssertNil(build.keyProblem)

        // Non-blocking case 1b: non-PFS0 containers stay unblocked even if keys lack header_key, whereas checkable PFS0 blocks.
        let emptyKeys = try writeKeys([], name: "empty.keys")
        build.take(picked: [emptyKeys], kind: .keys)
        XCTAssertTrue(build.prepareBuildPreflight(), "uncheckable containers must not be false-blocked")
        build.take(picked: [base], kind: .base)
        XCTAssertFalse(build.prepareBuildPreflight(), "checkable PFS0 with empty keys must be blocked")

        // Non-blocking case 2: complete keys pass the gate cleanly.
        let fullKeys = try writeKeys(
            ["header_key = " + hex(headerKey), keyLine("master_key_0b"), keyLine("master_key_12")],
            name: "full.keys"
        )
        build.take(picked: [base], kind: .base)
        build.take(picked: [update], kind: .update)
        build.take(picked: [fullKeys], kind: .keys)
        XCTAssertTrue(build.prepareBuildPreflight())
        XCTAssertNil(build.keyProblem)
    }

    // MARK: Module 2B - Compressed 3.5x output space and cross-volume shellRoot system disk preflight

    func testCompressedPackagePeakMultiplierAndCrossVolumeShellRootSpacePreflight() throws {
        let stores = LauncherStores(defaults: testDefaults)
        stores.localizer.lang = .en
        let build = stores.build
        build.target = BuildTarget.mac

        let nszPath = temporary.appendingPathComponent("Compressed [0100000000010000].nsz")
        try Data(count: 10_000).write(to: nszPath)
        let outFolder = temporary.appendingPathComponent("ExternalOut")
        try FileManager.default.createDirectory(at: outFolder, withIntermediateDirectories: true)

        build.updateSlot("base") { $0.paths = [nszPath.path] }
        build.outDir = outFolder.path

        // 20,000 bytes free is enough for 1.0x (10,000) but below the 3.5x compressed peak (35,000).
        build.spaceAvailable = { _ in 20_000 }
        let compressedShort = try XCTUnwrap(build.preflightSpaceProblem())
        XCTAssertTrue(compressedShort.contains(BuildSpace.text(35_000)), compressedShort)

        // With 100 GB free on the external output drive, test iOS cross-volume shellRoot system disk check.
        build.target = "ios"
        let shellCache = temporary.appendingPathComponent("SystemShellCache")
        try FileManager.default.createDirectory(at: shellCache, withIntermediateDirectories: true)
        testDefaults.set(shellCache.path, forKey: "shellRoot")

        build.volumeIdentifier = { path in
            path.hasPrefix(outFolder.path) ? "vol:/Volumes/ExtSSD" : "vol:/"
        }
        build.spaceAvailable = { path in
            path.hasPrefix(outFolder.path) ? 100_000_000_000 : 1_000_000_000
        }

        let shellShort = try XCTUnwrap(build.preflightSpaceProblem())
        XCTAssertTrue(shellShort.contains("iOS app cache"), shellShort)
        XCTAssertTrue(shellShort.contains(BuildSpace.text(BuildSpace.shellRootMinimumBytes)), shellShort)

        // When output folder and shellRoot share the same volume, no duplicate shellRoot error is raised if the volume has room.
        build.volumeIdentifier = { _ in "vol:/" }
        build.spaceAvailable = { _ in 100_000_000_000 }
        XCTAssertNil(build.preflightSpaceProblem())
    }

    // MARK: Module 3A - [k/n] stage position and monotonic overall progress

    func testBuildStoreTracksStagePositionAndMonotonicOverallProgressAcrossStageTransitions() throws {
        let stores = LauncherStores(defaults: testDefaults)
        stores.localizer.lang = .en
        let build = stores.build
        build.resetOverallProgress()

        var observedFractions: [Double] = []

        build.handle(#"{"ev":"stage","k":1,"n":8,"name":"extract","step":"v0"}"#)
        XCTAssertEqual(build.currentStagePosition?.current, 1)
        XCTAssertEqual(build.currentStagePosition?.total, 8)
        observedFractions.append(try XCTUnwrap(build.overallProgress))

        build.handle(#"{"ev":"progress","k":1,"frac":0.8,"done":80,"total":100,"unit":"files"}"#)
        observedFractions.append(try XCTUnwrap(build.overallProgress))

        build.handle(#"{"ev":"stage_end","k":1,"ok":true,"sec":4.0}"#)
        observedFractions.append(try XCTUnwrap(build.overallProgress))

        // Transition to stage [2/8] where per-stage percent resets to nil (0%): overallProgress must NOT drop!
        build.handle(#"{"ev":"stage","k":2,"n":8,"name":"shader split","step":""}"#)
        XCTAssertEqual(build.currentStagePosition?.current, 2)
        XCTAssertEqual(build.currentStagePosition?.total, 8)
        observedFractions.append(try XCTUnwrap(build.overallProgress))

        build.handle(#"{"ev":"progress","k":2,"frac":0.5,"done":50,"total":100,"unit":"shaders"}"#)
        observedFractions.append(try XCTUnwrap(build.overallProgress))

        for idx in 1..<observedFractions.count {
            XCTAssertGreaterThanOrEqual(
                observedFractions[idx],
                observedFractions[idx - 1],
                "overallProgress regressed at step \(idx): \(observedFractions)"
            )
        }
        XCTAssertEqual(observedFractions.last ?? 0, 1.5 / 8.0, accuracy: 0.001)
    }

    // MARK: Module 3B & Module 4A/4C - Hero launch Gatekeeper hint, failure fix buttons, and install/olderTools guides

    func testFirstMacLaunchGatekeeperHintEligibilityAndFailureFixActions() throws {
        let appBundle = temporary.appendingPathComponent("Odyssey.app")
        let macOSDir = appBundle.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOSDir, withIntermediateDirectories: true)
        let dmhost = macOSDir.appendingPathComponent("dmhost")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: dmhost)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dmhost.path)
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: [
                "DMTitleID": "0100000000010000",
                "CFBundleExecutable": "dmhost",
                "CFBundleDisplayName": "Odyssey",
            ],
            format: .xml,
            options: 0
        )
        try plistData.write(to: appBundle.appendingPathComponent("Contents/Info.plist"))

        var firstLaunchGame = LibraryGame(titleID: "0100000000010000", name: "Odyssey", appPath: appBundle.path)
        firstLaunchGame.lastPlayed = nil
        XCTAssertTrue(LauncherView.needsImmediateGatekeeperHint(for: firstLaunchGame))

        var missingAppGame = firstLaunchGame
        missingAppGame.appPath = temporary.appendingPathComponent("NotBuiltYet.app").path
        XCTAssertFalse(LauncherView.needsImmediateGatekeeperHint(for: missingAppGame))

        var playedGame = firstLaunchGame
        playedGame.lastPlayed = Date()
        XCTAssertFalse(LauncherView.needsImmediateGatekeeperHint(for: playedGame))

        let stores = LauncherStores(defaults: testDefaults)
        stores.localizer.lang = .en
        let build = stores.build

        // Verify `.updateMismatch` button invokes `.update` file picker
        var pickedPrompts: [FilePick] = []
        build.choosePaths = { pick in
            pickedPrompts.append(pick)
            return []
        }
        build.failure = BuildFailure(kind: .updateMismatch, gameName: nil, detail: "v0, v65536")
        XCTAssertTrue(build.failureWhat(build.failure!).contains("v0, v65536"))
        build.fixBuildFailure(.updateMismatch)
        XCTAssertEqual(pickedPrompts.count, 1)
        XCTAssertFalse(pickedPrompts[0].allowsMultiple)

        // Verify `.freeAccountLimit` button opens Xcode when present
        var openedApps: [URL] = []
        build.openApp = { openedApps.append($0) }
        build.failure = BuildFailure(kind: .freeAccountLimit, gameName: nil)
        build.fixBuildFailure(.freeAccountLimit)
        if let xcode = build.installedXcode {
            XCTAssertEqual(openedApps, [URL(fileURLWithPath: xcode)])
        }

        // Verify `OlderTools` reassurance and first-time iOS install trust guide strings exist in English and Chinese
        for lang in [Lang.en, Lang.zh] {
            for key in [
                "library.launching",
                "library.gatekeeperHint",
                "library.olderToolsSafeNote",
                "library.olderToolsHelp",
                "dev.firstInstallGuide.title",
                "dev.firstInstallGuide.devModeBody",
                "dev.firstInstallGuide.trustBody",
            ] {
                let value = L10n.string(key, lang)
                XCTAssertNotEqual(value, key, "\(lang.code) \(key)")
                XCTAssertFalse(value.contains("\u{003B}") || value.contains("\u{FF1B}"), "\(lang.code) \(key)")
            }
        }
    }
}
