import Foundation
import Testing
import ShellUI
@testable import ShellHost

/// The Picture row of a game's settings (#545): Fit or Fill, per game, passed to the engine as DM_PICTURE_FIT.
/// The row is the one dm/games/settings.py writes into launcher.json for an iOS game (platform:ios).
@MainActor @Suite struct PictureFitTests {
    static let note = "Fill crops the game's 16:9 picture to cover the screen. Health bars, subtitles or maps near the edges can be cut off. A full-screen picture without cropping needs a patch for each game."
    static let row: [String: Any] = ["env": "DM_PICTURE_FIT", "kind": "choice", "section": "Game", "label": "Picture", "note": note,
                                     "default": "fit", "options": [["fit", "Fit"], ["fill", "Fill"]]]

    /// The orbit fixture with the Picture row after its Game rows, as the engine's list puts it.
    private func box() throws -> Sandbox {
        let box = try Sandbox()
        try box.giveAppData()
        let url = box.games.appendingPathComponent(Fixtures.orbit).appendingPathComponent("launcher.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var settings = try #require(json["settings"] as? [[String: Any]])
        settings.insert(Self.row, at: 1)
        json["settings"] = settings
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        return box
    }

    private func pictureRow(_ model: ShellHostModel) throws -> SettingRow {
        let detail = try #require(model.details.first { $0.id == Fixtures.orbit })
        return try #require(detail.sections.first { $0.id == "Game" }?.rows.first { $0.id == "DM_PICTURE_FIT" })
    }

    @Test func theRowIsATwoWayChoiceWithItsNoteAndFitByDefault() throws {
        let box = try box()   // kept for the test: the sandbox removes its folder when it goes
        let model = ShellHostModel(config: box.config())
        let row = try pictureRow(model)
        #expect(row.value == "fit", "Fit is today's picture and stays the default")
        #expect(row.label == "Picture" && row.note == Self.note)
        guard case .choice(let options) = row.kind else { Issue.record("not a choice"); return }
        #expect(options.map(\.id) == ["fit", "fill"] && options.map(\.label) == ["Fit", "Fill"])
        #expect(!row.note.contains(";"))
    }

    @Test func fillIsKeptPerGameAndPassedToTheEngine() async throws {
        let box = try box()
        let launcher = RecordingLauncher()
        let model = ShellHostModel(config: box.config(), launcher: launcher)
        await model.playNow(Fixtures.orbit)
        #expect(launcher.launched.last?.environment["DM_PICTURE_FIT"] == "fit")

        model.change(Fixtures.orbit, setting: "DM_PICTURE_FIT", value: "fill")
        #expect(box.defaults(Fixtures.orbit).string(forKey: "launcher.DM_PICTURE_FIT") == "fill", "in the game's own suite")
        #expect(try pictureRow(model).value == "fill")
        await model.playNow(Fixtures.orbit)
        let game = try #require(launcher.launched.last)
        #expect(game.environment["DM_PICTURE_FIT"] == "fill")
        let plan = EngineLaunchPlan.make(game: game, appResources: box.root, documents: box.root, envFileText: nil)
        #expect(plan.environment["DM_PICTURE_FIT"] == "fill", "setenv gets it before the engine reads it")

        // A new model over the same suite, as after a relaunch, still has Fill. Fit again stores nothing.
        let again = ShellHostModel(config: box.config(), launcher: launcher)
        #expect(try pictureRow(again).value == "fill")
        again.change(Fixtures.orbit, setting: "DM_PICTURE_FIT", value: "fit")
        #expect(box.defaults(Fixtures.orbit).object(forKey: "launcher.DM_PICTURE_FIT") == nil)
    }

    @Test func aValueTheEngineDoesNotReadIsRefused() throws {
        let box = try box()
        let profile = try LauncherProfile.parse(Data(contentsOf: box.games.appendingPathComponent(Fixtures.orbit).appendingPathComponent("launcher.json")))
        let store = GameSettingsStore(profile: profile, defaults: box.defaults(Fixtures.orbit))
        #expect(!store.set("DM_PICTURE_FIT", to: "stretch"), "only the two values the engine reads")
        #expect(store.values()["DM_PICTURE_FIT"] == "fit")
    }
}
