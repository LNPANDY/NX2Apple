import Foundation
import Testing
import GameTime
@testable import ShellHost

@MainActor @Suite struct GameTimeTests {
    @Test func metricsStayInBackupsAndSurviveKeepingSaves() throws {
        let box = try Sandbox()
        let game = box.appData.appendingPathComponent(Fixtures.orbit)
        let local = try #require(DMGameTimeLocalURL(game.appendingPathComponent("save"), nil, Fixtures.orbit))
        var error: NSError?
        #expect(DMGameTimeUpdateRun(local, UUID().uuidString, 1000, &error))
        BackupExclusion.exclude(game.appendingPathComponent("playtime"))
        BackupExclusion.apply(appDataRoot: box.appData)
        #expect(!BackupExclusion.isExcluded(game.appendingPathComponent("playtime")))
        GameDeletion.delete(in: game, saves: false)
        #expect(FileManager.default.fileExists(atPath: local.path))
    }

    @Test func selectionReadsTimeWithoutLaunchingOrChangingLastPlayed() async throws {
        let box = try Sandbox()
        let id = Fixtures.orbit
        let save = box.appData.appendingPathComponent(id).appendingPathComponent("save")
        let local = try #require(DMGameTimeLocalURL(save, nil, id))
        var error: NSError?
        #expect(DMGameTimeUpdateRun(local, UUID().uuidString, 7_500_000, &error))
        let model = ShellHostModel(config: box.config(), launcher: RecordingLauncher(), picker: FakePicker())
        model.actions.onSelect(id)
        await model.waitForGameTime()
        #expect(model.details.first(where: { $0.id == id })?.game.playTime?.contains("2") == true)
        #expect(LastPlayedStore(defaults: box.defaults(id)).date == nil)
        #expect(!model.launchingGame)
    }
}
