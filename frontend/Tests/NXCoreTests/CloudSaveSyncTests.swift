import XCTest
@testable import NXCore

/// #499: the cloud saves folder a Mac game uses, read as dm/mac/launcher.c reads it, and the sync state of its last session's log.
final class CloudSaveSyncTests: XCTestCase {
    private let home = "/Users/jo"
    private let drive = "/Users/jo/Library/Mobile Documents/com~apple~CloudDocs"
    private let id = "0100535012974000"

    // ---- env.txt files as older versions and players wrote them ----

    /// What CloudSavesMigration wrote in v0.9 for a game on the old keyword: its comment, then the path.
    func testTheMigrationsPinnedPathCounts() {
        let text = CloudSavesMigration.comment + "\nDM_SAVE_SYNC=\(drive)/NX2Apple Saves\nDM_FPS_TARGET=60\n"
        let s = CloudSaveSync.resolve(playerEnv: text, appEnv: nil, preference: "/Elsewhere", home: home)
        XCTAssertEqual(s, .init(source: .playerEnv, value: "\(drive)/NX2Apple Saves", folder: "\(drive)/NX2Apple Saves"))
    }

    /// The keyword a player wrote by hand, with Windows line ends (#490 had one like it).
    func testTheIcloudKeywordIsNxnativeSaves() {
        let s = CloudSaveSync.resolve(playerEnv: "DM_SAVE_SYNC=icloud\r\n", appEnv: nil, preference: nil, home: home)
        XCTAssertEqual(s.folder, "\(drive)/nxnative Saves")
        XCTAssertEqual(s.value, "icloud")
    }

    func testCommentsSpacesAndTheFirstLineRule() {
        XCTAssertNil(CloudSaveSync.envValue("# DM_SAVE_SYNC=/old\n  #DM_SAVE_SYNC=/older\n"))
        XCTAssertEqual(CloudSaveSync.envValue("  DM_SAVE_SYNC =/a folder/  \t\nDM_SAVE_SYNC=/second\n"), "/a folder/")
        XCTAssertEqual(CloudSaveSync.envValue("DM_SAVE_SYNC= /x\n"), " /x", "launcher.c keeps what follows the = as it is")
        XCTAssertEqual(CloudSaveSync.folder(for: "/a folder/"), "/a folder")
        XCTAssertNil(CloudSaveSync.envValue("DM_SAVE_SYNCX=/no\n=nothing\n"))
    }

    func testOffWinsOverLaterPlaces() {
        let s = CloudSaveSync.resolve(playerEnv: "DM_SAVE_SYNC=0\n", appEnv: "DM_SAVE_SYNC=icloud\n", preference: "/P", home: home)
        XCTAssertEqual(s.source, .playerEnv)
        XCTAssertFalse(s.isOn)
    }

    func testTheOrderIsPlayerEnvThenAppEnvThenThePreference() {
        XCTAssertEqual(CloudSaveSync.resolve(playerEnv: "DM_FPS_TARGET=30\n", appEnv: "DM_SAVE_SYNC=/App\n", preference: "/P").source, .appEnv)
        XCTAssertEqual(CloudSaveSync.resolve(playerEnv: nil, appEnv: nil, preference: "/P"), .init(source: .preference, value: "/P", folder: "/P"))
        XCTAssertEqual(CloudSaveSync.resolve(playerEnv: nil, appEnv: nil, preference: ""), .init(source: .none, value: nil, folder: nil))
    }

    func testSettingTheLineKeepsEverythingElse() {
        let old = CloudSavesMigration.comment + "\r\nDM_SAVE_SYNC=icloud\r\nDM_FPS_TARGET=60\r\n"
        XCTAssertEqual(CloudSaveSync.settingEnv(old, to: "/New"), CloudSavesMigration.comment + "\r\nDM_SAVE_SYNC=/New\r\nDM_FPS_TARGET=60\r\n")
        XCTAssertEqual(CloudSaveSync.settingEnv("DM_FPS_TARGET=60", to: "0"), "DM_FPS_TARGET=60\nDM_SAVE_SYNC=0\n")
        XCTAssertEqual(CloudSaveSync.settingEnv(nil, to: "/New"), "DM_SAVE_SYNC=/New\n")
    }

    func testTheSaveFileFollowsCloudFile() {
        XCTAssertEqual(CloudSaveSync.saveFile(folder: "/C/Saves", titleID: id.lowercased()), "/C/Saves/\(id)/save.dmsync")
        XCTAssertEqual(CloudSaveSync.saveFile(folder: "/C/Saves/\(id.lowercased())", titleID: id), "/C/Saves/\(id.lowercased())/save.dmsync",
                       "the game's own folder is not given a second title ID")
    }

    func testTheFolderCheckSeesAWrongFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(CloudSaveSync.check(folder: root.path, titleID: id), .missing)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(id), withIntermediateDirectories: true)
        XCTAssertEqual(CloudSaveSync.check(folder: root.path, titleID: id), .noSave, "a folder nobody else writes this game to")
        try Data("DMSYNC1\n".utf8).write(to: root.appendingPathComponent("\(id)/save.dmsync"))
        guard case .hasSave(let date) = CloudSaveSync.check(folder: root.path, titleID: id) else { return XCTFail("the save is there") }
        XCTAssertNotNil(date)
    }

    // ---- the log ----

    func testTheLastResultOfTheLogCounts() {
        let log = """
        launcher: cloud saves through \(drive)/nxnative Saves
        [dm] save sync: on: \(drive)/nxnative Saves/\(id)/save.dmsync
        [dm] save sync: in step with the cloud
        [dm] save sync: this device's save (saved 2026-11-02 21:14:03) changed since the last sync: it goes to the cloud
        [dm] save sync: sent: 3 files, saved 2026-11-02 21:14:03, to \(drive)/nxnative Saves/\(id)/save.dmsync
        """
        XCTAssertEqual(CloudSaveSync.state(fromLog: log), .sent("3 files, saved 2026-11-02 21:14:03"))
    }

    func testEachResult() {
        func state(_ line: String) -> CloudSaveSync.LogState? { CloudSaveSync.state(fromLog: "[dm] save sync: on: /x\n[dm] " + line + "\n") }
        XCTAssertEqual(state("save sync: in step with the cloud"), .inStep)
        XCTAssertEqual(state("save sync: brought in the cloud's save (from iPhone17,1, saved 2026-11-02 08:00:00); this device's is kept in /s-backups/x"), .broughtIn("iPhone17,1"))
        XCTAssertEqual(state("save sync: this device's save (saved 2026-11-02 08:00:00) is not in the cloud yet: it goes to the cloud"), .waitingToSend)
        XCTAssertEqual(state("save sync: the cloud's save /x/save.dmsync cannot be read now; sending later"), .offline)
        XCTAssertEqual(state("save sync: the cloud's save did not come within 8 s"), .offline)
        XCTAssertEqual(state("save sync: no save here or in the cloud yet"), .nothingYet)
        XCTAssertEqual(state("save sync: off: iCloud Drive is not on for this Mac (no /Users/jo/Library/Mobile Documents/com~apple~CloudDocs)"),
                       .off("iCloud Drive is not on for this Mac (no /Users/jo/Library/Mobile Documents/com~apple~CloudDocs)"))
        XCTAssertEqual(state("[RED] save sync: sending to /x/save.dmsync failed (errno=13)"), .failed("sending to /x/save.dmsync failed (errno=13)"))
        XCTAssertNil(CloudSaveSync.state(fromLog: "launcher: saves /s\nfork patches: none\n"), "a session without cloud saves")
    }
}
