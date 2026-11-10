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
}
