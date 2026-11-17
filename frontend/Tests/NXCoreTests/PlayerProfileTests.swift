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

    // Empty and Unicode names: nothing reaches the engine that it would cut in half or show as a control character
    func testEmptyAndUnicodeNamesAreSafe() {
        XCTAssertEqual(PlayerProfile(id: "ana", name: "").nicknameEnvironment(), [:], "an empty name adds no DM_NICK")
        XCTAssertEqual(PlayerProfile(id: "ana", name: "\u{0}\u{7}").nicknameEnvironment(), [:], "only control characters")
        XCTAssertEqual(PlayerProfile(id: "a", name: "Ana\u{0}Maria").nickname, "Ana Maria")
        XCTAssertEqual(PlayerProfile(id: "a", name: "Ana\r\nMaria").nickname, "Ana Maria")
        // A decomposed é (e and a combining accent) is one character: kept whole
        XCTAssertEqual(PlayerProfile(id: "a", name: "Rene\u{301}").nickname, "Rene\u{301}")
        // A family emoji is 25 bytes of joined scalars: after 10 bytes it does not fit, so it is dropped, never split
        let family = "👨‍👩‍👧‍👦"
        let nick = PlayerProfile(id: "a", name: String(repeating: "a", count: 10) + family).nickname
        XCTAssertEqual(nick, String(repeating: "a", count: 10))
        XCTAssertEqual(PlayerProfile(id: "a", name: family).nickname, family, "the zero width joiners stay")
        XCTAssertEqual(PlayerProfile(id: "a", name: "\u{202E}Ana\u{200B}").nickname, "Ana", "lone format characters are dropped")
        for name in ["Zoë", "玩家", "플레이어", "Ψυχή", String(repeating: "é", count: 40), String(repeating: "🎮", count: 9)] {
            let cut = PlayerProfile(id: "a", name: name).nickname
            XCTAssertNotNil(cut)
            XCTAssertLessThanOrEqual(cut?.utf8.count ?? 0, PlayerProfile.nicknameBytes, name)
            XCTAssertTrue(name.hasPrefix(cut ?? "\u{FFFF}"), "a cut name is the start of the name: \(name)")
        }
    }
}
