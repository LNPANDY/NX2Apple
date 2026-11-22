import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import NXCore

private final class StubFetcher: CloudFileFetching {
    let resultProvider: @Sendable (URL) -> CloudFetchResult
    init(_ resultProvider: @escaping @Sendable (URL) -> CloudFetchResult) {
        self.resultProvider = resultProvider
    }
    func fetch(_ file: URL, cancelled: @escaping @Sendable () -> Bool) -> CloudFetchResult {
        resultProvider(file)
    }
}

final class CloudSaveArchiveTests: XCTestCase {
    private var root: URL!
    private let titleID = "0100ABCDEF000000"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-archive-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSaveFixture(at save: URL) throws -> Date {
        let fm = FileManager.default
        try fm.createDirectory(at: save.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: save.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try fm.createDirectory(atPath: save.path + "_device", withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: save.appendingPathComponent("a"))
        let b = save.appendingPathComponent("sub/b")
        try Data("xy".utf8).write(to: b)
        XCTAssertEqual(setxattr(b.path, "org.d2rmobile.guest-name", "B", 1, 0, XATTR_NOFOLLOW), 0)
        try Data("finder".utf8).write(to: save.appendingPathComponent(".DS_Store"))
        try Data("dev".utf8).write(to: URL(fileURLWithPath: save.path + "_device/d"))
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes([.modificationDate: when], ofItemAtPath: b.path)
        try fm.setAttributes([.modificationDate: when.addingTimeInterval(-50)], ofItemAtPath: save.appendingPathComponent("a").path)
        try fm.setAttributes([.modificationDate: when.addingTimeInterval(-60)], ofItemAtPath: save.path + "_device/d")
        return when
    }

    // MARK: - DMSYNC1 byte-level alignment with save_sync.c

    func testPackAndUnpackMatchesEngineHashGuestNameAndMtimes() throws {
        let save = root.appendingPathComponent("save")
        let when = try makeSaveFixture(at: save)
        let bundle = root.appendingPathComponent("cloud/\(titleID)/save.dmsync")

        let packed = try XCTUnwrap(CloudSaveArchive.writeCloudAtomically(save: save, titleID: titleID, device: "Mac16,1", to: bundle))
        XCTAssertEqual(packed.save.hash, "13ccb164be7f3e628ab478bd309e41d8")
        XCTAssertEqual(packed.save.saved, when)
        XCTAssertEqual(packed.save.device, "Mac16,1")
        XCTAssertEqual(packed.titleID, titleID)
        XCTAssertEqual(packed.files, 3)

        // Ensure no leftover .nosync staging file remains.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: bundle.deletingLastPathComponent().path)
        XCTAssertEqual(siblings, ["save.dmsync"])

        // Inspect header bytes directly.
        let raw = try Data(contentsOf: bundle)
        XCTAssertEqual(String(decoding: raw.prefix(8), as: UTF8.self), "DMSYNC1\n")
        XCTAssertEqual(String(decoding: raw.suffix(8), as: UTF8.self), "DMSYNCE\n")
        XCTAssertGreaterThanOrEqual(raw.count, 144 + 8)

        // Verify CloudSaveCheck header reader sees identical metadata.
        let headerMeta = try XCTUnwrap(CloudSaveCheck.cloudSave(file: bundle))
        XCTAssertEqual(headerMeta, packed.save)
        XCTAssertEqual(CloudSaveCheck.cloudTitle(file: bundle), titleID)

        // Unpack to a clean folder and confirm xattr, mtime, and hash match byte-for-byte.
        let unpackedRoot = root.appendingPathComponent("unpacked")
        let unpacked = try XCTUnwrap(CloudSaveArchive.readArchive(at: bundle, into: unpackedRoot))
        XCTAssertEqual(unpacked.save.hash, "13ccb164be7f3e628ab478bd309e41d8")
        let restoredSave = unpackedRoot.appendingPathComponent("save")
        XCTAssertEqual(CloudSaveCheck.localSave(save: restoredSave)?.hash, "13ccb164be7f3e628ab478bd309e41d8")
        XCTAssertEqual(try Data(contentsOf: unpackedRoot.appendingPathComponent("save_device/d")), Data("dev".utf8))

        var guestBuf = [UInt8](repeating: 0, count: 64)
        let gl = getxattr(restoredSave.appendingPathComponent("sub/b").path, "org.d2rmobile.guest-name", &guestBuf, guestBuf.count, 0, XATTR_NOFOLLOW)
        XCTAssertEqual(gl, 1)
        XCTAssertEqual(String(bytes: guestBuf.prefix(Int(gl)), encoding: .utf8), "B")

        let attrs = try FileManager.default.attributesOfItem(atPath: restoredSave.appendingPathComponent("sub/b").path)
        XCTAssertEqual((attrs[.modificationDate] as? Date)?.timeIntervalSince1970, when.timeIntervalSince1970)
    }

    func testReadArchiveRejectsCorruptedHashTrailingGarbageAndTraversal() throws {
        let save = root.appendingPathComponent("save")
        _ = try makeSaveFixture(at: save)
        let bundle = root.appendingPathComponent("save.dmsync")
        _ = try XCTUnwrap(CloudSaveArchive.packSave(save: save, titleID: titleID, device: "Mac", to: bundle))

        let validData = try Data(contentsOf: bundle)
        let target = root.appendingPathComponent("out")

        // 1. Trailing garbage byte after DMSYNCE\n must fail.
        var withExtra = validData
        withExtra.append(0x41)
        let extraURL = root.appendingPathComponent("extra.dmsync")
        try withExtra.write(to: extraURL)
        XCTAssertNil(CloudSaveArchive.readArchive(at: extraURL, into: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("save").path))

        // 2. Corrupted payload byte must fail hash check and clean partial unpacked files.
        var tampered = validData
        tampered[144 + 24 + 10] ^= 0xFF
        let tamperedURL = root.appendingPathComponent("tampered.dmsync")
        try tampered.write(to: tamperedURL)
        XCTAssertNil(CloudSaveArchive.readArchive(at: tamperedURL, into: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("save").path))

        // 3. Unsafe archive path checks.
        XCTAssertTrue(CloudSaveArchive.isSafeArchivePath("save/slot0/main.bin"))
        XCTAssertTrue(CloudSaveArchive.isSafeArchivePath("save_device/profile.bin"))
        XCTAssertFalse(CloudSaveArchive.isSafeArchivePath("save/../etc/passwd"))
        XCTAssertFalse(CloudSaveArchive.isSafeArchivePath("/save/a"))
        XCTAssertFalse(CloudSaveArchive.isSafeArchivePath("save\\a"))
        XCTAssertFalse(CloudSaveArchive.isSafeArchivePath("save/C:evil"))
        XCTAssertFalse(CloudSaveArchive.isSafeArchivePath("other/a"))
    }

    // MARK: - Sync guardrails, backups, and rollback

    func testSyncNowPullsAndPushesWithBaseTracking() throws {
        let fm = FileManager.default
        let cloudFolder = root.appendingPathComponent("cloud")
        let cloudFile = cloudFolder.appendingPathComponent("\(titleID)/save.dmsync")
        let remoteSource = root.appendingPathComponent("remote-save")
        _ = try makeSaveFixture(at: remoteSource)
        let packedRemote = try XCTUnwrap(CloudSaveArchive.writeCloudAtomically(save: remoteSource, titleID: titleID, device: "iPhone17,1", to: cloudFile))

        let localSave = root.appendingPathComponent("local/save")
        try fm.createDirectory(at: localSave, withIntermediateDirectories: true)
        try Data("old-local".utf8).write(to: localSave.appendingPathComponent("old.bin"))

        let plan = CloudSaveNow.SyncPlan(titleID: titleID, gameName: "TestGame", save: localSave, cloudFile: cloudFile)
        let fetcher = StubFetcher { FileManager.default.fileExists(atPath: $0.path) ? .ready : .missing }

        // Local has old file & no base; cloud has packedRemote -> conflict until user resolves or base matches.
        if case .conflict = CloudSaveNow.inspect(plan: plan, fetcher: fetcher) {} else {
            return XCTFail("Expected conflict when both local and cloud exist without a base")
        }

        // Write base matching local hash so cloud looks newer (onlyCloudChanged).
        let oldHash = try XCTUnwrap(CloudSaveCheck.localSave(save: localSave)?.hash)
        XCTAssertTrue(CloudSaveCheck.writeBase(save: localSave, hash: oldHash))
        if case .onlyCloudChanged = CloudSaveNow.inspect(plan: plan, fetcher: fetcher) {} else {
            return XCTFail("Expected onlyCloudChanged")
        }

        // SyncNow pulls cloud, backs up old local, and updates .sync base.
        let pullRes = CloudSaveNow.syncNow(plan: plan, isRunning: { false }, fetcher: fetcher)
        guard case .success(.pulled(let backup)) = pullRes else {
            return XCTFail("Expected pull success, got \(pullRes)")
        }
        let backupURL = try XCTUnwrap(backup)
        XCTAssertEqual(try Data(contentsOf: backupURL.appendingPathComponent("save/old.bin")), Data("old-local".utf8))
        XCTAssertEqual(CloudSaveCheck.localSave(save: localSave)?.hash, packedRemote.save.hash)
        XCTAssertEqual(CloudSaveCheck.base(save: localSave), packedRemote.save.hash)

        // Modify local -> onlyLocalChanged -> SyncNow pushes atomically and updates .sync base.
        try Data("new-local-progress".utf8).write(to: localSave.appendingPathComponent("a"))
        let newLocalHash = try XCTUnwrap(CloudSaveCheck.localSave(save: localSave)?.hash)
        let pushRes = CloudSaveNow.syncNow(plan: plan, isRunning: { false }, fetcher: fetcher)
        guard case .success(.pushed) = pushRes else {
            return XCTFail("Expected push success, got \(pushRes)")
        }
        XCTAssertEqual(CloudSaveArchive.readArchive(at: cloudFile, into: nil)?.save.hash, newLocalHash)
        XCTAssertEqual(CloudSaveCheck.base(save: localSave), newLocalHash)
    }

    func testSyncRefusesWhenRunningOrPendingPullJournalExists() throws {
        let localSave = root.appendingPathComponent("local/save")
        try FileManager.default.createDirectory(at: localSave, withIntermediateDirectories: true)
        try Data("stay".utf8).write(to: localSave.appendingPathComponent("slot.sav"))
        let cloudFile = root.appendingPathComponent("cloud/\(titleID)/save.dmsync")
        let plan = CloudSaveNow.SyncPlan(titleID: titleID, gameName: "TestGame", save: localSave, cloudFile: cloudFile)
        let fetcher = StubFetcher { FileManager.default.fileExists(atPath: $0.path) ? .ready : .missing }

        // 1. Running game must be rejected without touching cloud.
        let runningRes = CloudSaveNow.syncNow(plan: plan, isRunning: { true }, fetcher: fetcher)
        XCTAssertEqual(runningRes, .failure(.gameRunning))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloudFile.path))

        // 2. Existing .pull journal must block inspect & sync without touching cloud or local.
        try Data("kept\t/tmp/none\n".utf8).write(to: URL(fileURLWithPath: localSave.path + ".pull"))
        XCTAssertEqual(CloudSaveNow.inspect(plan: plan, fetcher: fetcher), .pendingPullRecovery)
        let pullBlocked = CloudSaveNow.syncNow(plan: plan, isRunning: { false }, fetcher: fetcher)
        XCTAssertEqual(pullBlocked, .failure(.pendingPullJournal))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloudFile.path))
    }

    func testResolveConflictCheckReadRevalidateAndWrongTitleIDRejection() throws {
        let localSave = root.appendingPathComponent("local/save")
        try FileManager.default.createDirectory(at: localSave, withIntermediateDirectories: true)
        try Data("local-v1".utf8).write(to: localSave.appendingPathComponent("s.bin"))
        let localHashV1 = try XCTUnwrap(CloudSaveCheck.localSave(save: localSave)?.hash)

        let remoteSource = root.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: remoteSource, withIntermediateDirectories: true)
        try Data("remote-v1".utf8).write(to: remoteSource.appendingPathComponent("s.bin"))
        let cloudFile = root.appendingPathComponent("cloud/\(titleID)/save.dmsync")
        let packedCloud = try XCTUnwrap(CloudSaveArchive.writeCloudAtomically(save: remoteSource, titleID: titleID, device: "iPhone17,1", to: cloudFile))
        let fetcher = StubFetcher { _ in .ready }
        let plan = CloudSaveNow.SyncPlan(titleID: titleID, gameName: "TestGame", save: localSave, cloudFile: cloudFile)

        // Mutate local after user saw conflict -> resolveConflict must abort with .changedDuringOperation!
        try Data("local-v2".utf8).write(to: localSave.appendingPathComponent("s.bin"))
        let staleRes = CloudSaveNow.resolveConflict(
            .cloud,
            expectedLocalHash: localHashV1,
            expectedCloudHash: packedCloud.save.hash,
            plan: plan,
            isRunning: { false },
            fetcher: fetcher
        )
        XCTAssertEqual(staleRes, .failure(.changedDuringOperation))
        XCTAssertEqual(try Data(contentsOf: localSave.appendingPathComponent("s.bin")), Data("local-v2".utf8))

        // Wrong TitleID in cloud archive must be rejected.
        let otherCloud = root.appendingPathComponent("cloud/\(titleID)/wrong.dmsync")
        _ = try XCTUnwrap(CloudSaveArchive.writeCloudAtomically(save: remoteSource, titleID: "0100999988880000", device: "iPhone17,1", to: otherCloud))
        let wrongPlan = CloudSaveNow.SyncPlan(titleID: titleID, gameName: "TestGame", save: localSave, cloudFile: otherCloud)
        if case .unreadable(_, .cloudWrongGame) = CloudSaveNow.inspect(plan: wrongPlan, fetcher: fetcher) {} else {
            return XCTFail("Expected cloudWrongGame rejection")
        }
    }

    func testMidSwapFailureRestoresOriginalSaveAndRemovesPartialFiles() throws {
        let localSave = root.appendingPathComponent("lib/save/\(titleID)")
        try FileManager.default.createDirectory(at: localSave, withIntermediateDirectories: true)
        try Data("original-save".utf8).write(to: localSave.appendingPathComponent("slot.sav"))
        let deviceSave = URL(fileURLWithPath: localSave.path + "_device")
        try FileManager.default.createDirectory(at: deviceSave, withIntermediateDirectories: true)
        try Data("original-device".utf8).write(to: deviceSave.appendingPathComponent("dev.sav"))

        let staged = root.appendingPathComponent("staged")
        try FileManager.default.createDirectory(at: staged.appendingPathComponent("save"), withIntermediateDirectories: true)
        try Data("new-incomplete".utf8).write(to: staged.appendingPathComponent("save/slot.sav"))

        XCTAssertThrowsError(
            try CloudSaveArchive.replaceSaveFolders(save: localSave, from: staged) { phase in
                if phase == "afterMoveIncoming" {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
            }
        )
        XCTAssertEqual(try Data(contentsOf: localSave.appendingPathComponent("slot.sav")), Data("original-save".utf8))
        XCTAssertEqual(try Data(contentsOf: deviceSave.appendingPathComponent("dev.sav")), Data("original-device".utf8))
    }

    func testBackupPruningKeepsNewestTenPerSide() throws {
        let save = root.appendingPathComponent("save")
        try FileManager.default.createDirectory(at: save, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: save.appendingPathComponent("f.bin"))
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<12 {
            _ = try CloudSaveArchive.backupLocalSave(
                save: save,
                now: baseDate.addingTimeInterval(Double(i * 10)),
                side: "local",
                prune: true
            )
        }
        let entries = try FileManager.default.contentsOfDirectory(atPath: save.path + "-backups")
            .filter { !$0.hasPrefix(".") }
            .sorted()
        XCTAssertEqual(entries.count, CloudSaveArchive.keepBackups)
    }

    func testFailedRollbackPreservesRollbackBackupDirectory() throws {
        let fm = FileManager.default
        let container = root.appendingPathComponent("lib/save")
        try fm.createDirectory(at: container, withIntermediateDirectories: true)
        let localSave = container.appendingPathComponent(titleID)
        try fm.createDirectory(at: localSave, withIntermediateDirectories: true)
        try Data("precious-save".utf8).write(to: localSave.appendingPathComponent("slot.sav"))

        let staged = root.appendingPathComponent("staged")
        try fm.createDirectory(at: staged.appendingPathComponent("save"), withIntermediateDirectories: true)
        try Data("incoming".utf8).write(to: staged.appendingPathComponent("save/slot.sav"))

        // Make container read-only after moveOld so restoring backup into container fails;
        // rollbackRoot MUST NOT be deleted when restoration fails!
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: container.path) }
        XCTAssertThrowsError(
            try CloudSaveArchive.replaceSaveFolders(save: localSave, from: staged) { phase in
                if phase == "afterMoveOld" {
                    try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: container.path)
                    throw CocoaError(.fileWriteNoPermission)
                }
            }
        )
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: container.path)
        let items = try fm.contentsOfDirectory(atPath: container.path)
        let rollbackDirs = items.filter { $0.hasPrefix("\(titleID).rollback-") }
        XCTAssertEqual(rollbackDirs.count, 1, "Failed rollback must preserve rollbackRoot rather than deleting it")
        let preserved = container.appendingPathComponent(rollbackDirs[0]).appendingPathComponent("save/slot.sav")
        XCTAssertEqual(try Data(contentsOf: preserved), Data("precious-save".utf8))
    }
}
