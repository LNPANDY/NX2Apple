import Foundation
import Testing
import ShellUI
@testable import ShellControllers
@testable import ShellHost

struct FakePicker: FolderPicker {
    var url: URL?
    func pickFolder() async -> URL? { url }
}

/// Records launches and can fail them.
final class RecordingLauncher: GameLauncher, @unchecked Sendable {
    private(set) var launched: [LaunchableGame] = []
    var error: (any Error)?
    @MainActor func launch(_ game: LaunchableGame) async throws {
        launched.append(game)
        if let error { throw error }
    }
}

@MainActor @Suite struct ShellHostModelTests {
    private func detail(_ model: ShellHostModel, _ id: String = Fixtures.orbit) throws -> GameDetail {
        try #require(model.details.first { $0.id == id })
    }
    private func value(_ model: ShellHostModel, _ setting: String, game: String = Fixtures.orbit) throws -> String? {
        try detail(model, game).sections.flatMap(\.rows).first { $0.id == setting }?.value
    }

    @Test func buildsTilesAndDetailsFromTheBundles() throws {
        let box = try Sandbox()
        let model = ShellHostModel(config: box.config())
        #expect(model.details.count == 8)
        let orbit = try detail(model)
        #expect(orbit.game.title == "Orbit Fixture" && orbit.game.subtitle == "1.0.0")
        #expect(orbit.game.state == .needsGameData)
        #expect(orbit.sections.map(\.title) == ["Game", "Performance"])
        #expect(orbit.dataSource == "" && !orbit.dataNote.isEmpty)
        #expect(orbit.cloudSaves == nil && orbit.dlc == "No additional content")
        #expect(try detail(model, Fixtures.chain).game.state == .needsAppUpdate)
        #expect(try detail(model, Fixtures.noFramework).game.state == .broken(reason: "Game code missing", detail: "DmGame.framework is not in this game's folder. Install the game again."))
        #expect(try detail(model, Fixtures.badManifest).sections.isEmpty)
    }

    @Test func bannerAndIconBecomeArtwork() throws {
        let box = try Sandbox()
        let dir = box.games.appendingPathComponent(Fixtures.orbit)
        try pngData(width: 160, height: 90).write(to: dir.appendingPathComponent("banner.png"))
        try pngData(width: 64, height: 64).write(to: dir.appendingPathComponent("icon.png"))
        try Data("not an image".utf8).write(to: box.games.appendingPathComponent(Fixtures.chain).appendingPathComponent("banner.png"))
        let model = ShellHostModel(config: box.config())
        #expect(try detail(model).game.banner != nil && detail(model).game.icon != nil)
        #expect(try detail(model, Fixtures.chain).game.banner == nil, "an unreadable picture is left out, not an error")
    }

    @Test func appDataMakesTheGamePlayable() throws {
        let box = try Sandbox()
        try box.giveAppData()
        try box.write("", to: box.appData.appendingPathComponent(Fixtures.orbit).appendingPathComponent("aoc/0.img"))
        let model = ShellHostModel(config: box.config())
        let orbit = try detail(model)
        #expect(orbit.game.state == .playable)
        #expect(orbit.dataSource == "This app's folder" && orbit.dataNote == "")
        #expect(orbit.dlc == "1 additional content pack")
    }

    @Test func changesPersistAndResetRestoresDefaults() throws {
        let box = try Sandbox()
        let model = ShellHostModel(config: box.config())
        model.actions.onChange(Fixtures.orbit, "DM_SHOW_FPS", "1")
        #expect(try value(model, "DM_SHOW_FPS") == "1")
        #expect(try detail(model).hasModifiedSettings)
        #expect(box.defaults(Fixtures.orbit).object(forKey: "launcher.DM_SHOW_FPS") as? String == "1")
        // Another model over the same defaults, as after a relaunch.
        #expect(try value(ShellHostModel(config: box.config()), "DM_SHOW_FPS") == "1")
        model.actions.onChange(Fixtures.orbit, "DM_UPSCALER", "fsr")
        #expect(try detail(model).sections[1].rows.map(\.id).contains("DM_UPSCALER_SHARPNESS"))
        model.actions.onResetDefaults(Fixtures.orbit)
        #expect(try value(model, "DM_SHOW_FPS") == "0")
        #expect(try value(model, "DM_UPSCALER") == "off")
        #expect(try !detail(model).hasModifiedSettings)
        #expect(try detail(model).sections[1].rows.map(\.id) == ["DM_UPSCALER", "DM_RENDER_SCALE"])
    }

    @Test func aRefusedValueChangesNothing() throws {
        let box = try Sandbox()
        let model = ShellHostModel(config: box.config())
        model.change(Fixtures.orbit, setting: "DM_OPMODE", value: "7")
        model.change("0100000000999999", setting: "DM_OPMODE", value: "0")
        #expect(try value(model, "DM_OPMODE") == "1")
    }

    @Test func pickingGameDataStoresABookmarkAndMarksTheGameReady() async throws {
        let box = try Sandbox()
        let drive = box.root.appendingPathComponent("Drive/Orbit", isDirectory: true)
        try box.write("", to: drive.appendingPathComponent("fixture.marker"))
        let model = ShellHostModel(config: box.config(), picker: FakePicker(url: drive))
        #expect(try detail(model).game.state == .needsGameData)
        await model.pickGameDataNow(Fixtures.orbit)
        let orbit = try detail(model)
        #expect(orbit.game.state == .playable)
        #expect(orbit.dataSource == "Orbit")
        #expect(box.defaults(Fixtures.orbit).data(forKey: "pickedDataBookmark") != nil)
        // It survives a relaunch.
        #expect(try detail(ShellHostModel(config: box.config())).game.state == .playable)
        // Back to the app's own folder, which has nothing yet.
        model.actions.onUseAppData(Fixtures.orbit)
        #expect(try detail(model).game.state == .needsGameData)
        #expect(model.notice?.contains("games/\(Fixtures.orbit)") == true)
        #expect(box.defaults(Fixtures.orbit).data(forKey: "pickedDataBookmark") == nil)
    }

    @Test func aPickedFolderWithoutTheGameIsSaidSo() async throws {
        let box = try Sandbox()
        let empty = box.root.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let model = ShellHostModel(config: box.config(), picker: FakePicker(url: empty))
        await model.pickGameDataNow(Fixtures.orbit)
        #expect(try detail(model).game.state == .needsGameData)
        #expect(model.notice?.contains("No game data for Orbit Fixture") == true)
    }

    @Test func aCancelledPickChangesNothing() async throws {
        let box = try Sandbox()
        let model = ShellHostModel(config: box.config(), picker: FakePicker(url: nil))
        await model.pickGameDataNow(Fixtures.orbit)
        await model.pickCloudSavesNow(Fixtures.orbit)
        #expect(model.notice == nil)
        #expect(try detail(model).cloudSaves == nil)
    }

    @Test func useAppDataWithDataPresentIsPlayable() throws {
        let box = try Sandbox()
        try box.giveAppData()
        let model = ShellHostModel(config: box.config())
        model.useAppData(Fixtures.orbit)
        #expect(try detail(model).game.state == .playable)
        #expect(model.notice == nil)
    }

    @Test func cloudSavesAreChosenPerGameAndTurnedOff() async throws {
        let box = try Sandbox()
        let folder = box.root.appendingPathComponent("iCloud/Game Saves", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = ShellHostModel(config: box.config(), picker: FakePicker(url: folder))
        await model.pickCloudSavesNow(Fixtures.orbit)
        #expect(try detail(model).cloudSaves == "Game Saves")
        #expect(try detail(model, Fixtures.chain).cloudSaves == nil)
        #expect(box.defaults(Fixtures.orbit).data(forKey: "cloudSavesBookmark") != nil)
        #expect(try detail(ShellHostModel(config: box.config())).cloudSaves == "Game Saves")
        model.actions.onDisableCloudSaves(Fixtures.orbit)
        #expect(try detail(model).cloudSaves == nil)
        #expect(box.defaults(Fixtures.orbit).data(forKey: "cloudSavesBookmark") == nil)
    }

    @Test func aStaleCloudFolderAsksForANewChoice() throws {
        let box = try Sandbox()
        box.defaults(Fixtures.orbit).set(Data("junk".utf8), forKey: "cloudSavesBookmark")
        box.defaults(Fixtures.orbit).set(Data("junk".utf8), forKey: "pickedDataBookmark")
        let orbit = try detail(ShellHostModel(config: box.config()))
        #expect(orbit.cloudSaves == nil && orbit.cloudNote.contains("choose it again"))
        #expect(orbit.dataNote.contains("no longer readable"))
    }

    @Test func showLogReadsTheGamesLogOrSaysThereIsNone() throws {
        let box = try Sandbox()
        let model = ShellHostModel(config: box.config())
        model.actions.onShowLog(Fixtures.orbit)
        #expect(model.log?.title == "Orbit Fixture" && model.log?.text == nil)
        try box.write("boot ok\nframe 1\n", to: box.appData.appendingPathComponent(Fixtures.orbit).appendingPathComponent("log.txt"))
        model.actions.onShowLog(Fixtures.orbit)
        #expect(model.log?.text == "boot ok\nframe 1\n" && model.log?.truncated == false)
    }

    @Test func aLongLogShowsItsEnd() throws {
        let box = try Sandbox()
        let url = box.appData.appendingPathComponent("log.txt")
        try box.write(String(repeating: "a", count: 100) + "END", to: url)
        let read = try #require(LogReader.read(url, maxBytes: 10))
        #expect(read.text == "aaaaaaaEND" && read.truncated)
        #expect(LogReader.read(box.root.appendingPathComponent("nope.txt")) == nil)
    }

    @Test func appUpdateOpensTheConfiguredURL() throws {
        let box = try Sandbox()
        let opened = LogBox()
        let url = URL(string: "https://example.invalid/update")!
        let model = ShellHostModel(config: box.config(updateURL: url, open: { opened.add($0.absoluteString) }))
        model.actions.onAppUpdate()
        #expect(opened.all == ["https://example.invalid/update"])
        let none = ShellHostModel(config: box.config())
        none.actions.onAppUpdate()
        #expect(none.notice != nil)
    }

    @Test func playHandsAPlayableGameToTheLauncher() async throws {
        let box = try Sandbox()
        try box.giveAppData()
        box.defaults(Fixtures.orbit).set("0", forKey: "launcher.DM_OPMODE")
        let launcher = RecordingLauncher()
        let model = ShellHostModel(config: box.config(), launcher: launcher)
        await model.playNow(Fixtures.orbit)
        let game = try #require(launcher.launched.first)
        #expect(game.titleID == Fixtures.orbit && game.environment["DM_OPMODE"] == "0" && game.environment["DM_SHOW_FPS"] == "0")
        #expect(game.dataURL.lastPathComponent == Fixtures.orbit && game.frameworkURL.lastPathComponent == "DmGame.framework")
        #expect(game.cloudSavesURL == nil && model.notice == nil)
    }

    @Test func theStubShowsThatLaunchingIsNotAvailable() async throws {
        let box = try Sandbox()
        try box.giveAppData()
        let model = ShellHostModel(config: box.config(), launcher: StubGameLauncher(log: { _ in }))
        await model.playNow(Fixtures.orbit)
        #expect(model.notice == "Launching is not available yet.")
    }

    @Test func playIgnoresGamesThatCannotStart() async throws {
        let box = try Sandbox()
        try box.giveAppData()
        let launcher = RecordingLauncher()
        let model = ShellHostModel(config: box.config(), launcher: launcher)
        for id in [Fixtures.chain, Fixtures.noFramework, Fixtures.badManifest, "0100000000999999"] { await model.playNow(id) }
        let needsData = ShellHostModel(config: try Sandbox().config(), launcher: launcher)
        await needsData.playNow(Fixtures.orbit)
        #expect(launcher.launched.isEmpty)
    }

    @Test func aFailingLauncherShowsItsError() async throws {
        let box = try Sandbox()
        try box.giveAppData()
        let launcher = RecordingLauncher()
        launcher.error = GameProblem(reason: "Out of memory")
        let model = ShellHostModel(config: box.config(), launcher: launcher)
        await model.playNow(Fixtures.orbit)
        #expect(model.notice == "Out of memory")
    }

    @Test func connectedControllersBecomeControllerInfo() {
        let c = ConnectedController(id: "a", name: "Pro Controller", player: 2, family: .nintendo, batteryPercent: 40, charging: true)
        #expect(ShellHostModel.info(for: c) == ControllerInfo(id: "a", name: "Pro Controller", player: "Player 2", batteryPercent: 40, charging: true))
    }
}
