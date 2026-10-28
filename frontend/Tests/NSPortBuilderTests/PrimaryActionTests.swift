import XCTest
@testable import NSPortBuilder

final class PrimaryActionTests: XCTestCase {
    private var temporary: URL!
    private let titleID = "0100535012974000"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-primary-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    private func makeApp(_ name: String = "Hades") throws -> URL {
        let app = temporary.appendingPathComponent(name + ".app")
        let executables = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
        for exe in ["nxnative", "dmhost"] {
            try FileManager.default.createSymbolicLink(at: executables.appendingPathComponent(exe), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        }
        let info: [String: Any] = ["DMTitleID": titleID, "CFBundleDisplayName": name, "CFBundleExecutable": "nxnative", "CFBundleIdentifier": "org.nxnative.primarytests"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }
    private func makeIPA() throws -> URL {
        let ipa = temporary.appendingPathComponent("Hades.ipa")
        try Data([0]).write(to: ipa)
        return ipa
    }
    private func makeIOSApp() throws -> URL {
        let app = temporary.appendingPathComponent("ios/Hades.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data([0]).write(to: app.appendingPathComponent("Info.plist"))
        return app
    }

    func testPrimaryForEachState() throws {
        let app = try makeApp(), ipa = try makeIPA(), ios = try makeIOSApp()
        XCTAssertEqual(LibraryGame(titleID: titleID, name: "H", appPath: app.path, ipaPath: ipa.path).primary, .play)
        var device = LibraryGame(titleID: titleID, name: "H", ipaPath: ipa.path, iosAppPath: ios.path)
        device.installedDevice = "UDID"
        XCTAssertEqual(device.primary, .openOnDevice)
        XCTAssertEqual(LibraryGame(titleID: titleID, name: "H", ipaPath: ipa.path).primary, .build, "an IPA alone builds, it does not offer to show the IPA")
        XCTAssertEqual(LibraryGame(titleID: titleID, name: "H").primary, .build)
        XCTAssertEqual(LibraryGame(titleID: titleID, name: "H", appPath: temporary.appendingPathComponent("gone.app").path).primary, .build, "a deleted Mac app")
    }

    func testRevealTargetPrefersWhatExists() throws {
        let app = try makeApp(), ipa = try makeIPA(), ios = try makeIOSApp()
        let gone = temporary.appendingPathComponent("gone").path
        XCTAssertEqual(LibraryGame(titleID: titleID, name: "H", appPath: app.path, ipaPath: ipa.path, iosAppPath: ios.path).revealTarget, app.path)
        XCTAssertEqual(LibraryGame(titleID: titleID, name: "H", appPath: gone, ipaPath: ipa.path, iosAppPath: ios.path).revealTarget, ipa.path)
        XCTAssertEqual(LibraryGame(titleID: titleID, name: "H", appPath: gone, ipaPath: gone, iosAppPath: ios.path).revealTarget, ios.path)
        XCTAssertNil(LibraryGame(titleID: titleID, name: "H", appPath: gone, ipaPath: gone, iosAppPath: gone).revealTarget)
        XCTAssertNil(LibraryGame(titleID: titleID, name: "H").revealTarget)
    }

    func testManageMenuShowsRevealOnlyWithATarget() throws {
        let ipa = try makeIPA()
        func ids(_ game: LibraryGame) -> [String] {
            ManageItem.list(game: game, labels: { $0 }, running: false, olderTools: false, activeBuildID: nil, hasBuildFolder: false, actions: ManageActions()).map(\.id)
        }
        XCTAssertTrue(ids(LibraryGame(titleID: titleID, name: "H", ipaPath: ipa.path)).contains("reveal"))
        XCTAssertFalse(ids(LibraryGame(titleID: titleID, name: "H", appPath: temporary.appendingPathComponent("gone.app").path)).contains("reveal"))
    }

    func testStalePathsAreClearedOnLoad() throws {
        let app = try makeApp(), ipa = try makeIPA()
        let gone = temporary.appendingPathComponent("gone").path
        let kept = LibraryGame(titleID: titleID, name: "Kept", appPath: app.path, ipaPath: ipa.path)
        var stale = LibraryGame(titleID: "0100000000010000", name: "Stale", appPath: gone + ".app", ipaPath: gone + ".ipa", iosAppPath: gone + "/Hades.app")
        stale.installedDevice = "UDID"
        let file = temporary.appendingPathComponent("library.json")
        try JSONEncoder().encode([kept, stale]).write(to: file)
        let library = GameLibrary(file: file)
        let a = try XCTUnwrap(library.games.first { $0.name == "Kept" }), b = try XCTUnwrap(library.games.first { $0.name == "Stale" })
        XCTAssertEqual(a.appPath, app.path)
        XCTAssertEqual(a.ipaPath, ipa.path)
        XCTAssertEqual([b.appPath, b.ipaPath, b.iosAppPath, b.installedDevice], ["", "", "", ""])
        // saved: a fresh load sees the cleared entry too, and the entries are kept
        let again = GameLibrary(file: file)
        XCTAssertEqual(again.games.first { $0.name == "Stale" }?.appPath, "")
        XCTAssertEqual(again.games.count, 2)
    }

    func testPathsOnAnUnmountedVolumeStayAndMissingFilesOnAMountedOneAreCleared() throws {
        let volumes = temporary.appendingPathComponent("Volumes")
        try FileManager.default.createDirectory(at: volumes.appendingPathComponent("NX"), withIntermediateDirectories: true)   // mounted
        var away = LibraryGame(titleID: titleID, name: "Away", appPath: volumes.path + "/Unplugged/Games/Hades.app",
                               ipaPath: volumes.path + "/Unplugged/Hades.ipa", iosAppPath: volumes.path + "/Unplugged/ios/Hades.app")
        away.installedDevice = "UDID"
        let deleted = LibraryGame(titleID: "0100000000010000", name: "Deleted", appPath: volumes.path + "/NX/Games/Gone.app",
                                  ipaPath: volumes.path + "/NX/Gone.ipa")
        let file = temporary.appendingPathComponent("library.json")
        try JSONEncoder().encode([away, deleted]).write(to: file)
        let library = GameLibrary(file: file, volumes: volumes.path)   // the load prunes, against this fake /Volumes
        let a = try XCTUnwrap(library.games.first { $0.name == "Away" }), d = try XCTUnwrap(library.games.first { $0.name == "Deleted" })
        XCTAssertEqual(a.appPath, volumes.path + "/Unplugged/Games/Hades.app", "the drive is not connected: nothing is forgotten")
        XCTAssertEqual(a.ipaPath, volumes.path + "/Unplugged/Hades.ipa")
        XCTAssertEqual(a.iosAppPath, volumes.path + "/Unplugged/ios/Hades.app")
        XCTAssertEqual(a.installedDevice, "UDID")
        XCTAssertFalse(a.isReady)
        XCTAssertEqual([d.appPath, d.ipaPath], ["", ""], "the volume is mounted and the files (and their folder) are gone")
        XCTAssertTrue(GameLibrary.onUnmountedVolume(volumes.path + "/Unplugged/x", volumes: volumes.path))
        XCTAssertFalse(GameLibrary.onUnmountedVolume(volumes.path + "/NX/x", volumes: volumes.path))
        XCTAssertFalse(GameLibrary.onUnmountedVolume("/Users/someone/x.app"))
    }

    func testPruneAfterAppIsDeletedWhileRunning() throws {
        let app = try makeApp()
        let library = GameLibrary(file: temporary.appendingPathComponent("library.json"))
        _ = try library.addApp(app)
        XCTAssertEqual(library.games[0].primary, .play)
        try FileManager.default.removeItem(at: app)
        library.pruneMissingPaths()
        XCTAssertEqual(library.games[0].appPath, "")
        XCTAssertEqual(library.games[0].primary, .build)
    }

    func testTitlebarActionFollowsTheSetting() {
        XCTAssertEqual(TitlebarAction.resolve(actionSetting: "Maximize", miniaturizeFlag: nil), .zoom)
        XCTAssertEqual(TitlebarAction.resolve(actionSetting: "Fill", miniaturizeFlag: nil), .zoom)
        XCTAssertEqual(TitlebarAction.resolve(actionSetting: "Minimize", miniaturizeFlag: nil), .minimize)
        XCTAssertEqual(TitlebarAction.resolve(actionSetting: "None", miniaturizeFlag: nil), .none)
        XCTAssertEqual(TitlebarAction.resolve(actionSetting: "Do Nothing", miniaturizeFlag: nil), .none)
        XCTAssertEqual(TitlebarAction.resolve(actionSetting: nil, miniaturizeFlag: nil), .zoom, "macOS's default")
        XCTAssertEqual(TitlebarAction.resolve(actionSetting: "", miniaturizeFlag: nil), .zoom)
        XCTAssertEqual(TitlebarAction.resolve(actionSetting: nil, miniaturizeFlag: true), .minimize, "the older setting, when the new one is absent")
        XCTAssertEqual(TitlebarAction.resolve(actionSetting: nil, miniaturizeFlag: false), .zoom)
        XCTAssertEqual(TitlebarAction.resolve(actionSetting: "Maximize", miniaturizeFlag: true), .zoom, "the new setting wins")
    }
}
