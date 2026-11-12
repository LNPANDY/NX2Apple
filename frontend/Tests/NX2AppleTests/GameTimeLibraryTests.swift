import Foundation
import XCTest
import GameTime
import NXCore
@testable import NX2Apple

@MainActor final class GameTimeLibraryTests: XCTestCase {
    func testRemovingAndReaddingTitleKeepsScopedHistoryAndUsesCanonicalRecency() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let save = root.appendingPathComponent("save"), id = "01000000000000AA"
        let local = try XCTUnwrap(DMGameTimeLocalURL(save, nil, id))
        var error: NSError?
        XCTAssertTrue(DMGameTimeUpdateSegments(local, [["id": UUID().uuidString, "day": "2026-11-12", "milliseconds": 3_600_000]], 1_794_480_000_000, &error))
        let library = GameLibrary(file: root.appendingPathComponent("library.json"))
        var game = LibraryGame(titleID: id, name: "Fixture")
        game.lastPlayed = Date(timeIntervalSince1970: 2_000_000_000) // a legacy launch attempt must not override measured recency
        library.upsert(game)
        let profile = PlayerProfile(id: PlayerProfile.defaultID, name: "")
        let settings = SaveGameOverride(cloud: .off, saveFolder: save.path)
        await library.refreshPlayTime(game, player: profile, global: SaveGlobalSettings(), override: settings)
        XCTAssertEqual(library.games.first?.playTime?.totalMilliseconds, 3_600_000)
        XCTAssertEqual(library.games.first?.activityDate, Date(timeIntervalSince1970: 1_794_480_000))
        await library.timeIndex.flush()
        library.remove(game.id)
        let added = LibraryGame(titleID: id, name: "Added again")
        library.upsert(added)
        await library.refreshPlayTime(added, player: profile, global: SaveGlobalSettings(), override: settings)
        XCTAssertEqual(library.games.first?.playTime?.totalMilliseconds, 3_600_000)
        XCTAssertEqual(DMGameTimeTotal(local, &error)?.uint64Value, 3_600_000)
        let stored = try String(contentsOf: root.appendingPathComponent("library.json"), encoding: .utf8)
        XCTAssertFalse(stored.contains("playTime"), "derived summaries stay in the persistent index rather than duplicating user library state")
    }
}
