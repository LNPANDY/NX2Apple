import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel

/// The Saves page's data (#1079, SavesOverview.swift): which games it lists, where each save is and why, what the folder
/// holds, a save left in another place (#1041), and the cloud switch, which must change what Launch options › Cloud saves does.
@MainActor final class SavesOverviewTests: IsolatedDefaultsTestCase {
    private let fm = FileManager.default
    private var temporary: URL!
    private var support: URL { temporary.appendingPathComponent("Support") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporary = fm.temporaryDirectory.appendingPathComponent("SavesOverviewTests-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: temporary)
        try super.tearDownWithError()
    }

    private func makeApp(_ titleID: String, name: String, in folder: URL) throws -> URL {
        let app = folder.appendingPathComponent(name + ".app")
        let executables = app.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: executables, withIntermediateDirectories: true)
        for tool in ["nxnative", "dmhost"] {
            try fm.createSymbolicLink(at: executables.appendingPathComponent(tool), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        }
        let info: [String: Any] = ["DMTitleID": titleID, "CFBundleDisplayName": name, "CFBundleExecutable": "nxnative",
                                   "CFBundleIdentifier": TestPreferences.domain(in: temporary, "saves-" + titleID)]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    private func write(_ bytes: Int, to file: URL, at date: Date? = nil) throws {
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: file)
        if let date { try fm.setAttributes([.modificationDate: date], ofItemAtPath: file.path) }
    }

    private func rows(_ games: [LibraryGame], global: SaveGlobalSettings = SaveGlobalSettings(), overrides: [String: SaveGameOverride] = [:],
                      player: PlayerProfile? = nil, cloud: CloudSaveSync.Setting = CloudSaveSync.Setting(source: .none, value: nil, folder: nil)) -> [SaveOverviewRow] {
        SavesOverview.rows(games, lang: .en, global: global, game: { overrides[$0] ?? SaveGameOverride() }, player: player,
                           cloudSetting: { _ in cloud }, support: support, volumeHolds: { _ in true })
    }

    func testOnlyGamesBuiltForTheMacAreListedByName() throws {
        let zelda = LibraryGame(titleID: "0100000000010000", name: "Zelda", appPath: try makeApp("0100000000010000", name: "Zelda", in: temporary).path)
        let abzu = LibraryGame(titleID: "0100000000020000", name: "Abzu", appPath: try makeApp("0100000000020000", name: "Abzu", in: temporary).path)
        let unbuilt = LibraryGame(titleID: "0100000000030000", name: "Unbuilt", appPath: "")
        XCTAssertEqual(rows([zelda, unbuilt, abzu]).map(\.name), ["Abzu", "Zelda"])
    }

    func testEachSaveSaysWhereItIsAndWhy() throws {
        let library = temporary.appendingPathComponent("Games")
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        fm.createFile(atPath: library.appendingPathComponent(".nx2apple-library").path, contents: Data())
        let beside = LibraryGame(titleID: "0100000000010000", name: "A", appPath: try makeApp("0100000000010000", name: "A", in: library).path)
        let usual = LibraryGame(titleID: "0100000000020000", name: "B", appPath: try makeApp("0100000000020000", name: "B", in: temporary).path)
        let own = LibraryGame(titleID: "0100000000030000", name: "C", appPath: try makeApp("0100000000030000", name: "C", in: temporary).path)
        var override = SaveGameOverride(); override.saveFolder = "/Volumes/Drive/C"
        let list = rows([beside, usual, own], overrides: [own.titleID: override])
        XCTAssertEqual(list.map(\.source), [.libraryFolder, .standard, .game])
        XCTAssertEqual(list[0].folder.path, library.appendingPathComponent("save/0100000000010000").path)
        XCTAssertEqual(list[1].folder.path, support.appendingPathComponent("nxnative/0100000000020000/save").path)
        XCTAssertEqual(list[2].folder.path, "/Volumes/Drive/C")
        XCTAssertEqual(SavesOverview.sourceKey(.libraryFolder), "savespage.from.library")
    }

    func testAnotherPlayerSeesTheirOwnFolder() throws {
        let game = LibraryGame(titleID: "0100000000010000", name: "A", appPath: try makeApp("0100000000010000", name: "A", in: temporary).path)
        let row = rows([game], player: PlayerProfile(id: "ana", name: "Ana"))[0]
        XCTAssertEqual(row.folder.path, support.appendingPathComponent("nxnative/0100000000010000/profiles/ana/save").path)
    }

    func testTheCloudStateAndWhereItIsSet() throws {
        let game = LibraryGame(titleID: "0100000000010000", name: "A", appPath: try makeApp("0100000000010000", name: "A", in: temporary).path)
        XCTAssertFalse(rows([game])[0].cloud.isOn)
        var global = SaveGlobalSettings(); global.cloudOn = true; global.cloudFolder = "icloud"
        XCTAssertEqual(rows([game], global: global)[0].cloud, SaveLocations.EffectiveCloud(folder: "icloud", source: .global))
        let env = rows([game], cloud: CloudSaveSync.Setting(source: .playerEnv, value: "icloud", folder: "/x"))[0]
        XCTAssertTrue(env.cloud.isOn)
        XCTAssertTrue(env.cloudFromEnv)
    }

    func testAFolderIsMeasuredAndFinderFilesDoNotCount() throws {
        let folder = temporary.appendingPathComponent("save")
        let old = Date(timeIntervalSince1970: 1_700_000_000), new = Date(timeIntervalSince1970: 1_800_000_000)
        try write(100, to: folder.appendingPathComponent("0000000000000001/save.dat"), at: old)
        try write(50, to: folder.appendingPathComponent("0000000000000001/option.sav"), at: new)
        try write(10, to: folder.appendingPathComponent("._option.sav"), at: Date())
        let stats = SavesOverview.folderStats(folder)
        XCTAssertEqual(stats.files, 2)
        XCTAssertEqual(stats.newest, new)
        XCTAssertGreaterThanOrEqual(stats.bytes, 150)
        XCTAssertEqual(SavesOverview.folderStats(temporary.appendingPathComponent("none")).files, 0)
    }

    // #1041: an app moved one folder down saves in ~/Library now; its save stayed beside the old place
    func testASaveLeftInAnotherPlaceIsFound() throws {
        let library = temporary.appendingPathComponent("Games"), moved = library.appendingPathComponent("Zelda")
        try fm.createDirectory(at: moved, withIntermediateDirectories: true)
        fm.createFile(atPath: library.appendingPathComponent(".nx2apple-library").path, contents: Data())
        let game = LibraryGame(titleID: "0100000000010000", name: "Zelda", appPath: try makeApp("0100000000010000", name: "Zelda", in: moved).path)
        try write(64, to: library.appendingPathComponent("save/0100000000010000/0000000000000001/save.dat"))
        let row = SavesOverview.measured(rows([game])[0], appPath: game.appPath, player: nil, support: support)
        XCTAssertEqual(row.source, .standard, "the moved app's folder has no library marker")
        XCTAssertFalse(row.hasSave)
        XCTAssertEqual(row.elsewhere?.path, library.appendingPathComponent("save/0100000000010000").path)
        try write(8, to: row.folder.appendingPathComponent("0000000000000001/save.dat"))
        let saved = SavesOverview.measured(rows([game])[0], appPath: game.appPath, player: nil, support: support)
        XCTAssertTrue(saved.hasSave)
        XCTAssertNil(saved.elsewhere, "a game with its own save shows no other place")
    }

    func testTheCloudSwitchMakesTheSameChangeAsTheGamesOptions() throws {
        let titleID = "0100000000010000"
        let settings = SaveSettingsStore(defaults: testDefaults)
        var preference: String?
        var saves = GameCloudSaves(titleID: titleID, appPath: "")
        saves.support = support; saves.home = temporary.path
        saves.readPreference = { preference }
        saves.writePreference = { preference = $0 }
        try SavesOverview.setCloud(true, titleID: titleID, saves: saves, settings: settings)
        XCTAssertEqual(preference, "icloud")
        XCTAssertEqual(settings.game(titleID).cloud, .folder("icloud"))
        try SavesOverview.setCloud(false, titleID: titleID, saves: saves, settings: settings)
        XCTAssertNil(preference)
        XCTAssertEqual(settings.game(titleID).cloud, .off)
        var global = settings.global; global.cloudOn = true; global.cloudFolder = "/Volumes/NAS/Saves"; settings.setGlobal(global)
        try SavesOverview.setCloud(true, titleID: titleID, saves: saves, settings: settings)
        XCTAssertEqual(preference, "/Volumes/NAS/Saves", "on uses the folder of the setup for every game")
    }
}
