import XCTest
@testable import NX2Apple
@testable import NXCore

/// The library's order, search and names (LNPANDY/NX2Apple#937, #895, #827).
final class LibraryOrderTests: IsolatedDefaultsTestCase {
    private func game(_ id: String, _ name: String, played: TimeInterval? = nil, names: [String: String] = [:], custom: String = "") -> LibraryGame {
        var game = LibraryGame(titleID: id, name: name)
        game.lastPlayed = played.map { Date(timeIntervalSince1970: $0) }
        game.titleNames = names
        game.customName = custom
        return game
    }

    func testRecentlyPlayedPutsTheLatestFirstAndUnplayedAfterByNameThenTitleID() {
        let games = [game("0100000000000003", "Zelda"), game("0100000000000002", "Hades", played: 100), game("0100000000000001", "Mario", played: 200),
                     game("0100000000000004", "Zelda")]
        XCTAssertEqual(LibrarySort.recent.ordered(games, lang: .en).map(\.titleID),
                       ["0100000000000001", "0100000000000002", "0100000000000003", "0100000000000004"])
        XCTAssertEqual(LibrarySort.name.ordered(games, lang: .en).map(\.name), ["Hades", "Mario", "Zelda", "Zelda"])
    }

    func testSortUsesTheNameShownInTheLanguage() {
        let games = [game("0100000000000001", "Zed", names: ["de": "Anfang"]), game("0100000000000002", "Mid")]
        XCTAssertEqual(LibrarySort.name.ordered(games, lang: Lang("de")).map(\.titleID), ["0100000000000001", "0100000000000002"])
        XCTAssertEqual(LibrarySort.name.ordered(games, lang: .en).map(\.titleID), ["0100000000000002", "0100000000000001"])
    }

    func testDefaultsToRecentlyPlayedAndRemembersAChoice() {
        XCTAssertEqual(LibrarySort.load(testDefaults), .recent)
        LibrarySort.name.save(testDefaults)
        XCTAssertEqual(LibrarySort.load(testDefaults), .name)
    }

    func testChangingTheOrderKeepsAValidSelectionAndOnlyAHiddenOneMoves() {
        let games = [game("0100000000000001", "A", played: 1), game("0100000000000002", "B", played: 2)]
        let selected = games[0].id
        XCTAssertEqual(LibraryFilter.owned.reconcile(games: games, selectedID: selected, focused: nil, sort: .recent).selectedID, selected)
        XCTAssertEqual(LibraryFilter.owned.reconcile(games: games, selectedID: selected, focused: nil, sort: .name).selectedID, selected)
        // The Built filter hides both (nothing is built): the selection falls to the first game it shows, which is none
        XCTAssertNil(LibraryFilter.built.reconcile(games: games, selectedID: selected, focused: nil, sort: .recent).selectedID)
    }

    func testSearchFindsEveryNameAGameAnswersTo() {
        let japanese = game("0100000000000001", "The Legend of Zelda", names: ["ja": "ゼルダの伝説", "en-US": "The Legend of Zelda"], custom: "Link's day out")
        let games = [japanese, game("0100000000000002", "Pokémon Legends")]
        func found(_ text: String, _ lang: Lang = Lang("ja")) -> [String] { LibraryFilter.owned.visibleGames(games, matching: text, lang: lang).map(\.titleID) }
        XCTAssertEqual(found("ゼルダ"), ["0100000000000001"], "the name shown")
        XCTAssertEqual(found("legend of zelda"), ["0100000000000001"], "the bundle name still finds it under another language")
        XCTAssertEqual(found("link's"), ["0100000000000001"], "a rename does not hide the others")
        XCTAssertEqual(found("pokemon"), ["0100000000000002"], "accents are ignored")
        XCTAssertEqual(found("0100000000000002"), ["0100000000000002"], "the title ID")
        XCTAssertEqual(found("nothing"), [])
        XCTAssertEqual(found("   ").count, 2, "a blank search shows everything")
    }

    func testPlayingRecordsTheDateAndAnOldLibraryStillDecodes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("order-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("library.json")
        let old = #"[{"id":"\#(UUID().uuidString)","titleID":"0100000000000001","name":"A"}]"#
        try old.write(to: file, atomically: true, encoding: .utf8)
        let library = GameLibrary(file: file)
        let first = try XCTUnwrap(library.games.first)
        XCTAssertNil(first.lastPlayed)
        XCTAssertTrue(first.defaultsApplied, "a game the library already had keeps what it has")
        library.recordPlayed(first.id, at: Date(timeIntervalSince1970: 500))
        XCTAssertEqual(GameLibrary(file: file).games.first?.lastPlayed, Date(timeIntervalSince1970: 500))
    }
}

/// #1057: the Switch 2 Edition note comes from file names only and never relabels the build.
final class Switch2EditionNoteTests: XCTestCase {
    func testOnlyAFileNamedForTheSwitch2EditionRaisesTheNote() {
        var game = LibraryGame(titleID: "01004D300C5AE000", name: "Kirby and the Forgotten Land")
        game.inputs = ["base": ["/g/Kirby [01004D300C5AE000][v0].nsp"], "dlc": ["/g/Kirby [01004D300C5AE001][v0].nsp"]]
        XCTAssertFalse(game.switch2EditionContentFound)
        game.inputs["dlc"] = ["/g/Kirby Nintendo Switch 2 Edition Upgrade Pack [01004D300C5AE0F1].nsp"]
        XCTAssertTrue(game.switch2EditionContentFound)
        game.inputs["dlc"] = ["/g/kirby_switch2edition.nsp"]
        XCTAssertTrue(game.switch2EditionContentFound)
    }
}
