import XCTest
import PayloadKit
@testable import ShellHost
#if canImport(UIKit)
import UIKit
#endif

@MainActor final class PayloadMigrationTests: XCTestCase {
    func testLegacyLibraryAndDataRemainInPlaceAndAnImportOverridesOnlyItsTitle() async throws {
        let box = try FrameworkBox()
        let bundled = try box.makeFramework()
        let documents = box.documents
        let suite = "payload-migration-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("kept", forKey: "launcher.SAVED_SETTING")
        let save = documents.appendingPathComponent("games/\(Fixtures.orbit)/save/progress")
        try box.write("save", to: save)
        let host = PayloadCapabilities(bundleID: "org.nxnative.shell", teamID: "TESTTEAM01", osVersion: "26.0")
        let store = try PayloadStore(documents: documents, host: host, validator: { _ in }, metadataValidator: ShellPayloads.validateMetadata)
        let config = ShellHostConfig(gamesRoot: box.frameworks, appDataRoot: documents.appendingPathComponent("games"),
                                     defaults: { _ in UserDefaults(suiteName: suite)! }, payloads: store)
        let model = ShellHostModel(config: config)
        let legacy = model.entries
        await model.refreshPayloads()?.value
        XCTAssertEqual(model.entries, legacy)
        XCTAssertEqual(model.entries.first?.frameworkURL, bundled)

        let source = try FrameworkBox()
        let replacement = try source.makeFramework()
        try prepareFramework(replacement, host: host)
        try deliver(replacement, documents: documents, host: host)
        await model.refreshPayloads()?.value
        XCTAssertEqual(model.entries.count, 1)
        XCTAssertEqual(model.entries.first?.id, Fixtures.orbit)
        XCTAssertNotEqual(model.entries.first?.frameworkURL, bundled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundled.path), "legacy bundle remains usable")
        XCTAssertEqual(try String(contentsOf: save, encoding: .utf8), "save")
        XCTAssertEqual(defaults.string(forKey: "launcher.SAVED_SETTING"), "kept")
        XCTAssertEqual(model.appFolder(for: Fixtures.orbit), documents.appendingPathComponent("games/" + Fixtures.orbit))
    }

    func testForegroundIntakeWaitsUntilLibraryIsVisible() async throws {
        let box = try FrameworkBox()
        let host = PayloadCapabilities(bundleID: "org.nxnative.shell", teamID: "TESTTEAM01", osVersion: "26.0")
        let store = try PayloadStore(documents: box.documents, host: host, validator: { _ in }, metadataValidator: ShellPayloads.validateMetadata)
        let model = ShellHostModel(config: ShellHostConfig(gamesRoot: box.frameworks, appDataRoot: box.documents.appendingPathComponent("games"), payloads: store))
        let source = try FrameworkBox()
        let framework = try source.makeFramework()
        try prepareFramework(framework, host: host)
        try deliver(framework, documents: box.documents, host: host)
        model.payloadLibraryVisibility(false)
        XCTAssertNil(model.refreshPayloads())
        XCTAssertTrue(model.entries.isEmpty)
        model.payloadLibraryVisibility(true)
        await model.refreshPayloads()?.value
        XCTAssertEqual(model.entries.map(\.id), [Fixtures.orbit])
        XCTAssertFalse(model.processingPayloads)
        XCTAssertEqual(model.details.first?.game.state, .needsGameData)
        let selected = await store.selections()[Fixtures.orbit]
        let active = try XCTUnwrap(selected?.active)
        let data = box.documents.appendingPathComponent(PayloadStore.gameDataPath(titleID: Fixtures.orbit, generation: active.generation))
        try box.write("", to: data.appendingPathComponent("romfs/fixture.marker"))
        // Code is accepted before its separate data copy finishes. The visible
        // library must notice that copy without reopening or reloading it.
        for _ in 0..<30 {
            if model.details.first?.game.state == .playable { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(model.details.first?.game.state, .playable)
    }

    func testStartupIntakeCanFinishBeforeRequestedPlayWhileTheSceneIsInactive() async throws {
        let box = try FrameworkBox()
        let host = PayloadCapabilities(bundleID: "org.nxnative.shell", teamID: "TESTTEAM01", osVersion: "26.0")
        let store = try PayloadStore(documents: box.documents, host: host, validator: { _ in }, metadataValidator: ShellPayloads.validateMetadata)
        let source = try FrameworkBox()
        let framework = try source.makeFramework()
        try prepareFramework(framework, host: host)
        try deliver(framework, documents: box.documents, host: host)
        try box.write("data", to: box.documents.appendingPathComponent("games/\(Fixtures.orbit)/fixture.marker"))
        let log = LogBox()
        let suite = "payload-startup-" + UUID().uuidString
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let model = ShellHostModel(config: ShellHostConfig(gamesRoot: box.frameworks, appDataRoot: box.documents.appendingPathComponent("games"),
                                                         defaults: { _ in UserDefaults(suiteName: suite)! }, payloads: store),
                                   launcher: StubGameLauncher(log: { log.add($0) }))
        // Start intake during bootstrap, before hosting observes an inactive
        // scene, then retain that task for the queued environment-selected Play.
        let startup = model.refreshPayloads()
        let play = Task { @MainActor in
            await startup?.value
            await model.playNow(Fixtures.orbit)
        }
        model.payloadSceneActive(false)
        await play.value
        XCTAssertEqual(log.all.count, 1, "requested Play must wait for the imported catalogue")
    }

    func testDamagedLauncherCannotReplaceAnExistingGame() async throws {
        let box = try FrameworkBox()
        let bundled = try box.makeFramework()
        let host = PayloadCapabilities(bundleID: "org.nxnative.shell", teamID: "TESTTEAM01", osVersion: "26.0")
        let store = try PayloadStore(documents: box.documents, host: host, validator: { _ in }, metadataValidator: ShellPayloads.validateMetadata)
        let model = ShellHostModel(config: ShellHostConfig(gamesRoot: box.frameworks, appDataRoot: box.documents.appendingPathComponent("games"), payloads: store))
        let source = try FrameworkBox()
        let framework = try source.makeFramework()
        try prepareFramework(framework, host: host)
        try box.write("broken", to: framework.appendingPathComponent("dm/launcher.json"))
        try deliver(framework, documents: box.documents, host: host)
        await model.refreshPayloads()?.value
        XCTAssertEqual(model.entries.first?.frameworkURL, bundled)
        XCTAssertNotNil(model.notice)
        let selections = await store.selections()
        XCTAssertNil(selections[Fixtures.orbit])
    }

    func testFailedInboxReceiptDoesNotHideExistingImportsAtStartup() async throws {
        let box = try FrameworkBox()
        let host = PayloadCapabilities(bundleID: "org.nxnative.shell", teamID: "TESTTEAM01", osVersion: "26.0")
        let store = try PayloadStore(documents: box.documents, host: host, validator: { _ in }, metadataValidator: ShellPayloads.validateMetadata)
        let source = try FrameworkBox()
        let framework = try source.makeFramework()
        try prepareFramework(framework, host: host)
        try deliver(framework, documents: box.documents, host: host)
        _ = try await store.processInbox()
        let generation = UUID().uuidString.lowercased()
        try box.write("bad-json", to: box.documents.appendingPathComponent("PayloadInbox/\(generation)/ready.json"))
        let receipts = box.documents.appendingPathComponent("PayloadReceipts")
        try FileManager.default.removeItem(at: receipts)
        try Data("blocked".utf8).write(to: receipts)
        let model = ShellHostModel(config: ShellHostConfig(gamesRoot: box.frameworks, appDataRoot: box.documents.appendingPathComponent("games"), payloads: store))
        await model.refreshPayloads()?.value
        XCTAssertEqual(model.entries.map(\.id), [Fixtures.orbit])
        XCTAssertNotNil(model.notice)
        XCTAssertFalse(model.processingPayloads)
    }

    func testLaterIntakeFailureDoesNotLoseTheReceiptThatRestoresADeletedTitle() async throws {
        let box = try FrameworkBox()
        _ = try box.makeFramework()
        let suite = "payload-partial-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = PayloadCapabilities(bundleID: "org.nxnative.shell", teamID: "TESTTEAM01", osVersion: "26.0")
        let receipts = box.documents.appendingPathComponent("PayloadReceipts")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: receipts.path) }
        let store = try PayloadStore(documents: box.documents, host: host, validator: { executable in
            let marker = executable.deletingLastPathComponent().appendingPathComponent("reject-and-block-receipt")
            if FileManager.default.fileExists(atPath: marker.path) {
                try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: receipts.path)
                throw PayloadError.signature("rejected test update")
            }
        }, metadataValidator: ShellPayloads.validateMetadata)
        let model = ShellHostModel(config: ShellHostConfig(gamesRoot: box.frameworks, appDataRoot: box.documents.appendingPathComponent("games"),
                                                         defaults: { _ in UserDefaults(suiteName: suite)! }, payloads: store))
        model.deleteGame(Fixtures.orbit, saves: false)
        XCTAssertTrue(model.entries.isEmpty)
        let source = try FrameworkBox()
        let framework = try source.makeFramework()
        try prepareFramework(framework, host: host)
        try deliver(framework, documents: box.documents, host: host)
        let fm = FileManager.default
        let good = try XCTUnwrap(fm.contentsOfDirectory(at: box.documents.appendingPathComponent("PayloadInbox"), includingPropertiesForKeys: nil).first)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: good.appendingPathComponent("ready.json").path)
        let rejected = try FrameworkBox()
        let rejectedFramework = try rejected.makeFramework()
        try prepareFramework(rejectedFramework, host: host)
        try box.write("reject", to: rejectedFramework.appendingPathComponent("reject-and-block-receipt"))
        try deliver(rejectedFramework, documents: box.documents, host: host)
        let bad = try XCTUnwrap(fm.contentsOfDirectory(at: box.documents.appendingPathComponent("PayloadInbox"), includingPropertiesForKeys: nil).first { $0 != good })
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2000)], ofItemAtPath: bad.appendingPathComponent("ready.json").path)
        await model.refreshPayloads()?.value
        XCTAssertEqual(model.entries.map(\.id), [Fixtures.orbit])
        XCTAssertNil(defaults.string(forKey: GameDeletion.deletedKey))
        XCTAssertNotNil(model.notice)
    }

    #if canImport(UIKit)
    func testUIKitActivationProcessesImportsWithoutASwiftUIScene() async throws {
        let box = try FrameworkBox()
        let host = PayloadCapabilities(bundleID: "org.nxnative.shell", teamID: "TESTTEAM01", osVersion: "26.0")
        let store = try PayloadStore(documents: box.documents, host: host, validator: { _ in }, metadataValidator: ShellPayloads.validateMetadata)
        let model = ShellHostModel(config: ShellHostConfig(gamesRoot: box.frameworks, appDataRoot: box.documents.appendingPathComponent("games"), payloads: store))
        model.payloadSceneActive(false)
        let source = try FrameworkBox()
        let framework = try source.makeFramework()
        try prepareFramework(framework, host: host)
        try deliver(framework, documents: box.documents, host: host)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await model.refreshPayloads()?.value
        XCTAssertEqual(model.entries.map(\.id), [Fixtures.orbit])
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertNil(model.refreshPayloads())
    }
    #endif

    func prepareFramework(_ framework: URL, host: PayloadCapabilities) throws {
        let file = framework.appendingPathComponent("game.manifest.json")
        var game = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        game["loader"] = "FH"
        game["min_os"] = "26.0"
        try JSONSerialization.data(withJSONObject: game).write(to: file)
        let executable = try XCTUnwrap(game["framework_executable"] as? String)
        func words(_ values: [UInt32], big: Bool = false) -> Data {
            var data = Data()
            for value in values { var v = big ? value.bigEndian : value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
            return data
        }
        let count = UInt32(53 + host.teamID.utf8.count)
        let cd = words([0xfade0c02, count, 0x20200, 0, 0, 0, 0, 0, 0, 0, 0, 0, 52], big: true) + Data(host.teamID.utf8) + Data([0])
        let sig = words([0xfade0cc0, UInt32(20 + cd.count), 1, 0, 20], big: true) + cd
        try (words([0xfeedfacf, 0x0100000c, 0, 6, 1, 16, 0, 0, 0x1d, 16, 48, UInt32(sig.count)]) + sig).write(to: framework.appendingPathComponent(executable))
        let info = ["CFBundleExecutable": executable, "CFBundleIdentifier": "org.nxnative.fixture"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: framework.appendingPathComponent("Info.plist"))
        for key in ["profile", "shader_map"] {
            let path = try XCTUnwrap(game[key] as? String)
            let url = framework.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: url)
        }
    }

    @discardableResult func deliver(_ framework: URL, documents: URL, host: PayloadCapabilities) throws -> PayloadManifest {
        let game = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: framework.appendingPathComponent("game.manifest.json"))) as? [String: Any])
        let manifest = PayloadManifest(titleID: Fixtures.orbit, displayVersion: game["display_version"] as! String,
                                       framework: framework.lastPathComponent, executable: game["framework_executable"] as! String,
                                       minOS: "26.0", teamID: host.teamID, files: try PayloadArchive.fileList(framework: framework))
        let transaction = documents.appendingPathComponent("PayloadInbox/" + manifest.generation)
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)
        let archive = transaction.appendingPathComponent(PayloadArchive.fileName)
        try PayloadArchive.write(manifest: manifest, parent: framework.deletingLastPathComponent(), to: archive)
        let ready = PayloadArchive.Ready(generation: manifest.generation, bytes: try PayloadArchive.size(archive), sha256: try PayloadArchive.digest(archive))
        try PayloadArchive.encode(ready).write(to: transaction.appendingPathComponent(PayloadArchive.readyName))
        return manifest
    }
}
