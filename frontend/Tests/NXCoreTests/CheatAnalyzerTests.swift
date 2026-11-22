import Foundation
import XCTest
@testable import NXCore

final class CheatAnalyzerTests: XCTestCase {
    func testMainFixupsMetadataParsesMainRxEndAndFallsBackToAlignedTextEnd() {
        let withRxEnd = """
        # PATCH_OFF\t0x1ea0000
        # TEXT_END\t0x12345
        # MAIN_RX_END\t0x14000
        # BUILD_ID\tcd57b23fa4bbad65803d9788c01821ee
        """
        let parsed = CheatMainFixupsMetadata.parse(withRxEnd)
        XCTAssertEqual(parsed.buildID, "CD57B23FA4BBAD65")
        XCTAssertEqual(parsed.mainRxEnd, 0x14000)

        let legacyOnlyTextEnd = """
        # TEXT_END\t0x10004
        # BUILD_ID\t1122334455667788aabbccddeeff0011
        """
        let legacy = CheatMainFixupsMetadata.parse(legacyOnlyTextEnd)
        XCTAssertEqual(legacy.buildID, "1122334455667788")
        XCTAssertEqual(legacy.mainRxEnd, 0x14000, "TEXT_END is rounded up to 16 KB page boundary")
    }

    func testTrampolinesMetadataParsesEntriesSitesAndIgnoresCaveOrMirrorRows() {
        let tsv = """
        # BUILD_ID\tCD57B23FA4BBAD65
        # MAIN_RX_END\t0x100000
        # SLOTS_USED\t2
        row_type\tname\tcheat_key\tkind\tslot_id\tvariant_mask\ttarget_off\tpatched_word\tkey_mask\tdetail
        entry\tMoon Jump\tMoon Jump\tbaked_conditional\t0\t0x1\t0x400\t0xd503201f\t0x202\t
        entry\tUnbaked Speed\tUnbaked Speed\tunbaked_code\t-1\t0x0\t0x800\t0x1e202800\t0x0\tprotected
        site\tMoon Jump\tMoon Jump\tbaked_conditional\t0\t0x1\t0x400\t0xd503201f\t0x202\t
        cave\tMasterCave\tMasterCave\tbaked_static\t-1\t0x0\t0x3000\t0xd503201f\t0x0\t
        mirror\tMasterCave\tMasterCave\tbaked_static\t-1\t0x0\t0x3100\t0x1000\t0x0\tsize=16
        """
        let meta = CheatTrampolineMetadata.parse(tsv)
        XCTAssertEqual(meta.buildID, "CD57B23FA4BBAD65")
        XCTAssertEqual(meta.mainRxEnd, 0x100000)
        XCTAssertEqual(meta.slotsUsed, 2)
        XCTAssertTrue(meta.isBaked(key: "Moon Jump"))
        XCTAssertFalse(meta.isBaked(key: "Unbaked Speed"))
        XCTAssertEqual(meta.record(forKey: "Moon Jump")?.keyMask, 0x202)
    }

    func testKeyMaskFormatsSwitchButtons() {
        XCTAssertEqual(CheatKeyMask.buttonNames(for: 0), [])
        XCTAssertNil(CheatKeyMask.formattedCombo(for: 0))
        // B (bit 1 = 0x2) + ZR (bit 9 = 0x200) -> 0x202
        XCTAssertEqual(CheatKeyMask.buttonNames(for: 0x202), ["B", "ZR"])
        XCTAssertEqual(CheatKeyMask.formattedCombo(for: 0x202), "B + ZR")
        // L (bit 6 = 0x40) + D-Up (bit 13 = 0x2000)
        XCTAssertEqual(CheatKeyMask.formattedCombo(for: 0x2040), "L + D-Up")
    }

    func testStaticAnalyzerClassifiesAllFourTiersAndPropagatesMasterDirtyRegisters() {
        let trampolines = CheatTrampolineMetadata.parse("""
        # BUILD_ID\tCD57B23FA4BBAD65
        # MAIN_RX_END\t0x100000
        row_type\tname\tcheat_key\tkind\tslot_id\tvariant_mask\ttarget_off\tpatched_word\tkey_mask\tdetail
        entry\tBaked Jump\tBaked Jump\tbaked_conditional\t0\t0x1\t0x400\t0xd503201f\t0x202\t
        """)

        let inputs: [CheatStaticAnalyzer.InputEntry] = [
            // 0: Data write in main .data (off = 0x180020 >= rxEnd 0x100000) -> dataReady
            .init(key: "Data HP", isMaster: false, isLabel: false, isBroken: false, words: [0x0400_0000, 0x0018_0020, 0x0000_03E7]),
            // 1: Baked conditional code write with Opcode 8 (ZR + B) -> codeBaked
            .init(key: "Baked Jump", isMaster: false, isLabel: false, isBroken: false, words: [0x8000_0202, 0x0400_0000, 0x0000_0400, 0xD503_201F, 0x2000_0000]),
            // 2: Unbaked code write (off = 0x800 < rxEnd 0x100000) with Opcode 8 (L) -> codeNeedsBake
            .init(key: "Unbaked Speed", isMaster: false, isLabel: false, isBroken: false, words: [0x8000_0040, 0x0400_0000, 0x0000_0800, 0x1E20_2800, 0x2000_0000]),
            // 3: Fixed non-zero heap offset (mem=1, reg=0 clean, rel=0x4200) -> fixedHeapWarning
            .init(key: "Fixed Heap Gold", isMaster: false, isLabel: false, isBroken: false, words: [0x0410_0000, 0x0000_4200, 0x000F_423F]),
            // 4: Pointer-resolved heap write (Opcode 5 loads reg0, then Opcode 0 writes heap+reg0+0x10) -> dataReady
            .init(key: "Pointer Heap HP", isMaster: false, isLabel: false, isBroken: false, words: [0x580F_0000, 0x0020_0000, 0x041F_0000, 0x0000_0010, 0x0000_03E7]),
        ]

        let analyzed = CheatStaticAnalyzer.analyze(
            entries: inputs,
            rxEnd: 0x100000,
            trampolines: trampolines,
            buildID: "CD57B23FA4BBAD65"
        )
        XCTAssertEqual(analyzed.map(\.capability), [.dataReady, .codeBaked, .codeNeedsBake, .fixedHeapWarning, .dataReady])
        XCTAssertEqual(analyzed[1].keyMask, 0x202)
        XCTAssertEqual(analyzed[2].keyMask, 0x40)
    }

    func testZingSectionMarkerDetectsStartAndEndSingleWords() {
        XCTAssertEqual(CheatStaticAnalyzer.zingSectionMarker(words: [0x2000_0000], isMaster: false, isBroken: false), true)
        XCTAssertEqual(CheatStaticAnalyzer.zingSectionMarker(words: [0x2000_0001], isMaster: false, isBroken: false), false)
        XCTAssertNil(CheatStaticAnalyzer.zingSectionMarker(words: [0x2000_0000], isMaster: true, isBroken: false))
        XCTAssertNil(CheatStaticAnalyzer.zingSectionMarker(words: [0x2000_0000, 0x0400_0000], isMaster: false, isBroken: false))
    }

    func testRepoLayoutSupportsCheatDirAndExistingCheatsDir() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nx-cheat-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let script = tmp.appendingPathComponent("scripts/build_ipa_from_nsp.py")
        try Data("ap.add_argument('--from-seed')\n".utf8).write(to: script)
        XCTAssertFalse(RepoLayout.supportsCheatDir(tmp.path))

        try Data("ap.add_argument('--cheat-dir')\n".utf8).write(to: script)
        XCTAssertTrue(RepoLayout.supportsCheatDir(tmp.path))

        let cheatsDir = tmp.appendingPathComponent("custom-cheats")
        try FileManager.default.createDirectory(at: cheatsDir, withIntermediateDirectories: true)
        XCTAssertNil(RepoLayout.existingCheatsDir(titleID: "010015100B514000", explicit: cheatsDir.path, home: tmp.path))

        try Data("[A]\n04000000 00100000 00000001\n".utf8).write(to: cheatsDir.appendingPathComponent("CD57B23FA4BBAD65.txt"))
        XCTAssertEqual(RepoLayout.existingCheatsDir(titleID: "010015100B514000", explicit: cheatsDir.path, home: tmp.path), cheatsDir.path)
    }
}
