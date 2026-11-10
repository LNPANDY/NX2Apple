import XCTest
@testable import NX2Apple
@testable import NXCore

/// #816 in console mode: the home screen's rows and the moves between them, all games' filters and tabs, the search's matching, and
/// the state of #952's paused game with its question before another game starts. Pure state, no view.
@MainActor final class ConsoleHomeTests: IsolatedDefaultsTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func game(_ id: String, _ status: ConsoleGame.Status = .ready, played: Double? = nil, older: Bool = false) -> ConsoleGame {
        var game = ConsoleGame(id: id, title: id.uppercased(), version: "", platforms: [.mac], artwork: nil, status: status)
        game.lastPlayed = played.map { now.addingTimeInterval(-$0) }
        game.olderTools = older
        return game
    }

    // MARK: Rows

    func testRowsGroupTheGamesAndLeaveEmptyRowsOut() {
        let games = [game("a"), game("b", played: 3600), game("c", .needsBuild), game("d", played: 60), game("e", older: true),
                     game("f", .needsData), game("g", .iphoneOnly), game("h", .broken("x")), game("i", .needsBuild, played: 10)]
        let sections = ConsoleHome.sections(games)
        XCTAssertEqual(sections.map(\.row), [.continuePlaying, .ready, .attention])
        XCTAssertEqual(sections[0].gameIDs, ["d", "b"], "played games ready on this Mac, the one played last first")
        XCTAssertEqual(sections[1].gameIDs, ["a"], "ready, never played, current tools")
        XCTAssertEqual(sections[2].gameIDs, ["c", "e", "f", "g", "h", "i"], "not built, older tools, no game data, iPhone only, incomplete: in the library's order")
        XCTAssertEqual(Set(sections.flatMap(\.gameIDs)).count, games.count, "every game is in exactly one row")

        XCTAssertEqual(ConsoleHome.sections([game("a"), game("b")]).map(\.row), [.ready], "no game played and none needs anything: one row")
        XCTAssertEqual(ConsoleHome.sections([game("a", .needsData)]).map(\.row), [.attention])
        XCTAssertEqual(ConsoleHome.sections([]), [])
        XCTAssertEqual(ConsoleHomeRow.allCases.map(\.titleKey).filter { L10n.table[$0] == nil }, [], "each row has its title")
    }

    func testAPausedGameLeadsContinuePlaying() {
        let sections = ConsoleHome.sections([game("a"), game("b", played: 60), game("c", played: 9000)], pausedGameID: "c")
        XCTAssertEqual(sections.first?.gameIDs, ["c", "b"], "the paused game is the one being played")
        XCTAssertEqual(ConsoleHome.sections([game("a"), game("b")], pausedGameID: "b").first?.gameIDs, ["b"], "even without a history yet")
    }

    func testMovesStayInTheRowAndKeepTheirPlaceBetweenRows() {
        let sections = [ConsoleHomeSection(row: .continuePlaying, gameIDs: ["p1", "p2"]),
                        ConsoleHomeSection(row: .ready, gameIDs: ["r1", "r2", "r3", "r4"]),
                        ConsoleHomeSection(row: .attention, gameIDs: ["n1"])]
        XCTAssertEqual(ConsoleHome.move(from: "r2", dx: 1, dy: 0, in: sections), "r3")
        XCTAssertEqual(ConsoleHome.move(from: "r4", dx: 1, dy: 0, in: sections), "r4", "the end of a row does not wrap or jump to another row")
        XCTAssertEqual(ConsoleHome.move(from: "r1", dx: -1, dy: 0, in: sections), "r1")
        XCTAssertEqual(ConsoleHome.move(from: "r2", dx: 0, dy: -1, in: sections), "p2", "up keeps the place")
        XCTAssertEqual(ConsoleHome.move(from: "r4", dx: 0, dy: -1, in: sections), "p2", "or the last tile of a shorter row")
        XCTAssertEqual(ConsoleHome.move(from: "r3", dx: 0, dy: 1, in: sections), "n1")
        XCTAssertNil(ConsoleHome.move(from: "p1", dx: 0, dy: -1, in: sections), "up from the first row leaves the rows (the top bar)")
        XCTAssertNil(ConsoleHome.move(from: "n1", dx: 0, dy: 1, in: sections), "down from the last row leaves them (the hints)")
        XCTAssertNil(ConsoleHome.move(from: "gone", dx: 1, dy: 0, in: sections))
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
