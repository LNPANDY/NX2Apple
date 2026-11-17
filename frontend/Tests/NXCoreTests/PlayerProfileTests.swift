import XCTest
@testable import NXCore

final class PlayerProfileTests: XCTestCase {
    func testSlugFoldsAndStaysUnique() {
        XCTAssertEqual(PlayerProfile.slug(for: "Marko Banušić", taken: []), "marko-banusic")
        XCTAssertEqual(PlayerProfile.slug(for: "Ana", taken: ["ana", "ana-2"]), "ana-3")
        XCTAssertEqual(PlayerProfile.slug(for: "玩家", taken: []), "player")
        XCTAssertEqual(PlayerProfile.slug(for: "Default", taken: []), "player")
    }

    func testDefaultPlayerAddsNothing() {
        let base = URL(fileURLWithPath: "/Users/x/Library/Application Support/nxnative/0100000000010000/save")
        let player = PlayerProfile(id: PlayerProfile.defaultID, name: "")
        XCTAssertEqual(player.saveFolder(base: base), base)
        XCTAssertEqual(player.environment(base: base), [:])
    }

    func testOtherPlayerGetsOwnSaveSharedPipelinesAndNoCloud() {
        let base = URL(fileURLWithPath: "/Users/x/Library/Application Support/nxnative/0100000000010000/save")
        let env = PlayerProfile(id: "ana", name: "Ana").environment(base: base)
        XCTAssertEqual(env["DM_SAVE"], "/Users/x/Library/Application Support/nxnative/0100000000010000/profiles/ana/save")
        XCTAssertEqual(env["DM_PSO_USER"], "/Users/x/Library/Application Support/nxnative/0100000000010000/pso_user.tsv")
        XCTAssertEqual(env["DM_SAVE_SYNC"], "0")
    }

    func testLibraryFolderSave() {
        let base = URL(fileURLWithPath: "/Games/save/0100000000010000")
        XCTAssertEqual(PlayerProfile(id: "ana", name: "Ana").saveFolder(base: base).path, "/Games/save/profiles/ana/0100000000010000")
    }

    func testExistingPipelineListWins() {
        let env = PlayerProfile(id: "ana", name: "Ana").environment(base: URL(fileURLWithPath: "/s/save"), existing: ["DM_PSO_USER": "/elsewhere"])
        XCTAssertNil(env["DM_PSO_USER"])
    }

    // #1128: the player's name is the game's user name (DM_NICK, dm/host/hle_account.c)
    func testThePlayersNameIsTheNickname() {
        XCTAssertEqual(PlayerProfile(id: "ana", name: "Ana").nicknameEnvironment(), ["DM_NICK": "Ana"])
        XCTAssertEqual(PlayerProfile(id: PlayerProfile.defaultID, name: "Bartek").nicknameEnvironment(), ["DM_NICK": "Bartek"],
                       "the default player once renamed")
        XCTAssertEqual(PlayerProfile(id: PlayerProfile.defaultID, name: "").nicknameEnvironment(), [:],
                       "Player 1 not renamed: the game keeps its own")
    }

    func testANicknameFromALaunchOptionWins() {
        XCTAssertEqual(PlayerProfile(id: "ana", name: "Ana").nicknameEnvironment(existing: ["DM_NICK": "Shulk"]), [:])
    }

    func testTheNicknameHasNoLineBreaksAndFitsTheEngine() {
        XCTAssertEqual(PlayerProfile(id: "a", name: "  Ana\nMaria\t ").nickname, "Ana Maria")
        XCTAssertNil(PlayerProfile(id: "a", name: " \n ").nickname)
        let long = PlayerProfile(id: "a", name: String(repeating: "a", count: 40)).nickname
        XCTAssertEqual(long?.utf8.count, PlayerProfile.nicknameBytes)
        // Never half a character: 11 three-byte characters are 33 bytes, so 10 are kept (30 bytes)
        let wide = PlayerProfile(id: "a", name: String(repeating: "玩", count: 11)).nickname
        XCTAssertEqual(wide, String(repeating: "玩", count: 10))
        XCTAssertEqual(PlayerProfile(id: "a", name: "Zoë 🎮").nickname, "Zoë 🎮")
    }
}
