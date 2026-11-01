import XCTest
@testable import NSPortBuilder

/// #382: a file name without a title ID used to give the work folder `game_build` and the app `game.app` for every game,
/// so a second game hit the first one's shader cache. One key per game now.
final class BuildKeyTests: XCTestCase {
    func testNameWithTitleIDKeepsItsFolder() {
        XCTAssertEqual(BuildModel.buildKey("/x/Game [01007EF00011E000][v0].nsp"), "01007EF00011E000")
        XCTAssertEqual(BuildModel.buildKey("/x/01007ef00011e000_v0_420d1c5034ab.nsp"), "01007EF00011E000")
    }

    func testDifferentNamesWithoutIDGetDifferentKeys() {
        let a = BuildModel.buildKey("/x/Zelda.nsp"), b = BuildModel.buildKey("/x/Mario.nsp")
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, "game")
    }

    func testSameNameGivesTheSameKeyEveryTime() {
        XCTAssertEqual(BuildModel.buildKey("/x/Zelda.nsp"), BuildModel.buildKey("/other/Zelda.nsp"))
        XCTAssertEqual(BuildModel.buildKey("/x/Zelda.nsp"), BuildModel.buildKey("/x/Zelda.nsp"))
        XCTAssertEqual(BuildModel.buildKey("/x/Zelda.nsp"), "Zelda-74c1008b")   // the Qt front end gives the same key
    }

    func testOddCharactersAreSanitized() {
        let k = BuildModel.buildKey("/x/Pokémon: Sword/Shield ../.. §.nsp")
        XCTAssertNil(k.range(of: "[^A-Za-z0-9_-]", options: .regularExpression))
        XCTAssertFalse(k.contains("/"))
        XCTAssertNotEqual(BuildModel.buildKey("/x/a b.nsp"), BuildModel.buildKey("/x/a_b.nsp"))   // same clean stem, different hash
        XCTAssertNil(BuildModel.buildKey("/x/日本語.nsp").range(of: "[^A-Za-z0-9_-]", options: .regularExpression))
    }

    func testBuildFolderStillEndsInBuild() {
        XCTAssertTrue((BuildModel.buildKey("/x/Zelda.nsp") + "_build").hasSuffix("_build"))
        XCTAssertEqual(BuildModel.buildKey("/x/[0100F2C0115B6000].nsp") + "_build", "0100F2C0115B6000_build")
    }

    /// The reporter's layout: <ID>/<ID>_v0_<hash>.nsp, the ID bare (no brackets), the full path passed in.
    func testBareIDInAFullPathIsFound() {
        let dir = "/Users/me/Games/01007EF00011E000/"
        XCTAssertEqual(BuildModel.titleID(dir + "01007EF00011E000_v0_420d1c5034ab.nsp"), 0x01007EF00011E000)
        XCTAssertEqual(BuildModel.buildKey(dir + "01007EF00011E000_v0_420d1c5034ab.nsp"), "01007EF00011E000")
        // the update and the DLC beside it keep their own IDs and never stand in for the base
        XCTAssertEqual(BuildModel.titleID(dir + "01007EF00011E800_v1048576_aaaa.nsp"), 0x01007EF00011E800)
        XCTAssertEqual(BuildModel.titleID(dir + "01007EF00011F001_bbbb.nsp"), 0x01007EF00011F001)
        XCTAssertEqual(BuildModel.buildKey(dir + "01007EF00011E000_v0_420d1c5034ab.nsp"),
                       BuildModel.buildKey("01007EF00011E000_v0_420d1c5034ab.nsp"))
        // the folder's ID does not leak into a file name that has none
        XCTAssertNotEqual(BuildModel.buildKey(dir + "Zelda.nsp"), "01007EF00011E000")
    }
}
