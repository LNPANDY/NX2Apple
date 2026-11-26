import Compression
import Darwin
import Foundation
import Testing
@testable import ShellHost
@testable import ShellUI

@Suite struct SaveArchiveServiceTests {
    private let titleID = Fixtures.orbit

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("save-archive-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Pure-Swift test ZIP builder supporting custom external attributes, raw/deflate payloads, and Central Directory tampering
    /// so all archive security & interop tests run natively on both macOS and iOS Simulator.
    private func buildTestZip(
        at zipURL: URL,
        entries: [(name: String, data: Data, compress: Bool, externalAttr: UInt32)],
        tamperLastCDUncompressedSize: UInt32? = nil
    ) throws {
        var out = Data()
        struct Record {
            let nameBytes: [UInt8]
            let method: UInt16
            let crc: UInt32
            let compSize: UInt32
            let uncompSize: UInt32
            let extAttr: UInt32
            let offset: UInt32
        }
        var records: [Record] = []

        for item in entries {
            let nameBytes = Array(item.name.utf8)
            let crc = testCRC32(item.data)
            let payload: Data
            let method: UInt16
            if item.compress, let deflated = testDeflateRaw(item.data) {
                payload = deflated
                method = 8
            } else {
                payload = item.data
                method = 0
            }
            let localOffset = UInt32(out.count)
            var lfh = [UInt8](repeating: 0, count: 30)
            putLE32(0x0403_4b50, into: &lfh, at: 0)
            putLE16(20, into: &lfh, at: 4)
            putLE16(0x0800, into: &lfh, at: 6)
            putLE16(method, into: &lfh, at: 8)
            putLE32(crc, into: &lfh, at: 14)
            putLE32(UInt32(payload.count), into: &lfh, at: 18)
            putLE32(UInt32(item.data.count), into: &lfh, at: 22)
            putLE16(UInt16(nameBytes.count), into: &lfh, at: 26)
            out.append(contentsOf: lfh)
            out.append(contentsOf: nameBytes)
            out.append(payload)

            let extAttr = item.externalAttr != 0 ? item.externalAttr : (UInt32(0o100644) << 16)
            records.append(Record(
                nameBytes: nameBytes,
                method: method,
                crc: crc,
                compSize: UInt32(payload.count),
                uncompSize: UInt32(item.data.count),
                extAttr: extAttr,
                offset: localOffset
            ))
        }

        let cdOffset = UInt32(out.count)
        var cdSize: UInt32 = 0
        for (idx, rec) in records.enumerated() {
            let uncomp = (idx == records.count - 1 ? tamperLastCDUncompressedSize : nil) ?? rec.uncompSize
            var cdh = [UInt8](repeating: 0, count: 46)
            putLE32(0x0201_4b50, into: &cdh, at: 0)
            putLE16(0x031E, into: &cdh, at: 4)
            putLE16(20, into: &cdh, at: 6)
            putLE16(0x0800, into: &cdh, at: 8)
            putLE16(rec.method, into: &cdh, at: 10)
            putLE32(rec.crc, into: &cdh, at: 16)
            putLE32(rec.compSize, into: &cdh, at: 20)
            putLE32(uncomp, into: &cdh, at: 24)
            putLE16(UInt16(rec.nameBytes.count), into: &cdh, at: 28)
            putLE32(rec.extAttr, into: &cdh, at: 38)
            putLE32(rec.offset, into: &cdh, at: 42)
            out.append(contentsOf: cdh)
            out.append(contentsOf: rec.nameBytes)
            cdSize += UInt32(46 + rec.nameBytes.count)
        }

        var eocd = [UInt8](repeating: 0, count: 22)
        putLE32(0x0605_4b50, into: &eocd, at: 0)
        putLE16(UInt16(records.count), into: &eocd, at: 8)
        putLE16(UInt16(records.count), into: &eocd, at: 10)
        putLE32(cdSize, into: &eocd, at: 12)
        putLE32(cdOffset, into: &eocd, at: 16)
        out.append(contentsOf: eocd)
        try out.write(to: zipURL)
    }

    #if os(macOS)
    private func pythonLiteral(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(data: data, encoding: .utf8)!
    }

    private func runPythonScript(_ script: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = ["-c", script]
        let err = Pipe()
        proc.standardError = err
        try proc.run()
        proc.waitUntilExit()
        #expect(proc.terminationStatus == 0, "python3 failed: \(String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")")
    }
    #endif

    // MARK: - Format support: Folder, JKSV .zip, standard .zip, single extensionless file

    @Test func folderImportSupportsSaveSubfoldersAndUnzippedJKSV() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let appFolder = root.appendingPathComponent("app", isDirectory: true)
        let sourceDir = root.appendingPathComponent("picked-folder", isDirectory: true)
        let saveSub = sourceDir.appendingPathComponent("save/FarmA_111", isDirectory: true)
        let devSub = sourceDir.appendingPathComponent("save_device", isDirectory: true)
        try FileManager.default.createDirectory(at: saveSub, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: devSub, withIntermediateDirectories: true)
        try Data("farm-a".utf8).write(to: saveSub.appendingPathComponent("FarmA_111"))
        try Data("info-a".utf8).write(to: saveSub.appendingPathComponent("SaveGameInfo"))
        try Data("dev".utf8).write(to: devSub.appendingPathComponent("device.bin"))

        let preview = try SaveArchiveService.preview(sourceDir, expectedTitleID: titleID)
        #expect(preview.sourceKind == .folder)
        #expect(preview.fileCount == 3)
        #expect(preview.folders == ["save", "save_device"])

        let backup = try SaveArchiveService.performImport(preview, into: appFolder, mode: .replace, gameRunning: false)
        #expect(backup == nil)
        #expect(try Data(contentsOf: appFolder.appendingPathComponent("save/FarmA_111/FarmA_111")) == Data("farm-a".utf8))
        #expect(try Data(contentsOf: appFolder.appendingPathComponent("save/FarmA_111/SaveGameInfo")) == Data("info-a".utf8))
        #expect(try Data(contentsOf: appFolder.appendingPathComponent("save_device/device.bin")) == Data("dev".utf8))

        // Unzipped JKSV folder with mismatched .nx_save_meta.bin must be blocked.
        let badFolder = root.appendingPathComponent("unzipped-jksv-wrong", isDirectory: true)
        try FileManager.default.createDirectory(at: badFolder, withIntermediateDirectories: true)
        try SaveArchiveService.Meta(titleID: 0x0100_9999_8888_0000, saveType: 1).encode()
            .write(to: badFolder.appendingPathComponent(SaveArchiveService.metaFileName))
        try Data("x".utf8).write(to: badFolder.appendingPathComponent("slot.dat"))

        #expect(throws: SaveArchiveFailure.titleIDMismatch(expected: titleID, found: "0100999988880000")) {
            _ = try SaveArchiveService.preview(badFolder, expectedTitleID: titleID)
        }
    }

    @Test func standardZipAndSingleExtensionlessStardewFileImport() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let appFolder = root.appendingPathComponent("app", isDirectory: true)
        let pcZip = root.appendingPathComponent("1RLtR8.zip")
        try buildTestZip(at: pcZip, entries: [
            ("ThienChuong_335352527/ThienChuong_335352527", Data("stardew-main".utf8), true, 0),
            ("ThienChuong_335352527/SaveGameInfo", Data("stardew-info".utf8), true, 0),
        ])

        let zipPreview = try SaveArchiveService.preview(pcZip, expectedTitleID: titleID)
        #expect(zipPreview.sourceKind == .zipArchive)
        #expect(zipPreview.meta == nil)
        #expect(zipPreview.fileCount == 2)
        _ = try SaveArchiveService.performImport(zipPreview, into: appFolder, mode: .replace, gameRunning: false)
        #expect(try Data(contentsOf: appFolder.appendingPathComponent("save/ThienChuong_335352527/ThienChuong_335352527")) == Data("stardew-main".utf8))

        // Import an extensionless single save file and merge it alongside existing files.
        let singleFile = root.appendingPathComponent("ExtraFarm_999999")
        try Data("extra-farm".utf8).write(to: singleFile)
        let singlePreview = try SaveArchiveService.preview(singleFile, expectedTitleID: titleID)
        #expect(singlePreview.sourceKind == .singleFile)
        #expect(singlePreview.fileCount == 1)

        let backup = try SaveArchiveService.performImport(singlePreview, into: appFolder, mode: .merge, gameRunning: false)
        #expect(backup != nil)
        #expect(try Data(contentsOf: appFolder.appendingPathComponent("save/ThienChuong_335352527/ThienChuong_335352527")) == Data("stardew-main".utf8))
        #expect(try Data(contentsOf: appFolder.appendingPathComponent("save/ExtraFarm_999999")) == Data("extra-farm".utf8))
    }

    @Test func jksvImportExportRoundTripAndBaseClearing() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let appFolder = root.appendingPathComponent("app", isDirectory: true)
        let save = appFolder.appendingPathComponent("save", isDirectory: true)
        try FileManager.default.createDirectory(at: save, withIntermediateDirectories: true)
        try Data("old-progress".utf8).write(to: save.appendingPathComponent("old.sav"))
        #expect(CloudSaveSyncCheck.writeBase(save: save, hash: "0123456789abcdef0123456789abcdef"))

        let tidNum = try #require(UInt64(titleID, radix: 16))
        let meta = SaveArchiveService.Meta(titleID: tidNum, saveType: 1).encode()
        #expect(meta.count == 86)

        let incomingZip = root.appendingPathComponent("jksv-in.zip")
        try buildTestZip(at: incomingZip, entries: [
            (".nx_save_meta.bin", meta, false, 0),
            ("slot0/main.dat", Data(repeating: 0x4A, count: 4096), true, 0),
            ("empty.bin", Data(), false, 0),
            ("info/名.txt", Data("utf8-save".utf8), true, 0),
        ])

        let preview = try SaveArchiveService.preview(incomingZip, expectedTitleID: titleID)
        #expect(preview.sourceKind == .jksvArchive)
        #expect(preview.fileCount == 3)
        #expect(preview.meta?.formattedTitleID == titleID)

        let backup = try #require(try SaveArchiveService.performImport(preview, into: appFolder, mode: .replace, gameRunning: false))
        #expect(try Data(contentsOf: backup.appendingPathComponent("save/old.sav")) == Data("old-progress".utf8))
        #expect(!FileManager.default.fileExists(atPath: save.appendingPathComponent(".nx_save_meta.bin").path))
        #expect(!FileManager.default.fileExists(atPath: save.appendingPathComponent("old.sav").path))
        #expect(try Data(contentsOf: save.appendingPathComponent("slot0/main.dat")) == Data(repeating: 0x4A, count: 4096))
        #expect(try Data(contentsOf: save.appendingPathComponent("empty.bin")) == Data())
        #expect(try Data(contentsOf: save.appendingPathComponent("info/名.txt")) == Data("utf8-save".utf8))
        #expect(CloudSaveSyncCheck.base(save: save) == nil)
        #expect(CloudSaveSyncCheck.latestBackup(in: appFolder) != nil)

        // Export back to JKSV .zip and re-import into a fresh app folder.
        let exportedZip = root.appendingPathComponent("jksv-out.zip")
        let exported = try SaveArchiveService.exportJKSV(from: appFolder, titleID: titleID, to: exportedZip)
        #expect(exported.files == 3)

        #if os(macOS)
        try runPythonScript("""
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
        """)
        #endif

        let appFolder2 = root.appendingPathComponent("app2", isDirectory: true)
        let reimportPreview = try SaveArchiveService.preview(exportedZip, expectedTitleID: titleID)
        #expect(reimportPreview.sourceKind == .jksvArchive)
        #expect(reimportPreview.meta?.formattedTitleID == titleID)
        _ = try SaveArchiveService.performImport(reimportPreview, into: appFolder2, mode: .replace, gameRunning: false)
        #expect(try Data(contentsOf: appFolder2.appendingPathComponent("save/slot0/main.dat")) == Data(repeating: 0x4A, count: 4096))
        #expect(try Data(contentsOf: appFolder2.appendingPathComponent("save/info/名.txt")) == Data("utf8-save".utf8))
    }

    // MARK: - Replace vs Merge, APFS case collisions, and JKSV Title ID mismatch

    @Test func mergeModePreservesExistingSlotsAndCaseCollisions() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let appFolder = root.appendingPathComponent("app", isDirectory: true)
        let initialZip = root.appendingPathComponent("initial.zip")
        try buildTestZip(at: initialZip, entries: [
            ("save/Profile.dat", Data("upper-old".utf8), false, 0),
            ("save/profile.dat", Data("lower-old".utf8), false, 0),
            ("save/Farm1/slot.dat", Data("farm1".utf8), false, 0),
        ])
        let p1 = try SaveArchiveService.preview(initialZip, expectedTitleID: titleID)
        _ = try SaveArchiveService.performImport(p1, into: appFolder, mode: .replace, gameRunning: false)

        let mergeZip = root.appendingPathComponent("merge.zip")
        try buildTestZip(at: mergeZip, entries: [
            ("save/profile.dat", Data("lower-new".utf8), false, 0),
            ("save/Farm2/slot.dat", Data("farm2".utf8), false, 0),
        ])
        let p2 = try SaveArchiveService.preview(mergeZip, expectedTitleID: titleID)
        let backup = try #require(try SaveArchiveService.performImport(p2, into: appFolder, mode: .merge, gameRunning: false))

        let save = appFolder.appendingPathComponent("save", isDirectory: true)
        #expect(try Data(contentsOf: save.appendingPathComponent("Profile.dat")) == Data("upper-old".utf8))
        #expect(try Data(contentsOf: save.appendingPathComponent(".dm-case-1")) == Data("lower-new".utf8))
        #expect(try Data(contentsOf: save.appendingPathComponent("Farm1/slot.dat")) == Data("farm1".utf8))
        #expect(try Data(contentsOf: save.appendingPathComponent("Farm2/slot.dat")) == Data("farm2".utf8))
        #expect(try Data(contentsOf: backup.appendingPathComponent("save/.dm-case-1")) == Data("lower-old".utf8))

        let reexportZip = root.appendingPathComponent("merged-export.zip")
        let exported = try SaveArchiveService.exportJKSV(from: appFolder, titleID: titleID, to: reexportZip)
        #expect(exported.files == 4)

        let handle = try FileHandle(forReadingFrom: reexportZip)
        defer { try? handle.close() }
        let entries = try SaveZipCodec.parseCentralDirectory(handle: handle)
        let names = Set(entries.map(\.rawName))
        #expect(names.contains("Profile.dat"))
        #expect(names.contains("profile.dat"))
        #expect(names.contains("Farm1/slot.dat"))
        #expect(names.contains("Farm2/slot.dat"))
    }

    @Test func jksvTitleIDMismatchIsRejectedBeforeTouchingSave() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let wrongTID: UInt64 = 0x0100_9999_8888_0000
        let wrongZip = root.appendingPathComponent("wrong.zip")
        try buildTestZip(at: wrongZip, entries: [
            (".nx_save_meta.bin", SaveArchiveService.Meta(titleID: wrongTID, saveType: 1).encode(), false, 0),
            ("slot.bin", Data("wrong".utf8), false, 0),
        ])
        #expect(throws: SaveArchiveFailure.titleIDMismatch(expected: titleID, found: "0100999988880000")) {
            _ = try SaveArchiveService.preview(wrongZip, expectedTitleID: titleID)
        }
    }

    // MARK: - Security gates: paths, symlinks, quotas, zip bombs, running/pull guards & rollback

    @Test func unsafePathsAndSymlinksAreRejectedInZipAndFolders() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let badPaths = [
            "../escape.sav",
            "save/../../escape.sav",
            "/etc/passwd",
            "\\windows\\evil.sav",
            "C:drive.sav",
        ]
        for (i, path) in badPaths.enumerated() {
            let zipURL = root.appendingPathComponent("bad-\(i).zip")
            try buildTestZip(at: zipURL, entries: [(path, Data("evil".utf8), false, 0)])
            #expect(throws: SaveArchiveFailure.unsafePath(path)) {
                _ = try SaveArchiveService.preview(zipURL, expectedTitleID: titleID)
            }
        }

        // Symlink inside ZIP.
        let symlinkZip = root.appendingPathComponent("symlink.zip")
        try buildTestZip(at: symlinkZip, entries: [("save/link", Data("/etc/passwd".utf8), false, UInt32(0o120777) << 16)])
        #expect(throws: SaveArchiveFailure.symlinkNotAllowed("save/link")) {
            _ = try SaveArchiveService.preview(symlinkZip, expectedTitleID: titleID)
        }

        // Symlink inside folder.
        let badFolder = root.appendingPathComponent("folder-with-symlink", isDirectory: true)
        try FileManager.default.createDirectory(at: badFolder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: badFolder.appendingPathComponent("escape").path, withDestinationPath: "/etc/passwd")
        #expect(throws: SaveArchiveFailure.symlinkNotAllowed("escape")) {
            _ = try SaveArchiveService.preview(badFolder, expectedTitleID: titleID)
        }

        // Folder entry with colon in name.
        let colonFolder = root.appendingPathComponent("folder-with-colon", isDirectory: true)
        try FileManager.default.createDirectory(at: colonFolder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: colonFolder.appendingPathComponent("bad:name"))
        #expect(throws: SaveArchiveFailure.unsafePath("bad:name")) {
            _ = try SaveArchiveService.preview(colonFolder, expectedTitleID: titleID)
        }
    }

    @Test func quotaAndDecompressionBombsAreRejectedWithoutRecursiveZipExpansion() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let bombHeaderZip = root.appendingPathComponent("bomb-header.zip")
        try buildTestZip(
            at: bombHeaderZip,
            entries: [("save/big.bin", Data("small".utf8), false, 0)],
            tamperLastCDUncompressedSize: 600 * 1024 * 1024
        )
        #expect(throws: SaveArchiveFailure.quotaExceeded) {
            _ = try SaveArchiveService.preview(bombHeaderZip, expectedTitleID: titleID)
        }

        let lyingZip = root.appendingPathComponent("bomb-lying.zip")
        try buildTestZip(
            at: lyingZip,
            entries: [("save/lying.bin", Data(repeating: 0, count: 64 * 1024), true, 0)],
            tamperLastCDUncompressedSize: 16
        )
        let preview = try SaveArchiveService.preview(lyingZip, expectedTitleID: titleID)
        let appFolder = root.appendingPathComponent("bomb-app", isDirectory: true)
        #expect(throws: SaveArchiveFailure.quotaExceeded) {
            _ = try SaveArchiveService.performImport(preview, into: appFolder, mode: .replace, gameRunning: false)
        }
        #expect(!FileManager.default.fileExists(atPath: appFolder.appendingPathComponent("save/lying.bin").path))

        // Nested .zip inside .zip is treated as an opaque regular file (never recursively expanded).
        let innerZip = root.appendingPathComponent("inner.zip")
        try buildTestZip(at: innerZip, entries: [("../escape", Data("evil".utf8), false, 0)])
        let outerZip = root.appendingPathComponent("outer.zip")
        try buildTestZip(at: outerZip, entries: [("nested.zip", try Data(contentsOf: innerZip), false, 0)])
        let outerPreview = try SaveArchiveService.preview(outerZip, expectedTitleID: titleID)
        #expect(outerPreview.fileCount == 1)
        let safeApp = root.appendingPathComponent("nested-app", isDirectory: true)
        _ = try SaveArchiveService.performImport(outerPreview, into: safeApp, mode: .replace, gameRunning: false)
        #expect(FileManager.default.fileExists(atPath: safeApp.appendingPathComponent("save/nested.zip").path))
    }

    @Test func runningGamePendingPullAndMidSwapRollbackSafety() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let validZip = root.appendingPathComponent("valid.zip")
        try buildTestZip(at: validZip, entries: [("slot.bin", Data("new".utf8), false, 0)])
        let preview = try SaveArchiveService.preview(validZip, expectedTitleID: titleID)

        let appFolder = root.appendingPathComponent("guard", isDirectory: true)
        let save = appFolder.appendingPathComponent("save", isDirectory: true)
        try FileManager.default.createDirectory(at: save, withIntermediateDirectories: true)
        try Data("orig".utf8).write(to: save.appendingPathComponent("slot.bin"))

        #expect(throws: SaveArchiveFailure.gameRunning) {
            _ = try SaveArchiveService.performImport(preview, into: appFolder, mode: .replace, gameRunning: true)
        }

        let pullFile = appFolder.appendingPathComponent("save.pull")
        try Data("kept\t/tmp\n".utf8).write(to: pullFile)
        #expect(throws: SaveArchiveFailure.pendingPullJournal) {
            _ = try SaveArchiveService.performImport(preview, into: appFolder, mode: .replace, gameRunning: false)
        }
        try FileManager.default.removeItem(at: pullFile)

        #expect(throws: CocoaError.self) {
            _ = try SaveArchiveService.performImport(preview, into: appFolder, mode: .replace, gameRunning: false) { phase in
                if phase == "afterMoveIncoming" {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
            }
        }
        #expect(try Data(contentsOf: save.appendingPathComponent("slot.bin")) == Data("orig".utf8))
    }

    // MARK: - ShellHostModel integration & race/generation checks

    @MainActor @Test func shellHostModelImportExportRoundTripAndRunningGuard() async throws {
        let sandbox = try Sandbox()
        try sandbox.giveAppData(Fixtures.orbit)

        let srcRoot = sandbox.root.appendingPathComponent("ext", isDirectory: true)
        let srcApp = srcRoot.appendingPathComponent("srcApp", isDirectory: true)
        let srcSave = srcApp.appendingPathComponent("save/slot0", isDirectory: true)
        try FileManager.default.createDirectory(at: srcSave, withIntermediateDirectories: true)
        try Data("imported-payload".utf8).write(to: srcSave.appendingPathComponent("main.dat"))
        let importZip = srcRoot.appendingPathComponent("orbit-import.zip")
        _ = try SaveArchiveService.exportJKSV(from: srcApp, titleID: Fixtures.orbit, to: importZip)

        let presenter = StubSavePresenter()
        presenter.pickOutcome = .picked(importZip)

        var runningID: String? = nil
        var config = sandbox.config()
        config.activeRunningGameID = { runningID }
        let model = ShellHostModel(config: config, savePresenter: presenter)
        await model.waitForDataChecks()

        let pickOutcome = await model.pickSaveImportNow(for: Fixtures.orbit)
        guard case .preview(let prompt) = pickOutcome else {
            Issue.record("Expected preview outcome, got \(pickOutcome)")
            return
        }
        #expect(prompt.jksvTitleID == Fixtures.orbit)
        #expect(prompt.fileCount == 1)

        // Running game blocks commit cleanly.
        runningID = Fixtures.orbit
        let blocked = await model.confirmSaveImportNow(for: Fixtures.orbit, token: prompt.token, mode: .replace)
        guard case .failed = blocked else {
            Issue.record("Expected running game failure, got \(blocked)")
            return
        }

        // Re-pick when idle and commit successfully.
        runningID = nil
        let pickOutcome2 = await model.pickSaveImportNow(for: Fixtures.orbit)
        guard case .preview(let prompt2) = pickOutcome2 else {
            Issue.record("Expected second preview outcome")
            return
        }
        let commitOutcome = await model.confirmSaveImportNow(for: Fixtures.orbit, token: prompt2.token, mode: .replace)
        guard case .imported = commitOutcome else {
            Issue.record("Expected imported outcome, got \(commitOutcome)")
            return
        }

        let detail = try #require(model.details.first(where: { $0.id == Fixtures.orbit }))
        #expect(detail.hasLocalSave)
        #expect(detail.localSaveSummary != nil)

        // Export packs a valid JKSV .zip and passes it to presenter.
        presenter.exportOutcome = .exported
        let exportOutcome = await model.exportSaveNow(for: Fixtures.orbit)
        guard case .exported = exportOutcome else {
            Issue.record("Expected exported outcome, got \(exportOutcome)")
            return
        }
        #expect(presenter.exportedFileName == "Orbit Fixture [0100000000010000].zip")
        if let exportedURL = presenter.exportedURL {
            #expect(!FileManager.default.fileExists(atPath: exportedURL.path))
        }
    }
}

private func testDeflateRaw(_ data: Data) -> Data? {
    guard !data.isEmpty else { return Data() }
    let cap = max(64, data.count + 128)
    let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
    defer { dst.deallocate() }
    let outLen = data.withUnsafeBytes { raw -> Int in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
        return compression_encode_buffer(dst, cap, base, data.count, nil, COMPRESSION_ZLIB)
    }
    guard outLen > 0 else { return nil }
    return Data(bytes: dst, count: outLen)
}

private let testCRCTable: [UInt32] = (0..<256).map { i -> UInt32 in
    var c = UInt32(i)
    for _ in 0..<8 {
        c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
    }
    return c
}

private func testCRC32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for b in data {
        crc = testCRCTable[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8)
    }
    return crc ^ 0xFFFF_FFFF
}

private func putLE16(_ value: UInt16, into buf: inout [UInt8], at offset: Int) {
    buf[offset] = UInt8(value & 0xFF)
    buf[offset + 1] = UInt8((value >> 8) & 0xFF)
}

private func putLE32(_ value: UInt32, into buf: inout [UInt8], at offset: Int) {
    buf[offset] = UInt8(value & 0xFF)
    buf[offset + 1] = UInt8((value >> 8) & 0xFF)
    buf[offset + 2] = UInt8((value >> 16) & 0xFF)
    buf[offset + 3] = UInt8((value >> 24) & 0xFF)
}

private final class StubSavePresenter: SaveTransferPresenter, @unchecked Sendable {
    var pickOutcome: SaveSourcePickOutcome = .cancelled
    var exportOutcome: SaveExportShareOutcome = .cancelled
    var exportedFileName: String?
    var exportedURL: URL?

    @MainActor func pickSaveSourceOutcome() async -> SaveSourcePickOutcome {
        pickOutcome
    }

    @MainActor func presentExportArchive(at url: URL) async -> SaveExportShareOutcome {
        exportedFileName = url.lastPathComponent
        exportedURL = url
        #expect(FileManager.default.fileExists(atPath: url.path))
        if let preview = try? SaveArchiveService.preview(url, expectedTitleID: Fixtures.orbit) {
            #expect(preview.sourceKind == .jksvArchive)
            #expect(preview.fileCount == 1)
        } else {
            Issue.record("Exported URL was not a valid JKSV archive")
        }
        return exportOutcome
    }
}
