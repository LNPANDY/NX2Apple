import CryptoKit
import Darwin
import Foundation
import Testing
import ShellUI
@testable import ShellHost

// MARK: - Helpers for DMSYNC1 archives and synchronized progress gates

private func freshShellSettings() -> ShellSettingsStore {
    ShellSettingsStore(defaults: UserDefaults(suiteName: "c2-shell-\(UUID().uuidString)")!)
}

private enum DMSyncTestWriter {
    static let magic = Array("DMSYNC1\n".utf8)
    static let endMarker = Array("DMSYNCE\n".utf8)

    struct Entry {
        var kind: UInt8 // 1 = dir, 2 = file
        var path: String
        var guestName: String = ""
        var mtime: Int64 = 1_700_000_000
        var body: Data = Data()
    }

    static func le16(_ v: UInt16) -> [UInt8] { (0..<2).map { UInt8((v >> (8 * UInt16($0))) & 0xff) } }
    static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xff) } }
    static func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xff) } }

    /// Builds a real DMSYNC1 binary archive matching `ss_pack` in `engine/dm/host/save_sync.c`.
    static func pack(entries: [Entry], titleID: String, device: String = "MacBookPro",
                     saved: Int64 = 1_700_000_100, overrideHash: String? = nil) -> (data: Data, hash: String) {
        let sorted = entries.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        var sha = SHA256()
        var fileCount = 0
        var bodyChunks = Data()

        for entry in sorted {
            let pathBytes = Array(entry.path.utf8)
            let guestBytes = Array(entry.guestName.utf8)
            let fileSize: UInt64 = entry.kind == 2 ? UInt64(entry.body.count) : 0
            var eh = [UInt8](repeating: 0, count: 24)
            eh[0] = entry.kind
            let pl = le16(UInt16(pathBytes.count))
            let gl = le16(UInt16(guestBytes.count))
            let sz = le64(fileSize)
            let mt = le64(UInt64(bitPattern: entry.mtime))
            eh[2] = pl[0]; eh[3] = pl[1]
            eh[4] = gl[0]; eh[5] = gl[1]
            for i in 0..<8 { eh[8 + i] = sz[i]; eh[16 + i] = mt[i] }

            sha.update(data: Data(eh[0..<16]))
            sha.update(data: Data(pathBytes))
            sha.update(data: Data(guestBytes))
            if entry.kind == 2 {
                fileCount += 1
                sha.update(data: entry.body)
            }

            bodyChunks.append(contentsOf: eh)
            bodyChunks.append(contentsOf: pathBytes)
            bodyChunks.append(contentsOf: guestBytes)
            if entry.kind == 2 {
                bodyChunks.append(entry.body)
            }
        }

        let computed = fileCount > 0 ? sha.finalize().prefix(16).map { String(format: "%02x", $0) }.joined() : ""
        let headerHash = overrideHash ?? computed

        var out = Data()
        out.append(contentsOf: magic)
        out.append(contentsOf: le32(1))
        out.append(contentsOf: le32(UInt32(sorted.count)))
        var hashField = Data(headerHash.utf8)
        hashField.count = 32
        out.append(hashField)
        out.append(contentsOf: le64(UInt64(bitPattern: saved)))
        var titleField = Data(titleID.uppercased().utf8)
        titleField.count = 24
        out.append(titleField)
        var deviceField = Data(device.utf8)
        deviceField.count = 64
        out.append(deviceField)
        out.append(bodyChunks)
        out.append(contentsOf: endMarker)
        return (out, computed)
    }
}

private final class JoinGate: @unchecked Sendable {
    private let proceed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var pausedOnce = false
    private var midwayReached = false
    private var midwayWaiter: CheckedContinuation<Bool, Never>?
    private var released = false
    private var storedEvents: [DataParts.Progress] = []

    var events: [DataParts.Progress] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents
    }

    func record(_ progress: DataParts.Progress, pauseWhenMidway: Bool = false) {
        var waiterToResume: CheckedContinuation<Bool, Never>?
        var shouldPause = false
        lock.lock()
        storedEvents.append(progress)
        if pauseWhenMidway, !pausedOnce, progress.doneBytes > 0, progress.doneBytes < progress.totalBytes {
            pausedOnce = true
            midwayReached = true
            waiterToResume = midwayWaiter
            midwayWaiter = nil
            shouldPause = !released
        }
        lock.unlock()
        waiterToResume?.resume(returning: true)
        if shouldPause {
            _ = proceed.wait(timeout: .now() + 15.0)
        }
    }

    func waitUntilMidway(timeoutSeconds: TimeInterval = 15.0) async -> Bool {
        let alreadyReached: Bool = {
            lock.lock()
            defer { lock.unlock() }
            return midwayReached
        }()
        if alreadyReached {
            return true
        }
        let timeoutNanoseconds = UInt64(max(0.1, timeoutSeconds) * 1_000_000_000)
        let timeoutTask = Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            self?.expireMidwayWaiter()
        }
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var immediate: CheckedContinuation<Bool, Never>?
            lock.lock()
            if midwayReached {
                immediate = continuation
            } else {
                midwayWaiter = continuation
            }
            lock.unlock()
            immediate?.resume(returning: true)
        }
        timeoutTask.cancel()
        return result
    }

    private func expireMidwayWaiter() {
        var expired: CheckedContinuation<Bool, Never>?
        lock.lock()
        if !midwayReached {
            expired = midwayWaiter
            midwayWaiter = nil
        }
        lock.unlock()
        expired?.resume(returning: false)
    }

    func release() {
        var shouldSignal = false
        lock.lock()
        if !released {
            released = true
            shouldSignal = true
        }
        lock.unlock()
        if shouldSignal {
            proceed.signal()
        }
    }
}

// MARK: - 1. Wrong-folder data diagnostics (UX 3.3.1)

@MainActor @Suite struct DataFolderDiagnosticsTests {
    private func installRealIdentityManifest(in box: Sandbox, titleID: String = Fixtures.orbit,
                                             size: Int = 61, indexHex: String = "90b5abb4d1ea10d2") throws {
        let url = box.games.appendingPathComponent(titleID).appendingPathComponent("game.manifest.json")
        let updated = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "\"DMROMFSID1 fixture\"",
                                  with: "\"DMROMFSID1 title=\(titleID) version=1.0 build=v0 size=\(size) index=\(indexHex)\"")
        try Data(updated.utf8).write(to: url)
    }

    @Test func guidanceTextExplainsSelectingAFolderRatherThanAGreyedOutImageFile() throws {
        let box = try Sandbox()
        let model = ShellHostModel(config: box.config())
        let orbit = try #require(model.details.first { $0.id == Fixtures.orbit })
        #expect(orbit.dataNote.contains("folder"))
        #expect(!orbit.dataNote.contains(";"))
    }

    @Test func detectsUndownloadedICloudPlaceholderInPickedFolder() async throws {
        let box = try Sandbox()
        try installRealIdentityManifest(in: box)
        let icloudDir = box.root.appendingPathComponent("iCloudDrive/OrbitData", isDirectory: true)
        try box.write("placeholder", to: icloudDir.appendingPathComponent(".romfs.img.icloud"))

        let model = ShellHostModel(config: box.config(), picker: FakePicker(url: icloudDir))
        await model.pickGameDataNow(Fixtures.orbit)

        let orbit = try #require(model.details.first { $0.id == Fixtures.orbit })
        #expect(orbit.game.state == .needsGameData)
        #expect(model.notice?.contains("iCloud Drive") == true)
        #expect(model.notice?.contains("Download it in Files") == true)
        #expect(orbit.dataNote == model.notice)
    }

    @Test func detectsUnjoinedSplitPartsInExternalPickedFolder() async throws {
        let box = try Sandbox()
        try installRealIdentityManifest(in: box)
        let external = box.root.appendingPathComponent("USBDrive/SplitFolder", isDirectory: true)
        try box.write("0123", to: external.appendingPathComponent("romfs.img.nxpart.0000.0002"))
        try box.write("4567", to: external.appendingPathComponent("romfs.img.nxpart.0001.0002"))

        let model = ShellHostModel(config: box.config(), picker: FakePicker(url: external))
        await model.pickGameDataNow(Fixtures.orbit)

        let orbit = try #require(model.details.first { $0.id == Fixtures.orbit })
        #expect(orbit.game.state == .needsGameData)
        #expect(model.notice?.contains(".nxpart") == true)
        #expect(model.notice?.contains("games/\(Fixtures.orbit)") == true)
        #expect(orbit.dataNote == model.notice)
    }

    @Test func detectsWrongGameByRomfsIdentityAndByKnownSiblingTitleID() async throws {
        let box = try Sandbox()
        try installRealIdentityManifest(in: box)

        // Case A: unknown other game's romfs.img directly inside picked folder.
        let otherUnknown = box.root.appendingPathComponent("Drive/OtherGame", isDirectory: true)
        try FileManager.default.createDirectory(at: otherUnknown, withIntermediateDirectories: true)
        try ShellDataFolderTests.dmromfs(ShellDataFolderTests.indexB).write(to: otherUnknown.appendingPathComponent("romfs.img"))

        let modelA = ShellHostModel(config: box.config(), picker: FakePicker(url: otherUnknown))
        await modelA.pickGameDataNow(Fixtures.orbit)
        #expect(modelA.notice?.contains("another game") == true)
        #expect(modelA.notice?.contains("not Orbit Fixture") == true)

        // Case B: sibling folder named after another installed game's Title ID (`Fixtures.chain` = Chain Fixture).
        let otherKnown = box.root.appendingPathComponent("Drive/LibraryRoot", isDirectory: true)
        let chainSub = otherKnown.appendingPathComponent(Fixtures.chain, isDirectory: true)
        try FileManager.default.createDirectory(at: chainSub, withIntermediateDirectories: true)
        try ShellDataFolderTests.dmromfs(ShellDataFolderTests.indexB).write(to: chainSub.appendingPathComponent("romfs.img"))

        let modelB = ShellHostModel(config: box.config(), picker: FakePicker(url: otherKnown))
        await modelB.pickGameDataNow(Fixtures.orbit)
        #expect(modelB.notice?.contains("Chain Fixture") == true)
        #expect(modelB.notice?.contains("not Orbit Fixture") == true)
    }

    @Test func scansAllAllowedDepthsAndPrioritizesDeeperTargetMatchOverShallowWrongGame() async throws {
        let box = try Sandbox()
        try installRealIdentityManifest(in: box)

        // Picked folder is 2 levels too high AND also contains a shallow wrong-game folder at depth 1.
        // Diagnostics must scan all allowed depths rather than returning early on depth 1.
        let highRoot = box.root.appendingPathComponent("SwitchDump", isDirectory: true)
        let shallowWrong = highRoot.appendingPathComponent(Fixtures.chain, isDirectory: true)
        let deepRight = highRoot.appendingPathComponent("Backups/OrbitDump", isDirectory: true)
        try FileManager.default.createDirectory(at: shallowWrong, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: deepRight, withIntermediateDirectories: true)
        try ShellDataFolderTests.dmromfs(ShellDataFolderTests.indexB).write(to: shallowWrong.appendingPathComponent("romfs.img"))
        try ShellDataFolderTests.dmromfs(ShellDataFolderTests.indexA).write(to: deepRight.appendingPathComponent("romfs.img"))

        let model = ShellHostModel(config: box.config(), picker: FakePicker(url: highRoot))
        await model.pickGameDataNow(Fixtures.orbit)

        let orbit = try #require(model.details.first { $0.id == Fixtures.orbit })
        #expect(orbit.game.state == .needsGameData)
        #expect(model.notice?.contains("Backups/OrbitDump") == true)
        #expect(orbit.dataNote.contains("Backups/OrbitDump"))

        // Selecting the inner folder directly clears the diagnostic note and makes the game playable.
        let fixedModel = ShellHostModel(config: box.config(), picker: FakePicker(url: deepRight))
        await fixedModel.pickGameDataNow(Fixtures.orbit)
        let ready = try #require(fixedModel.details.first { $0.id == Fixtures.orbit })
        #expect(ready.game.state == .playable)
        #expect(ready.dataNote.isEmpty)

        // Switching back to app data on the earlier model also clears the stale diagnostic note.
        model.useAppData(Fixtures.orbit)
        let resetOrbit = try #require(model.details.first { $0.id == Fixtures.orbit })
        #expect(!resetOrbit.dataNote.contains("Backups/OrbitDump"))
    }
}

// MARK: - 2. Real-time `.nxpart` join progress and generation protection (UX 3.3.1)

@MainActor @Suite(.serialized) struct JoiningProgressModelTests {
    @Test func joinAllReportsMonotonicByteProgressPerTitleID() throws {
        let box = try Sandbox()
        let dir = box.appData.appendingPathComponent(Fixtures.orbit, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("0123".utf8).write(to: dir.appendingPathComponent("romfs.img.nxpart.0000.0003"))
        try Data("4567".utf8).write(to: dir.appendingPathComponent("romfs.img.nxpart.0001.0003"))
        try Data("89".utf8).write(to: dir.appendingPathComponent("romfs.img.nxpart.0002.0003"))

        let gate = JoinGate()
        let joined = DataParts.joinAll(appDataRoot: box.appData, partSize: 4) { progress in
            gate.record(progress)
        }
        let reports = gate.events
        #expect(joined.count == 1)
        #expect(!reports.isEmpty)
        #expect(reports.allSatisfy { $0.titleID == Fixtures.orbit && $0.totalBytes == 10 })
        #expect(reports.first?.doneBytes == 0)
        #expect(reports.last?.doneBytes == 10)
        #expect(reports.map(\.doneBytes) == reports.map(\.doneBytes).sorted())
    }

    @Test func modelShowsJoiningGameDataWhilePartsMergeAndUnlocksPlayWhenDone() async throws {
        let box = try Sandbox()
        let manifestURL = box.games.appendingPathComponent(Fixtures.orbit).appendingPathComponent("game.manifest.json")
        let imageBytes = ShellDataFolderTests.dmromfs(ShellDataFolderTests.indexA) // 61 bytes
        let updated = try String(contentsOf: manifestURL, encoding: .utf8)
            .replacingOccurrences(of: "\"DMROMFSID1 fixture\"",
                                  with: "\"DMROMFSID1 title=\(Fixtures.orbit) version=1.0 build=v0 size=61 index=90b5abb4d1ea10d2\"")
        try Data(updated.utf8).write(to: manifestURL)

        let dir = box.appData.appendingPathComponent(Fixtures.orbit, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let partSize = 20
        let count = (imageBytes.count + partSize - 1) / partSize
        for i in 0..<count {
            let chunk = imageBytes[(i * partSize)..<min(imageBytes.count, (i + 1) * partSize)]
            let name = String(format: "romfs.img.nxpart.%04d.%04d", i, count)
            try Data(chunk).write(to: dir.appendingPathComponent(name))
        }

        let gate = JoinGate()
        defer { gate.release() }
        var cfg = box.config()
        cfg.joinPartSize = Int64(partSize)
        cfg.onJoinProgress = { progress in
            gate.record(progress, pauseWhenMidway: true)
        }

        let model = ShellHostModel(config: cfg)
        let reachedMidway = await gate.waitUntilMidway()
        #expect(reachedMidway)
        for _ in 0..<40 {
            if let orbit = model.details.first(where: { $0.id == Fixtures.orbit }),
               case .joiningGameData(let pct, _, _) = orbit.game.state, pct > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let midDetail = try #require(model.details.first { $0.id == Fixtures.orbit })
        if case .joiningGameData(let percent, _, _) = midDetail.game.state {
            #expect(percent > 0 && percent < 100)
        } else {
            Issue.record("Expected .joiningGameData while split parts are merging, got \(midDetail.game.state)")
        }
        #expect(midDetail.dataNote.contains(".nxpart"))

        gate.release()
        await model.waitForStartupTasks()

        let finalDetail = try #require(model.details.first { $0.id == Fixtures.orbit })
        #expect(finalDetail.game.state == .playable)
        #expect(finalDetail.dataNote.isEmpty)
    }

    @Test func joinGenerationPreventsStaleProgressFromOverwritingDeletedGame() async throws {
        let box = try Sandbox()
        let dir = box.appData.appendingPathComponent(Fixtures.orbit, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("0123".utf8).write(to: dir.appendingPathComponent("romfs.img.nxpart.0000.0002"))
        try Data("4567".utf8).write(to: dir.appendingPathComponent("romfs.img.nxpart.0001.0002"))

        let gate = JoinGate()
        defer { gate.release() }
        var cfg = box.config()
        cfg.joinPartSize = 4
        cfg.onJoinProgress = { progress in
            gate.record(progress, pauseWhenMidway: true)
        }

        let model = ShellHostModel(config: cfg)
        let reachedDeleteMidway = await gate.waitUntilMidway()
        #expect(reachedDeleteMidway)

        // Delete the game while the background join is still in flight, incrementing joinGeneration.
        model.deleteGame(Fixtures.orbit, saves: true)
        #expect(!model.details.contains { $0.id == Fixtures.orbit })

        gate.release()
        await model.waitForStartupTasks()

        // Stale progress callbacks from the old generation must never put stale joining notes back.
        #expect(model.details.first { $0.id == Fixtures.orbit }?.game.state != .joiningGameData(percent: 50, doneSize: "4 bytes", totalSize: "8 bytes"))
    }
}

// MARK: - 4. iOS CloudSaveGate and `save-backups/` restore (UX 3.3.2)

@MainActor @Suite struct CloudSaveGateAndBackupTests {
    @Test func localSaveHashAndArchiveRoundTripMatchTheEngineContract() throws {
        let box = try Sandbox()
        let appFolder = box.appData.appendingPathComponent(Fixtures.orbit, isDirectory: true)
        let save = appFolder.appendingPathComponent("save", isDirectory: true)
        let fm = FileManager.default

        #expect(CloudSaveSyncCheck.localSave(save: save) == .empty)
        try fm.createDirectory(at: save.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: save.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try fm.createDirectory(atPath: save.path + "_device", withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: save.appendingPathComponent("a"))
        let b = save.appendingPathComponent("sub/b")
        try Data("xy".utf8).write(to: b)
        #expect(setxattr(b.path, "org.d2rmobile.guest-name", "B", 1, 0, XATTR_NOFOLLOW) == 0)
        try Data("finder".utf8).write(to: save.appendingPathComponent(".DS_Store"))
        try Data("dev".utf8).write(to: URL(fileURLWithPath: save.path + "_device/d"))

        let scanned = try #require(CloudSaveSyncCheck.localSave(save: save))
        // Exact SHA-256 prefix produced by `ss_scan` in `engine/dm/host/save_sync.c`.
        #expect(scanned.hash == "13ccb164be7f3e628ab478bd309e41d8")

        // Pack into DMSYNC1 and unpack into a clean folder: both hash and guest-name xattr survive identically.
        let packed = DMSyncTestWriter.pack(entries: [
            .init(kind: 2, path: "save/a", body: Data("hello".utf8)),
            .init(kind: 1, path: "save/empty"),
            .init(kind: 1, path: "save/sub"),
            .init(kind: 2, path: "save/sub/b", guestName: "B", body: Data("xy".utf8)),
            .init(kind: 2, path: "save_device/d", body: Data("dev".utf8)),
        ], titleID: Fixtures.orbit)
        #expect(packed.hash == "13ccb164be7f3e628ab478bd309e41d8")

        let archiveURL = box.root.appendingPathComponent("roundtrip.dmsync")
        try packed.data.write(to: archiveURL)
        let unpackedRoot = box.root.appendingPathComponent("unpacked", isDirectory: true)
        let unpackedMeta = try #require(CloudSaveSyncCheck.readArchive(at: archiveURL, into: unpackedRoot))
        #expect(unpackedMeta.hash == "13ccb164be7f3e628ab478bd309e41d8")
        let rescanned = try #require(CloudSaveSyncCheck.localSave(save: unpackedRoot.appendingPathComponent("save")))
        #expect(rescanned.hash == "13ccb164be7f3e628ab478bd309e41d8")
    }

    @Test func archiveReaderRejectsTraversalWrongTitleTruncatedAndTrailingGarbage() throws {
        let box = try Sandbox()
        #expect(!CloudSaveSyncCheck.isSafeArchivePath("../escape"))
        #expect(!CloudSaveSyncCheck.isSafeArchivePath("save/../../escape"))
        #expect(!CloudSaveSyncCheck.isSafeArchivePath("/save/slot1"))
        #expect(!CloudSaveSyncCheck.isSafeArchivePath("save\\slot1"))
        #expect(!CloudSaveSyncCheck.isSafeArchivePath("C:save/slot1"))
        #expect(!CloudSaveSyncCheck.isSafeArchivePath("other/slot1"))
        #expect(CloudSaveSyncCheck.isSafeArchivePath("save/slot1/data.bin"))
        #expect(CloudSaveSyncCheck.isSafeArchivePath("save_device/common.bin"))

        let traversal = DMSyncTestWriter.pack(entries: [
            .init(kind: 2, path: "save/../../escape.txt", body: Data("bad".utf8))
        ], titleID: Fixtures.orbit)
        let travFile = box.root.appendingPathComponent("trav.dmsync")
        try traversal.data.write(to: travFile)
        let dest = box.root.appendingPathComponent("stage", isDirectory: true)
        #expect(CloudSaveSyncCheck.readArchive(at: travFile, into: dest) == nil)
        #expect(!FileManager.default.fileExists(atPath: box.root.appendingPathComponent("escape.txt").path))

        // Valid archive with trailing garbage byte must fail integrity check.
        let clean = DMSyncTestWriter.pack(entries: [
            .init(kind: 2, path: "save/slot.bin", body: Data("ok".utf8))
        ], titleID: Fixtures.orbit)
        let trailingFile = box.root.appendingPathComponent("trailing.dmsync")
        try (clean.data + Data([0x00])).write(to: trailingFile)
        #expect(CloudSaveSyncCheck.readArchive(at: trailingFile, into: nil) == nil)

        // Wrong Title ID in cloud folder must report .unreadable rather than importing another game's save.
        let cloudFolder = box.root.appendingPathComponent("Cloud", isDirectory: true)
        let gameCloudDir = cloudFolder.appendingPathComponent(Fixtures.orbit, isDirectory: true)
        try FileManager.default.createDirectory(at: gameCloudDir, withIntermediateDirectories: true)
        let wrongTitle = DMSyncTestWriter.pack(entries: [
            .init(kind: 2, path: "save/slot.bin", body: Data("other".utf8))
        ], titleID: Fixtures.chain)
        try wrongTitle.data.write(to: gameCloudDir.appendingPathComponent("save.dmsync"))
        let report = CloudSaveSyncCheck.inspect(cloudFolder: cloudFolder, titleID: Fixtures.orbit,
                                                appFolder: box.appData.appendingPathComponent(Fixtures.orbit))
        #expect(report.outcome == .unreadable)
    }

    @Test func conflictBlocksPlayBacksUpUnchosenSaveAndSupportsRestoringFromSaveBackups() async throws {
        let box = try Sandbox()
        let appFolder = try box.giveAppData(Fixtures.orbit)
        let cloudRoot = box.root.appendingPathComponent("iCloudSaves", isDirectory: true)
        let cloudGameDir = cloudRoot.appendingPathComponent(Fixtures.orbit, isDirectory: true)
        try FileManager.default.createDirectory(at: cloudGameDir, withIntermediateDirectories: true)

        // Local save on iPhone ("iphone-progress") and divergent save in iCloud ("mac-progress") with no common sync base.
        try box.write("iphone-progress", to: appFolder.appendingPathComponent("save/slot1.sav"))
        let cloudPacked = DMSyncTestWriter.pack(entries: [
            .init(kind: 2, path: "save/slot1.sav", mtime: 1_700_000_500, body: Data("mac-progress".utf8))
        ], titleID: Fixtures.orbit, device: "MacStudio")
        try cloudPacked.data.write(to: cloudGameDir.appendingPathComponent("save.dmsync"))

        let clock = Clock(Date(timeIntervalSince1970: 1_710_000_000))
        let launcher = RecordingLauncher()
        let model = ShellHostModel(config: box.config(now: { clock.date }), launcher: launcher,
                                   picker: FakePicker(url: cloudRoot), shellSettings: freshShellSettings())
        await model.pickCloudSavesNow(Fixtures.orbit)

        // 1. Launching pauses on the conflict prompt instead of overwriting either save.
        await model.playNow(Fixtures.orbit)
        #expect(launcher.launched.isEmpty)
        let prompt = try #require(model.cloudConflict)
        #expect(!prompt.isUnreadable && prompt.gameID == Fixtures.orbit && prompt.cloudDevice == "MacStudio")

        // 2. Cancelling leaves both saves untouched and does not launch.
        await model.resolveCloudConflictNow(.cancel)
        #expect(model.cloudConflict == nil && launcher.launched.isEmpty)
        #expect(try String(contentsOf: appFolder.appendingPathComponent("save/slot1.sav"), encoding: .utf8) == "iphone-progress")

        // 3. Re-trigger Play and choose `.useCloud`: local save is backed up to `save-backups/`, cloud save becomes active,
        //    `DM_SAVE_SYNC_CHOICE=cloud:<hash>` is passed, and `latestSaveBackup` appears on the game detail.
        await model.playNow(Fixtures.orbit)
        #expect(model.cloudConflict != nil)
        await model.resolveCloudConflictNow(.useCloud)
        #expect(model.cloudConflict == nil)
        #expect(launcher.launched.count == 1)
        #expect(launcher.launched.last?.environment["DM_SAVE_SYNC_CHOICE"] == "cloud:\(cloudPacked.hash)")
        #expect(try String(contentsOf: appFolder.appendingPathComponent("save/slot1.sav"), encoding: .utf8) == "mac-progress")
        #expect(CloudSaveSyncCheck.base(save: appFolder.appendingPathComponent("save")) == cloudPacked.hash)

        let orbitAfterSync = try #require(model.details.first { $0.id == Fixtures.orbit })
        let backupLabel = try #require(orbitAfterSync.latestSaveBackup)
        #expect(!backupLabel.isEmpty)
        #expect(orbitAfterSync.cloudNote.contains(backupLabel))
        #expect(CloudSaveSyncCheck.latestBackup(in: appFolder)?.name.hasSuffix(" local") == true)

        // 4. Subsequent launch with no further changes starts immediately with `DM_SAVE_SYNC_CHOICE=ask` and zero prompt.
        await model.playNow(Fixtures.orbit)
        #expect(model.cloudConflict == nil && launcher.launched.count == 2)
        #expect(launcher.launched.last?.environment["DM_SAVE_SYNC_CHOICE"] == "ask")

        // 5. Restore the backup from `save-backups/` via `restoreLatestSaveBackupNow`:
        //    current "mac-progress" is backed up first, "iphone-progress" is restored, and `save.sync` is cleared.
        clock.date = clock.date.addingTimeInterval(120)
        await model.restoreLatestSaveBackupNow(Fixtures.orbit)
        #expect(try String(contentsOf: appFolder.appendingPathComponent("save/slot1.sav"), encoding: .utf8) == "iphone-progress")
        #expect(CloudSaveSyncCheck.base(save: appFolder.appendingPathComponent("save")) == nil)
        #expect(model.notice?.contains("Restored the save backup") == true)
        #expect(CloudSaveSyncCheck.listBackups(in: appFolder).count == 2)
    }

    @Test func choosingDeviceSaveBacksUpCloudSaveAndUnreadableCloudSupportsOfflineLaunch() async throws {
        let box = try Sandbox()
        let appFolder = try box.giveAppData(Fixtures.orbit)
        let cloudRoot = box.root.appendingPathComponent("iCloudSaves", isDirectory: true)
        let cloudGameDir = cloudRoot.appendingPathComponent(Fixtures.orbit, isDirectory: true)
        try FileManager.default.createDirectory(at: cloudGameDir, withIntermediateDirectories: true)

        try box.write("local-keep", to: appFolder.appendingPathComponent("save/slot1.sav"))
        let cloudPacked = DMSyncTestWriter.pack(entries: [
            .init(kind: 2, path: "save/slot1.sav", body: Data("cloud-old".utf8))
        ], titleID: Fixtures.orbit, device: "iPad")
        try cloudPacked.data.write(to: cloudGameDir.appendingPathComponent("save.dmsync"))

        let launcher = RecordingLauncher()
        let model = ShellHostModel(config: box.config(), launcher: launcher,
                                   picker: FakePicker(url: cloudRoot), shellSettings: freshShellSettings())
        await model.pickCloudSavesNow(Fixtures.orbit)

        await model.playNow(Fixtures.orbit)
        #expect(model.cloudConflict?.isUnreadable == false)
        await model.resolveCloudConflictNow(.useDevice)

        #expect(launcher.launched.count == 1)
        #expect(launcher.launched.last?.environment["DM_SAVE_SYNC_CHOICE"] == "local:\(cloudPacked.hash)")
        #expect(try String(contentsOf: appFolder.appendingPathComponent("save/slot1.sav"), encoding: .utf8) == "local-keep")
        let backups = CloudSaveSyncCheck.listBackups(in: appFolder)
        let firstBackup = try #require(backups.first)
        #expect(backups.count == 1 && firstBackup.name.hasSuffix(" cloud"))
        #expect(try String(contentsOf: firstBackup.url.appendingPathComponent("save/slot1.sav"), encoding: .utf8) == "cloud-old")

        // Corrupt the cloud archive -> unreadable prompt -> `.playOffline` launches with `DM_SAVE_SYNC_CHOICE=offline`.
        try Data("corrupted-cloud-bytes".utf8).write(to: cloudGameDir.appendingPathComponent("save.dmsync"))
        await model.playNow(Fixtures.orbit)
        let unreadable = try #require(model.cloudConflict)
        #expect(unreadable.isUnreadable)
        await model.resolveCloudConflictNow(.playOffline)
        #expect(launcher.launched.count == 2)
        #expect(launcher.launched.last?.environment["DM_SAVE_SYNC_CHOICE"] == "offline")
    }
}

// MARK: - 5 & 6. `DM_PAD_MERGE` toggle and 7-day signing `<= 48h` banner (UX 3.3.2)

@MainActor @Suite struct PadMergeAndSigningTests {
    @Test func padMergePersistsAndReachesGameLaunchAndEngineLaunchPlan() async throws {
        let box = try Sandbox()
        try box.giveAppData(Fixtures.orbit)
        let shell = freshShellSettings()
        let launcher = RecordingLauncher()
        let model = ShellHostModel(config: box.config(), launcher: launcher, shellSettings: shell)

        #expect(!model.padMerge)
        await model.playNow(Fixtures.orbit)
        #expect(launcher.launched.last?.environment["DM_PAD_MERGE"] == nil)

        model.actions.onPadMergeChange(true)
        #expect(model.padMerge && shell.padMerge)
        #expect(ShellSettingsStore(defaults: shell.defaults).padMerge)

        await model.playNow(Fixtures.orbit)
        let launchedGame = try #require(launcher.launched.last)
        #expect(launchedGame.environment["DM_PAD_MERGE"] == "1")
        let plan = EngineLaunchPlan.make(game: launchedGame, appResources: box.root,
                                         documents: box.appData.deletingLastPathComponent(), envFileText: nil)
        #expect(plan.environment["DM_PAD_MERGE"] == "1")

        model.actions.onPadMergeChange(false)
        #expect(!model.padMerge && !shell.padMerge)
        await model.playNow(Fixtures.orbit)
        #expect(launcher.launched.last?.environment["DM_PAD_MERGE"] == nil)
    }

    @Test func provisioningProfileParsesCMSWrappedPlistAndHandlesBoundariesSafely() throws {
        let box = try Sandbox()
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let plistObj: [String: Any] = ["AppIDName": "NX2Apple", "ExpirationDate": expiry]
        let xmlPlist = try PropertyListSerialization.data(fromPropertyList: plistObj, format: .xml, options: 0)

        // Wrap XML plist inside realistic binary CMS envelope bytes before `<?xml` and after `</plist>`.
        var cmsData = Data([0x30, 0x82, 0x05, 0x10, 0x06, 0x09, 0x2A, 0x86, 0x48])
        cmsData.append(xmlPlist)
        cmsData.append(Data([0x31, 0x82, 0x01, 0x00, 0xDE, 0xAD, 0xBE, 0xEF]))

        let profileURL = box.root.appendingPathComponent("embedded.mobileprovision")
        try cmsData.write(to: profileURL)
        #expect(ProvisioningProfile.expiration(at: profileURL) == expiry)
        #expect(ProvisioningProfile.expiration(fromProfile: xmlPlist) == expiry)

        // Missing, empty, damaged, and oversize (> 4 MiB) inputs return nil safely without throwing or trapping.
        #expect(ProvisioningProfile.expiration(at: box.root.appendingPathComponent("missing.mobileprovision")) == nil)
        #expect(ProvisioningProfile.expiration(fromProfile: Data()) == nil)
        #expect(ProvisioningProfile.expiration(fromProfile: Data("<?xml broken".utf8)) == nil)
        let oversize = Data(repeating: 0x41, count: ProvisioningProfile.maxProfileBytes + 1)
        #expect(ProvisioningProfile.expiration(fromProfile: oversize) == nil)

        // 48-hour threshold boundaries.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ProvisioningProfile.warning(expiration: nil, now: now) == nil)
        #expect(ProvisioningProfile.warning(expiration: now.addingTimeInterval(48 * 3600 + 1), now: now) == nil)
        #expect(ProvisioningProfile.warning(expiration: now.addingTimeInterval(48 * 3600), now: now) == .expiringHours(48))
        #expect(ProvisioningProfile.warning(expiration: now.addingTimeInterval(12 * 3600 + 1800), now: now) == .expiringHours(12))
        #expect(ProvisioningProfile.warning(expiration: now.addingTimeInterval(1800), now: now) == .expiringSoon)
        #expect(ProvisioningProfile.warning(expiration: now, now: now) == .expired)
        #expect(ProvisioningProfile.warning(expiration: now.addingTimeInterval(-7200), now: now) == .expired)
    }

    @Test func modelPublishesAndDismissesSigningWarningBanner() async throws {
        let box = try Sandbox()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var cfg = box.config(now: { now })
        cfg.provisioningExpiration = { now.addingTimeInterval(18 * 3600 + 600) }

        let model = ShellHostModel(config: cfg)
        await model.waitForStartupTasks()
        #expect(model.signingWarning == .expiringHours(18))

        model.dismissSigningWarning()
        #expect(model.signingWarning == nil)
    }
}
