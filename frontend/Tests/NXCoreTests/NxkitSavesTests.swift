import XCTest
@testable import NXCore

/// The save flow of an app nxkit built runs with nxkit's names and commands (SaveEngine): the same flow as the dm engine's.
final class NxkitSavesTests: XCTestCase {
    private let support = URL(fileURLWithPath: "/Users/x/Library/Application Support")
    private let tid = "0100abcdef000000"
    private let nxkit = NxkitSaveEngine()

    func testAnAppNxkitBuiltGetsNxkitsEngine() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("nxkit-app-\(UUID().uuidString)/Hades.app")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources/nxkit"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: app.appendingPathComponent("Contents/MacOS/nxkit-host"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.appendingPathComponent("Contents/MacOS/nxkit-host").path)
        let plist: [String: Any] = ["CFBundleExecutable": "nxkit-host", "CFBundleIdentifier": "org.nxkit.game.\(tid)", "CFBundleName": "Hades",
                                    "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(SaveEngines.forApp(app.path).saveKey, "NXKIT_SAVE")
        XCTAssertEqual(SaveEngines.forApp("/nonexistent/Game.app").saveKey, "DM_SAVE")
        XCTAssertEqual(SaveEngines.forApp("").saveKey, "DM_SAVE")
    }

    func testTheUsualSaveIsNxkitsAndALibraryFolderDoesNotMoveIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nxkit-lib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent(".nx2apple-library"))
        let save = SaveLocations.effectiveSave(titleID: tid, appPath: root.appendingPathComponent("Hades.app").path, global: .init(), game: .init(),
                                               support: support, engine: nxkit, volumeHolds: { _ in true })
        XCTAssertEqual(save.path.path, "/Users/x/Library/Application Support/nxkit/0100ABCDEF000000/save")
        XCTAssertEqual(save.source, .standard, "nxkit-host finds it without being told")
        XCTAssertEqual(SaveLocations.environment(save: save, cloud: .init(folder: nil, source: .standard), engine: nxkit), [:])
    }

    func testAChosenSaveAndCloudFolderGoUnderNxkitsNames() {
        let save = SaveLocations.effectiveSave(titleID: tid, appPath: "", global: .init(), game: SaveGameOverride(saveFolder: "/Volumes/Mine/hades"),
                                               support: support, engine: nxkit, volumeHolds: { _ in true })
        let env = SaveLocations.environment(save: save, cloud: .init(folder: "icloud", source: .global), engine: nxkit)
        XCTAssertEqual(env, ["NXKIT_SAVE": "/Volumes/Mine/hades", "NXKIT_SAVE_SYNC": "icloud"])
    }

    func testAPlayerPlaysAsUserOneInTheirOwnFolderUnderTheirName() {
        let base = URL(fileURLWithPath: "/Users/x/Library/Application Support/nxkit/0100ABCDEF000000/save")
        let env = PlayerProfile(id: "ana", name: "Ana").environment(base: base, engine: nxkit)
        XCTAssertEqual(env, ["NXKIT_SAVE": "/Users/x/Library/Application Support/nxkit/0100ABCDEF000000/profiles/ana/save",
                             "NXKIT_SAVE_SYNC": "0", "NXKIT_USER": "1", "NXKIT_NICK": "Ana"])
        XCTAssertEqual(PlayerProfile(id: PlayerProfile.defaultID, name: "").environment(base: base, engine: nxkit), [:])
        XCTAssertEqual(PlayerProfile(id: PlayerProfile.defaultID, name: "Zijad").environment(base: base, engine: nxkit),
                       ["NXKIT_USER": "1", "NXKIT_NICK": "Zijad"], "the default player keeps the usual save and cloud saves")
    }

    func testTheReportAndTheSendAreTheAppsOwnHost() {
        XCTAssertEqual(nxkit.reportCommand(app: "/Games/Hades.app", wait: 10), ["/Games/Hades.app/Contents/MacOS/nxkit-host", "--save-sync-report=10000"])
        XCTAssertEqual(nxkit.sendCommand(app: "/Games/Hades.app"), ["/Games/Hades.app/Contents/MacOS/nxkit-host", "--save-sync-send"])
        XCTAssertTrue(nxkit.takesChoice(app: "/Games/Hades.app"))
        XCTAssertNil(DmSaveEngine().reportCommand(app: "/Games/Hades.app", wait: 10), "the launcher compares a dm game's saves itself")
        XCTAssertNil(DmSaveEngine().sendCommand(app: "/Games/Hades.app"), "the dm engine sends at its exit")
    }

    func testTheSendRunsWithTheGamesEnvironmentOnlyWhenItSyncs() throws {
        let game = ["NXKIT_SAVE": "/s/save", "NXKIT_SAVE_SYNC": "/Volumes/Cloud"]
        let launch = try XCTUnwrap(CloudSaveSend.launch(app: "/Games/Hades.app", environment: game, engine: nxkit, base: ["HOME": "/Users/x", "NXKIT_SAVE": "/old"]))
        XCTAssertEqual(launch.executable, "/Games/Hades.app/Contents/MacOS/nxkit-host")
        XCTAssertEqual(launch.arguments, ["--save-sync-send"])
        XCTAssertEqual(launch.environment, ["HOME": "/Users/x", "NXKIT_SAVE": "/s/save", "NXKIT_SAVE_SYNC": "/Volumes/Cloud"])
        XCTAssertNil(CloudSaveSend.launch(app: "/Games/Hades.app", environment: ["NXKIT_SAVE_SYNC": "0"], engine: nxkit))
        XCTAssertNil(CloudSaveSend.launch(app: "/Games/Hades.app", environment: [:], engine: nxkit))
        XCTAssertNil(CloudSaveSend.launch(app: "/Games/Hades.app", environment: ["DM_SAVE_SYNC": "icloud"], engine: DmSaveEngine()))
    }

    func testTheChoiceGoesUnderTheEnginesName() {
        let cloud = CloudSaveCheck.Save(hash: "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(CloudSaveCheck.environment(.cloud, cloud: cloud, key: nxkit.choiceKey), ["NXKIT_SAVE_SYNC_CHOICE": "cloud:0123456789abcdef0123456789abcdef"])
        XCTAssertEqual(CloudSaveCheck.environment(.local, cloud: .empty, key: nxkit.choiceKey), ["NXKIT_SAVE_SYNC_CHOICE": "local:none"])
    }

    func testTheUsersComeFromTheRegistry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nxkit-users-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let save = root.appendingPathComponent("save")
        XCTAssertEqual(SaveUsers.users(save: save), [1], "no registry: user 1 alone")
        try "nxnative-users-1 b\n".write(toFile: save.path + ".users", atomically: true, encoding: .utf8)
        XCTAssertEqual(SaveUsers.users(save: save), [1, 2, 4])
        XCTAssertEqual(SaveUsers.userPaths(save: save), [save.path + "_user2", save.path + "_user4", save.path + ".users"])
        try "garbage\n".write(toFile: save.path + ".users", atomically: true, encoding: .utf8)
        XCTAssertEqual(SaveUsers.users(save: save), [1])
    }
}
