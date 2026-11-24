import Foundation
import XCTest
@testable import NXCore

final class MngSharedSaveTests: XCTestCase {
    private var root: URL!
    private var support: URL!
    private let fm = FileManager.default
    private let totkTID = "0100F2C0115B6000"
    private let botwTID = "01007EF00011E000"
    private let pkpTID = "0400A3A01EE4C000"
    private let dkbTID = "040074A01BF12000"
    private let ootTID = "0400486024DEC000"
    private let acnhTID = "01006F8002326000"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fm.temporaryDirectory.appendingPathComponent("mng-shared-save-" + UUID().uuidString, isDirectory: true)
        support = root.appendingPathComponent("support", isDirectory: true)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func write(_ url: URL, content: String = "data") throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    private func makeCheckout(includePR2375: Bool) throws -> URL {
        let tree = root.appendingPathComponent("mng-tree-\(includePR2375 ? "new" : "old")", isDirectory: true)
        try write(tree.appendingPathComponent("build_app.py"), content: "# mng\n")
        if includePR2375 {
            try write(tree.appendingPathComponent("shared/runtime/account.c"), content: "const char *e = getenv(\"DM_SAVE\");\n")
            try write(tree.appendingPathComponent("games/totk/app/launcher.m"), content: "static BOOL prepare_external_save(void) { return YES; }\n")
            try write(tree.appendingPathComponent("games/totk/runtime/fs_host.c"), content: "static int use_dm_save = 1;\n")
            try write(tree.appendingPathComponent("games/oot/app/launcher.m"), content: "static BOOL prepare_external_save(void) { return YES; }\n")
            try write(tree.appendingPathComponent("games/oot/runtime/fs_host.c"), content: "static int use_dm_save = 1;\n")
        } else {
            try write(tree.appendingPathComponent("shared/runtime/account.c"), content: "/* legacy account */\n")
            try write(tree.appendingPathComponent("games/totk/app/launcher.m"), content: "/* legacy totk */\n")
            try write(tree.appendingPathComponent("games/totk/runtime/fs_host.c"), content: "/* legacy fs_host */\n")
            try write(tree.appendingPathComponent("games/oot/app/launcher.m"), content: "/* legacy oot */\n")
            try write(tree.appendingPathComponent("games/oot/runtime/fs_host.c"), content: "/* legacy fs_host */\n")
        }
        return tree
    }

    private func makeBundle(
        name: String,
        titleID: String,
        bundleID: String = "org.macnativegames.totk",
        sharedMarker: Bool = false,
        lsSaveEnv: String? = nil,
        binaryMarker: Bool = false
    ) throws -> URL {
        let app = root.appendingPathComponent(name, isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        let exe = macOS.appendingPathComponent("GameBin")
        if binaryMarker {
            try Data("prefix\0[totk] host save storage (DM_SAVE): %s\0suffix".utf8).write(to: exe)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        } else {
            try fm.createSymbolicLink(at: exe, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        }
        var info: [String: Any] = [
            "CFBundleExecutable": "GameBin",
            "CFBundleIdentifier": bundleID,
            "CFBundleDisplayName": name,
            "DMTitleID": titleID,
            "DMUpstream": "macnativegames",
        ]
        if sharedMarker { info["MNGSharedSave"] = true }
        if let lsSaveEnv { info["LSEnvironment"] = ["DM_SAVE": lsSaveEnv] }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    func testCheckoutVersionAndFeatureDetectionWithNegativeControls() throws {
        let newTree = try makeCheckout(includePR2375: true)
        let oldTree = try makeCheckout(includePR2375: false)

        for tid in [totkTID, botwTID, pkpTID, dkbTID, ootTID] {
            XCTAssertTrue(MngSharedSave.checkoutSupportsSharedSave(forTitleID: tid, in: newTree.path), "Expected #2375 support for \(tid)")
            XCTAssertFalse(MngSharedSave.checkoutSupportsSharedSave(forTitleID: tid, in: oldTree.path), "Old tree must stay unshared for \(tid)")
        }
        XCTAssertTrue(MngSharedSave.checkoutSupportsSharedSave(forTitleID: nil, in: newTree.path))
        XCTAssertFalse(MngSharedSave.checkoutSupportsSharedSave(forTitleID: nil, in: oldTree.path))
        // Other 7 MNG ports never opt into DM_SAVE even on a #2375 checkout.
        XCTAssertFalse(MngSharedSave.checkoutSupportsSharedSave(forTitleID: acnhTID, in: newTree.path))

        // Negative verification: dropping the OoT fs_host feature disables OoT while leaving TOTK intact.
        try write(newTree.appendingPathComponent("games/oot/runtime/fs_host.c"), content: "/* legacy oot fs_host */\n")
        XCTAssertFalse(MngSharedSave.checkoutSupportsSharedSave(forTitleID: ootTID, in: newTree.path))
        XCTAssertFalse(MngSharedSave.checkoutSupportsSharedSave(forTitleID: nil, in: newTree.path))
        XCTAssertTrue(MngSharedSave.checkoutSupportsSharedSave(forTitleID: totkTID, in: newTree.path))
    }

    func testSaveEngineRoutingForLegacyVsSharedMNGBundles() throws {
        let legacyMNG = try makeBundle(name: "TOTK-Legacy.app", titleID: totkTID)
        let plistMarkedMNG = try makeBundle(name: "TOTK-Shared.app", titleID: totkTID, sharedMarker: true)
        let binaryOnlyMNG = try makeBundle(name: "OOT-Binary.app", titleID: ootTID, bundleID: "org.macnativegames.oot", binaryMarker: true)
        let acnhMarked = try makeBundle(name: "ACNH-Fake.app", titleID: acnhTID, bundleID: "org.macnativegames.acnh", sharedMarker: true)

        XCTAssertTrue(SaveEngines.forApp(legacyMNG.path, titleID: totkTID) is MacNativeGamesSaveEngine)
        XCTAssertFalse(EngineUpstreamKind.macNativeGames.sharesSaveWithNxnative(titleID: totkTID, appPath: legacyMNG.path))

        XCTAssertTrue(SaveEngines.forApp(plistMarkedMNG.path, titleID: totkTID) is MngSharedDmSaveEngine)
        XCTAssertTrue(EngineUpstreamKind.macNativeGames.sharesSaveWithNxnative(titleID: totkTID, appPath: plistMarkedMNG.path))

        XCTAssertTrue(SaveEngines.forApp(binaryOnlyMNG.path, titleID: ootTID) is MngSharedDmSaveEngine)
        XCTAssertTrue(EngineUpstreamKind.macNativeGames.sharesSaveWithNxnative(titleID: ootTID, appPath: binaryOnlyMNG.path))

        // Non-5-title ports stay isolated even if plist has an unexpected marker.
        XCTAssertTrue(SaveEngines.forApp(acnhMarked.path, titleID: acnhTID) is MacNativeGamesSaveEngine)
        XCTAssertFalse(EngineUpstreamKind.macNativeGames.sharesSaveWithNxnative(titleID: acnhTID, appPath: acnhMarked.path))

        // Always injects DM_SAVE even on standard path (without library marker or overrides).
        let engine = SaveEngines.forApp(plistMarkedMNG.path, titleID: totkTID)
        let eff = SaveLocations.effectiveSave(
            titleID: totkTID,
            appPath: plistMarkedMNG.path,
            global: SaveGlobalSettings(),
            game: SaveGameOverride(),
            support: support,
            engine: engine
        )
        XCTAssertEqual(eff.source, .standard)
        let env = SaveLocations.environment(save: eff, cloud: .init(folder: "icloud", source: .game), engine: engine)
        XCTAssertEqual(env["DM_SAVE"], support.appendingPathComponent("nxnative/\(totkTID)/save").path)
        XCTAssertEqual(env["DM_SAVE_SYNC"], "icloud")
    }

    func testLSEnvironmentInjectionAndLaunchServicesDoubleClickProbe() throws {
        let compiler = "/usr/bin/cc"
        let openTool = "/usr/bin/open"
        guard fm.isExecutableFile(atPath: compiler), fm.isExecutableFile(atPath: openTool) else {
            throw XCTSkip("clang or open tool unavailable")
        }

        let app = root.appendingPathComponent("TOTK [MacNativeGames].app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        let probeOut = root.appendingPathComponent("launch-env.txt")
        let src = root.appendingPathComponent("probe.c")
        let exe = macOS.appendingPathComponent("TOTK")
        let cCode = """
        #include <stdio.h>
        #include <stdlib.h>
        int main(void) {
            const char *marker = "host save storage (DM_SAVE):";
            FILE *f = fopen("\(probeOut.path)", "w");
            const char *v = getenv("DM_SAVE");
            fprintf(f, "%s|%s\\n", marker, v ? v : "(null)");
            fclose(f);
            return 0;
        }
        """
        try write(src, content: cCode)
        let ccRes = SystemProcessRunner().capture(ProcessLaunch(executable: compiler, arguments: [src.path, "-o", exe.path]))
        XCTAssertTrue(ccRes.ok, ccRes.err)

        let info: [String: Any] = [
            "CFBundleExecutable": "TOTK",
            "CFBundleIdentifier": "org.macnativegames.totk.testprobe",
            "CFBundlePackageType": "APPL",
            "CFBundleDisplayName": "TOTK",
            "DMUpstream": "macnativegames",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))

        let sharedSavePath = support.appendingPathComponent("nxnative/\(totkTID)/save").path
        try MngAppLaunchConfig.configure(appURL: app, titleID: totkTID, savePath: sharedSavePath, codesign: true)

        // Verify signature validity.
        let verifyRes = SystemProcessRunner().capture(ProcessLaunch(executable: "/usr/bin/codesign", arguments: ["--verify", "--strict", app.path]))
        XCTAssertTrue(verifyRes.ok, verifyRes.err)

        // Simulate Finder double-click via `open -g -W -n`.
        let openRes = SystemProcessRunner().capture(ProcessLaunch(executable: openTool, arguments: ["-g", "-W", "-n", app.path]))
        XCTAssertTrue(openRes.ok, openRes.err)
        let captured = try String(contentsOf: probeOut, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(captured.hasSuffix("|\(sharedSavePath)"), "Expected Finder-launched process to inherit DM_SAVE, got: \(captured)")

        // Negative verification: updating save path re-signs and propagates new DM_SAVE on next Finder launch.
        let customSavePath = root.appendingPathComponent("custom-saves/\(totkTID)/save").path
        MngAppLaunchConfig.syncIfNeeded(
            appPath: app.path,
            titleID: totkTID,
            global: SaveGlobalSettings(),
            game: SaveGameOverride(saveFolder: customSavePath),
            support: support,
            isRunning: false,
            codesign: true
        )
        let openRes2 = SystemProcessRunner().capture(ProcessLaunch(executable: openTool, arguments: ["-g", "-W", "-n", app.path]))
        XCTAssertTrue(openRes2.ok, openRes2.err)
        let captured2 = try String(contentsOf: probeOut, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(captured2.hasSuffix("|\(customSavePath)"), "Expected updated LSEnvironment DM_SAVE, got: \(captured2)")
    }

    func testMigrationAllThreeScenariosPreserveBackups() throws {
        let uid = "bc947674f5e2b55ebbb6afdf0579d70b"
        let app = try makeBundle(name: "TOTK [MacNativeGames].app", titleID: totkTID, sharedMarker: true)
        let profileDir = support.appendingPathComponent("MacNativeGames/TOTK/profile", isDirectory: true)
        let mngUIDDir = profileDir.appendingPathComponent("save/\(uid)", isDirectory: true)
        let nxSaveDir = support.appendingPathComponent("nxnative/\(totkTID)/save", isDirectory: true)

        // 1. Neither side (or MNG empty): assessment == .none
        XCTAssertEqual(
            MngSaveMigration.assess(titleID: totkTID, appPath: app.path, global: SaveGlobalSettings(), game: SaveGameOverride(), support: support),
            .none
        )

        // 2. MNG has data, nxnative empty -> .mngOnly
        try write(profileDir.appendingPathComponent("users.txt"), content: "*\(uid)\tLocal\n")
        try write(mngUIDDir.appendingPathComponent("slot_00/progress.sav"), content: "mng-progress-v1")
        let onlyAssessment = MngSaveMigration.assess(
            titleID: totkTID, appPath: app.path, global: SaveGlobalSettings(), game: SaveGameOverride(), support: support
        )
        guard case .mngOnly(let src, let dst, let count, _) = onlyAssessment else {
            return XCTFail("Expected .mngOnly, got \(onlyAssessment)")
        }
        XCTAssertEqual(src.standardizedFileURL.path, mngUIDDir.standardizedFileURL.path)
        XCTAssertEqual(dst.standardizedFileURL.path, nxSaveDir.standardizedFileURL.path)
        XCTAssertEqual(count, 1)

        // Keeping nxnative leaves shared folder empty and preserves legacy MNG save untouched.
        let keepRes = try MngSaveMigration.execute(choice: .keepNxnative, assessment: onlyAssessment, gameRunning: false)
        XCTAssertEqual(keepRes.choice, .keepNxnative)
        XCTAssertFalse(fm.fileExists(atPath: nxSaveDir.appendingPathComponent("slot_00/progress.sav").path))
        XCTAssertTrue(fm.fileExists(atPath: mngUIDDir.appendingPathComponent("slot_00/progress.sav").path))

        // Importing MNG flattens `<uid>/` into shared DM_SAVE and keeps legacy MNG save untouched.
        let importRes = try MngSaveMigration.execute(choice: .importMNG, assessment: onlyAssessment, gameRunning: false)
        XCTAssertEqual(importRes.copiedFiles, 1)
        XCTAssertNil(importRes.backupURL)
        XCTAssertEqual(try String(contentsOf: nxSaveDir.appendingPathComponent("slot_00/progress.sav")), "mng-progress-v1")
        XCTAssertTrue(fm.fileExists(atPath: mngUIDDir.appendingPathComponent("slot_00/progress.sav").path))

        // 3. Both have saves -> .bothHaveSaves
        try write(mngUIDDir.appendingPathComponent("slot_00/progress.sav"), content: "mng-progress-v2")
        try write(nxSaveDir.appendingPathComponent("slot_00/progress.sav"), content: "nx-progress-v1")
        try write(nxSaveDir.deletingLastPathComponent().appendingPathComponent("save_device/dev.sav"), content: "nx-dev-v1")

        let bothAssessment = MngSaveMigration.assess(
            titleID: totkTID, appPath: app.path, global: SaveGlobalSettings(), game: SaveGameOverride(), support: support
        )
        guard case .bothHaveSaves(_, _, _, let mngFiles, _, let nxFiles, _) = bothAssessment else {
            return XCTFail("Expected .bothHaveSaves, got \(bothAssessment)")
        }
        XCTAssertEqual(mngFiles, 1)
        XCTAssertEqual(nxFiles, 2)

        // Running game must block migration without touching either save.
        XCTAssertThrowsError(try MngSaveMigration.execute(choice: .importMNG, assessment: bothAssessment, gameRunning: true)) { err in
            XCTAssertEqual(err as? MngSaveMigration.MigrationError, .gameRunning)
        }
        XCTAssertEqual(try String(contentsOf: nxSaveDir.appendingPathComponent("slot_00/progress.sav")), "nx-progress-v1")

        // Choosing keepNxnative preserves nxnative and leaves MNG legacy folder intact.
        _ = try MngSaveMigration.execute(choice: .keepNxnative, assessment: bothAssessment, gameRunning: false)
        XCTAssertEqual(try String(contentsOf: nxSaveDir.appendingPathComponent("slot_00/progress.sav")), "nx-progress-v1")
        XCTAssertEqual(try String(contentsOf: mngUIDDir.appendingPathComponent("slot_00/progress.sav")), "mng-progress-v2")

        // Choosing importMNG backs up existing nxnative (save + save_device) and keeps legacy MNG intact.
        let replaceRes = try MngSaveMigration.execute(choice: .importMNG, assessment: bothAssessment, gameRunning: false)
        let backup = try XCTUnwrap(replaceRes.backupURL)
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("save/slot_00/progress.sav")), "nx-progress-v1")
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("save_device/dev.sav")), "nx-dev-v1")
        XCTAssertEqual(try String(contentsOf: nxSaveDir.appendingPathComponent("slot_00/progress.sav")), "mng-progress-v2")
        XCTAssertFalse(fm.fileExists(atPath: nxSaveDir.deletingLastPathComponent().appendingPathComponent("save_device/dev.sav").path))
        XCTAssertTrue(fm.fileExists(atPath: mngUIDDir.appendingPathComponent("slot_00/progress.sav").path))
    }
}
