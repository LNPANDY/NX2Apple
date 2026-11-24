import Foundation
import Testing
@testable import ShellHost
@testable import ShellUI

private struct FixedCheatPicker: CheatFilePicker {
    let outcome: CheatFilePickOutcome
    func pickCheatFileOutcome() async -> CheatFilePickOutcome { outcome }
}

@MainActor @Suite struct GameCheatsStoreTests {
    private let titleID = "0100000000010000"
    private let buildID = "CD57B23FA4BBAD65"

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nx-ios-cheats-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func parsesZingAndEdiZonSectionsFourTierCapabilitiesAndKeyMasks() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let fw = root.appendingPathComponent("DmGame.framework", isDirectory: true)
        let dm = fw.appendingPathComponent("dm", isDirectory: true)
        try FileManager.default.createDirectory(at: dm, withIntermediateDirectories: true)
        try Data("# BUILD_ID\t\(buildID)803d9788c01821ee\n# MAIN_RX_END\t0x100000\n".utf8)
            .write(to: dm.appendingPathComponent("main.fixups.tsv"))
        let trampolines = """
        # BUILD_ID\t\(buildID)
        # MAIN_RX_END\t0x100000
        row_type\tname\tcheat_key\tkind\tslot_id\tvariant_mask\ttarget_off\tpatched_word\tkey_mask\tdetail
        entry\tMoon Jump\tMoon Jump\tbaked_conditional\t0\t0x1\t0x400\t0xd503201f\t0x202\t
        site\tMoon Jump\tMoon Jump\tbaked_conditional\t0\t0x1\t0x400\t0xd503201f\t0x202\t
        """
        try Data(trampolines.utf8).write(to: dm.appendingPathComponent("cheat_trampolines.tsv"))

        let appFolder = root.appendingPathComponent("app", isDirectory: true)
        let store = GameCheatsStore(titleID: titleID, appFolder: appFolder, frameworkURL: fw)
        let cheatText = """
        [Player Stats]
        20000000
        [Infinite Health]
        04000000 00180020 000003E7
        [Max Rupees]
        04100000 00004200 000F423F
        [Player Stats End]
        20000001
        [--SectionStart:Movement--]
        [Moon Jump]
        80000202
        04000000 00000400 D503201F
        20000000
        [2x Speed]
        04000000 00000800 1E202800
        [--SectionEnd:Movement--]
        """
        _ = try store.saveCheatFile(data: Data(cheatText.utf8), targetBuildID: buildID, gameTitle: "Orbit Fixture")

        let snap = store.loadSnapshot(gameTitle: "Orbit Fixture")
        #expect(snap.buildID == buildID)
        #expect(snap.hasCurrentFile)
        #expect(snap.dataReadyCount == 1)
        #expect(snap.fixedHeapWarningCount == 1)
        #expect(snap.codeBakedCount == 1)
        #expect(snap.codeNeedsBakeCount == 1)

        let visible = snap.visibleEntries
        #expect(visible.map(\.name) == ["Infinite Health", "Max Rupees", "Moon Jump", "2x Speed"])
        #expect(visible.map(\.section) == ["Player Stats", "Player Stats", "Movement", "Movement"])
        #expect(visible.map(\.capability) == [.dataReady, .fixedHeapWarning, .codeBaked, .codeNeedsBake])
        #expect(visible[2].triggerKeys == ["B", "ZR"])
        #expect(visible[2].switchableOnIOS)
        #expect(!visible[3].switchableOnIOS)

        // Enabling dataReady + codeBaked persists to <BID>.enabled; codeNeedsBake cannot be persisted.
        _ = try store.setEntryEnabled(key: "Infinite Health", on: true, gameTitle: "Orbit Fixture")
        _ = try store.setEntryEnabled(key: "Moon Jump", on: true, gameTitle: "Orbit Fixture")
        let afterCodeAttempt = try store.setEntryEnabled(key: "2x Speed", on: true, gameTitle: "Orbit Fixture")
        #expect(afterCodeAttempt.visibleEntries.first(where: { $0.key == "Infinite Health" })?.enabled == true)
        #expect(afterCodeAttempt.visibleEntries.first(where: { $0.key == "Moon Jump" })?.enabled == true)
        #expect(afterCodeAttempt.visibleEntries.first(where: { $0.key == "2x Speed" })?.enabled == false)

        // Master toggle writes/removes .cheats-off-<TID>
        try store.setMaster(false)
        #expect(!store.masterOn)
        try store.setMaster(true)
        #expect(store.masterOn)
    }

    @Test func hostModelImportsMatchingAndBuildMismatchedFilesAndClearsFuseAlert() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let gamesRoot = root.appendingPathComponent("Games", isDirectory: true)
        let gameDir = gamesRoot.appendingPathComponent(titleID, isDirectory: true)
        let fw = gameDir.appendingPathComponent("DmGame.framework", isDirectory: true)
        let dm = fw.appendingPathComponent("dm", isDirectory: true)
        try FileManager.default.createDirectory(at: dm, withIntermediateDirectories: true)
        try Data("# BUILD_ID\t\(buildID)803d9788c01821ee\n# MAIN_RX_END\t0x100000\n".utf8)
            .write(to: dm.appendingPathComponent("main.fixups.tsv"))
        try Data("bin".utf8).write(to: fw.appendingPathComponent("DmGame"))
        let manifest = """
        {
          "schema": 1,
          "title_id": "\(titleID)",
          "name": "Orbit Fixture",
          "display_version": "1.0.0",
          "package_version": "65536",
          "modules": ["main"],
          "nro_count": 0,
          "chain": "b-3f9a2c",
          "loader": "FR",
          "framework": "DmGame.framework",
          "framework_executable": "DmGame",
          "image_marker": "dmgame_image_marker",
          "profile": "profile.tsv",
          "shader_map": "dm/shader_map.tsv",
          "launcher": "dm/launcher.json",
          "romfs_marker": "fixture.marker",
          "romfs_identity": "DMROMFSID1 fixture",
          "min_os": "26.0"
        }
        """
        try Data(manifest.utf8).write(to: gameDir.appendingPathComponent("game.manifest.json"))
        try Data("{\"sections\":[]}".utf8).write(to: gameDir.appendingPathComponent("launcher.json"))

        let appData = root.appendingPathComponent("appData", isDirectory: true)
        let config = ShellHostConfig(
            gamesRoot: gamesRoot,
            appDataRoot: appData,
            environment: HostEnvironment(chain: "b-3f9a2c"),
            defaults: TestDefaults.keyed("cheats-host-test"),
            sideloadCertBacking: InMemoryCertBacking()
        )
        let payload = Data("[HP]\n04000000 00180020 000003E7\n[Speed]\n04000000 00000800 1E202800\n".utf8)

        // 1. Mismatched filename prompts buildMismatch, then confirms and archives under current buildID.
        let mismatchModel = ShellHostModel(
            config: config,
            cheatPicker: FixedCheatPicker(outcome: .picked(data: payload, fileName: "AABBCCDDEEFF0011.txt")),
            shellSettings: ShellSettingsStore(defaults: TestDefaults.make("cheats-shell"))
        )
        let outcome = await mismatchModel.importCheatFileNow(for: titleID)
        guard case .buildMismatch(let fileBID, let expectedBID, let name, let token) = outcome else {
            Issue.record("Expected buildMismatch outcome, got \(outcome)")
            return
        }
        #expect(fileBID == "AABBCCDDEEFF0011")
        #expect(expectedBID == buildID)
        #expect(name == "AABBCCDDEEFF0011.txt")

        let confirmed = mismatchModel.confirmMismatchCheatImport(for: titleID, token: token)
        guard case .imported(let snapshot, let savedBID, let count) = confirmed else {
            Issue.record("Expected imported after confirm, got \(confirmed)")
            return
        }
        #expect(savedBID == buildID)
        #expect(count == 2)
        #expect(snapshot.dataReadyCount == 1)
        #expect(snapshot.codeNeedsBakeCount == 1)

        // 2. Simulate 30s crash guard trip and verify UI alert + dismiss clears receipt.
        let cheatsDir = appData.appendingPathComponent(titleID).appendingPathComponent("cheats")
        _ = mismatchModel.setCheatEntry(for: titleID, key: "HP", on: true)
        let fuse = CheatFuseGuard(titleID: titleID, folder: cheatsDir)
        _ = fuse.armBeforeLaunch(buildID: buildID)
        _ = fuse.recoverIfArmed()

        let trippedSnap = mismatchModel.loadCheatsSnapshot(for: titleID)
        #expect(trippedSnap.fuseAlert?.disabledItems == ["HP"])
        let clearedSnap = mismatchModel.dismissCheatFuseAlert(for: titleID)
        #expect(clearedSnap.fuseAlert == nil)
    }

    @Test func oversizedFilesAreRejectedBySaveAndSkippedByLoadSnapshot() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let fw = root.appendingPathComponent("DmGame0100000000010000.framework/dm")
        try FileManager.default.createDirectory(at: fw, withIntermediateDirectories: true)
        try "# BUILD_ID\tCD57B23FA4BBAD65\n# MAIN_RX_END\t0x100000\n".write(
            to: fw.appendingPathComponent("main.fixups.tsv"), atomically: true, encoding: .utf8
        )

        let cheatsDir = root.appendingPathComponent("cheats")
        try FileManager.default.createDirectory(at: cheatsDir, withIntermediateDirectories: true)
        let store = GameCheatsStore(
            titleID: "0100000000010000",
            cheatsFolder: cheatsDir,
            frameworkURL: root.appendingPathComponent("DmGame0100000000010000.framework")
        )

        let overLimit = Data(repeating: UInt8(ascii: "A"), count: GameCheatsStore.maxFileBytes + 64)
        #expect(throws: GameCheatsStore.StoreError.fileTooLarge) {
            _ = try store.saveCheatFile(data: overLimit, targetBuildID: "CD57B23FA4BBAD65", gameTitle: "Huge")
        }
        #expect(!FileManager.default.fileExists(atPath: cheatsDir.appendingPathComponent("CD57B23FA4BBAD65.txt").path))

        // If placed manually on disk, loadSnapshot skips reading it without OOM.
        try overLimit.write(to: cheatsDir.appendingPathComponent("CD57B23FA4BBAD65.txt"))
        let snap = store.loadSnapshot(gameTitle: "Huge")
        #expect(snap.hasCurrentFile)
        #expect(snap.entries.isEmpty)
    }

    @Test func setEntryEnabledDoesNotClobberUnmatchedBuildEnabledFile() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let cheatsDir = root.appendingPathComponent("cheats")
        try FileManager.default.createDirectory(at: cheatsDir, withIntermediateDirectories: true)
        try "[A]\n04000000 00180000 00000001\n".write(
            to: cheatsDir.appendingPathComponent("1111111111111111.txt"), atomically: true, encoding: .utf8
        )
        try "[B]\n04000000 00180004 00000001\n".write(
            to: cheatsDir.appendingPathComponent("2222222222222222.txt"), atomically: true, encoding: .utf8
        )
        try "A\n".write(
            to: cheatsDir.appendingPathComponent("1111111111111111.enabled"), atomically: true, encoding: .utf8
        )

        // Framework has no build ID and there are two .txt files -> ambiguous (hasCurrentFile == false).
        let store = GameCheatsStore(titleID: "0100000000010000", cheatsFolder: cheatsDir, frameworkURL: nil)
        let snap = try store.setEntryEnabled(key: "A", on: false, gameTitle: "Ambiguous")
        #expect(!snap.hasCurrentFile)
        // Must preserve existing 1111111111111111.enabled untouched.
        let preserved = try String(contentsOf: cheatsDir.appendingPathComponent("1111111111111111.enabled"), encoding: .utf8)
        #expect(preserved == "A\n")
    }

    @Test func parseLinksOnOffPairsAndKeepsUnpairedPatchOff() {
        let raw = Data("""
        [Speed - on]
        04000000 00180010 00000002
        [Speed - off]
        04000000 00180010 00000001
        [Orphan Restore]
        04000000 00180020 00000000
        """.utf8)
        let meta = """
        name\tkind\tpair\tsection\tonce\taction\taddress\ttype
        Orphan Restore\tpatch-off\t\t\t0\t\t\t
        """
        let parsed = GameCheatsStore.parse(raw, meta: meta)
        let names = parsed.map(\.name)
        #expect(names.contains("Speed - on"))
        #expect(!names.contains("Speed - off"))
        #expect(names.contains("Orphan Restore"))
    }

    @Test func edizonZeroPlaceholdersBecomeHiddenLabelsAndDecodeFailuresBecomeBroken() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let fw = root.appendingPathComponent("DmGame.framework", isDirectory: true)
        let dm = fw.appendingPathComponent("dm", isDirectory: true)
        try FileManager.default.createDirectory(at: dm, withIntermediateDirectories: true)
        try Data("# BUILD_ID\t\(buildID)\n# MAIN_RX_END\t0x100000\n".utf8)
            .write(to: dm.appendingPathComponent("main.fixups.tsv"))

        let appFolder = root.appendingPathComponent("app", isDirectory: true)
        let store = GameCheatsStore(titleID: titleID, appFolder: appFolder, frameworkURL: fw)
        let rawText = """
        [--SectionStart:ItemPoint Gain--]
        00000000 00000000 00000000
        [x2]
        040F0000 00351EA0 8B080936
        [--SectionEnd:ItemPoint Gain--]
        00000000 00000000 00000000
        [Truncated T0]
        04000000 00001000
        [Unknown FF0]
        80000040
        FF000000 00000001
        [All Zero Regular]
        00000000 00000000 00000000
        [--SectionStart:Real Code--]
        04000000 00180020 000003E7
        """
        _ = try store.saveCheatFile(data: Data(rawText.utf8), targetBuildID: buildID, gameTitle: "Orbit Fixture")
        let snap = store.loadSnapshot(gameTitle: "Orbit Fixture")

        #expect(snap.dataReadyCount == 2)
        #expect(snap.totalActiveCount == 2)

        let visible = snap.visibleEntries
        #expect(visible.map(\.name) == ["x2", "Truncated T0", "Unknown FF0", "All Zero Regular", "--SectionStart:Real Code--"])
        #expect(visible.map(\.isBroken) == [false, true, true, true, false])
        #expect(visible.map(\.switchableOnIOS) == [true, false, false, false, true])
        #expect(visible[2].triggerKeys.isEmpty)

        // Broken entries cannot be persisted into <BID>.enabled.
        let afterToggle = try store.setEntryEnabled(key: "Truncated T0", on: true, gameTitle: "Orbit Fixture")
        #expect(afterToggle.visibleEntries.first(where: { $0.key == "Truncated T0" })?.enabled == false)
        let summary = store.loadSummary(gameTitle: "Orbit Fixture")
        #expect(summary.totalCount == 2)
    }

    @Test func importRejectsFileWithOnlySectionPlaceholdersAndDecodeFailures() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let gamesRoot = root.appendingPathComponent("Games", isDirectory: true)
        let gameDir = gamesRoot.appendingPathComponent(titleID, isDirectory: true)
        let fw = gameDir.appendingPathComponent("DmGame.framework", isDirectory: true)
        let dm = fw.appendingPathComponent("dm", isDirectory: true)
        try FileManager.default.createDirectory(at: dm, withIntermediateDirectories: true)
        try Data("# BUILD_ID\t\(buildID)\n# MAIN_RX_END\t0x100000\n".utf8)
            .write(to: dm.appendingPathComponent("main.fixups.tsv"))
        try Data("bin".utf8).write(to: fw.appendingPathComponent("DmGame"))
        let manifest = """
        {
          "schema": 1,
          "title_id": "\(titleID)",
          "name": "Orbit Fixture",
          "display_version": "1.0.0",
          "package_version": "65536",
          "modules": ["main"],
          "nro_count": 0,
          "chain": "b-3f9a2c",
          "loader": "FR",
          "framework": "DmGame.framework",
          "framework_executable": "DmGame",
          "image_marker": "dmgame_image_marker",
          "profile": "profile.tsv",
          "shader_map": "dm/shader_map.tsv",
          "launcher": "dm/launcher.json",
          "romfs_marker": "fixture.marker",
          "romfs_identity": "DMROMFSID1 fixture",
          "min_os": "26.0"
        }
        """
        try Data(manifest.utf8).write(to: gameDir.appendingPathComponent("game.manifest.json"))
        try Data("{\"sections\":[]}".utf8).write(to: gameDir.appendingPathComponent("launcher.json"))

        let appData = root.appendingPathComponent("appData", isDirectory: true)
        let config = ShellHostConfig(
            gamesRoot: gamesRoot,
            appDataRoot: appData,
            environment: HostEnvironment(chain: "b-3f9a2c"),
            defaults: TestDefaults.keyed("cheats-bad-only-test"),
            sideloadCertBacking: InMemoryCertBacking()
        )
        let badOnly = Data("""
        [--SectionStart:Empty--]
        00000000 00000000 00000000
        [--SectionEnd:Empty--]
        00000000 00000000 00000000
        [Bad]
        FF000000 00000001
        """.utf8)
        let model = ShellHostModel(
            config: config,
            cheatPicker: FixedCheatPicker(outcome: .picked(data: badOnly, fileName: "\(buildID).txt")),
            shellSettings: ShellSettingsStore(defaults: TestDefaults.make("cheats-bad-only-shell"))
        )
        let outcome = await model.importCheatFileNow(for: titleID)
        guard case .failed = outcome else {
            Issue.record("Expected failed import for file with only section placeholders and malformed cheats, got \(outcome)")
            return
        }
    }
}
