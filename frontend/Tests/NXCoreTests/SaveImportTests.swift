import Darwin
import Foundation
import XCTest
@testable import NXCore

final class SaveImportTests: XCTestCase {
    private var root: URL!
    private let stardewTID = "0100E65002BB8000"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("save-import-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ url: URL, _ content: String = "data") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    private func buildPythonZip(at zipURL: URL, entries: [(name: String, data: Data, extAttr: UInt32)]) throws {
        let staging = root.appendingPathComponent("zip-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var manifest: [[String: Any]] = []
        for (idx, item) in entries.enumerated() {
            let p = staging.appendingPathComponent("p-\(idx).bin")
            try item.data.write(to: p)
            manifest.append(["name": item.name, "payload": p.path, "ext": item.extAttr])
        }
        let manifestURL = staging.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let script = """
        import json, sys, zipfile
        with open(sys.argv[1], "r", encoding="utf-8") as f:
            items = json.load(f)
        with zipfile.ZipFile(sys.argv[2], "w") as zf:
            for it in items:
                with open(it["payload"], "rb") as pf:
                    data = pf.read()
                zi = zipfile.ZipInfo(it["name"])
                zi.compress_type = zipfile.ZIP_DEFLATED
                if it["ext"]:
                    zi.external_attr = it["ext"]
                zf.writestr(zi, data)
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = ["-c", script, manifestURL.path, zipURL.path]
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)
    }

    // MARK: - Stardew Valley nested slot directories & extensionless files

    func testStardewSlotFolderAndExtensionlessFilesMergeWithoutLosingExistingFarm() throws {
        let save = root.appendingPathComponent("mac/save")
        try write(save.appendingPathComponent("OldFarm_111/OldFarm_111"), "<SaveGame>old</SaveGame>")
        try write(save.appendingPathComponent("OldFarm_111/SaveGameInfo"), "<Farmer>old</Farmer>")
        XCTAssertTrue(CloudSaveCheck.writeBase(save: save, hash: "0123456789abcdef0123456789abcdef"))

        let slotName = "Thiện Chương_335352527"
        let downloadRoot = root.appendingPathComponent("1RLtR8")
        let slotDir = downloadRoot.appendingPathComponent(slotName)
        let mainFile = slotDir.appendingPathComponent(slotName)
        let infoFile = slotDir.appendingPathComponent("SaveGameInfo")
        try write(downloadRoot.appendingPathComponent(".DS_Store"), "finder")
        try write(downloadRoot.appendingPathComponent("upload.farm_instructions.txt"), "instructions")
        try write(mainFile, "<SaveGame>stardew</SaveGame>")
        try write(infoFile, "<Farmer>stardew</Farmer>")

        // 1. Selecting the slot directory directly preserves `<slot>/` and recommends `.merge` when a save exists.
        let slotPlan = try SaveImport.preview([slotDir], expectedTitleID: stardewTID, into: save)
        XCTAssertEqual(slotPlan.kind, .slotFolder(name: slotName))
        XCTAssertEqual(slotPlan.recommendedMode, .merge)
        XCTAssertEqual(slotPlan.entries.map(\.displayPath).sorted(), [
            "save/\(slotName)/SaveGameInfo",
            "save/\(slotName)/\(slotName)",
        ])

        // 2. Selecting the two extensionless files inside the slot folder also keeps the parent slot directory name!
        let filesPlan = try SaveImport.preview([mainFile, infoFile], expectedTitleID: stardewTID, into: save)
        XCTAssertEqual(filesPlan.kind, .files(slotFolder: slotName))
        XCTAssertEqual(filesPlan.recommendedMode, .merge)
        XCTAssertEqual(filesPlan.entries.map(\.displayPath).sorted(), [
            "save/\(slotName)/SaveGameInfo",
            "save/\(slotName)/\(slotName)",
        ])

        // 3. Selecting a single extensionless file inside a non-slot folder places it at `save/<filename>`.
        let standalone = root.appendingPathComponent("plain/main_save")
        try write(standalone, "raw-bytes")
        let standalonePlan = try SaveImport.preview([standalone], expectedTitleID: stardewTID, into: save)
        XCTAssertEqual(standalonePlan.kind, .files(slotFolder: nil))
        XCTAssertEqual(standalonePlan.entries.map(\.displayPath), ["save/main_save"])

        // 4. Merging preserves OldFarm_111, backs up before import, clears .sync, and adds the new farm slot.
        let backup = try XCTUnwrap(
            try SaveImport.execute(filesPlan, into: save, mode: .merge, gameRunning: false, now: Date(timeIntervalSince1970: 1_700_000_000), volumeHolds: { _ in true })
        )
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("save/OldFarm_111/OldFarm_111")), "<SaveGame>old</SaveGame>")
        XCTAssertEqual(try String(contentsOf: save.appendingPathComponent("OldFarm_111/OldFarm_111")), "<SaveGame>old</SaveGame>")
        XCTAssertEqual(try String(contentsOf: save.appendingPathComponent("\(slotName)/\(slotName)")), "<SaveGame>stardew</SaveGame>")
        XCTAssertEqual(try String(contentsOf: save.appendingPathComponent("\(slotName)/SaveGameInfo")), "<Farmer>stardew</Farmer>")
        XCTAssertNil(CloudSaveCheck.base(save: save))

        // 5. Selecting the outer download folder `1RLtR8` ignores `.DS_Store` and preserves the slot folder structure.
        let outerPlan = try SaveImport.preview([downloadRoot], expectedTitleID: stardewTID, into: save)
        XCTAssertEqual(outerPlan.kind, .folder)
        XCTAssertFalse(outerPlan.entries.contains { $0.relativePath.contains(".DS_Store") })
        XCTAssertTrue(outerPlan.entries.contains { $0.relativePath == "\(slotName)/\(slotName)" })
    }

    // MARK: - Plain ZIP vs JKSV ZIP auto-detection & Title ID guard

    func testPlainZipUnwrapsOuterContainerWhilePreservingSlotFolderAndDetectsJKSV() throws {
        let save = root.appendingPathComponent("zip/save")
        try write(save.appendingPathComponent("Existing_1/Existing_1"), "existing")

        let slotName = "Thien_335352527"
        // Plain ZIP with outer wrapper container `1RLtR8/` around a Stardew slot directory.
        let wrappedZip = root.appendingPathComponent("1RLtR8.zip")
        try buildPythonZip(at: wrappedZip, entries: [
            ("1RLtR8/.DS_Store", Data("junk".utf8), 0),
            ("1RLtR8/\(slotName)/\(slotName)", Data("main".utf8), 0),
            ("1RLtR8/\(slotName)/SaveGameInfo", Data("info".utf8), 0),
        ])
        let wrappedPlan = try SaveImport.preview([wrappedZip], expectedTitleID: stardewTID, into: save)
        XCTAssertEqual(wrappedPlan.kind, .zip)
        XCTAssertEqual(wrappedPlan.recommendedMode, .merge)
        XCTAssertEqual(wrappedPlan.entries.map(\.displayPath).sorted(), [
            "save/\(slotName)/SaveGameInfo",
            "save/\(slotName)/\(slotName)",
        ])

        // Plain ZIP where the slot directory itself is the sole top-level entry must NOT be stripped.
        let directSlotZip = root.appendingPathComponent("slot.zip")
        try buildPythonZip(at: directSlotZip, entries: [
            ("\(slotName)/\(slotName)", Data("main".utf8), 0),
            ("\(slotName)/SaveGameInfo", Data("info".utf8), 0),
        ])
        let directPlan = try SaveImport.preview([directSlotZip], expectedTitleID: stardewTID, into: save)
        XCTAssertEqual(directPlan.recommendedMode, .merge)
        XCTAssertEqual(directPlan.entries.map(\.displayPath).sorted(), [
            "save/\(slotName)/SaveGameInfo",
            "save/\(slotName)/\(slotName)",
        ])

        // JKSV ZIP with matching Title ID succeeds and identifies itself as `.jksvZip`.
        let tidNum = try XCTUnwrap(UInt64(stardewTID, radix: 16))
        let goodMeta = JKSVArchive.Meta(titleID: tidNum, saveType: 1).encode()
        let jksvZip = root.appendingPathComponent("jksv-good.zip")
        try buildPythonZip(at: jksvZip, entries: [
            (".nx_save_meta.bin", goodMeta, 0),
            ("\(slotName)/\(slotName)", Data("jksv-main".utf8), 0),
        ])
        let jksvPlan = try SaveImport.preview([jksvZip], expectedTitleID: stardewTID, into: save)
        XCTAssertEqual(jksvPlan.kind, .jksvZip(titleID: stardewTID))

        _ = try SaveImport.execute(jksvPlan, into: save, mode: .merge, gameRunning: false, volumeHolds: { _ in true })
        XCTAssertEqual(try String(contentsOf: save.appendingPathComponent("Existing_1/Existing_1")), "existing")
        XCTAssertEqual(try String(contentsOf: save.appendingPathComponent("\(slotName)/\(slotName)")), "jksv-main")

        // JKSV ZIP with mismatched Title ID is rejected upfront.
        let wrongMeta = JKSVArchive.Meta(titleID: 0x0100_9999_0000_0000, saveType: 1).encode()
        let wrongZip = root.appendingPathComponent("jksv-wrong.zip")
        try buildPythonZip(at: wrongZip, entries: [
            (".nx_save_meta.bin", wrongMeta, 0),
            ("slot.bin", Data("x".utf8), 0),
        ])
        XCTAssertThrowsError(try SaveImport.preview([wrongZip], expectedTitleID: stardewTID, into: save)) { err in
            XCTAssertEqual(err as? SaveImportFailure, .titleIDMismatch(expected: stardewTID, found: "0100999900000000"))
        }
    }

    // MARK: - Symlink, path traversal, quota, running guard & rollback

    func testSecurityGuardsRejectSymlinksUnsafePathsQuotaAndRestoreOnMidSwapFault() throws {
        let save = root.appendingPathComponent("sec/save")
        try write(save.appendingPathComponent("keep.sav"), "precious")

        // 1. Symlink file selected directly is rejected.
        let secret = root.appendingPathComponent("secret.txt")
        try write(secret, "secret")
        let linkFile = root.appendingPathComponent("evil_link")
        try FileManager.default.createSymbolicLink(at: linkFile, withDestinationURL: secret)
        XCTAssertThrowsError(try SaveImport.preview([linkFile], expectedTitleID: stardewTID, into: save)) { err in
            XCTAssertEqual(err as? SaveImportFailure, .symlinkNotAllowed("evil_link"))
        }

        // 2. Symlink nested inside an imported directory is rejected.
        let dirWithLink = root.appendingPathComponent("dir-link")
        try write(dirWithLink.appendingPathComponent("ok.bin"), "ok")
        try FileManager.default.createDirectory(at: dirWithLink.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dirWithLink.appendingPathComponent("sub/escape"), withDestinationURL: secret)
        XCTAssertThrowsError(try SaveImport.preview([dirWithLink], expectedTitleID: stardewTID, into: save)) { err in
            XCTAssertEqual(err as? SaveImportFailure, .symlinkNotAllowed("sub/escape"))
        }

        // 3. Running game and mid-swap fault leave existing save completely intact.
        let validFile = root.appendingPathComponent("good/slot.sav")
        try write(validFile, "new-data")
        let plan = try SaveImport.preview([validFile], expectedTitleID: stardewTID, into: save)
        XCTAssertThrowsError(try SaveImport.execute(plan, into: save, mode: .replace, gameRunning: true, volumeHolds: { _ in true })) { err in
            XCTAssertEqual(err as? SaveImportFailure, .gameRunning)
        }
        XCTAssertThrowsError(
            try SaveImport.execute(plan, into: save, mode: .replace, gameRunning: false, volumeHolds: { _ in true }, faultHook: { phase in
                if phase == "afterMoveIncoming" { throw CocoaError(.fileWriteOutOfSpace) }
            })
        )
        XCTAssertEqual(try String(contentsOf: save.appendingPathComponent("keep.sav")), "precious")

        // 4. Quota limit rejects oversized entries in ZIP preflight.
        let bigZip = root.appendingPathComponent("big.zip")
        try buildPythonZip(at: bigZip, entries: [("save/a.bin", Data("small".utf8), 0)])
        var raw = try Data(contentsOf: bigZip)
        let sig = Data([0x50, 0x4B, 0x01, 0x02])
        let cdIdx = try XCTUnwrap(raw.range(of: sig, options: .backwards)).lowerBound
        var bigSize = UInt32(600 * 1024 * 1024).littleEndian
        raw.replaceSubrange((cdIdx + 24)..<(cdIdx + 28), with: Data(bytes: &bigSize, count: 4))
        try raw.write(to: bigZip)
        XCTAssertThrowsError(try SaveImport.preview([bigZip], expectedTitleID: stardewTID, into: save)) { err in
            XCTAssertEqual(err as? SaveImportFailure, .quotaExceeded)
        }

        // 5. Multiple ZIPs in one selection is rejected cleanly.
        let zip2 = root.appendingPathComponent("second.zip")
        try buildPythonZip(at: zip2, entries: [("save/b.bin", Data("b".utf8), 0)])
        XCTAssertThrowsError(try SaveImport.preview([validFile, zip2], expectedTitleID: stardewTID, into: save)) { err in
            XCTAssertEqual(err as? SaveImportFailure, .multipleArchivesNotAllowed)
        }
    }
}
