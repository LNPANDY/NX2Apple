import Foundation
import Testing
import ShellUI
@testable import ShellHost

@MainActor @Suite struct WidgetSnapshotTests {
    @Test func modelPublishesSnapshotOnLoadAndPlayAndRoutesDeepLinks() async throws {
        let box = try Sandbox()
        try box.giveAppData(Fixtures.orbit)
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let launcher = RecordingLauncher()
        let settingsSuite = "widget.host.tests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: settingsSuite) }
        let shell = ShellSettingsStore(defaults: UserDefaults(suiteName: settingsSuite)!)

        let model = ShellHostModel(
            config: box.config(now: { clock.date }),
            launcher: launcher,
            shellSettings: shell
        )
        await model.waitForStartupTasks()

        let snapshotDir = box.appData.deletingLastPathComponent()
        let initialPayload = try #require(WidgetSnapshotStore.readSnapshotFile(in: snapshotDir))
        #expect(initialPayload.readyCount >= 1)
        #expect(initialPayload.games.first?.id == Fixtures.orbit)
        #expect(initialPayload.games.first?.isPlayable == true)
        #expect(initialPayload.games.first?.lastPlayedEpoch == nil)

        // Deep-link navigation to settings and controllers increments sequence monotonically.
        #expect(model.open(URL(string: "nx2apple://settings/\(Fixtures.orbit)")!))
        let nav1 = try #require(model.navigation)
        #expect(nav1.link == .settings(id: Fixtures.orbit))

        #expect(model.open(URL(string: "nx2apple://controllers")!))
        let nav2 = try #require(model.navigation)
        #expect(nav2.link == .controllers)
        #expect(nav2.sequence > nav1.sequence)

        #expect(!model.open(URL(string: "https://example.com")!))

        // Deep-link play launches the playable game and updates lastPlayedEpoch in widget-snapshot.json.
        clock.date = Date(timeIntervalSince1970: 1_800_003_600)
        #expect(model.open(URL(string: "nx2apple://play/\(Fixtures.orbit.lowercased())")!))
        for _ in 0..<40 where launcher.launched.isEmpty {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(launcher.launched.map(\.titleID) == [Fixtures.orbit])

        let updatedPayload = try #require(WidgetSnapshotStore.readSnapshotFile(in: snapshotDir))
        #expect(updatedPayload.games.first?.id == Fixtures.orbit)
        #expect(updatedPayload.games.first?.lastPlayedEpoch == 1_800_003_600)
    }
}
