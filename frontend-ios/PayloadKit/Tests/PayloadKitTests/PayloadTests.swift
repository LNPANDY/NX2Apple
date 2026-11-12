import XCTest
@testable import PayloadKit

final class PayloadTests: XCTestCase {
    let fm = FileManager.default
    var root: URL!
    let title = "0100000000000000"
    let host = PayloadCapabilities(bundleID: "org.nxnative.shell", teamID: "TESTTEAM01", osVersion: "26.0")

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("payload-tests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try fm.removeItem(at: root) }

    func fixture(version: String = "1", content: Data = Data("resource".utf8)) throws -> (PayloadManifest, URL) {
        let parent = root.appendingPathComponent(UUID().uuidString)
        let framework = parent.appendingPathComponent("DmGame.framework")
        try fm.createDirectory(at: framework.appendingPathComponent("dm"), withIntermediateDirectories: true)
        try Self.native(team: host.teamID).write(to: framework.appendingPathComponent("DmGame"))
        let info: [String: Any] = ["CFBundleExecutable": "DmGame", "CFBundleIdentifier": "org.nxnative.game"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: framework.appendingPathComponent("Info.plist"))
        let game: [String: Any] = ["schema": 1, "loader": "FH", "title_id": title, "framework": "DmGame.framework",
                                  "framework_executable": "DmGame", "display_version": version, "min_os": "26.0",
                                  "modules": ["main"], "profile": "dm/profile.tsv", "shader_map": "dm/shaders.tsv", "launcher": "launcher.json"]
        try JSONSerialization.data(withJSONObject: game).write(to: framework.appendingPathComponent("game.manifest.json"))
        for name in ["dm/profile.tsv", "dm/shaders.tsv", "launcher.json"] { try content.write(to: framework.appendingPathComponent(name)) }
        let manifest = PayloadManifest(titleID: title, displayVersion: version, framework: "DmGame.framework", executable: "DmGame",
                                       minOS: "26.0", teamID: host.teamID, files: try PayloadArchive.fileList(framework: framework))
        return (manifest, parent)
    }

    func archive(_ manifest: PayloadManifest, _ parent: URL) throws -> URL {
        let file = root.appendingPathComponent(UUID().uuidString + ".nxpayload")
        try PayloadArchive.write(manifest: manifest, parent: parent, to: file)
        return file
    }

    @discardableResult func deliver(_ manifest: PayloadManifest, _ parent: URL, docs: URL, ready: Bool = true) throws -> URL {
        let inbox = docs.appendingPathComponent(PayloadStore.inboxName).appendingPathComponent(manifest.generation)
        try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        let payload = inbox.appendingPathComponent(PayloadArchive.fileName)
        try PayloadArchive.write(manifest: manifest, parent: parent, to: payload)
        if ready {
            let marker = PayloadArchive.Ready(generation: manifest.generation, bytes: try PayloadArchive.size(payload), sha256: try PayloadArchive.digest(payload))
            try PayloadArchive.encode(marker).write(to: inbox.appendingPathComponent(PayloadArchive.readyName))
        }
        return inbox
    }

    func testStreamRoundTripAndResourceBytes() throws {
        let (manifest, parent) = try fixture(content: Data(repeating: 0xa5, count: (1 << 20) + 17))
        let packed = try archive(manifest, parent)
        let dest = root.appendingPathComponent("extracted")
        XCTAssertEqual(try PayloadArchive.extract(packed, to: dest, host: host), manifest)
        for file in manifest.files { XCTAssertEqual(try PayloadArchive.digest(dest.appendingPathComponent(file.path)), file.sha256) }
        try PayloadNativeCode.validateFramework(manifest, directory: dest, validate: { _ in })
    }

    func testCancelledPackagingStopsAndRemovesItsPartialArchive() throws {
        let (manifest, parent) = try fixture(content: Data(repeating: 7, count: 3 << 20))
        let packed = root.appendingPathComponent("cancelled.nxpayload")
        var checks = 0
        XCTAssertThrowsError(try PayloadArchive.write(manifest: manifest, parent: parent, to: packed) {
            checks += 1
            if checks == 4 { throw CancellationError() }
        })
        XCTAssertEqual(checks, 4)
        XCTAssertFalse(fm.fileExists(atPath: packed.path))
    }

    func testCorruptAndTruncatedArchivesLeaveNoPartialGeneration() throws {
        let (manifest, parent) = try fixture()
        let packed = try archive(manifest, parent)
        let bytes = try Data(contentsOf: packed)
        for bad in [Data(bytes.dropLast()), bytes + Data([1]), Data("wrong".utf8)] {
            let input = root.appendingPathComponent(UUID().uuidString)
            try bad.write(to: input)
            let destination = root.appendingPathComponent(UUID().uuidString)
            XCTAssertThrowsError(try PayloadArchive.extract(input, to: destination, host: host))
            XCTAssertFalse(fm.fileExists(atPath: destination.path))
        }
        var corrupted = bytes
        corrupted[corrupted.count - 1] ^= 1
        try corrupted.write(to: packed)
        let destination = root.appendingPathComponent("bad-digest")
        XCTAssertThrowsError(try PayloadArchive.extract(packed, to: destination, host: host))
        XCTAssertFalse(fm.fileExists(atPath: destination.path))
    }

    func testManifestRejectsTraversalCollisionsAndOverflow() throws {
        let (original, _) = try fixture()
        for path in ["../escape", "/absolute", "DmGame.framework/../escape", "DmGame.framework//file", "DmGame.framework/a\\b", "DmGame.framework/a\0b"] {
            var manifest = original
            manifest.files[0].path = path
            XCTAssertThrowsError(try manifest.validate(), path)
        }
        var duplicate = original
        duplicate.files.append(duplicate.files[0])
        XCTAssertThrowsError(try duplicate.validate())
        duplicate = original
        duplicate.files.append(.init(path: original.files[0].path.uppercased(), bytes: 0, sha256: String(repeating: "0", count: 64)))
        XCTAssertThrowsError(try duplicate.validate())
        duplicate = original
        duplicate.files[0].bytes = UInt64.max
        XCTAssertThrowsError(try duplicate.validate())
    }

    func testRejectsLinksBeforePackaging() throws {
        let (_, parent) = try fixture()
        let framework = parent.appendingPathComponent("DmGame.framework")
        try fm.createSymbolicLink(at: framework.appendingPathComponent("outside"), withDestinationURL: root)
        XCTAssertThrowsError(try PayloadArchive.fileList(framework: framework))
    }

    func testRejectsALinkedFrameworkRootBeforeSigningBuildProducts() throws {
        let (_, parent) = try fixture()
        let alias = root.appendingPathComponent("Linked.framework")
        try fm.createSymbolicLink(at: alias, withDestinationURL: parent.appendingPathComponent("DmGame.framework"))
        XCTAssertThrowsError(try PayloadArchive.fileList(framework: alias))
    }

    func testRejectsTeamOSAndABIMismatch() throws {
        let (manifest, _) = try fixture()
        for bad in [PayloadCapabilities(bundleID: host.bundleID, teamID: "OTHER", osVersion: "26.0"),
                    PayloadCapabilities(bundleID: host.bundleID, teamID: host.teamID, glueABI: 99, osVersion: "26.0"),
                    PayloadCapabilities(bundleID: host.bundleID, teamID: host.teamID, osVersion: "25.0")] {
            XCTAssertThrowsError(try manifest.compatible(with: bad))
        }
    }

    func testUnsignedAndFakeSignatureAreNotAcceptedByKernelValidator() throws {
        let (manifest, parent) = try fixture()
        let executable = parent.appendingPathComponent(manifest.framework).appendingPathComponent(manifest.executable)
        XCTAssertEqual(try PayloadNativeCode.teamID(executable), host.teamID)
        XCTAssertThrowsError(try PayloadNativeCode.validate(executable))
    }

    func testAddReplayAndSavePreservation() async throws {
        let docs = root.appendingPathComponent("Documents")
        let store = try PayloadStore(documents: docs, host: host, validator: { _ in })
        let empty = try Data(contentsOf: docs.appendingPathComponent(PayloadStore.registryName))
        XCTAssertNil(try PayloadStore.selectedManifest(in: empty, titleID: title), "bundled-only hosts publish an authoritative empty selection")
        let (manifest, parent) = try fixture()
        let save = docs.appendingPathComponent("games/\(title)/save/progress")
        try fm.createDirectory(at: save.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("save".utf8).write(to: save)
        try deliver(manifest, parent, docs: docs)
        let receipts = try await store.processInbox()
        XCTAssertEqual(receipts.map(\.state), [.active])
        let active = await store.activeFrameworks()
        XCTAssertNotNil(active[title])
        XCTAssertEqual(try Data(contentsOf: save), Data("save".utf8))
        let replayedTransaction = try deliver(manifest, parent, docs: docs)
        let replay = try await store.processInbox()
        XCTAssertTrue(replay.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: replayedTransaction.path), "a durable receipt makes a replayed archive disposable")
    }

    func testLoadedUpdateIsDeferredUntilANewStoreStarts() async throws {
        let docs = root.appendingPathComponent("Documents")
        let store = try PayloadStore(documents: docs, host: host, validator: { _ in })
        let (old, parent) = try fixture()
        try deliver(old, parent, docs: docs)
        _ = try await store.processInbox()
        let active = await store.activeFrameworks()
        try await store.prepareLaunch(titleID: title, framework: XCTUnwrap(active[title]))
        let (update, updatedParent) = try fixture(version: "2")
        try deliver(update, updatedParent, docs: docs)
        let result = try await store.processInbox()
        XCTAssertEqual(result.map(\.state), [.restartRequired])
        let selections = await store.selections()
        XCTAssertEqual(selections[title]?.active, old)
        XCTAssertEqual(selections[title]?.pending, update)
        do { _ = try await store.activatePending(); XCTFail("promoted loaded code") } catch {}
        let restarted = try PayloadStore(documents: docs, host: host, validator: { _ in })
        let promoted = try await restarted.activatePending()
        XCTAssertEqual(promoted.map(\.state), [.active])
        let after = await restarted.selections()
        XCTAssertEqual(after[title]?.active, update)
        XCTAssertEqual(after[title]?.previous, old)
    }

    func testQueuedUpdatesFollowCompletionOrderInsteadOfRandomUUIDOrder() async throws {
        for loaded in [false, true] {
            let docs = root.appendingPathComponent("Documents-\(loaded)")
            let store = try PayloadStore(documents: docs, host: host, validator: { _ in })
            if loaded { try await store.prepareLaunch(titleID: title, framework: root.appendingPathComponent("bundled.framework")) }
            var (old, parent) = try fixture()
            old.generation = "ffffffff-ffff-ffff-ffff-ffffffffffff"
            var (update, updatedParent) = try fixture(version: "2")
            update.generation = "00000000-0000-0000-0000-000000000001"
            for (manifest, source, time) in [(old, parent, 1000.0), (update, updatedParent, 2000.0)] {
                let transaction = try deliver(manifest, source, docs: docs)
                try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: time)],
                                     ofItemAtPath: transaction.appendingPathComponent(PayloadArchive.readyName).path)
            }
            _ = try await store.processInbox()
            let selection = await store.selections()[title]
            XCTAssertEqual(loaded ? selection?.pending : selection?.active, update)
        }
    }

    func testCommittedImportWithoutReceiptDoesNotReplaceItsRecoveryHistory() async throws {
        for loaded in [false, true] {
            let docs = root.appendingPathComponent("Documents-\(loaded)")
            let store = try PayloadStore(documents: docs, host: host, validator: { _ in })
            let (old, parent) = try fixture()
            try deliver(old, parent, docs: docs)
            _ = try await store.processInbox()
            let (update, updatedParent) = try fixture(version: "2")
            try deliver(update, updatedParent, docs: docs)
            _ = try await store.processInbox()
            if loaded {
                let frameworks = await store.activeFrameworks()
                try await store.prepareLaunch(titleID: title, framework: XCTUnwrap(frameworks[title]))
            }
            // Simulate a committed registry with its transaction still present,
            // as after termination between the registry and receipt writes.
            try fm.removeItem(at: docs.appendingPathComponent("PayloadReceipts/\(update.generation).json"))
            try deliver(update, updatedParent, docs: docs)
            let receipts = try await store.processInbox()
            XCTAssertEqual(receipts.map(\.state), [.active])
            let selection = await store.selections()[title]
            XCTAssertEqual(selection?.active, update)
            XCTAssertEqual(selection?.previous, old)
            XCTAssertNil(selection?.pending)
        }
    }

    func testIncompleteTransferIsIgnoredAndRejectedUpdateKeepsCurrent() async throws {
        let docs = root.appendingPathComponent("Documents")
        let store = try PayloadStore(documents: docs, host: host, validator: { _ in })
        let (old, parent) = try fixture()
        try deliver(old, parent, docs: docs)
        _ = try await store.processInbox()
        let (update, updatedParent) = try fixture(version: "2")
        let transaction = try deliver(update, updatedParent, docs: docs, ready: false)
        let incomplete = try await store.processInbox()
        XCTAssertTrue(incomplete.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: transaction.path), "an incomplete transfer must remain available to finish")
        let bad = PayloadArchive.Ready(generation: update.generation, bytes: 1, sha256: "wrong")
        try PayloadArchive.encode(bad).write(to: transaction.appendingPathComponent(PayloadArchive.readyName))
        let rejected = try await store.processInbox()
        XCTAssertEqual(rejected.map(\.state), [.rejected])
        let after = await store.selections()
        XCTAssertEqual(after[title]?.active, old)
        XCTAssertFalse(fm.fileExists(atPath: transaction.path), "rejected payload bytes must not accumulate in the inbox")
        let saved = try JSONDecoder().decode(PayloadReceipt.self, from: Data(contentsOf:
            docs.appendingPathComponent("PayloadReceipts/\(update.generation).json")))
        XCTAssertEqual(saved.state, .rejected, "cleanup preserves the rejection outcome")
    }

    func testAReadyMarkerWithAMissingPartCanFinishLater() async throws {
        let docs = root.appendingPathComponent("Documents")
        let store = try PayloadStore(documents: docs, host: host, validator: { _ in })
        let (manifest, parent) = try fixture()
        let packed = try archive(manifest, parent)
        let bytes = try Data(contentsOf: packed)
        let transaction = docs.appendingPathComponent("PayloadInbox/" + manifest.generation)
        try fm.createDirectory(at: transaction, withIntermediateDirectories: true)
        let partSize = 512
        let count = (bytes.count + partSize - 1) / partSize
        func part(_ index: Int) -> URL { transaction.appendingPathComponent(String(format: "%@.nxpart.%04d.%04d", PayloadArchive.fileName, index, count)) }
        for index in 0..<(count - 1) { try bytes[(index * partSize)..<((index + 1) * partSize)].write(to: part(index)) }
        let ready = PayloadArchive.Ready(generation: manifest.generation, bytes: UInt64(bytes.count), sha256: try PayloadArchive.digest(packed), partSize: UInt64(partSize))
        try PayloadArchive.encode(ready).write(to: transaction.appendingPathComponent(PayloadArchive.readyName))
        let incomplete = try await store.processInbox()
        XCTAssertTrue(incomplete.isEmpty, "a completion/join race must not create a rejection receipt")
        try bytes[((count - 1) * partSize)...].write(to: part(count - 1))
        let complete = try await store.processInbox()
        XCTAssertEqual(complete.map(\.state), [.active])
    }

    func testChangingImportedCodeBeforePlayIsRejected() async throws {
        let docs = root.appendingPathComponent("Documents")
        let store = try PayloadStore(documents: docs, host: host, validator: { _ in })
        let (manifest, parent) = try fixture()
        try deliver(manifest, parent, docs: docs)
        _ = try await store.processInbox()
        let frameworks = await store.activeFrameworks()
        let framework = try XCTUnwrap(frameworks[title])
        let executable = framework.appendingPathComponent(manifest.executable)
        var bytes = try Data(contentsOf: executable)
        bytes[bytes.count - 2] ^= 1
        try bytes.write(to: executable)
        do { try await store.prepareLaunch(titleID: title, framework: framework); XCTFail("loaded modified code") } catch {}
    }

    func testDelayedOlderPartsCannotReplaceANewerSelectionAfterRestart() async throws {
        for loaded in [false, true] {
            let docs = root.appendingPathComponent("Delayed-\(loaded)")
            let store = try PayloadStore(documents: docs, host: host, validator: { _ in })
            if loaded { try await store.prepareLaunch(titleID: title, framework: root.appendingPathComponent("bundled.framework")) }
            let (old, parent) = try fixture()
            let packed = try archive(old, parent)
            let bytes = try Data(contentsOf: packed)
            let transaction = docs.appendingPathComponent("PayloadInbox/" + old.generation)
            try fm.createDirectory(at: transaction, withIntermediateDirectories: true)
            let partSize = 512
            let count = (bytes.count + partSize - 1) / partSize
            func part(_ i: Int) -> URL { transaction.appendingPathComponent(String(format: "%@.nxpart.%04d.%04d", PayloadArchive.fileName, i, count)) }
            for i in 0..<(count - 1) { try bytes[(i * partSize)..<((i + 1) * partSize)].write(to: part(i)) }
            let marker = transaction.appendingPathComponent(PayloadArchive.readyName)
            let ready = PayloadArchive.Ready(generation: old.generation, bytes: UInt64(bytes.count), sha256: try PayloadArchive.digest(packed), partSize: UInt64(partSize))
            try PayloadArchive.encode(ready).write(to: marker)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: marker.path)
            let incomplete = try await store.processInbox()
            XCTAssertTrue(incomplete.isEmpty)
            let (newer, newerParent) = try fixture(version: "2")
            let latest = try deliver(newer, newerParent, docs: docs)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2000)],
                                 ofItemAtPath: latest.appendingPathComponent(PayloadArchive.readyName).path)
            _ = try await store.processInbox()
            try bytes[((count - 1) * partSize)...].write(to: part(count - 1))
            let restarted = try PayloadStore(documents: docs, host: host, validator: { _ in })
            let late = try await restarted.processInbox()
            XCTAssertEqual(late.map(\.state), [.rejected])
            let selection = await restarted.selections()[title]
            XCTAssertEqual(loaded ? selection?.pending : selection?.active, newer)
        }
    }

    func testReadingAnExistingLibraryDoesNotRequireAdvertisingWrites() async throws {
        let docs = root.appendingPathComponent("ReadOnly")
        let store = try PayloadStore(documents: docs, host: host, validator: { _ in })
        let (manifest, parent) = try fixture()
        try deliver(manifest, parent, docs: docs)
        _ = try await store.processInbox()
        try fm.removeItem(at: docs.appendingPathComponent(PayloadStore.inboxName))
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: docs.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docs.path) }
        let reopened = try PayloadStore(documents: docs, host: host, validator: { _ in })
        let frameworks = await reopened.activeFrameworks()
        XCTAssertNotNil(frameworks[title])
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docs.path)
        _ = try await reopened.processInbox()
        XCTAssertTrue(fm.fileExists(atPath: docs.appendingPathComponent(PayloadStore.inboxName).path))
    }

    func testColdStartWithoutPendingDoesNotWriteTheRegistry() async throws {
        let docs = root.appendingPathComponent("ReadOnlyColdStart")
        let store = try PayloadStore(documents: docs, host: host, validator: { _ in })
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: docs.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docs.path) }
        let result = try await store.activatePending()
        XCTAssertTrue(result.isEmpty)
    }

    func testRegistryWithoutCompletionMetadataStillLoads() async throws {
        let docs = root.appendingPathComponent("LegacyRegistry")
        let store = try PayloadStore(documents: docs, host: host, validator: { _ in })
        let (manifest, parent) = try fixture()
        try deliver(manifest, parent, docs: docs)
        _ = try await store.processInbox()
        let registryFile = docs.appendingPathComponent(PayloadStore.registryName)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: registryFile)) as? [String: Any])
        var games = try XCTUnwrap(json["games"] as? [String: [String: Any]])
        games[title]?.removeValue(forKey: "lastCompletion")
        json["games"] = games
        try JSONSerialization.data(withJSONObject: json).write(to: registryFile)
        let reopened = try PayloadStore(documents: docs, host: host, validator: { _ in })
        let selected = await reopened.selections()
        XCTAssertEqual(selected[title]?.active, manifest)
    }

    func testColdStartRejectionKeepsThePreviousActiveGeneration() async throws {
        let docs = root.appendingPathComponent("Documents")
        let store = try PayloadStore(documents: docs, host: host, validator: { _ in })
        let (old, parent) = try fixture()
        try deliver(old, parent, docs: docs)
        _ = try await store.processInbox()
        let frameworks = await store.activeFrameworks()
        try await store.prepareLaunch(titleID: title, framework: XCTUnwrap(frameworks[title]))
        let (update, updatedParent) = try fixture(version: "2")
        try deliver(update, updatedParent, docs: docs)
        _ = try await store.processInbox()
        let generation = update.generation
        let restarted = try PayloadStore(documents: docs, host: host, validator: { url in
            if url.path.contains(generation) { throw PayloadError.signature("rotated identity") }
        })
        let receipts = try await restarted.activatePending()
        XCTAssertEqual(receipts.map(\.state), [.rejected])
        let selected = await restarted.selections()
        XCTAssertEqual(selected[title]?.active, old)
        XCTAssertNil(selected[title]?.pending)
    }

    // Deliberately non-cryptographic CodeDirectory fixture. Tests inject a
    // validator only for storage behavior, the real validator rejects this.
    static func native(team: String) -> Data {
        func words(_ values: [UInt32], big: Bool = false) -> Data {
            var result = Data()
            for value in values {
                var number = big ? value.bigEndian : value.littleEndian
                withUnsafeBytes(of: &number) { result.append(contentsOf: $0) }
            }
            return result
        }
        let length = UInt32(52 + team.utf8.count + 1)
        let directory = words([0xfade0c02, length, 0x20200, 0, 0, 0, 0, 0, 0, 0, 0, 0, 52], big: true) + Data(team.utf8) + Data([0])
        let signature = words([0xfade0cc0, UInt32(20 + directory.count), 1, 0, 20], big: true) + directory
        return words([0xfeedfacf, 0x0100000c, 0, 6, 1, 16, 0, 0, 0x1d, 16, 48, UInt32(signature.count)]) + signature
    }
}
