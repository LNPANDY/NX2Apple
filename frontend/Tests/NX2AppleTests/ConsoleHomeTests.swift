import XCTest
import AppKit
import SwiftUI
@testable import NX2Apple
@testable import NXCore

/// #816 in console mode: the home screen's row and the moves through it, all games' filters and tabs, the search's matching, and
/// the state of #952's paused game with its question before another game starts. Pure state, no view.
@MainActor final class ConsoleHomeTests: IsolatedDefaultsTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func game(_ id: String, _ status: ConsoleGame.Status = .ready, played: Double? = nil, older: Bool = false) -> ConsoleGame {
        var game = ConsoleGame(id: id, title: id.uppercased(), version: "", platforms: [.mac], artwork: nil, status: status)
        game.lastPlayed = played.map { now.addingTimeInterval(-$0) }
        game.olderTools = older
        return game
    }

    // MARK: The row

    /// One row as a PlayStation 5 home (#1458): the paused game, then the ones played last, then the rest by name. Every game is in it,
    /// whatever it needs: that is its tile's chip.
    func testTheRowOrdersEveryGameByLastPlayedThenByName() {
        let games = [game("d"), game("b", played: 3600), game("c", .needsBuild), game("a", played: 60), game("e", older: true),
                     game("f", .needsData), game("g", .iphoneOnly)]
        XCTAssertEqual(ConsoleHome.order(games), ["a", "b", "c", "d", "e", "f", "g"], "played last first, then by name")
        XCTAssertEqual(ConsoleHome.order(games, pausedGameID: "f"), ["f", "a", "b", "c", "d", "e", "g"], "the paused game leads")
        XCTAssertEqual(Set(ConsoleHome.order(games)).count, games.count, "every game is in the row")
        XCTAssertEqual(ConsoleHome.order([]), [])
    }

    func testMovesWalkTheRowAndEndOnAllGames() {
        let order = ["a", "b", "c"]
        XCTAssertEqual(ConsoleHome.move(from: "a", by: 1, in: order), "b")
        XCTAssertEqual(ConsoleHome.move(from: "a", by: -1, in: order), "a", "the start of the row stops")
        XCTAssertEqual(ConsoleHome.move(from: "c", by: 1, in: order), ConsoleHome.allGamesID, "All games is the last tile")
        XCTAssertEqual(ConsoleHome.move(from: ConsoleHome.allGamesID, by: 1, in: order), ConsoleHome.allGamesID, "and the row ends there")
        XCTAssertEqual(ConsoleHome.move(from: ConsoleHome.allGamesID, by: -1, in: order), "c")
        XCTAssertNil(ConsoleHome.move(from: "gone", by: 1, in: order))
        XCTAssertNotNil(L10n.table["console.allGames"])
    }

    func testPointerFocusesAndOpensEveryTileInOneActivation() {
        var focused = "a", opened: [String] = []
        func tap(_ id: String) {
            ConsoleHomePointerInput.tapTile(id, focused: focused, focus: { focused = id }, open: { opened.append(id) })
        }
        tap("b")
        XCTAssertEqual(focused, "b")
        XCTAssertEqual(opened, ["b"])
        tap("b")
        XCTAssertEqual(opened, ["b", "b"])
        tap("c")
        XCTAssertEqual(focused, "c")
        XCTAssertEqual(opened, ["b", "b", "c"])
    }

    func testWheelAndDragStepThroughTheRowOneTileAtATime() {
        let order = ["a", "b", "c"]
        var focused = "a", wheel = ConsoleHomePointerInput()
        func move(_ step: Int?) {
            if let step, let next = ConsoleHome.move(from: focused, by: step, in: order) { focused = next }
        }
        move(wheel.wheel(deltaY: -1, phase: .began))
        XCTAssertEqual(focused, "a", "small trackpad deltas accumulate")
        move(wheel.wheel(deltaY: -19, phase: .changed))
        XCTAssertEqual(focused, "b")
        move(wheel.wheel(deltaY: -100, phase: .changed))
        XCTAssertEqual(focused, "b", "one trackpad gesture is one step")
        move(wheel.wheel(deltaY: -50, phase: .ended))
        move(wheel.wheel(deltaY: -80, momentum: true))
        XCTAssertEqual(focused, "b", "momentum does not step again")
        move(wheel.wheel(deltaY: -1))
        XCTAssertEqual(focused, "c", "one wheel notch is one step")
        move(wheel.wheel(deltaY: 0, deltaX: 3))
        XCTAssertEqual(focused, "b", "a sideways wheel steps too")
        move(ConsoleHomePointerInput.drag(CGSize(width: -60, height: 5)))
        XCTAssertEqual(focused, "c", "a swipe to the left goes on")
        move(ConsoleHomePointerInput.drag(CGSize(width: 0, height: 60)))
        XCTAssertEqual(focused, "b")
        XCTAssertNil(ConsoleHomePointerInput.drag(CGSize(width: 1, height: 10)))
    }

    // MARK: Switching games

    /// Another game on the home row switches plainly, as a console's home scrolls its covers: the row moves under the fixed focus in
    /// 0.14 s and the focused cover's ring and scale finish with it, the title changes at once, the art cross-fades in 0.2 s. No spring.
    /// Under Reduce Motion everything is instant. The redesign's Library timing (#1458) and the lighter fades after it looked strange.
    func testTheHomeSwitchesGamesPlainly() {
        XCTAssertEqual(ConsoleHomeMotion.row(reduceMotion: false), .easeOut(duration: 0.14))
        XCTAssertEqual(ConsoleHomeMotion.tileFocus(homeRow: true, reduceMotion: false), ConsoleHomeMotion.row(reduceMotion: false),
                       "the focus ring and scale finish with the row")
        XCTAssertNil(ConsoleHomeMotion.title, "the title changes at once")
        XCTAssertEqual(ConsoleHomeMotion.artwork(reduceMotion: false), .easeOut(duration: 0.2))
        XCTAssertEqual(ConsoleHomeMotion.heroArrival(reduceMotion: false), .easeOut(duration: 0.2))
        XCTAssertEqual(ConsoleHomeMotion.tileFocus(homeRow: false, reduceMotion: false), .easeOut(duration: 0.22), "a grid's focus ring")
        for animation in [ConsoleHomeMotion.row(reduceMotion: true), ConsoleHomeMotion.artwork(reduceMotion: true),
                          ConsoleHomeMotion.heroArrival(reduceMotion: true), ConsoleHomeMotion.tileFocus(homeRow: true, reduceMotion: true),
                          ConsoleHomeMotion.tileFocus(homeRow: false, reduceMotion: true)] {
            XCTAssertNil(animation, "Reduce Motion switches at once")
        }
    }

    /// The home's views take every animation of a game switch from ConsoleHomeMotion: no Library timing (#1458), no fan or tilt of the
    /// covers, no spring, and only the art fades in and out by its id (two titles overlapping as ghosts looked odd).
    func testTheHomeViewsAnimateTheSwitchOnlyWithConsoleHomeMotion() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/NX2Apple")
        let keyed = try NSRegularExpression(pattern: #"\.(?:ds)?[aA]nimation\((.*), value: (?:game\??\.id|index|selected)\)"#)
        let transition = try NSRegularExpression(pattern: #"\.id\(game\.id\)\.transition\((.*)\)"#)
        var checked = 0, transitions = 0
        for name in ["ConsoleHomeView.swift", "ConsoleBackdrop.swift", "ConsoleTiles.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            XCTAssertFalse(text.contains("LibraryHeroTransition"), "\(name) uses the Library's timing on the console home")
            for effect in ["rotation3DEffect", "rearOffset", "tilt:", ".spring", ".interpolatingSpring"] {
                XCTAssertFalse(text.contains(effect), "\(name) fans, tilts or springs the home's covers (\(effect))")
            }
            for (number, line) in text.components(separatedBy: "\n").enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                if let match = keyed.firstMatch(in: line, range: range), let animation = Range(match.range(at: 1), in: line) {
                    checked += 1
                    XCTAssertTrue(line[animation].hasPrefix("ConsoleHomeMotion."), "\(name):\(number + 1) animates the switch with its own timing")
                }
                if let match = transition.firstMatch(in: line, range: range), let value = Range(match.range(at: 1), in: line) {
                    transitions += 1
                    XCTAssertTrue(line[value].hasPrefix("ConsoleHomeMotion."), "\(name):\(number + 1) fades a game's view with its own transition")
                }
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 5, "the title, the artwork, the row and the tiles are found")
        XCTAssertEqual(transitions, 1, "only the artwork fades by its id")
    }

    // MARK: All games and a game's page

    func testFiltersAndTabsStepAndStopAtTheEnds() {
        let games = [game("a"), game("b", .needsBuild), game("c", .needsData), game("d", .iphoneOnly), game("e", .broken("x"))]
        XCTAssertEqual(games.filter(ConsoleLibraryFilter.all.includes).count, 5)
        XCTAssertEqual(games.filter(ConsoleLibraryFilter.readyOnMac.includes).map(\.id), ["a"])
        XCTAssertEqual(games.filter(ConsoleLibraryFilter.notBuilt.includes).map(\.id), ["b", "d", "e"], "no build for this Mac: not built")
        XCTAssertEqual(games.filter(ConsoleLibraryFilter.needsData.includes).map(\.id), ["c"])
        XCTAssertEqual(ConsoleLibraryFilter.all.stepped(-1), .all)
        XCTAssertEqual(ConsoleLibraryFilter.all.stepped(1), .readyOnMac)
        XCTAssertEqual(ConsoleLibraryFilter.needsData.stepped(1), .needsData)
        XCTAssertEqual(ConsoleGameTab.overview.stepped(-1), .overview)
        XCTAssertEqual(ConsoleGameTab.overview.stepped(3), .cheats)
        XCTAssertEqual(ConsoleGameTab.cheats.stepped(1), .cheats)
        for key in ConsoleLibraryFilter.allCases.map(\.titleKey) + ConsoleGameTab.allCases.map(\.titleKey) { XCTAssertNotNil(L10n.table[key], key) }

        var state = ConsoleState(games: games, focusedGameID: "a")
        state.libraryOrder = ["c", "a", "x"]
        XCTAssertEqual(state.libraryGames.map(\.id), ["c", "a", "b", "d", "e"], "the order's games, then any it does not know yet")
        state.openAllGames()
        state.stepLibraryFilter(2)
        XCTAssertEqual(state.libraryFilter, .notBuilt)
        XCTAssertEqual(state.libraryGames.map(\.id), ["b", "d", "e"])
        state.openGamePage("b")
        XCTAssertEqual(state.presentedSheet, .gamePage("b"))
        state.stepLibraryFilter(1)
        XCTAssertEqual(state.libraryFilter, .notBuilt, "L and R on a game's page switch its tabs, not the filter")
        state.stepGameTab(1)
        XCTAssertEqual(state.gameTab, .saves)
        state.back()
        XCTAssertEqual(state.presentedSheet, .allGames, "B goes back to all games")
        state.openGamePage("a")
        XCTAssertEqual(state.gameTab, .overview, "a page opens on its Overview")
    }

    /// The search matches as the desktop's does: any name the game answers to, case and accents ignored, the title ID too.
    func testSearchFindsLocalizedNamesAndAliases() {
        var zelda = LibraryGame(titleID: "0100F2C0115B6000", name: "The Legend of Zelda")
        zelda.titleNames = ["ja": "ゼルダの伝説", "en": "The Legend of Zelda"]
        zelda.customName = "Totk"
        var pokemon = LibraryGame(titleID: "0100A3D008C5C000", name: "Pokémon Scarlet")
        pokemon.lastPlayed = now
        let games = [zelda, pokemon]
        func search(_ query: String, _ sort: LibrarySort = .name) -> [String] {
            LiveConsoleDriver.searchResults(games, query: query, sort: sort, lang: .en).compactMap { id in games.first { $0.id.uuidString == id }?.titleID }
        }
        XCTAssertEqual(search("zelda"), ["0100F2C0115B6000"], "the game's own name, under the player's")
        XCTAssertEqual(search("ゼルダ"), ["0100F2C0115B6000"], "its name in another language")
        XCTAssertEqual(search("TOTK"), ["0100F2C0115B6000"], "the player's name")
        XCTAssertEqual(search("pokemon"), ["0100A3D008C5C000"], "accents are ignored")
        XCTAssertEqual(search("0100a3d"), ["0100A3D008C5C000"], "the title ID")
        XCTAssertEqual(search("e", .recent), ["0100A3D008C5C000", "0100F2C0115B6000"], "in the chosen order: played last first")
        XCTAssertEqual(search("  "), [], "nothing typed, nothing listed")
        XCTAssertEqual(search("xyz"), [])
    }

    // MARK: #952: a paused game

    func testAPausedGameIsAskedAboutBeforeAnotherStarts() {
        var state = ConsoleState(games: [game("a"), game("b"), game("c", .needsBuild)], focusedGameID: "a")
        state.sheets = [.menu]
        state.gamePaused("b")
        XCTAssertEqual(state.pausedGameID, "b")
        XCTAssertEqual(state.focusedGameID, "a", "a page open in the console keeps its place")
        state.sheets = []
        state.gamePaused("b")
        XCTAssertEqual(state.focusedGameID, "b", "on the home screen the paused game is focused")

        state.play("b")
        XCTAssertNil(state.startingGameID, "the paused game is resumed by the driver, not started again")
        XCTAssertNil(state.presentedSheet)
        state.play("c")
        XCTAssertEqual(state.presentedSheet, .explanation("c"), "a game that cannot start explains why, without asking about the paused one")
        state.back()

        state.play("a")
        XCTAssertNil(state.startingGameID)
        XCTAssertEqual(state.presentedSheet, .confirmQuitPaused, "Quit <game>? first")
        XCTAssertEqual(state.afterQuit, .play("a"))
        state.back()
        XCTAssertNil(state.presentedSheet, "Cancel keeps the game paused")
        XCTAssertNil(state.afterQuit)
        XCTAssertEqual(state.pausedGameID, "b")

        state.play("a")
        state.beginQuitPaused()
        XCTAssertTrue(state.quittingPaused)
        state.back()
        XCTAssertEqual(state.presentedSheet, .confirmQuitPaused, "while it quits B does not take the answer back")
        XCTAssertEqual(state.pausedGameEnded(), .play("a"), "once it has quit, the game that waited starts")
        XCTAssertNil(state.pausedGameID)
        XCTAssertNil(state.presentedSheet)
        state.play("a")
        XCTAssertEqual(state.startingGameID, "a")
    }

    func testLeavingOrQuittingWithAPausedGameAsksTheSameWay() {
        var state = ConsoleState(games: [game("a"), game("b")], focusedGameID: "a")
        state.gamePaused("b")
        state.back()
        XCTAssertEqual(state.presentedSheet, .confirmQuitPaused, "B on the home screen asks about the paused game, not Leave console mode?")
        XCTAssertEqual(state.afterQuit, .leave(selecting: nil))
        state.back()
        state.confirmExit()
        XCTAssertEqual(state.presentedSheet, .confirmQuitPaused, "so does the menu's Leave console mode")
        state.back()
        state.askQuitPaused(then: .terminate)
        XCTAssertEqual(state.afterQuit, .terminate)
        state.back()

        // the game resumed by itself (the Dock) while the question was open: the question goes
        state.askQuitPaused(then: .leave(selecting: "a"))
        state.gameResumed()
        XCTAssertNil(state.pausedGameID)
        XCTAssertNil(state.presentedSheet)
        XCTAssertNil(state.afterQuit)
        state.back()
        XCTAssertEqual(state.presentedSheet, .confirmExit, "no paused game: the usual question")

        // a paused game that ended by itself (quit from the Dock, a crash) runs nothing that was not answered
        var other = ConsoleState(games: [game("a"), game("b")], focusedGameID: "a")
        other.gamePaused("b")
        other.askQuitPaused(then: .play("a"))
        XCTAssertNil(other.pausedGameEnded(), "Quit was not chosen")
        XCTAssertNil(other.presentedSheet)
    }

    func testTheScreenAfterACrash() {
        var state = ConsoleState(games: [game("a"), game("b")], focusedGameID: "a")
        state.sheets = [.menu]
        let saved = now.addingTimeInterval(-60)
        state.showStopped("b", lastSave: saved)
        XCTAssertEqual(state.sheets, [.stopped], "over the home screen")
        XCTAssertEqual(state.focusedGameID, "b")
        XCTAssertEqual(state.stopped, ConsoleStopped(gameID: "b", lastSave: saved))
        XCTAssertTrue(ConsoleSheet.stopped.isQuestion)
        state.play("b")
        XCTAssertEqual(state.startingGameID, "b", "Play again")
        XCTAssertNil(state.stopped)
        var back = ConsoleState(games: [game("a")], focusedGameID: "a")
        back.showStopped("a", lastSave: nil)
        back.back()
        XCTAssertNil(back.presentedSheet, "Back")
        XCTAssertNil(back.stopped)
        back.showStopped("gone", lastSave: nil)
        XCTAssertNil(back.stopped)
    }
}
