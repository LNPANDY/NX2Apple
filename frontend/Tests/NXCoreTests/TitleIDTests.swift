import XCTest
@testable import NXCore

/// #382: a file name without a title ID used to give the work folder `game_build` and the app `game.app` for every game,
/// so a second game hit the first one's shader cache. One key per game now.
final class TitleIDTests: XCTestCase {
    func testNameWithTitleIDKeepsItsFolder() {
        XCTAssertEqual(TitleID.buildKey("/x/Game [01007EF00011E000][v0].nsp"), "01007EF00011E000")
        XCTAssertEqual(TitleID.buildKey("/x/01007ef00011e000_v0_420d1c5034ab.nsp"), "01007EF00011E000")
    }

    func testDifferentNamesWithoutIDGetDifferentKeys() {
        let a = TitleID.buildKey("/x/Zelda.nsp"), b = TitleID.buildKey("/x/Mario.nsp")
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, "game")
    }

    func testSameNameGivesTheSameKeyEveryTime() {
        XCTAssertEqual(TitleID.buildKey("/x/Zelda.nsp"), TitleID.buildKey("/other/Zelda.nsp"))
        XCTAssertEqual(TitleID.buildKey("/x/Zelda.nsp"), TitleID.buildKey("/x/Zelda.nsp"))
        XCTAssertEqual(TitleID.buildKey("/x/Zelda.nsp"), "Zelda-74c1008b")   // the Qt front end gives the same key
    }

    func testOddCharactersAreSanitized() {
        let k = TitleID.buildKey("/x/Pokémon: Sword/Shield ../.. §.nsp")
        XCTAssertNil(k.range(of: "[^A-Za-z0-9_-]", options: .regularExpression))
        XCTAssertFalse(k.contains("/"))
        XCTAssertNotEqual(TitleID.buildKey("/x/a b.nsp"), TitleID.buildKey("/x/a_b.nsp"))   // same clean stem, different hash
        XCTAssertNil(TitleID.buildKey("/x/日本語.nsp").range(of: "[^A-Za-z0-9_-]", options: .regularExpression))
    }

    func testBuildFolderStillEndsInBuild() {
        XCTAssertTrue((TitleID.buildKey("/x/Zelda.nsp") + "_build").hasSuffix("_build"))
        XCTAssertEqual(TitleID.buildKey("/x/[0100F2C0115B6000].nsp") + "_build", "0100F2C0115B6000_build")
    }

    /// The reporter's layout: <ID>/<ID>_v0_<hash>.nsp, the ID bare (no brackets), the full path passed in.
    func testBareIDInAFullPathIsFound() {
        let dir = "/Users/me/Games/01007EF00011E000/"
        XCTAssertEqual(TitleID.parse(dir + "01007EF00011E000_v0_420d1c5034ab.nsp"), 0x01007EF00011E000)
        XCTAssertEqual(TitleID.buildKey(dir + "01007EF00011E000_v0_420d1c5034ab.nsp"), "01007EF00011E000")
        // the update and the DLC beside it keep their own IDs and never stand in for the base
        XCTAssertEqual(TitleID.parse(dir + "01007EF00011E800_v1048576_aaaa.nsp"), 0x01007EF00011E800)
        XCTAssertEqual(TitleID.parse(dir + "01007EF00011F001_bbbb.nsp"), 0x01007EF00011F001)
        XCTAssertEqual(TitleID.buildKey(dir + "01007EF00011E000_v0_420d1c5034ab.nsp"),
                       TitleID.buildKey("01007EF00011E000_v0_420d1c5034ab.nsp"))
        // the folder's ID does not leak into a file name that has none
        XCTAssertNotEqual(TitleID.buildKey(dir + "Zelda.nsp"), "01007EF00011E000")
    }

    func testTitleIDReadsTheBracketedFormTheFilesUse() {
        XCTAssertEqual(TitleID.parse("Mario Wonder [010015100B514000][v0].nsp"), 0x010015100B514000)
        XCTAssertEqual(TitleID.parse("/ROMs/TotK [01007EF00011E000].xci"), 0x01007EF00011E000)
        XCTAssertNil(TitleID.parse("no title id here.nsp"))
    }

    /// Issue #58: a folder holding several games is staged down to the picked one, and its update
    /// and add-on content come along, classified exactly as build_ipa_from_nsp.py:445 does.
    func testSiblingsOfThePickedGameAreClassifiedAsTheScriptDoes() {
        let base = UInt64(0x010015100B514000)
        let app = base & ~UInt64(0xFFF)
        let owner = TitleID.owner
        XCTAssertEqual(owner(base), app, "the base game")
        XCTAssertEqual(owner(base + 0x800), app, "its update")
        XCTAssertEqual(owner(base + 0x1001), app, "add-on content 1")
        XCTAssertNotEqual(owner(UInt64(0x01007EF00011E000)), app, "another game")
        XCTAssertNotEqual(owner(UInt64(0x01007EF00011E800)), app, "another game's update")
    }
}
