import Foundation
import XCTest
@testable import NXCore

final class GameLinkPlaySettingsTests: XCTestCase {
    func testLanAutoJoinAndUnrelatedOptionsArePreserved() throws {
        var c = LinkPlayConfiguration()
        c.enabled = true
        c.joinAddress = "192.168.1.50:47600"
        c.discovery = false
        c.interact = true
        let old = "# per-game options\nDM_VCLOCK_MODE=restart\nDM_AUDIO=1\nDM_COOP=off\n"
        let result = try GameLinkPlaySettings.replacing(old, with: c)
        XCTAssertTrue(result.contains("DM_VCLOCK_MODE=restart\n"))
        XCTAssertTrue(result.contains("DM_AUDIO=1\n"))
        XCTAssertTrue(result.contains("DM_COOP=auto\n"))
        XCTAssertTrue(result.contains("DM_COOP_JOIN=192.168.1.50:47600\n"))
        XCTAssertTrue(result.contains("DM_COOP_DISCOVERY=0\n"))
        XCTAssertTrue(result.contains("DM_COOP_INTERNET=0\n"))
        XCTAssertTrue(result.contains("DM_COOP_INTERACT=1\n"))
        XCTAssertEqual(result.components(separatedBy: "DM_COOP=").count, 2)
    }

    func testPublicJoinNeedsInternetAndRoom() throws {
        var c = LinkPlayConfiguration()
        c.enabled = true
        c.joinAddress = "8.8.8.8"
        XCTAssertThrowsError(try GameLinkPlaySettings.validate(c)) {
            XCTAssertEqual($0 as? LinkPlaySettingsError, .publicJoin)
        }
        c.internet = true
        XCTAssertThrowsError(try GameLinkPlaySettings.validate(c)) {
            XCTAssertEqual($0 as? LinkPlaySettingsError, .missingRoom)
        }
        c.room = "ABCD-EFGH-JKMN-PQRS"
        XCTAssertNoThrow(try GameLinkPlaySettings.validate(c))
        c.relayAddress = "not-an-address"
        XCTAssertThrowsError(try GameLinkPlaySettings.validate(c)) {
            XCTAssertEqual($0 as? LinkPlaySettingsError, .invalidRelay)
        }
    }

    func testRoomNormalizationAndStoryImpliesInteraction() throws {
        XCTAssertEqual(GameLinkPlaySettings.roomCode("abcd-efgh-ikmn-oqrs"), "ABCD-EFGH-1KMN-0QRS")
        XCTAssertNil(GameLinkPlaySettings.roomCode("far-too-short"))
        var c = LinkPlayConfiguration()
        c.enabled = true
        c.story = true
        let values = GameLinkPlaySettings.values(in: try GameLinkPlaySettings.replacing("", with: c))
        XCTAssertEqual(values["DM_COOP_STORY"], "1")
        XCTAssertEqual(values["DM_COOP_INTERACT"], "1")
        c.enabled = false
        let disabled = GameLinkPlaySettings.values(in: try GameLinkPlaySettings.replacing("", with: c))
        XCTAssertEqual(disabled["DM_COOP_STORY"], "0")
        XCTAssertEqual(disabled["DM_COOP_INTERACT"], "0")
    }

    func testSettingsRoundTripOutsideSignedBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = GameLinkPlaySettings(titleID: "0400A3A01EE4C000", support: root)
        var c = LinkPlayConfiguration()
        c.enabled = true
        c.joinAddress = "10.0.0.2"
        try settings.save(c)
        XCTAssertEqual(settings.load(), c)
        c.enabled = false
        try settings.save(c)
        XCTAssertFalse(settings.load().enabled)
        XCTAssertTrue(try String(contentsOf: settings.playerEnv, encoding: .utf8).contains("DM_COOP=off"))
    }

    func testLegacyJoinModeLoadsIntoAutoSettings() {
        let old = GameLinkPlaySettings.parse(["DM_COOP": "join:172.16.0.9:47600"])
        XCTAssertTrue(old.enabled)
        XCTAssertEqual(old.joinAddress, "172.16.0.9:47600")
    }
}
