import Foundation
import Testing
@testable import ShellHost
import ShellUI

@MainActor @Suite struct ShellInGameMenuTests {
    private static let mixedProfileJSON = """
    {
      "schema": 1,
      "game": "0100000000010000",
      "settings": [
        {"env":"DM_METAL_HUD","kind":"toggle","section":"Graphics","label":"Performance overlay","note":"","default":"0","on":"1","off":"0"},
        {"env":"DM_TOUCH_HAPTICS","kind":"toggle","section":"Controls","label":"Button haptics","note":"","default":"1","on":"1","off":"0"},
        {"env":"DM_RUMBLE","kind":"toggle","section":"Controls","label":"Rumble","note":"","default":"1","on":"1","off":"0"},
        {"env":"DM_TOUCH_SIZE","kind":"choice","section":"Controls","label":"Touch size","note":"","default":"medium","options":[["small","Small"],["medium","Medium"],["large","Large"]]},
        {"env":"DM_TOUCH_STICK","kind":"choice","section":"Controls","label":"Left stick","note":"","default":"corner","options":[["corner","Corner"],["higher","Higher"],["inward","Inward"]]},
        {"env":"DM_SHOW_FPS","kind":"toggle","section":"Graphics","label":"Frame-rate counter","note":"","default":"0","on":"1","off":"0"},
        {"env":"DM_OPMODE","kind":"choice","section":"Game","label":"Console mode","note":"","default":"1","options":[["1","Docked"],["0","Handheld"]]},
        {"env":"DM_PICTURE_FIT","kind":"choice","section":"Graphics","label":"Picture","note":"","default":"fit","options":[["fit","Fit"],["fill","Fill"]]},
        {"env":"DM_AUDIO_MIX","kind":"toggle","section":"Audio","label":"Mix with other audio","note":"","default":"0","on":"1","off":"0"},
        {"env":"DM_LANG","kind":"choice","section":"Game","label":"Game language","note":"","default":"en-US","options":[["en-US","American English"],["ja","Japanese"]]},
        {"env":"DM_RENDER_SCALE","kind":"range","section":"Performance","label":"Render scale","note":"","default":"1.0","min":0.5,"max":1.5,"step":0.05}
      ]
    }
    """

    @Test func allowlistOrderAndExclusion() throws {
        let profile = try LauncherProfile.parse(Data(Self.mixedProfileJSON.utf8))
        let payload = ShellInGameMenu.build(profile: profile, titleID: Fixtures.orbit, shellDefaults: [:])
        #expect(payload.suiteName == GameDefaults.suitePrefix + Fixtures.orbit)
        #expect(payload.items.map(\.env) == ["DM_OPMODE", "DM_PICTURE_FIT", "DM_SHOW_FPS", "DM_AUDIO_MIX", "DM_METAL_HUD"])

        let excluded: Set<String> = ["DM_TOUCH_HAPTICS", "DM_RUMBLE", "DM_TOUCH_SIZE", "DM_TOUCH_STICK", "DM_LANG", "DM_RENDER_SCALE"]
        #expect(Set(payload.items.map(\.env)).isDisjoint(with: excluded))
    }

    @Test func localizesMenuUsingBundle() throws {
        let profile = try LauncherProfile.parse(Data(Self.mixedProfileJSON.utf8))
        let expected: [(lang: String, consoleMode: String, docked: String, fps: String)] = [
            ("zh-Hans", "主机模式", "底座模式", "帧率显示"),
            ("ja", "本体モード", "TV モード", "フレームレート表示"),
            ("de", "Konsolenmodus", "Angedockt", "Bildraten-Anzeige"),
        ]

        for entry in expected {
            let lprojPath = try #require(ShellStrings.bundle.path(forResource: entry.lang, ofType: "lproj"))
            let bundle = try #require(Bundle(path: lprojPath))
            let payload = ShellInGameMenu.build(profile: profile, titleID: Fixtures.orbit, shellDefaults: [:], bundle: bundle)

            let opmode = try #require(payload.items.first { $0.env == "DM_OPMODE" })
            #expect(opmode.label == entry.consoleMode)
            #expect(opmode.label != "Console mode")
            #expect(opmode.options?.first { $0[0] == "1" }?[1] == entry.docked)
            #expect(opmode.options?.first { $0[0] == "0" }?[1] != "Handheld" || entry.lang == "de")

            let fps = try #require(payload.items.first { $0.env == "DM_SHOW_FPS" })
            #expect(fps.label == entry.fps)
            #expect(fps.label != "Frame-rate counter")

            let picture = try #require(payload.items.first { $0.env == "DM_PICTURE_FIT" })
            #expect(picture.label != "Picture")
            #expect(picture.options?.first { $0[0] == "fit" }?[1] != "Fit")

            let audioMix = try #require(payload.items.first { $0.env == "DM_AUDIO_MIX" })
            #expect(audioMix.label != "Mix with other audio")

            let hud = try #require(payload.items.first { $0.env == "DM_METAL_HUD" })
            #expect(hud.label != "Performance overlay")
        }
    }

    @Test func twoWayPersistenceCancellationAndReturnNotification() async throws {
        let box = try Sandbox()
        try box.giveAppData()
        let shellSuite = "t-shell-\(UUID().uuidString)"
        let shellDefaults = UserDefaults(suiteName: shellSuite)!
        defer { shellDefaults.removePersistentDomain(forName: shellSuite) }
        let shell = ShellSettingsStore(defaults: shellDefaults)
        shell.storeShowFPS(true)

        let launcher = RecordingLauncher()
        let model = ShellHostModel(config: box.config(), launcher: launcher, shellSettings: shell)
        await model.waitForDataChecks()

        await model.playNow(Fixtures.orbit)
        let firstLaunch = try #require(launcher.launched.last)
        #expect(firstLaunch.environment["DM_SHOW_FPS"] == "1")
        let encoded = try #require(firstLaunch.environment["DM_SHELL_MENU"])
        let payload = try JSONDecoder().decode(ShellInGameMenu.Payload.self, from: Data(encoded.utf8))
        #expect(payload.suiteName == GameDefaults.suitePrefix + Fixtures.orbit)
        let fpsItem = try #require(payload.items.first { $0.env == "DM_SHOW_FPS" })
        #expect(fpsItem.effectiveDefault == "1")

        // Plant an unscanned DLC marker on disk to verify return refresh does not rescan disk.
        try box.write("", to: box.appData.appendingPathComponent(Fixtures.orbit).appendingPathComponent("aoc/0.img"))

        let gameDefaults = box.defaults(Fixtures.orbit)
        ShellInGameMenu.persistSelection(payload: payload, env: "DM_SHOW_FPS", value: "0", defaults: gameDefaults)
        #expect(gameDefaults.object(forKey: "launcher.DM_SHOW_FPS") as? String == "0")

        NotificationCenter.default.post(name: ShellHostModel.didReturnToLibraryNotification, object: nil)
        func detail() throws -> GameDetail {
            try #require(model.details.first { $0.id == Fixtures.orbit })
        }
        func fpsValue() throws -> String? {
            try detail().sections.flatMap(\.rows).first { $0.id == "DM_SHOW_FPS" }?.value
        }

        for _ in 0..<50 where (try? fpsValue()) != "0" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(try fpsValue() == "0")
        #expect(try detail().hasModifiedSettings)
        #expect(try detail().dlc == "No additional content")

        await model.playNow(Fixtures.orbit)
        #expect(launcher.launched.last?.environment["DM_SHOW_FPS"] == "0")

        // Reverting to effectiveDefault removes the override key via cancellation rule.
        ShellInGameMenu.persistSelection(payload: payload, env: "DM_SHOW_FPS", value: "1", defaults: gameDefaults)
        #expect(gameDefaults.object(forKey: "launcher.DM_SHOW_FPS") == nil)

        NotificationCenter.default.post(name: ShellHostModel.didReturnToLibraryNotification, object: nil)
        for _ in 0..<50 where (try? fpsValue()) != "1" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(try fpsValue() == "1")
        #expect(try !detail().hasModifiedSettings)
    }
}
