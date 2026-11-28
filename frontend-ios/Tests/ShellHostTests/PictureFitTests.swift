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

    @Test func portraitLaunchResolvesAutoScreenAspectTo43RegardlessOfFitAndPreservesPerGameTouchSize() async throws {
        let box = try box()
        let url = box.games.appendingPathComponent(Fixtures.orbit).appendingPathComponent("launcher.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var settings = try #require(json["settings"] as? [[String: Any]])
        settings.append([
            "env": "DM_SCREEN_ASPECT",
            "kind": "choice",
            "section": "Game",
            "label": "Picture shape",
            "note": "",
            "default": "auto",
            "options": [["auto", "Match screen"], ["0", "16:9 (Switch)"]]
        ])
        settings.append([
            "env": "DM_ROTATION",
            "kind": "choice",
            "section": "Game",
            "label": "Rotation",
            "note": "",
            "default": "auto",
            "options": [["auto", "Automatic"], ["landscape", "Landscape"], ["portrait", "Portrait"]]
        ])
        settings.append([
            "env": "DM_TOUCH_SIZE",
            "kind": "choice",
            "section": "Controls",
            "label": "Size",
            "note": "",
            "default": "medium",
            "options": [["small", "Small"], ["medium", "Medium"], ["large", "Large"]]
        ])
        json["settings"] = settings
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let launcher = RecordingLauncher()
        let model = ShellHostModel(config: box.config(), launcher: launcher)
        model.shellSettings.storeTouchSize("small", for: .landscape)
        model.shellSettings.storeTouchSize("large", for: .portrait)
        model.change(Fixtures.orbit, setting: "DM_ROTATION", value: "portrait")
        model.change(Fixtures.orbit, setting: "DM_TOUCH_SIZE", value: "large")

        // Default Fit in locked portrait resolves DM_SCREEN_ASPECT=auto to 4:3 (1.333).
        await model.playNow(Fixtures.orbit)
        let fitGame = try #require(launcher.launched.last)
        let fitPlan = EngineLaunchPlan.make(game: fitGame, appResources: box.root, documents: box.root, envFileText: nil)
        #expect(fitPlan.environment["DM_PICTURE_FIT"] == "fit")
        #expect(fitPlan.environment["DM_SCREEN_ASPECT"] == "1.333")
        #expect(fitPlan.environment["DM_TOUCH_SIZE"] == "large")
        #expect(fitPlan.environment["DM_TOUCH_SIZE_PORTRAIT"] == nil)

        // Fill in locked portrait also resolves DM_SCREEN_ASPECT=auto to 4:3 (1.333).
        model.change(Fixtures.orbit, setting: "DM_PICTURE_FIT", value: "fill")
        await model.playNow(Fixtures.orbit)
        let fillGame = try #require(launcher.launched.last)
        let fillPlan = EngineLaunchPlan.make(game: fillGame, appResources: box.root, documents: box.root, envFileText: nil)
        #expect(fillPlan.environment["DM_SCREEN_ASPECT"] == "1.333")

        // Explicit 16:9 (0) stays 0 in portrait.
        model.change(Fixtures.orbit, setting: "DM_SCREEN_ASPECT", value: "0")
        await model.playNow(Fixtures.orbit)
        let forced169Game = try #require(launcher.launched.last)
        #expect(EngineLaunchPlan.make(game: forced169Game, appResources: box.root, documents: box.root, envFileText: nil).environment["DM_SCREEN_ASPECT"] == "0")

        // Landscape and Automatic rotation leave DM_SCREEN_ASPECT=auto untouched for front_ios.m.
        model.change(Fixtures.orbit, setting: "DM_SCREEN_ASPECT", value: "auto")
        for rotation in ["landscape", "auto"] {
            model.change(Fixtures.orbit, setting: "DM_ROTATION", value: rotation)
            await model.playNow(Fixtures.orbit)
            let game = try #require(launcher.launched.last)
            #expect(EngineLaunchPlan.make(game: game, appResources: box.root, documents: box.root, envFileText: nil).environment["DM_SCREEN_ASPECT"] == "auto")
        }
    }

    @Test func portraitFullScreenAspectPassesThroughForFrontIOSToLatchAndResolveDeviceSlot() async throws {
        let box = try box()
        let url = box.games.appendingPathComponent(Fixtures.orbit).appendingPathComponent("launcher.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var settings = try #require(json["settings"] as? [[String: Any]])
        settings.append([
            "env": "DM_SCREEN_ASPECT",
            "kind": "choice",
            "section": "Game",
            "label": "Picture shape",
            "note": "",
            "default": "auto",
            "options": [
                ["auto", "Match screen"],
                ["portrait-full", "Portrait full screen"],
                ["1.43", "iPhone Duo screen (1.43:1)"],
                ["0", "16:9 (Switch)"]
            ]
        ])
        settings.append([
            "env": "DM_ROTATION",
            "kind": "choice",
            "section": "Game",
            "label": "Rotation",
            "note": "",
            "default": "auto",
            "options": [["auto", "Automatic"], ["landscape", "Landscape"], ["portrait", "Portrait"]]
        ])
        json["settings"] = settings
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let launcher = RecordingLauncher()
        let model = ShellHostModel(config: box.config(), launcher: launcher)
        model.change(Fixtures.orbit, setting: "DM_ROTATION", value: "portrait")

        // Default DM_SCREEN_ASPECT=auto resolves to 1.333 (standard 4:3 below Dynamic Island).
        await model.playNow(Fixtures.orbit)
        let standardGame = try #require(launcher.launched.last)
        let standardPlan = EngineLaunchPlan.make(game: standardGame, appResources: box.root, documents: box.root, envFileText: nil)
        #expect(standardPlan.environment["DM_SCREEN_ASPECT"] == "1.333")

        // DM_SCREEN_ASPECT=portrait-full passes "portrait-full" through across every rotation mode so front_ios.m latches portraitFull and resolves the exact slot aspect (~0.921) in portrait or 16:9 in landscape.
        model.change(Fixtures.orbit, setting: "DM_SCREEN_ASPECT", value: "portrait-full")
        for rotation in ["portrait", "auto", "landscape"] {
            model.change(Fixtures.orbit, setting: "DM_ROTATION", value: rotation)
            await model.playNow(Fixtures.orbit)
            let fullGame = try #require(launcher.launched.last)
            let fullPlan = EngineLaunchPlan.make(game: fullGame, appResources: box.root, documents: box.root, envFileText: nil)
            #expect(fullPlan.environment["DM_SCREEN_ASPECT"] == "portrait-full")
        }

        // Explicit 1.43 and 0 stay untouched in locked portrait.
        model.change(Fixtures.orbit, setting: "DM_ROTATION", value: "portrait")
        for explicit in ["1.43", "0"] {
            model.change(Fixtures.orbit, setting: "DM_SCREEN_ASPECT", value: explicit)
            await model.playNow(Fixtures.orbit)
            let explicitGame = try #require(launcher.launched.last)
            let explicitPlan = EngineLaunchPlan.make(game: explicitGame, appResources: box.root, documents: box.root, envFileText: nil)
            #expect(explicitPlan.environment["DM_SCREEN_ASPECT"] == explicit)
        }
    }
}
