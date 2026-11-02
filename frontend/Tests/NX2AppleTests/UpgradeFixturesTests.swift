import XCTest
@testable import NX2Apple
@testable import NXCore

/// Files an older NX2Apple left on a player's Mac (Tests/Fixtures/upgrade), run through today's code. Each test checks one expectation
/// of tools/verify/expectations. A known gap is wrapped in XCTExpectFailure: the test passes while the gap is there and fails once the
/// behavior changes, so the fix also drops the gap mark of its expectation (tools/verify/README.md).
final class UpgradeFixturesTests: XCTestCase {
    private let titleID = "01006BB00C6F0000"
    private let fm = FileManager.default
    private var home: URL!
    private var support: URL { home.appendingPathComponent("Library/Application Support") }
    private var drive: URL { home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs") }

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appendingPathComponent("nxnative-upgrade-" + UUID().uuidString)
        try fm.createDirectory(at: drive, withIntermediateDirectories: true)
        try fm.createDirectory(at: support.appendingPathComponent("nxnative"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try fm.removeItem(at: home) }

    /// The fixture's text with `$HOME` as the temporary home.
    private func fixture(_ name: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<2 { url.deleteLastPathComponent() }   // frontend/Tests/NX2AppleTests/<this file> -> frontend/Tests
        let text = try String(contentsOf: url.appendingPathComponent("Fixtures/upgrade/\(name)"), encoding: .utf8)
        return text.replacingOccurrences(of: "$HOME", with: home.path)
    }

    /// The fixture as the game's env.txt in ~/Library/Application Support/nxnative/<title ID>.
    @discardableResult
    private func install(_ name: String) throws -> URL {
        let dir = support.appendingPathComponent("nxnative/\(titleID)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("env.txt")
        try Data(try fixture(name).utf8).write(to: file)
        return file
    }

    private func value(_ key: String, in text: String) -> String? {
        text.split(separator: "\n").first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
    }

    // expects: cloud-saves-04
    func testAnExplicitSyncFolderFromAnOlderVersionIsLeftAsItIs() throws {
        let file = try install("1.0.0-issue-490/env.txt")
        let before = try Data(contentsOf: file)
        // Both folders a player of #490 can have: the migration must not take the old NX2Apple Saves for the folder of this line
        try fm.createDirectory(at: drive.appendingPathComponent(CloudSavesMigration.oldFolder), withIntermediateDirectories: true)
        try fm.createDirectory(at: drive.appendingPathComponent("nxnative_launcher/\(titleID)"), withIntermediateDirectories: true)
        XCTAssertEqual(CloudSavesMigration.run(support: support.appendingPathComponent("nxnative"), drive: drive, log: { _ in }), [])
        XCTAssertEqual(try Data(contentsOf: file), before, "an explicit folder is the player's choice and stays byte for byte")
    }

    // expects: cloud-saves-05
    func testTheOldIcloudKeywordKeepsTheFolderTheIPhoneUses() throws {
        let file = try install("icloud-keyword/env.txt")
        try fm.createDirectory(at: drive.appendingPathComponent(CloudSavesMigration.oldFolder), withIntermediateDirectories: true)
        XCTAssertEqual(CloudSavesMigration.run(support: support.appendingPathComponent("nxnative"), drive: drive, log: { _ in }), [titleID])
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(value("DM_SAVE_SYNC", in: text), drive.appendingPathComponent(CloudSavesMigration.oldFolder).path)
        XCTAssertEqual(value("DM_FPS_TARGET", in: text), "30")
        XCTAssertEqual(value("DM_SHOW_FPS", in: text), "1")
    }

    /// #490: the engine reads DM_SAVE from the game's env.txt (the log of #490 says so), the Saves sheet does not. A save copied from the
    /// iPhone lands in Application Support, and the game, which reads the iCloud folder of DM_SAVE, never opens it.
    // expects: saves-05
    func testTheSavesSheetUsesTheDMSaveFolderOfEnvTxt() throws {
        let text = try fixture("1.0.0-issue-490/env.txt")
        try install("1.0.0-issue-490/env.txt")
        let dmSave = try XCTUnwrap(value("DM_SAVE", in: text))
        let app = home.appendingPathComponent("Games/switch/games/ported/\(titleID).app").path   // not a library folder
        let mac = SaveTransfer.macSave(titleID: titleID, appPath: app, support: support)
        // What it does today, so a change of either kind shows here
        XCTAssertEqual(mac.save.path, support.appendingPathComponent("nxnative/\(titleID)/save").path)
        XCTExpectFailure("#490: SaveTransfer.macSave does not read DM_SAVE from env.txt") {
            XCTAssertEqual(mac.save.path, dmSave)
        }
    }
}
