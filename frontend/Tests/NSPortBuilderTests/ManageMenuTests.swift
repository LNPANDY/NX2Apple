import XCTest
@testable import NSPortBuilder

/// The Manage menu: its rows and when they can be used, what a controller's buttons do around it, and that its rows run
/// the actions the system menu ran.
final class ManageMenuTests: XCTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-manage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    private let titleID = "0100535012974000"

    private func readyGame() throws -> LibraryGame {
        let app = temporary.appendingPathComponent("Hades.app")
        let executables = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
        for name in ["nxnative", "dmhost"] {
            try FileManager.default.createSymbolicLink(at: executables.appendingPathComponent(name), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        }
        let info: [String: Any] = ["DMTitleID": titleID, "CFBundleDisplayName": "Hades", "CFBundleExecutable": "nxnative"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        var game = LibraryGame(titleID: titleID, name: "Hades", appPath: app.path)
        game.inputs = ["base": ["/preview/Hades.nsp"]]
        return game
    }

    private func items(_ game: LibraryGame, running: Bool = false, older: Bool = false, active: UUID? = nil, folder: Bool = false, log: Bool = false,
                       actions: ManageActions = ManageActions()) -> [ManageItem] {
        ManageItem.list(game: game, labels: { L10n.string($0, .en) }, running: running, olderTools: older, activeBuildID: active,
                        hasBuildFolder: folder, hasLog: log, actions: actions)
    }

    func testAReadyGameHasEveryRowInTheOldOrderAndRemoveLastInRed() throws {
        var game = try readyGame()
        game.artworkPath = "/art.png"
        let list = items(game, folder: true, log: true)
        XCTAssertEqual(list.map(\.id), ["rebuild", "options", "saves", "cheats", "artwork", "resetArtwork", "reveal", "log", "freeSpace", "remove"])
        XCTAssertEqual(list.map(\.title), ["library.buildAgain", "launch.title", "saves.menu", "cheats.menu", "library.changeArtwork", "library.resetArtwork", "install.reveal", "library.showLog", "free.menu", "library.remove"]
            .map { L10n.string($0, .en) })
        XCTAssertTrue(list.allSatisfy(\.enabled))
        XCTAssertEqual(list.last?.destructive, true)
        XCTAssertEqual(list.last?.separatorBefore, true)
        XCTAssertEqual(list.filter(\.destructive).count, 1)
        XCTAssertEqual(list.filter(\.separatorBefore).count, 1)
    }

    func testANotBuiltGameLeavesOutTheRowsThatNeedABuild() {
        var game = LibraryGame(titleID: titleID, name: "Hades")
        var list = items(game)
        XCTAssertEqual(list.map(\.id), ["rebuild", "saves", "cheats", "artwork", "remove"], "no launch options, Finder or Free space without a build")
        XCTAssertFalse(list[0].enabled, "no recorded inputs: nothing to build again")
        game.inputs = ["base": ["/preview/Hades.nsp"]]
        list = items(game)
        XCTAssertTrue(list[0].enabled)
    }

    func testWhileABuildRunsRebuildIsOffAndRemoveIsOffOnlyForTheGameBuilding() throws {
        let game = try readyGame()
        var list = items(game, running: true, active: game.id)
        XCTAssertFalse(list.first { $0.id == "rebuild" }!.enabled)
        XCTAssertFalse(list.first { $0.id == "remove" }!.enabled)
        XCTAssertTrue(list.first { $0.id == "saves" }!.enabled)
        list = items(game, running: true, active: UUID())
        XCTAssertFalse(list.first { $0.id == "rebuild" }!.enabled, "any running build blocks a new one")
        XCTAssertTrue(list.first { $0.id == "remove" }!.enabled, "another game's build does not block removing this one")
    }

    func testOlderToolsRenameTheFirstRow() throws {
        let game = try readyGame()
        XCTAssertNotEqual(items(game)[0].title, items(game, older: true)[0].title)
        XCTAssertEqual(items(game, older: true)[0].title, L10n.string("library.rebuild", .en))
    }

    func testShowGameLogIsOffWithATooltipUntilTheGameHasALog() throws {
        let game = try readyGame()
        let none = try XCTUnwrap(items(game).first { $0.id == "log" })
        XCTAssertFalse(none.enabled)
        XCTAssertEqual(none.hint, L10n.string("library.showLog.none", .en))
        let some = try XCTUnwrap(items(game, log: true).first { $0.id == "log" })
        XCTAssertTrue(some.enabled)
        XCTAssertNil(some.hint)
        XCTAssertNil(items(LibraryGame(titleID: titleID, name: "Hades")).first { $0.id == "log" }, "no Mac app, no log row")
        for key in ["library.showLog", "library.showLog.none"] {
            for lang in [Lang.en, .zh] { XCTAssertFalse(L10n.string(key, lang).contains(";") || L10n.string(key, lang).contains("\u{FF1B}"), key) }
        }
    }

    func testRowsRunTheirActions() throws {
        let game = try readyGame()
        var log: [String] = []
        let actions = ManageActions(rebuild: { log.append("rebuild") }, options: { log.append("options") }, saves: { log.append("saves") },
                                    cheats: { log.append("cheats") }, changeArtwork: { log.append("artwork") }, resetArtwork: { log.append("reset") }, reveal: { log.append("reveal") }, showLog: { log.append("log") },
                                    freeSpace: { log.append("free") }, remove: { log.append("remove") })
        for item in items(game, folder: true, log: true, actions: actions) { item.run() }
        XCTAssertEqual(log, ["rebuild", "options", "saves", "cheats", "artwork", "reveal", "log", "free", "remove"])
    }

    func testTheControllerLandsOnTheFirstUsableRow() throws {
        let game = try readyGame()
        XCTAssertEqual(ManagePad.firstFocus(items(game)), "manage.rebuild")
        XCTAssertEqual(ManagePad.firstFocus(items(LibraryGame(titleID: titleID, name: "Hades"))), "manage.saves", "Build again is off: the next row")
        XCTAssertNil(ManagePad.firstFocus([]))
    }

    func testYOpensTheMenuAndNotSaves() {
        XCTAssertEqual(ManagePad.route(.y, menuOpen: false, sheetOpen: false, hasGame: true), .open)
        XCTAssertEqual(ManagePad.route(.y, menuOpen: false, sheetOpen: true, hasGame: true), .pass, "not over a sheet")
        XCTAssertEqual(ManagePad.route(.y, menuOpen: false, sheetOpen: false, hasGame: false), .pass, "no selected game")
    }

    func testBClosesAndXLRYAreIgnoredWhileOpen() {
        XCTAssertEqual(ManagePad.route(.b, menuOpen: true, sheetOpen: false, hasGame: true), .close)
        for button in [LauncherGamepad.Action.x, .l, .r, .y] {
            XCTAssertEqual(ManagePad.route(button, menuOpen: true, sheetOpen: false, hasGame: true), .swallow)
        }
        for button in [LauncherGamepad.Action.up, .down, .left, .right, .a] {
            XCTAssertEqual(ManagePad.route(button, menuOpen: true, sheetOpen: false, hasGame: true), .pass)
        }
        XCTAssertEqual(ManagePad.route(.b, menuOpen: false, sheetOpen: false, hasGame: true), .pass, "closed: B keeps going back")
    }

    func testTheDPadMovesInTheMenusScopeAndAActivates() throws {
        let game = try readyGame()
        var log: [String] = []
        let rows = items(game, actions: ManageActions(rebuild: { log.append("rebuild") }, options: { log.append("options") }, saves: { log.append("saves") }))
        let focus = PadFocus()
        focus.setFrames(rows.enumerated().map { .init(id: $1.padID, frame: CGRect(x: 0, y: CGFloat($0) * 36, width: 250, height: 36)) }, scope: "manage")
        focus.scope = "manage"
        focus.show(default: ManagePad.firstFocus(rows))
        XCTAssertEqual(focus.focused, "manage.rebuild")
        focus.move(dx: 0, dy: 1); focus.move(dx: 0, dy: 1)
        XCTAssertEqual(focus.focused, "manage.saves")
        for row in rows { focus.register(row.padID, .init(activate: row.run)) }
        focus.activate()
        XCTAssertEqual(log, ["saves"])
    }
}
