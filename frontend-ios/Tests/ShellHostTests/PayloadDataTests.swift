import XCTest
import PayloadKit
import ShellUI
@testable import ShellHost

extension PayloadMigrationTests {
    func testCloudSavePromptDefersIncomingPayloadUntilCancelled() async throws {
        let box = try FrameworkBox()
        let bundled = try box.makeFramework()
        let suite = "payload-cloud-" + UUID().uuidString
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let host = PayloadCapabilities(bundleID: "org.nxnative.shell", teamID: "TESTTEAM01", osVersion: "26.0")
        let store = try PayloadStore(documents: box.documents, host: host, validator: { _ in }, metadataValidator: ShellPayloads.validateMetadata)
        let cloud = box.root.appendingPathComponent("Cloud")
        try box.write("unreadable archive", to: cloud.appendingPathComponent("\(Fixtures.orbit)/save.dmsync"))
        try box.write("data", to: box.documents.appendingPathComponent("games/\(Fixtures.orbit)/fixture.marker"))
        let launcher = RecordingLauncher()
        let model = ShellHostModel(config: ShellHostConfig(gamesRoot: box.frameworks, appDataRoot: box.documents.appendingPathComponent("games"),
                                                         defaults: { _ in UserDefaults(suiteName: suite)! }, payloads: store),
                                   launcher: launcher, picker: FakePicker(url: cloud), shellSettings: ShellSettingsStore(defaults: UserDefaults(suiteName: suite)!))
        await model.waitForStartupTasks()
        await model.pickCloudSavesNow(Fixtures.orbit)
        await model.playNow(Fixtures.orbit)
        XCTAssertTrue(try XCTUnwrap(model.cloudConflict).isUnreadable)
        XCTAssertTrue(launcher.launched.isEmpty)

        let source = try FrameworkBox()
        let framework = try source.makeFramework()
        try prepareFramework(framework, host: host)
        try deliver(framework, documents: box.documents, host: host)
        XCTAssertNil(model.refreshPayloads(), "a save decision must retain the code generation it was prepared for")
        XCTAssertFalse(model.processingPayloads)
        XCTAssertEqual(model.entries.first?.frameworkURL, bundled)
        XCTAssertNotNil(model.cloudConflict)
        let waiting = await store.hasReadyTransactions()
        XCTAssertTrue(waiting)

        await model.resolveCloudConflictNow(.cancel)
        await model.refreshPayloads()?.value
        XCTAssertNil(model.cloudConflict)
        XCTAssertNotEqual(model.entries.first?.frameworkURL, bundled)
        XCTAssertTrue(launcher.launched.isEmpty)
    }

    func testStartupJoinKeepsPayloadGenerationDataSeparate() async throws {
        let box = try FrameworkBox()
        let source = try FrameworkBox()
        let host = PayloadCapabilities(bundleID: "org.nxnative.shell", teamID: "TESTTEAM01", osVersion: "26.0")
        let store = try PayloadStore(documents: box.documents, host: host, validator: { _ in }, metadataValidator: ShellPayloads.validateMetadata)
        let framework = try source.makeFramework()
        try prepareFramework(framework, host: host)
        let active = try deliver(framework, documents: box.documents, host: host)
        let activeData = box.documents.appendingPathComponent(PayloadStore.gameDataPath(titleID: Fixtures.orbit, generation: active.generation))
        let otherData = box.documents.appendingPathComponent(PayloadStore.gameDataPath(titleID: Fixtures.orbit, generation: UUID().uuidString.lowercased()))
        for (folder, text) in [(activeData, "active"), (otherData, "unused")] {
            try box.write(String(text.prefix(4)), to: folder.appendingPathComponent("fixture.marker.nxpart.0000.0002"))
            try box.write(String(text.dropFirst(4)), to: folder.appendingPathComponent("fixture.marker.nxpart.0001.0002"))
        }
        let suite = "payload-join-" + UUID().uuidString
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let launcher = RecordingLauncher()
        let model = ShellHostModel(config: ShellHostConfig(gamesRoot: box.frameworks, appDataRoot: box.documents.appendingPathComponent("games"),
                                                         defaults: { _ in UserDefaults(suiteName: suite)! }, joinPartSize: 4, payloads: store),
                                   launcher: launcher, shellSettings: ShellSettingsStore(defaults: UserDefaults(suiteName: suite)!))
        await model.refreshPayloads()?.value
        await model.waitForStartupTasks()
        XCTAssertEqual(try String(contentsOf: activeData.appendingPathComponent("fixture.marker"), encoding: .utf8), "active")
        XCTAssertEqual(try String(contentsOf: otherData.appendingPathComponent("fixture.marker"), encoding: .utf8), "unused")
        await model.playNow(Fixtures.orbit)
        XCTAssertEqual(launcher.launched.last?.dataURL.path, activeData.path)
        XCTAssertEqual(launcher.launched.last?.appFolder, model.appFolder(for: Fixtures.orbit))
    }

    func testLoadedUpdateKeepsItsDataUntilTheNewGenerationActivates() async throws {
        let box = try FrameworkBox()
        let host = PayloadCapabilities(bundleID: "org.nxnative.shell", teamID: "TESTTEAM01", osVersion: "26.0")
        let store = try PayloadStore(documents: box.documents, host: host, validator: { _ in }, metadataValidator: ShellPayloads.validateMetadata)
        let suite = "payload-data-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func config(_ store: PayloadStore) -> ShellHostConfig {
            ShellHostConfig(gamesRoot: box.frameworks, appDataRoot: box.documents.appendingPathComponent("games"),
                            defaults: { _ in UserDefaults(suiteName: suite)! }, payloads: store)
        }
        let launcher = RecordingLauncher()
        let model = ShellHostModel(config: config(store), launcher: launcher)
        let source = try FrameworkBox()
        let framework = try source.makeFramework()
        try prepareFramework(framework, host: host)
        let gameFile = framework.appendingPathComponent("game.manifest.json")
        var game = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: gameFile)) as? [String: Any])
        game["romfs_marker"] = ""
        game["romfs_identity"] = ""
        try JSONSerialization.data(withJSONObject: game).write(to: gameFile)
        let old = try deliver(framework, documents: box.documents, host: host)
        let appFolder = model.appFolder(for: Fixtures.orbit)
        let save = appFolder.appendingPathComponent("save/progress")
        try box.write("save", to: save)
        try box.write("legacy", to: appFolder.appendingPathComponent("romfs.img"))
        await model.refreshPayloads()?.value
        await model.playNow(Fixtures.orbit)
        XCTAssertEqual(launcher.launched.last?.dataURL, appFolder, "legacy data remains usable before a generation has its own copy")

        let oldData = box.documents.appendingPathComponent(PayloadStore.gameDataPath(titleID: Fixtures.orbit, generation: old.generation), isDirectory: true)
        try box.write("old", to: oldData.appendingPathComponent("romfs.img"))
        await model.playNow(Fixtures.orbit)
        XCTAssertEqual(launcher.launched.last?.dataURL, oldData)
        let update = try deliver(framework, documents: box.documents, host: host)
        let newData = box.documents.appendingPathComponent(PayloadStore.gameDataPath(titleID: Fixtures.orbit, generation: update.generation), isDirectory: true)
        try box.write("new", to: newData.appendingPathComponent("romfs.img"))
        await model.refreshPayloads()?.value
        let selection = await store.selections()[Fixtures.orbit]
        XCTAssertEqual(selection?.pending, update)
        await model.playNow(Fixtures.orbit)
        XCTAssertEqual(launcher.launched.last?.dataURL, oldData, "pending game data must not change the loaded generation's resources")
        XCTAssertEqual(try String(contentsOf: oldData.appendingPathComponent("romfs.img"), encoding: .utf8), "old")

        let restarted = try PayloadStore(documents: box.documents, host: host, validator: { _ in }, metadataValidator: ShellPayloads.validateMetadata)
        let nextLauncher = RecordingLauncher()
        let next = ShellHostModel(config: config(restarted), launcher: nextLauncher)
        await next.refreshPayloads()?.value
        await next.playNow(Fixtures.orbit)
        XCTAssertEqual(nextLauncher.launched.last?.dataURL, newData)
        XCTAssertEqual(nextLauncher.launched.last?.appFolder, appFolder, "save and cache paths stay title-based")
        XCTAssertEqual(try String(contentsOf: save, encoding: .utf8), "save")

        next.deleteGame(Fixtures.orbit, saves: false)
        XCTAssertTrue(next.entries.isEmpty)
        try box.write("old again", to: oldData.appendingPathComponent("romfs.img"))
        next.reload()
        XCTAssertTrue(next.entries.isEmpty, "an older retained generation must not revive a deleted markerless title")
        try box.write("new again", to: newData.appendingPathComponent("romfs.img"))
        next.reload()
        XCTAssertEqual(next.entries.map(\.id), [Fixtures.orbit], "only the active generation's restored data revives the title")
        XCTAssertEqual(try String(contentsOf: save, encoding: .utf8), "save")
    }
}
