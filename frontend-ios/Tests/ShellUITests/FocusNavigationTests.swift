import XCTest
@testable import ShellUI

final class FocusNavigationTests: XCTestCase {
    private func target(_ id: String, _ x: CGFloat, _ y: CGFloat) -> FocusTarget {
        FocusTarget(id: id, frame: CGRect(x: x, y: y, width: 44, height: 44), activate: {})
    }
    func testDirectionalNavigationPrefersSameRowAndDoesNotWrap() {
        let targets = [target("a", 0, 0), target("b", 80, 0), target("c", 0, 100), target("d", 80, 100)]
        XCTAssertEqual(FocusNavigation.next(from: "a", action: .right, targets: targets), "b")
        XCTAssertEqual(FocusNavigation.next(from: "b", action: .down, targets: targets), "d")
        XCTAssertEqual(FocusNavigation.next(from: "d", action: .left, targets: targets), "c")
        XCTAssertEqual(FocusNavigation.next(from: "c", action: .left, targets: targets), "c")
        XCTAssertEqual(FocusNavigation.next(from: "missing", action: .down, targets: targets), "a")
        XCTAssertNil(FocusNavigation.next(from: nil, action: .down, targets: []))
    }

    /// #1026: only the focused target draws a ring, never a neighbour, and none while focus is hidden.
    func testOnlyTheFocusedTargetDrawsARing() {
        XCTAssertTrue(ShellFocusTarget.drawsRing(showsRing: true, visible: true, focused: "set.row.DM_LANG", id: "set.row.DM_LANG"))
        XCTAssertFalse(ShellFocusTarget.drawsRing(showsRing: true, visible: true, focused: "set.row.DM_LANG", id: "shs.row.hud"))
        XCTAssertFalse(ShellFocusTarget.drawsRing(showsRing: true, visible: false, focused: "set.row.DM_LANG", id: "set.row.DM_LANG"))
        XCTAssertFalse(ShellFocusTarget.drawsRing(showsRing: false, visible: true, focused: "a", id: "a"))
    }

    /// #1026: the toolbar's controller button reaches the gear to its right and back, and every row of a settings list is reached in order,
    /// the game language row (a tall row with a menu) included.
    func testTheToolbarGearAndEveryRowAreReachable() {
        let controller = FocusTarget(id: "lib.controllers", frame: CGRect(x: 640, y: 20, width: 44, height: 44), activate: {})
        let gear = FocusTarget(id: "lib.shellSettings", frame: CGRect(x: 696, y: 20, width: 44, height: 44), activate: {})
        XCTAssertEqual(FocusNavigation.next(from: "lib.controllers", action: .right, targets: [controller, gear]), "lib.shellSettings")
        XCTAssertEqual(FocusNavigation.next(from: "lib.shellSettings", action: .left, targets: [controller, gear]), "lib.controllers")
        let rows = ["set.row.DM_MODE", "set.row.DM_LANG", "set.row.DM_FPS", "set.row.DM_SHOW_FPS"].enumerated().map { i, id in
            FocusTarget(id: id, frame: CGRect(x: 20, y: 100 + CGFloat(i) * 70, width: 340, height: i == 1 ? 96 : 52), activate: {})
        }
        var seen = [rows[0].id]
        while let next = FocusNavigation.next(from: seen.last, action: .down, targets: rows), next != seen.last { seen.append(next) }
        XCTAssertEqual(seen, rows.map(\.id), "down visits every row once, the language row too")
    }

    /// #1067: the ring of the Play and game settings buttons follows a capsule and a circle.
    func testCapsuleRadiusRoundsTheRingOfPlayAndSettings() {
        let play = ShellFocusTarget.ringCornerRadius(radius: ShellFocusTarget.capsule, size: CGSize(width: 150, height: 52))
        XCTAssertEqual(play, 31, "the ring end is a half circle of the 52 pt button, with the 5 pt ring gap")
        let gear = ShellFocusTarget.ringCornerRadius(radius: ShellFocusTarget.capsule, size: CGSize(width: 52, height: 52))
        XCTAssertEqual(gear, 31)
        XCTAssertEqual(ShellFocusTarget.ringCornerRadius(radius: 12, size: CGSize(width: 150, height: 52)), 17, "covers keep their small radius")
    }
}

@MainActor final class NativeToolbarFocusTests: XCTestCase {
    func testClosingANativeSheetRestoresLibraryTargetsWithoutNewGeometry() {
        let targets = FocusTargetBuffer()
        let frame = CGRect(x: 20, y: 80, width: 44, height: 44)
        targets.libraryValues = [FocusTarget(id: "lib.tile.orbit", frame: frame, activate: {})]
        targets.values = [FocusTarget(id: "set.row.mode", frame: frame, activate: {})]
        XCTAssertEqual(targets.active(prefix: "set.", toolbarIDs: []).map(\.id), ["set.row.mode"])
        XCTAssertEqual(targets.active(prefix: "lib.", toolbarIDs: []).map(\.id), ["lib.tile.orbit"])
    }

    func testToolbarReplacesDuplicatePreferencesAndDropsInactiveScreenActions() {
        let targets = FocusTargetBuffer()
        var activations = 0
        let frame = CGRect(x: 20, y: 80, width: 44, height: 44)
        targets.values = [FocusTarget(id: "lib.settings", frame: frame, activate: {}),
                          FocusTarget(id: "set.play", frame: frame, activate: {})]
        targets.toolbarValues = [
            "lib.settings": FocusTarget(id: "lib.settings", frame: frame, activate: {}),
            "set.back": FocusTarget(id: "set.back", frame: frame, activate: { activations += 1 })]
        let active = targets.active(prefix: "set.", toolbarIDs: ["set.back"])
        XCTAssertEqual(Set(active.map(\.id)), ["set.back", "set.play"])
        active.first { $0.id == "set.back" }?.activate()
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(targets.active(prefix: "lib.", toolbarIDs: ["lib.settings"]).count, 1)
    }

    func testReturningToLibraryWithEmptyTileTargetsPreservesDirectionsAndActivate() {
        let games = [
            GameDetail(game: GameTile(id: "g1", title: "Game 1")),
            GameDetail(game: GameTile(id: "g2", title: "Game 2")),
            GameDetail(game: GameTile(id: "g3", title: "Game 3")),
        ]
        // Returning with previous tile focus must allow directional keys without stalling on missing geometry.
        XCTAssertTrue(LibraryView.shouldDispatchWhenFocusMissing(action: .right, topLayer: nil, hadTileFocus: true, isCoverFlow: false, hasGames: true))
        XCTAssertTrue(LibraryView.shouldDispatchWhenFocusMissing(action: .down, topLayer: nil, hadTileFocus: true, isCoverFlow: false, hasGames: true))
        XCTAssertTrue(LibraryView.shouldDispatchWhenFocusMissing(action: .left, topLayer: nil, hadTileFocus: false, isCoverFlow: true, hasGames: true))
        // First controller press with nil focus and not Cover Flow keeps highlighting default focus without skipping.
        XCTAssertFalse(LibraryView.shouldDispatchWhenFocusMissing(action: .right, topLayer: nil, hadTileFocus: false, isCoverFlow: false, hasGames: true))
        // When a sheet is open on top, missing focus must not step the underlying library.
        XCTAssertFalse(LibraryView.shouldDispatchWhenFocusMissing(action: .down, topLayer: .settings, hadTileFocus: true, isCoverFlow: false, hasGames: true))
        XCTAssertNil(LibraryView.fallbackSteppedGameID(games: games, selectedID: "g2", focusID: "lib.tile.g2", action: .right, isCoverFlow: true, topLayer: .settings, hasTileTargets: false))

        // Stepping across games when tile targets have not re-reported yet.
        XCTAssertEqual(LibraryView.fallbackSteppedGameID(games: games, selectedID: "g1", focusID: "lib.tile.g1", action: .right, isCoverFlow: false, topLayer: nil, hasTileTargets: false), "g2")
        XCTAssertEqual(LibraryView.fallbackSteppedGameID(games: games, selectedID: "g2", focusID: "lib.tile.g2", action: .up, isCoverFlow: false, topLayer: nil, hasTileTargets: false), "g1")
        // Once real tile targets exist in non-CoverFlow mode, defer to FocusNavigation geometry.
        XCTAssertNil(LibraryView.fallbackSteppedGameID(games: games, selectedID: "g1", focusID: "lib.tile.g1", action: .right, isCoverFlow: false, topLayer: nil, hasTileTargets: true))
        // In Cover Flow, toolbar focus is not hijacked when stepping.
        XCTAssertNil(LibraryView.fallbackSteppedGameID(games: games, selectedID: "g1", focusID: "lib.controllers", action: .right, isCoverFlow: true, topLayer: nil, hasTileTargets: true))

        // Activate fallback resolves tile focus back to the matching game and ignores toolbar focus IDs.
        XCTAssertEqual(LibraryView.fallbackActivatedGame(games: games, selected: games[0], focusID: "lib.tile.g2")?.id, "g2")
        XCTAssertEqual(LibraryView.fallbackActivatedGame(games: games, selected: games[1], focusID: nil)?.id, "g2")
        XCTAssertNil(LibraryView.fallbackActivatedGame(games: games, selected: games[0], focusID: "lib.controllers"))
    }
}
