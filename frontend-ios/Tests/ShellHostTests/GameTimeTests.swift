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
    @Test func deletingAndReaddingKeepsRuntimeHistoryRecencyAndDestination() async throws {
        for removeSaves in [false, true] {
            let box = try Sandbox()
            let folder = try box.giveAppData()
            let cloud = box.root.appendingPathComponent("Cloud")
            try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
            let at = Date(timeIntervalSince1970: 1_794_480_000)
            let model = ShellHostModel(config: box.config(now: { at }), launcher: RecordingLauncher(), picker: MutablePicker(cloud))
            await model.pickCloudSavesNow(Fixtures.orbit)
            let destination = BookmarkStore(defaults: box.defaults(Fixtures.orbit), key: BookmarkStore.cloudSavesKey).resolve()
            guard case .url(let resolvedCloud) = destination else { Issue.record("cloud bookmark must resolve"); return }
            let local = try #require(DMGameTimeLocalURL(folder.appendingPathComponent("save"), DMGameTimeCloudURL(resolvedCloud.path, Fixtures.orbit), Fixtures.orbit))
            var error: NSError?
            #expect(DMGameTimeUpdateSegments(local, [["id": UUID().uuidString, "day": "2026-11-12", "milliseconds": 7_500_000]], 1_794_480_000_000, &error))
            model.actions.onSelect(Fixtures.orbit)
            await model.waitForGameTime()
            #expect(model.details.first { $0.id == Fixtures.orbit }?.game.recentlyPlayed == "Played today")
            #expect(LastPlayedStore(defaults: box.defaults(Fixtures.orbit)).date == at)
            model.deleteGame(Fixtures.orbit, saves: removeSaves)
            #expect(FileManager.default.fileExists(atPath: local.path))
            #expect(box.defaults(Fixtures.orbit).data(forKey: BookmarkStore.cloudSavesKey) != nil)
            try box.giveAppData()
            let again = ShellHostModel(config: box.config(now: { at }), launcher: RecordingLauncher())
            again.actions.onSelect(Fixtures.orbit)
            await again.waitForGameTime()
            #expect(again.details.first { $0.id == Fixtures.orbit }?.game.playTime?.contains("2") == true)
            #expect(again.details.first { $0.id == Fixtures.orbit }?.game.recentlyPlayed == "Played today")
            #expect(DMGameTimeTotal(local, &error)?.uint64Value == 7_500_000)
            #expect(DMGameTimeUpdateSegments(local, [["id": UUID().uuidString, "day": "2026-11-12", "milliseconds": 60_000]], 1_794_480_060_000, &error))
            again.refreshSelectedGameTime(); await again.waitForGameTime()
            #expect(DMGameTimeTotal(local, &error)?.uint64Value == 7_560_000, "cached retained totals must never be added again as new history")
        }
    }

}
