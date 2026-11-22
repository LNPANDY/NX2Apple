import Compression
import Darwin
import Foundation
import XCTest
@testable import NXCore

final class JKSVArchiveTests: XCTestCase {
    private var root: URL!
    private let titleID = "0100ABCDEF000000"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("jksv-archive-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers using real Python zipfile generator

    private func buildPythonZip(
        at zipURL: URL,
        entries: [(name: String, data: Data, compress: Bool, externalAttr: UInt32)],
        tamperScript: String? = nil
    ) throws {
        let staging = root.appendingPathComponent("py-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var manifest: [[String: Any]] = []
        for (idx, item) in entries.enumerated() {
            let payloadFile = staging.appendingPathComponent("payload-\(idx).bin")
            try item.data.write(to: payloadFile)
            manifest.append([
                "name": item.name,
                "payload": payloadFile.path,
                "compress": item.compress,
                "ext": item.externalAttr
            ])
        }
        let manifestURL = staging.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)

        let script = """
        import json, sys, zipfile
        manifest_path, zip_path = sys.argv[1], sys.argv[2]
        with open(manifest_path, "r", encoding="utf-8") as f:
            items = json.load(f)
        with zipfile.ZipFile(zip_path, "w") as zf:
            for it in items:
                with open(it["payload"], "rb") as pf:
                    data = pf.read()
                zi = zipfile.ZipInfo(it["name"])
                zi.compress_type = zipfile.ZIP_DEFLATED if it["compress"] else zipfile.ZIP_STORED
                if it["ext"]:
                    zi.external_attr = it["ext"]
                zf.writestr(zi, data)
        \(tamperScript ?? "")
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = ["-c", script, manifestURL.path, zipURL.path]
        let err = Pipe()
        proc.standardError = err
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTFail("python3 zip builder failed: \(msg)")
        }
    }

    private func pythonLiteral(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(data: data, encoding: .utf8)!
    }

    // MARK: - Round-trip, Python zipfile interop, metadata & .sync clearing

    func testJKSVImportExportRoundTripAndBaseClearing() throws {
        let save = root.appendingPathComponent("local/save")
        try FileManager.default.createDirectory(at: save, withIntermediateDirectories: true)
        try Data("old-progress".utf8).write(to: save.appendingPathComponent("old.sav"))
        XCTAssertTrue(CloudSaveCheck.writeBase(save: save, hash: "0123456789abcdef0123456789abcdef"))

        let tidNum = try XCTUnwrap(UInt64(titleID, radix: 16))
        let meta = JKSVArchive.Meta(titleID: tidNum, saveType: 1).encode()
        XCTAssertEqual(meta.count, 86)

        let incomingZip = root.appendingPathComponent("jksv-in.zip")
        try buildPythonZip(at: incomingZip, entries: [
            (".nx_save_meta.bin", meta, false, 0),
            ("slot0/main.dat", Data(repeating: 0x4A, count: 4096), true, 0),
            ("empty.bin", Data(), false, 0),
            ("info/名.txt", Data("utf8-save".utf8), true, 0),
        ])

        let preview = try JKSVArchive.preview(incomingZip, expectedTitleID: titleID)
        XCTAssertEqual(preview.fileCount, 3)
        XCTAssertEqual(preview.meta?.formattedTitleID, titleID)
        XCTAssertEqual(preview.folders, ["save"])

        let backup = try XCTUnwrap(try JKSVArchive.import(preview, into: save, gameRunning: false))
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("save/old.sav")), Data("old-progress".utf8))
        // .nx_save_meta.bin must NOT be written into save/!
        XCTAssertFalse(FileManager.default.fileExists(atPath: save.appendingPathComponent(".nx_save_meta.bin").path))
        XCTAssertEqual(try Data(contentsOf: save.appendingPathComponent("slot0/main.dat")), Data(repeating: 0x4A, count: 4096))
        XCTAssertEqual(try Data(contentsOf: save.appendingPathComponent("empty.bin")), Data())
        XCTAssertEqual(try Data(contentsOf: save.appendingPathComponent("info/名.txt")), Data("utf8-save".utf8))
        // .sync base MUST be cleared so next cloud sync pushes the imported Switch save.
        XCTAssertNil(CloudSaveCheck.base(save: save))

        // Export back to JKSV .zip and validate with Python's zipfile.ZipFile.testzip().
        let exportedZip = root.appendingPathComponent("jksv-out.zip")
        let exported = try JKSVArchive.export(save: save, titleID: titleID, to: exportedZip)
        XCTAssertEqual(exported.files, 3)

        let verifyScript = """
        import zipfile
        with zipfile.ZipFile(\(pythonLiteral(exportedZip.path)), "r") as zf:
            assert zf.testzip() is None
            names = sorted(zf.namelist())
            assert ".nx_save_meta.bin" in names
            meta = zf.read(".nx_save_meta.bin")
            assert len(meta) == 86 and meta[:4] == b"JKSV" and meta[4] == 1
            assert int.from_bytes(meta[5:13], "little") == \(tidNum)
            assert meta[37] == 1
            assert zf.read("slot0/main.dat") == b"J" * 4096
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = ["-c", verifyScript]
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0, "Exported ZIP failed Python zipfile validation")
    }

    func testJKSVDeviceSaveTypeAndTitleIDMismatchNegative() throws {
        let otherTID: UInt64 = 0x0100_9999_8888_0000
        let wrongMeta = JKSVArchive.Meta(titleID: otherTID, saveType: 1).encode()
        let wrongZip = root.appendingPathComponent("wrong-game.zip")
        try buildPythonZip(at: wrongZip, entries: [
            (".nx_save_meta.bin", wrongMeta, false, 0),
            ("save.bin", Data("x".utf8), false, 0),
        ])

        XCTAssertThrowsError(try JKSVArchive.preview(wrongZip, expectedTitleID: titleID)) { error in
            XCTAssertEqual(error as? JKSVArchive.Failure, .titleIDMismatch(expected: titleID, found: "0100999988880000"))
        }

        // save_type == 3 with title_id == 0 and meta placed inside save/ must succeed without stripping save/.
        let devMeta = JKSVArchive.Meta(titleID: 0, saveType: 3).encode()
        let devZip = root.appendingPathComponent("device-save.zip")
        try buildPythonZip(at: devZip, entries: [
            ("save/.nx_save_meta.bin", devMeta, false, 0),
            ("save/nested.bin", Data("nested".utf8), true, 0),
            ("device.bin", Data("devdata".utf8), true, 0),
        ])
        let save = root.appendingPathComponent("local/save")
        let preview = try JKSVArchive.preview(devZip, expectedTitleID: titleID)
        XCTAssertEqual(preview.folders, ["save", "save_device"])
        _ = try JKSVArchive.import(preview, into: save, gameRunning: false)
        XCTAssertEqual(try Data(contentsOf: save.appendingPathComponent("nested.bin")), Data("nested".utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: save.path + "_device/device.bin")), Data("devdata".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: save.path))
    }

    // MARK: - APFS case collision (.dm-case-N + guest-name xattr)

    func testCaseCollisionProducesDmCaseAndRestoresOnExport() throws {
        let collisionZip = root.appendingPathComponent("case-collision.zip")
        try buildPythonZip(at: collisionZip, entries: [
            ("save/Profile.dat", Data("upper".utf8), false, 0),
            ("save/profile.dat", Data("lower".utf8), false, 0),
            ("save/Dir/item.bin", Data("dirA".utf8), false, 0),
            ("save/dir/item.bin", Data("dirB".utf8), false, 0),
        ])

        let save = root.appendingPathComponent("case/save")
        let preview = try JKSVArchive.preview(collisionZip, expectedTitleID: titleID)
        _ = try JKSVArchive.import(preview, into: save, gameRunning: false)

        // Both physical files must exist without overwriting each other!
        XCTAssertEqual(try Data(contentsOf: save.appendingPathComponent("Profile.dat")), Data("upper".utf8))
        XCTAssertEqual(try Data(contentsOf: save.appendingPathComponent(".dm-case-1")), Data("lower".utf8))

        var buf = [UInt8](repeating: 0, count: 256)
        let gl = getxattr(save.appendingPathComponent(".dm-case-1").path, "org.d2rmobile.guest-name", &buf, buf.count, 0, XATTR_NOFOLLOW)
        XCTAssertEqual(String(bytes: buf.prefix(Int(max(0, gl))), encoding: .utf8), "profile.dat")

        // Export back to ZIP and verify both exact-case names are restored cleanly!
        let reexportZip = root.appendingPathComponent("case-out.zip")
        let exported = try JKSVArchive.export(save: save, titleID: titleID, to: reexportZip)
        XCTAssertEqual(exported.files, 4)

        let verifyScript = """
        import zipfile
        with zipfile.ZipFile(\(pythonLiteral(reexportZip.path)), "r") as zf:
            names = set(zf.namelist())
            assert "Profile.dat" in names and "profile.dat" in names
            assert "Dir/item.bin" in names and "dir/item.bin" in names
            assert zf.read("Profile.dat") == b"upper"
            assert zf.read("profile.dat") == b"lower"
            assert zf.read("Dir/item.bin") == b"dirA"
            assert zf.read("dir/item.bin") == b"dirB"
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = ["-c", verifyScript]
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)
    }

    // MARK: - Archive security negative tests

    func testUnsafePathsAndSymlinksRejectedInPreflight() throws {
        let badPaths = [
            "../escape.sav",
            "save/../../escape.sav",
            "/etc/passwd",
            "\\windows\\evil.sav",
            "C:drive.sav",
        ]
        for (i, path) in badPaths.enumerated() {
            let zipURL = root.appendingPathComponent("bad-\(i).zip")
            try buildPythonZip(at: zipURL, entries: [(path, Data("evil".utf8), false, 0)])
            XCTAssertThrowsError(try JKSVArchive.preview(zipURL, expectedTitleID: titleID), "Path should fail: \(path)") { err in
                XCTAssertEqual(err as? JKSVArchive.Failure, .unsafePath(path))
            }
        }

        // Symlink entry via Unix external_attr (S_IFLNK = 0o120000 << 16).
        let symlinkZip = root.appendingPathComponent("symlink.zip")
        let symlinkAttr = UInt32(0o120777) << 16
        try buildPythonZip(at: symlinkZip, entries: [("save/link", Data("/etc/passwd".utf8), false, symlinkAttr)])
        XCTAssertThrowsError(try JKSVArchive.preview(symlinkZip, expectedTitleID: titleID)) { err in
            XCTAssertEqual(err as? JKSVArchive.Failure, .symlinkNotAllowed("save/link"))
        }
    }

    func testQuotaAndDecompressionBombRejected() throws {
        // 1. Central directory claiming uncompressedSize > maxTotalBytes.
        let bombHeaderZip = root.appendingPathComponent("bomb-header.zip")
        try buildPythonZip(
            at: bombHeaderZip,
            entries: [("save/big.bin", Data("small".utf8), false, 0)],
            tamperScript: """
            raw = bytearray(open(\(pythonLiteral(bombHeaderZip.path)), "rb").read())
            # Patch CD entry uncompressed size to 600 MB
            cd_sig = raw.rfind(b"PK\\x01\\x02")
            raw[cd_sig + 24 : cd_sig + 28] = (600 * 1024 * 1024).to_bytes(4, "little")
            open(\(pythonLiteral(bombHeaderZip.path)), "wb").write(raw)
            """
        )
        XCTAssertThrowsError(try JKSVArchive.preview(bombHeaderZip, expectedTitleID: titleID)) { err in
            XCTAssertEqual(err as? JKSVArchive.Failure, .quotaExceeded)
        }

        // 2. Lying header: deflate payload actually expands to > declared uncompressedSize!
        let lyingZip = root.appendingPathComponent("bomb-lying.zip")
        let hugeZeros = Data(repeating: 0, count: 64 * 1024)
        try buildPythonZip(
            at: lyingZip,
            entries: [("save/lying.bin", hugeZeros, true, 0)],
            tamperScript: """
            raw = bytearray(open(\(pythonLiteral(lyingZip.path)), "rb").read())
            cd_sig = raw.rfind(b"PK\\x01\\x02")
            raw[cd_sig + 24 : cd_sig + 28] = (16).to_bytes(4, "little")
            open(\(pythonLiteral(lyingZip.path)), "wb").write(raw)
            """
        )
        let preview = try JKSVArchive.preview(lyingZip, expectedTitleID: titleID)
        let save = root.appendingPathComponent("bomb/save")
        XCTAssertThrowsError(try JKSVArchive.import(preview, into: save, gameRunning: false)) { err in
            XCTAssertEqual(err as? JKSVArchive.Failure, .quotaExceeded)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: save.path))
    }

    func testRunningGamePendingPullAndMidSwapFailureSafety() throws {
        let validZip = root.appendingPathComponent("valid.zip")
        try buildPythonZip(at: validZip, entries: [("slot.bin", Data("new".utf8), false, 0)])
        let preview = try JKSVArchive.preview(validZip, expectedTitleID: titleID)

        let save = root.appendingPathComponent("guard/save")
        try FileManager.default.createDirectory(at: save, withIntermediateDirectories: true)
        try Data("orig".utf8).write(to: save.appendingPathComponent("slot.bin"))

        // 1. Running game refuses import.
        XCTAssertThrowsError(try JKSVArchive.import(preview, into: save, gameRunning: true)) { err in
            XCTAssertEqual(err as? JKSVArchive.Failure, .gameRunning)
        }

        // 2. Pending .pull journal refuses import.
        let pullPath = save.path + ".pull"
        try Data("kept\t/tmp\n".utf8).write(to: URL(fileURLWithPath: pullPath))
        XCTAssertThrowsError(try JKSVArchive.import(preview, into: save, gameRunning: false)) { err in
            XCTAssertEqual(err as? JKSVArchive.Failure, .pendingPullJournal)
        }
        try FileManager.default.removeItem(atPath: pullPath)

        // 3. Simulated mid-swap failure restores original save untouched!
        XCTAssertThrowsError(
            try JKSVArchive.import(preview, into: save, gameRunning: false, faultHook: { phase in
                if phase == "afterMoveIncoming" {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
            })
        )
        XCTAssertEqual(try Data(contentsOf: save.appendingPathComponent("slot.bin")), Data("orig".utf8))
    }
}
