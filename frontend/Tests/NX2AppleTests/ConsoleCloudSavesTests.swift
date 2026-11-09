import XCTest
@testable import NX2Apple
@testable import NXCore

/// Console mode's Cloud saves page reads each game's save state from the same files as the desktop's Cloud saves section, in a
/// temporary folder here: the setting, the folder's save and the last session's log. Nothing of the real ones is touched.
final class ConsoleCloudSavesTests: IsolatedDefaultsTestCase {
    private var root: URL!
    private let titleID = "0100535012974000"
    private var preference: String?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-console-saves-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        preference = nil
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func write(_ text: String, _ relative: String, date: Date? = nil) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let date { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
    }

    private func saves() -> GameCloudSaves {
        var s = GameCloudSaves(titleID: titleID, appPath: root.path + "/lib/Hades.app")
        s.home = root.path + "/home"
        s.support = root.appendingPathComponent("support")
        s.readPreference = { [unowned self] in preference }
        s.writePreference = { [unowned self] in preference = $0 }
        return s
    }
    private func row() -> ConsoleSaveRow { ConsoleCloudSaves.row(id: "g", title: "Hades", saves: saves()) }
    private var log: String { "home/Library/Logs/nxnative/\(titleID).log" }
    private var folder: String { root.path + "/cloud" }

    func testOffAndAMissingFolder() throws {
        XCTAssertEqual(row().status, .off)
        XCTAssertNil(row().updated)
        preference = folder
        XCTAssertEqual(row().status, .missingFolder, "the folder is not on this Mac")
    }

    func testNotPlayedThenEachLogState() throws {
        preference = folder
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        XCTAssertEqual(row().status, .notPlayed, "no log yet")
        let session = Date(timeIntervalSince1970: 1_790_000_000)
        let cases: [(String, ConsoleSaveStatus)] = [
            ("x\n", .notSynced),
            ("save sync: in step with the cloud\n", .synced),
            ("save sync: sent: 3 files, saved 12:00, to /c/save.dmsync\n", .synced),
            ("save sync: this device's save (saved 12:00) is newer than the cloud's: it goes to the cloud\n", .pending),
            ("save sync: no save here or in the cloud yet\n", .noSave),
            ("[RED] save sync: could not write the cloud's save\n", .failed),
            ("save sync: off: DM_SAVE_SYNC=0\n", .notSynced),
        ]
        for (text, status) in cases {
            try write(text, log, date: session)
            XCTAssertEqual(row().status, status, text)
            XCTAssertEqual(row().updated, session, "no save in the folder: the last session's time")
            XCTAssertEqual(row().updatedFrom, .lastSession)
        }
        try write("save sync: brought in the cloud's save (from iPhone, saved 11:00)\n", log, date: session)
        XCTAssertEqual(row().status, .synced)
        XCTAssertEqual(row().device, "iPhone")
        try write("[RED] save sync: no space\n", log, date: session)
        XCTAssertEqual(row().detail, "no space", "the log's own words")
    }

    func testTheCloudSaveTimeWins() throws {
        preference = folder
        let cloud = Date(timeIntervalSince1970: 1_791_000_000)
        try write("save", "cloud/\(titleID)/save.dmsync", date: cloud)
        try write("save sync: in step with the cloud\n", log, date: Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(row().updated, cloud)
        XCTAssertEqual(row().updatedFrom, .cloudSave)
    }

    func testNewestFirstWithoutATimeLast() {
        let a = ConsoleSaveRow(id: "a", title: "A", status: .off)
        let b = ConsoleSaveRow(id: "b", title: "B", status: .synced, updated: Date(timeIntervalSince1970: 10))
        let c = ConsoleSaveRow(id: "c", title: "C", status: .synced, updated: Date(timeIntervalSince1970: 20))
        let d = ConsoleSaveRow(id: "d", title: "D", status: .off)
        XCTAssertEqual(ConsoleCloudSaves.sorted([a, b, c, d]).map(\.id), ["c", "b", "a", "d"])
    }
}
