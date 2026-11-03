import XCTest
@testable import NXCore

/// Which files make a game: classifying dropped files and a chosen folder into the four rows, and what a row accepts.
/// Runs on NXCore alone, without SwiftUI.
final class GameInputsTests: XCTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-inputs-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    /// A stand-in file of `size` bytes (the classification skips empty ones, as an unfinished download leaves).
    @discardableResult private func file(_ name: String, size: Int = 16, in folder: String = "") throws -> String {
        let dir = folder.isEmpty ? temporary! : temporary.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(name).path
        FileManager.default.createFile(atPath: path, contents: Data(repeating: 0, count: size))
        return path
    }

    /// The per-row Choose… dialog must not grey out compressed dumps (issue #236).
    func testChooseDialogOffersCompressedDumps() {
        XCTAssertEqual(Set(GameInputs.allowedFileTypes(for: .base)), ["nsp", "xci", "nsz", "xcz"])
        XCTAssertEqual(GameInputs.allowedFileTypes(for: .update), GameInputs.allowedFileTypes(for: .base))
        XCTAssertEqual(Set(GameInputs.allowedFileTypes(for: .dlc)), ["nsp", "nsz"])
        XCTAssertEqual(GameInputs.allowedFileTypes(for: .keys), ["keys"])
    }

    func testADroppedMixedSetIsSortedByTitleID() throws {
        let base = try file("Game [0100000000010000][v0].nsp", size: 64)
        let repack = try file("Game [0100000000010000].nsz", size: 32)
        let old = try file("Game [0100000000010800][v65536].nsp")
        let new = try file("Game [0100000000010800][v131072].nsz")
        let dlc1 = try file("Game DLC [0100000000011001].nsp"), dlc2 = try file("Game DLC [0100000000011002].xci")
        let keys = try file("prod.keys")
        let unfinished = try file("Game [0100000000010000].xci", size: 0)
        let unnamed = try file("game.nsp"), text = try file("readme.txt")
        let found = GameInputs.classify([dlc2, text, old, repack, unfinished, base, keys, new, unnamed, dlc1])
        XCTAssertEqual(found, GameInputs.Found(base: base, update: new, dlc: [dlc1, dlc2], keys: keys),
                       "the largest base, the newest update, every add-on sorted, the keys")
        XCTAssertEqual(GameInputs.classify([text, unnamed]), GameInputs.Found())
        XCTAssertFalse(GameInputs.Found(keys: keys).anyGame)
    }

    /// The names from issue #237: the title ID bare at the start of the name, the version as a `_vN` token.
    func testBareTitleIDNamesAreClassified() throws {
        let base = try file("01007EF00011E000_v0_420d1c5034ab.nsp", size: 64)
        let old = try file("01007EF00011E800_v1048576_48d51e6d7ff4.nsp")
        let new = try file("01007EF00011E800_v1114112_038ff9df0888.nsp")
        let dlc1 = try file("01007EF00011F001_v196608_8a46aae731b8.nsp")
        let dlc2 = try file("01007EF00011F002_v196608_193e5731baf2.nsp")
        let found = GameInputs.classify([dlc2, old, base, dlc1, new])
        XCTAssertEqual(found, GameInputs.Found(base: base, update: new, dlc: [dlc1, dlc2]))
        XCTAssertEqual(found.updateCount, 2)
        XCTAssertEqual(found.updateVersion, 1114112)
        // bracket names keep working, and win when a name has both
        XCTAssertEqual(TitleID.parse("Game [0100F2C0115B6000][v0].nsp"), 0x0100F2C0115B6000)
        XCTAssertEqual(TitleID.parse("Game 0100AAAA00000000 [0100F2C0115B6000].nsp"), 0x0100F2C0115B6000)
        XCTAssertEqual(TitleID.updateVersion("Game [v65536] _v1.nsp"), 65536)
        XCTAssertEqual(TitleID.updateVersion("Game v131072.nsp"), 131072)
        XCTAssertEqual(TitleID.updateVersion("01007EF00011E800_v1114112_038ff9df0888.nsp"), 1114112)
        XCTAssertEqual(TitleID.updateVersion("game.nsp"), 0)
        // token separators, and only IDs that look like Switch title IDs
        XCTAssertEqual(TitleID.parse("Game (01007EF00011E000).nsp"), 0x01007EF00011E000)
        XCTAssertEqual(TitleID.parse("Game-01007EF00011E000.nsp"), 0x01007EF00011E000)
        XCTAssertNil(TitleID.parse("0200000000000000_v0.nsp"))
        XCTAssertNil(TitleID.parse("x01007EF00011E000.nsp"), "not a token")
        XCTAssertNil(TitleID.parse("01007EF00011E0001.nsp"), "17 digits")
        // another game's update and DLC in the same folder are not taken for this base
        let other = try file("0100AAAA00000800_v65536_aaaaaaaaaaaa.nsp")
        let otherDLC = try file("0100AAAA00001001_v0_bbbbbbbbbbbb.nsp")
        XCTAssertEqual(GameInputs.classify([base, new, dlc1, other, otherDLC]).update, new)
        XCTAssertEqual(GameInputs.classify([base, new, dlc1, other, otherDLC]).dlc, [dlc1])
    }

    func testRowChecks() throws {
        let base = "01007EF00011E000_v0_420d1c5034ab.nsp"
        let update = "01007EF00011E800_v1114112_038ff9df0888.nsp"
        let dlc = "01007EF00011F001_v196608_8a46aae731b8.nsp"
        func check(_ kind: InputKind, _ name: String, _ b: String? = base) -> GameInputs.RowMismatch? {
            GameInputs.rowMismatch(kind, name: name, base: b)
        }
        XCTAssertNil(check(.update, update))
        XCTAssertNil(check(.dlc, dlc))
        XCTAssertNil(check(.base, base, nil))
        XCTAssertEqual(check(.dlc, update), .notDLC(0x01007EF00011E800), "the reporter's update in the DLC row")
        XCTAssertEqual(check(.update, dlc), .notUpdate(0x01007EF00011F001))
        XCTAssertEqual(check(.dlc, base), .notDLC(0x01007EF00011E000))
        XCTAssertEqual(check(.update, base), .notUpdate(0x01007EF00011E000))
        XCTAssertEqual(check(.base, update, nil), .notBase(0x01007EF00011E800))
        XCTAssertEqual(check(.base, dlc, nil), .notBase(0x01007EF00011F001))
        XCTAssertEqual(check(.update, "0100AAAA00000800_v1.nsp"), .otherGame)
        XCTAssertEqual(check(.dlc, "0100AAAA00001001_v1.nsp"), .otherGame)
        XCTAssertNil(check(.update, "0100AAAA00000800_v1.nsp", nil), "no base chosen yet")
        XCTAssertNil(check(.dlc, "game.nsp"), "no title ID in the name: the build script reads it from the package")
        XCTAssertNil(check(.keys, "prod.keys"))
    }
}
