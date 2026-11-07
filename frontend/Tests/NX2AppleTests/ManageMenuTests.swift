import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

/// The Manage menu: its rows and when they can be used, what a controller's buttons do around it, and that its rows run
/// the actions the system menu ran.
final class ManageMenuTests: IsolatedDefaultsTestCase {
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
                       launching: Bool = false, actions: ManageActions = ManageActions()) -> [ManageItem] {
        ManageItem.list(game: game, labels: { L10n.string($0, .en) }, running: running, olderTools: older, activeBuildID: active,
                        hasBuildFolder: folder, hasLog: log, deviceName: "iPad mini", launching: launching, actions: actions)
    }

    func testGameReadyOnMacAndDeviceOffersBothLaunchDestinations() throws {
        var game = try readyGame()
        let app = temporary.appendingPathComponent("Shell.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data().write(to: app.appendingPathComponent("Info.plist"))
        game.iosAppPath = app.path
        XCTAssertFalse(items(game).contains { $0.id == "device" }, "an exported app has no installed device")
        game.installedDevice = "DEVICE"
        XCTAssertEqual(game.primary, .play)
        var launches = 0
        let actions = ManageActions(openOnDevice: { launches += 1 })
        let item = try XCTUnwrap(items(game, actions: actions).first { $0.id == "device" })
        XCTAssertEqual(item.title, "Open on iPad mini")
        XCTAssertTrue(item.enabled)
        item.run()
        XCTAssertEqual(launches, 1)
        XCTAssertEqual(items(game, launching: true).first { $0.id == "device" }?.enabled, false)
        game.appPath = ""
        XCTAssertEqual(game.primary, .openOnDevice)
        XCTAssertFalse(items(game).contains { $0.id == "device" }, "the hero already opens this game on its device")
    }

    func testAReadyGameHasEveryRowInTheOldOrderAndRemoveAndDeleteLastInRed() throws {
        var game = try readyGame()
        game.artwork.hero = ArtworkChoice(source: .banner)
        let list = items(game, folder: true, log: true)
        XCTAssertEqual(list.map(\.id), ["rebuild", "options", "saves", "cheats", "artwork", "reveal", "log", "freeSpace", "remove", "delete"])
        XCTAssertEqual(list.map(\.title), ["library.buildAgain", "launch.title", "saves.menu", "cheats.menu", "library.changeArtwork", "install.reveal", "library.showLog", "free.menu", "library.remove", "delete.menu"]
            .map { L10n.string($0, .en) })
        XCTAssertTrue(list.allSatisfy(\.enabled))
        XCTAssertEqual(list.last?.destructive, true)
        XCTAssertEqual(list.first { $0.id == "remove" }?.separatorBefore, true, "Remove and Delete sit under one divider")
        XCTAssertEqual(list.filter(\.destructive).map(\.id), ["remove", "delete"])
        XCTAssertEqual(list.filter(\.separatorBefore).count, 1)
    }

    func testANotBuiltGameLeavesOutTheRowsThatNeedABuild() {
        var game = LibraryGame(titleID: titleID, name: "Hades")
        var list = items(game)
        XCTAssertEqual(list.map(\.id), ["rebuild", "saves", "cheats", "artwork", "remove", "delete"], "no launch options, Finder or Free space without a build")
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
        XCTAssertFalse(list.first { $0.id == "delete" }!.enabled, "a build may write into the build folder or the shared app's folder")
        XCTAssertEqual(list.first { $0.id == "delete" }!.hint, L10n.string("delete.busy", .en))
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
                                    cheats: { log.append("cheats") }, changeArtwork: { log.append("artwork") }, reveal: { log.append("reveal") }, showLog: { log.append("log") },
                                    freeSpace: { log.append("free") }, remove: { log.append("remove") }, delete: { log.append("delete") })
        for item in items(game, folder: true, log: true, actions: actions) { item.run() }
        XCTAssertEqual(log, ["rebuild", "options", "saves", "cheats", "artwork", "reveal", "log", "free", "remove", "delete"])
    }

    func testChangeArtworkOpensThePanel() throws {
        var game = try readyGame()
        game.artwork = GameArtwork(hero: ArtworkChoice(source: .banner), thumbnail: ArtworkChoice(source: .screenshot(1)))
        var log: [String] = []
        let list = items(game, actions: ManageActions(changeArtwork: { log.append("panel") }))
        try XCTUnwrap(list.first { $0.id == "artwork" }).run()
        XCTAssertEqual(log, ["panel"], "the row opens the panel: it no longer asks for a file")
        XCTAssertEqual(list.first { $0.id == "artwork" }?.title, L10n.string("library.changeArtwork", .en))
        XCTAssertNil(list.first { $0.id == "resetArtwork" }, "each slot resets in the panel: the menu has no reset row")
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
