import XCTest
@testable import NSPortBuilder

/// The `DM_SAVE_SYNC=icloud` keyword changed meaning in the engine (NX2Apple Saves became nxnative Saves). A player whose Mac app
/// uses the keyword and whose iPhone app a bookmark to NX2Apple Saves must keep both on that folder. A folder chosen in either
/// app's window is already a path and is never touched.
final class CloudSavesMigrationTests: XCTestCase {
    private var temporary: URL!
    private var drive: URL { temporary.appendingPathComponent("CloudDocs") }
    private var support: URL { temporary.appendingPathComponent("nxnative") }
    private let folder = "/Users/p/Library/Mobile Documents/com~apple~CloudDocs/NX2Apple Saves"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-cloud-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    private func env(_ id: String, _ text: String?) throws -> URL {
        let dir = support.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("env.txt")
        if let text { try Data(text.utf8).write(to: file) }
        return file
    }

    private func oldFolderExists() throws {
        try FileManager.default.createDirectory(at: drive.appendingPathComponent(CloudSavesMigration.oldFolder), withIntermediateDirectories: true)
    }

    func testTheKeywordBecomesTheOldFolderAndTheRestOfTheFileStays() throws {
        let out = try XCTUnwrap(CloudSavesMigration.pinned("DM_FPS_TARGET=60\nDM_SAVE_SYNC=icloud\nDM_SHOW_FPS=1\n", to: folder))
        XCTAssertEqual(out, "DM_FPS_TARGET=60\n\(CloudSavesMigration.comment)\nDM_SAVE_SYNC=\(folder)\nDM_SHOW_FPS=1\n")
        XCTAssertNil(CloudSavesMigration.pinned(out, to: folder), "the second run changes nothing")
    }

    func testOnlyTheEffectiveLineIsRead() {
        XCTAssertNil(CloudSavesMigration.pinned("DM_SAVE_SYNC=0\nDM_SAVE_SYNC=icloud\n", to: folder), "the launcher keeps the first line, so the second never ran")
        XCTAssertNil(CloudSavesMigration.pinned("# DM_SAVE_SYNC=icloud\n", to: folder), "a comment")
        XCTAssertNil(CloudSavesMigration.pinned("DM_SAVE_SYNC=/Users/p/iCloud/Mine\n", to: folder), "an explicit folder")
        XCTAssertNil(CloudSavesMigration.pinned("DM_SAVE_SYNC=icloud-ish\nDM_OTHER=icloud\n", to: folder))
        XCTAssertNil(CloudSavesMigration.pinned("", to: folder))
        XCTAssertNotNil(CloudSavesMigration.pinned("  DM_SAVE_SYNC =icloud  \n", to: folder), "spaces around the key and at the end, as the launcher reads it")
        XCTAssertEqual(CloudSavesMigration.pinned("DM_SAVE_SYNC=icloud", to: folder)?.hasSuffix("DM_SAVE_SYNC=\(folder)"), true, "no final newline")
    }

    func testWindowsLineEndingsStay() throws {
        let out = try XCTUnwrap(CloudSavesMigration.pinned("DM_SAVE_SYNC=icloud\r\nDM_X=1\r\n", to: folder))
        XCTAssertEqual(out, "\(CloudSavesMigration.comment)\r\nDM_SAVE_SYNC=\(folder)\r\nDM_X=1\r\n")
    }

    func testAGameWithTheKeywordAndTheOldFolderKeepsIt() throws {
        try oldFolderExists()
        let file = try env("01007EF00011E000", "DM_SAVE_SYNC=icloud\n")
        let untouched = try env("0100000000010000", "DM_SAVE_SYNC=/somewhere/else\n")
        let none = try env("010015100B514000", nil)
        var lines: [String] = []
        XCTAssertEqual(CloudSavesMigration.run(support: support, drive: drive, log: { lines.append($0) }), ["01007EF00011E000"])
        XCTAssertTrue(try String(contentsOf: file).contains("DM_SAVE_SYNC=\(drive.appendingPathComponent("NX2Apple Saves").path)\n"))
        XCTAssertEqual(try String(contentsOf: untouched), "DM_SAVE_SYNC=/somewhere/else\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: none.path))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(CloudSavesMigration.run(support: support, drive: drive, log: { _ in }), [], "once")
    }

    func testWithoutTheOldFolderTheKeywordStaysAndMeansTheNewOne() throws {
        let file = try env("01007EF00011E000", "DM_SAVE_SYNC=icloud\n")
        XCTAssertEqual(CloudSavesMigration.run(support: support, drive: drive, log: { _ in }), [])
        XCTAssertEqual(try String(contentsOf: file), "DM_SAVE_SYNC=icloud\n")
    }

    func testTheOldFolderAndTheNewOneBothThereStillKeepsTheOldOne() throws {
        // The Mac app was rebuilt before this ran and wrote to nxnative Saves: the iPhone app is still on NX2Apple Saves
        try oldFolderExists()
        try FileManager.default.createDirectory(at: drive.appendingPathComponent("nxnative Saves"), withIntermediateDirectories: true)
        _ = try env("01007EF00011E000", "DM_SAVE_SYNC=icloud\n")
        XCTAssertEqual(CloudSavesMigration.run(support: support, drive: drive, log: { _ in }), ["01007EF00011E000"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: drive.appendingPathComponent("nxnative Saves").path), "nothing is deleted")
    }

    func testNothingToDoWithoutICloudDriveOrApps() {
        XCTAssertEqual(CloudSavesMigration.run(support: temporary.appendingPathComponent("none"), drive: temporary.appendingPathComponent("none"), log: { _ in }), [])
    }
}
