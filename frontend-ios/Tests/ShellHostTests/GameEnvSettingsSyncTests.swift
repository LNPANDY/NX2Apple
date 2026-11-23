import Foundation
import Testing
@testable import ShellHost
import ShellUI

@MainActor @Suite(.serialized) struct GameEnvSettingsSyncTests {
    private func installModeAndFPSSettings(in box: Sandbox) throws {
        let url = box.games.appendingPathComponent(Fixtures.orbit).appendingPathComponent("launcher.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["settings"] = [
            [
                "env": "DM_OPMODE",
                "section": "Graphics",
                "label": "Mode",
                "note": "",
                "kind": "choice",
                "default": "1",
                "options": [["0", "Handheld"], ["1", "Docked"]]
            ],
            [
                "env": "DM_FPS_TARGET",
                "section": "Graphics",
                "label": "Frame rate",
                "note": "",
                "kind": "choice",
                "default": "0",
                "options": [["0", "Game"], ["30", "30"], ["60", "60"]]
            ],
            [
                "env": "DM_SHOW_FPS",
                "section": "Interface",
                "label": "FPS",
                "note": "",
                "kind": "toggle",
                "default": "0",
                "on": "1",
                "off": "0"
            ]
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
    }

    private func row(_ model: ShellHostModel, env: String) throws -> SettingRow {
        let detail = try #require(model.details.first { $0.id == Fixtures.orbit })
        return try #require(detail.sections.flatMap(\.rows).first { $0.id == env })
    }

    private func rowValue(_ model: ShellHostModel, env: String) throws -> String {
        try row(model, env: env).value
    }

    @Test func perGameEnvFileOverridesUntouchedBuiltInDefaultInUIInGameMenuAndLaunchPlan() async throws {
        let box = try Sandbox()
        try box.giveAppData()
        try installModeAndFPSSettings(in: box)
        let envURL = box.appData.appendingPathComponent(Fixtures.orbit + "/env.txt")
        try box.write("# pushed tuning\nDM_OPMODE=0\nDM_GUEST_FILE=1\n", to: envURL)

        let launcher = RecordingLauncher()
        let model = ShellHostModel(config: box.config(), launcher: launcher)
        #expect(try rowValue(model, env: "DM_OPMODE") == "0")
        let detail = try #require(model.details.first { $0.id == Fixtures.orbit })
        #expect(detail.hasModifiedSettings)

        await model.playNow(Fixtures.orbit)
        let launched = try #require(launcher.launched.last)
        #expect(launched.environment["DM_OPMODE"] == "0")
        #expect(launched.builtInDefaultKeys.contains("DM_OPMODE"))

        let menuRaw = try #require(launched.environment["DM_SHELL_MENU"])
        let menu = try JSONDecoder().decode(ShellInGameMenu.Payload.self, from: Data(menuRaw.utf8))
        let modeItem = try #require(menu.items.first { $0.env == "DM_OPMODE" })
        #expect(modeItem.effectiveDefault == "0")

        let plan = EngineLaunchPlan.make(game: launched, appResources: box.root, documents: box.root, envFileText: nil)
        #expect(plan.environment["DM_OPMODE"] == "0")
        #expect(plan.environment["DM_GUEST_FILE"] == "1")
        let envFileKeys = Set((plan.environment["DM_ENV_FILE_KEYS"] ?? "").split(separator: " ").map(String.init))
        #expect(!envFileKeys.contains("DM_OPMODE"), "per-game in-game-menu keys stay editable in the gear menu")
        #expect(envFileKeys.contains("DM_GUEST_FILE"), "non-menu per-game env keys remain listed in DM_ENV_FILE_KEYS")
    }

    @Test func perGameEnvFileUnlocksAllInGameMenuKeysWhileSharedAndFrameworkEnvFilesStillLockThem() async throws {
        let box = try Sandbox()
        try box.giveAppData()
        try installModeAndFPSSettings(in: box)
        let envURL = box.appData.appendingPathComponent(Fixtures.orbit + "/env.txt")
        try box.write(
            "DM_OPMODE=0\nDM_METAL_HUD=0\nDM_SHOW_FPS=1\nDM_PICTURE_FIT=fill\nDM_AUDIO_MIX=1\nDM_GUEST_FILE=1\n",
            to: envURL
        )

        let launcher = RecordingLauncher()
        let model = ShellHostModel(config: box.config(), launcher: launcher)
        await model.playNow(Fixtures.orbit)
        let launched = try #require(launcher.launched.last)

        let plan = EngineLaunchPlan.make(game: launched, appResources: box.root, documents: box.root, envFileText: nil)
        #expect(plan.environment["DM_OPMODE"] == "0")
        #expect(plan.environment["DM_METAL_HUD"] == "0")
        #expect(plan.environment["DM_SHOW_FPS"] == "1")
        #expect(plan.environment["DM_PICTURE_FIT"] == "fill")
        #expect(plan.environment["DM_AUDIO_MIX"] == "1")
        #expect(plan.environment["DM_GUEST_FILE"] == "1")
        let ownKeys = Set((plan.environment["DM_ENV_FILE_KEYS"] ?? "").split(separator: " ").map(String.init))
        for key in ShellInGameMenu.allowedEnvs {
            #expect(!ownKeys.contains(key), "\(key) from per-game env.txt should not lock the in-game menu")
        }
        #expect(ownKeys == ["DM_GUEST_FILE"])

        // Shared Documents/env.txt and framework dm/env.txt still mark in-game-menu keys as file-locked.
        let sharedBox = try Sandbox()
        try sharedBox.giveAppData()
        try installModeAndFPSSettings(in: sharedBox)
        let sharedLauncher = RecordingLauncher()
        let sharedModel = ShellHostModel(config: sharedBox.config(), launcher: sharedLauncher)
        await sharedModel.playNow(Fixtures.orbit)
        let sharedLaunched = try #require(sharedLauncher.launched.last)
        try sharedBox.write("DM_OPMODE=0\n", to: sharedLaunched.frameworkURL.appendingPathComponent("dm/env.txt"))

        let lockedPlan = EngineLaunchPlan.make(
            game: sharedLaunched,
            appResources: sharedBox.root,
            documents: sharedBox.root,
            envFileText: "DM_METAL_HUD=0\n"
        )
        #expect(lockedPlan.environment["DM_METAL_HUD"] == "0")
        #expect(lockedPlan.environment["DM_OPMODE"] == "0")
        let lockedKeys = Set((lockedPlan.environment["DM_ENV_FILE_KEYS"] ?? "").split(separator: " ").map(String.init))
        #expect(lockedKeys.contains("DM_METAL_HUD"))
        #expect(lockedKeys.contains("DM_OPMODE"))
    }

    @Test func uiChangeToDefaultCommentsOutEnvFileLineAndPreventsGhostRebirth() async throws {
        let box = try Sandbox()
        try box.giveAppData()
        try installModeAndFPSSettings(in: box)
        let envURL = box.appData.appendingPathComponent(Fixtures.orbit + "/env.txt")
        try box.write("# keep comment\nDM_OPMODE=0\nDM_GUEST_FILE=1\n", to: envURL)

        let launcher = RecordingLauncher()
        let model = ShellHostModel(config: box.config(), launcher: launcher)
        #expect(try rowValue(model, env: "DM_OPMODE") == "0")

        // User switches back to built-in default ("1" = Docked) in the app UI.
        model.change(Fixtures.orbit, setting: "DM_OPMODE", value: "1")
        #expect(try rowValue(model, env: "DM_OPMODE") == "1")

        let updated = try String(contentsOf: envURL, encoding: .utf8)
        #expect(updated.contains("# keep comment"))
        #expect(updated.contains("# DM_OPMODE=0"))
        #expect(updated.contains("DM_GUEST_FILE=1"))
        #expect(GameEnvFileSync.parseOverrides(updated)["DM_OPMODE"] == nil)

        await model.playNow(Fixtures.orbit)
        let launched = try #require(launcher.launched.last)
        let plan = EngineLaunchPlan.make(game: launched, appResources: box.root, documents: box.root, envFileText: nil)
        #expect(plan.environment["DM_OPMODE"] == "1")
        #expect(plan.environment["DM_GUEST_FILE"] == "1")
    }

    @Test func uiChangeToNonDefaultUpdatesEnvFileInPlaceAndDeduplicates() throws {
        let box = try Sandbox()
        try box.giveAppData()
        try installModeAndFPSSettings(in: box)
        let envURL = box.appData.appendingPathComponent(Fixtures.orbit + "/env.txt")
        try box.write("# fps tuning\nDM_FPS_TARGET=30\nDM_FPS_TARGET=120\nDM_GUEST_FILE=1\n", to: envURL)

        let model = ShellHostModel(config: box.config())
        #expect(try rowValue(model, env: "DM_FPS_TARGET") == "30")

        model.change(Fixtures.orbit, setting: "DM_FPS_TARGET", value: "60")
        #expect(try rowValue(model, env: "DM_FPS_TARGET") == "60")

        let updated = try String(contentsOf: envURL, encoding: .utf8)
        #expect(updated.contains("DM_FPS_TARGET=60"))
        #expect(updated.contains("# DM_FPS_TARGET=120"))
        #expect(updated.contains("DM_GUEST_FILE=1"))
        #expect(GameEnvFileSync.parseOverrides(updated) == ["DM_FPS_TARGET": "60", "DM_GUEST_FILE": "1"])
    }

    @Test func resetDefaultsCommentsOutOnlyProfileManagedKeysAndPreservesAdvancedKeys() throws {
        let box = try Sandbox()
        try box.giveAppData()
        try installModeAndFPSSettings(in: box)
        let envURL = box.appData.appendingPathComponent(Fixtures.orbit + "/env.txt")
        try box.write("DM_OPMODE=0\nDM_FPS_TARGET=30\nDM_GUEST_FILE=1\nDM_MEMSTAT=/tmp/m.tsv\n", to: envURL)

        let model = ShellHostModel(config: box.config())
        model.resetDefaults(Fixtures.orbit)

        #expect(try rowValue(model, env: "DM_OPMODE") == "1")
        #expect(try rowValue(model, env: "DM_FPS_TARGET") == "0")
        let detail = try #require(model.details.first { $0.id == Fixtures.orbit })
        #expect(!detail.hasModifiedSettings)

        let updated = try String(contentsOf: envURL, encoding: .utf8)
        let parsed = GameEnvFileSync.parseOverrides(updated)
        #expect(parsed == ["DM_GUEST_FILE": "1", "DM_MEMSTAT": "/tmp/m.tsv"])
    }

    @Test func inGameMenuChangeReconcilesBackToEnvFileOnReturnToLibrary() async throws {
        let box = try Sandbox()
        try box.giveAppData()
        try installModeAndFPSSettings(in: box)
        let envURL = box.appData.appendingPathComponent(Fixtures.orbit + "/env.txt")
        try box.write("DM_OPMODE=0\nDM_GUEST_FILE=1\n", to: envURL)

        let launcher = RecordingLauncher()
        let model = ShellHostModel(config: box.config(), launcher: launcher)
        await model.playNow(Fixtures.orbit)
        let launched = try #require(launcher.launched.last)
        let menuRaw = try #require(launched.environment["DM_SHELL_MENU"])
        let payload = try JSONDecoder().decode(ShellInGameMenu.Payload.self, from: Data(menuRaw.utf8))

        // Simulate switching back to Docked ("1") inside the in-game gear menu.
        ShellInGameMenu.persistSelection(payload: payload, env: "DM_OPMODE", value: "1", defaults: box.defaults(Fixtures.orbit))
        #expect(box.defaults(Fixtures.orbit).string(forKey: "launcher.DM_OPMODE") == "1")

        model.handleReturnToLibrary()

        #expect(try rowValue(model, env: "DM_OPMODE") == "1")
        let updated = try String(contentsOf: envURL, encoding: .utf8)
        #expect(GameEnvFileSync.parseOverrides(updated) == ["DM_GUEST_FILE": "1"])
        #expect(box.defaults(Fixtures.orbit).object(forKey: "launcher.DM_OPMODE") == nil)

        await model.playNow(Fixtures.orbit)
        let relaunched = try #require(launcher.launched.last)
        let plan = EngineLaunchPlan.make(game: relaunched, appResources: box.root, documents: box.root, envFileText: nil)
        #expect(plan.environment["DM_OPMODE"] == "1")
    }

    @Test func sharedAndFrameworkEnvFilesBeatUntouchedBuiltInDefaultWhileShellSettingBeatsSharedEnv() async throws {
        let box = try Sandbox()
        try box.giveAppData()
        try installModeAndFPSSettings(in: box)

        let shellDefaults = TestDefaults.make("shell-test-envsync")
        let shell = ShellSettingsStore(defaults: shellDefaults)
        shell.storeShowFPS(true)

        let launcher = RecordingLauncher()
        let model = ShellHostModel(config: box.config(), launcher: launcher, shellSettings: shell)
        await model.playNow(Fixtures.orbit)
        let launched = try #require(launcher.launched.last)
        try box.write("DM_OPMODE=0\n", to: launched.frameworkURL.appendingPathComponent("dm/env.txt"))

        let plan = EngineLaunchPlan.make(
            game: launched,
            appResources: box.root,
            documents: box.root,
            envFileText: "DM_SHOW_FPS=0\nDM_FPS_TARGET=30\n"
        )
        #expect(plan.environment["DM_SHOW_FPS"] == "1", "shell setting beats shared Documents/env.txt")
        #expect(plan.environment["DM_FPS_TARGET"] == "30", "shared Documents/env.txt beats untouched built-in default")
        #expect(plan.environment["DM_OPMODE"] == "0", "framework dm/env.txt beats untouched built-in default")
    }

    @Test func changingSettingWithoutExistingEnvFileDoesNotCreateEnvFile() throws {
        let box = try Sandbox()
        try box.giveAppData()
        try installModeAndFPSSettings(in: box)
        let envURL = box.appData.appendingPathComponent(Fixtures.orbit + "/env.txt")
        #expect(!FileManager.default.fileExists(atPath: envURL.path))

        let model = ShellHostModel(config: box.config())
        model.change(Fixtures.orbit, setting: "DM_OPMODE", value: "0")
        #expect(!FileManager.default.fileExists(atPath: envURL.path))
        #expect(try rowValue(model, env: "DM_OPMODE") == "0")
    }

    @Test func perGameEnvFileMarksRowFromEnvFileUntilChangedOrReset() throws {
        let box = try Sandbox()
        try box.giveAppData()
        try installModeAndFPSSettings(in: box)
        let envURL = box.appData.appendingPathComponent(Fixtures.orbit + "/env.txt")
        try box.write("DM_OPMODE=0\nDM_FPS_TARGET=0\n", to: envURL)

        let model = ShellHostModel(config: box.config())
        let modeRow = try row(model, env: "DM_OPMODE")
        #expect(modeRow.value == "0")
        #expect(modeRow.fromEnvFile)
        #expect(!modeRow.fromShell)
        #expect(!modeRow.changed)

        let fpsRow = try row(model, env: "DM_FPS_TARGET")
        #expect(fpsRow.value == "0")
        #expect(fpsRow.fromEnvFile)
        #expect(!fpsRow.fromShell)
        #expect(!fpsRow.changed)

        // Manual UI change clears the env.txt origin mark immediately (A5).
        model.change(Fixtures.orbit, setting: "DM_FPS_TARGET", value: "30")
        let changedFPS = try row(model, env: "DM_FPS_TARGET")
        #expect(changedFPS.value == "30")
        #expect(!changedFPS.fromEnvFile)
        #expect(changedFPS.changed)
        #expect(try row(model, env: "DM_OPMODE").fromEnvFile)

        // Reset to defaults comments out both env.txt overrides and clears all origin marks (A6).
        model.resetDefaults(Fixtures.orbit)
        let resetMode = try row(model, env: "DM_OPMODE")
        let resetFPS = try row(model, env: "DM_FPS_TARGET")
        #expect(!resetMode.fromEnvFile && !resetMode.changed && resetMode.value == "1")
        #expect(!resetFPS.fromEnvFile && !resetFPS.changed && resetFPS.value == "0")
        let detail = try #require(model.details.first { $0.id == Fixtures.orbit })
        #expect(!detail.hasModifiedSettings)
    }

    @Test func perGameEnvFileEqualToDefaultStillEnablesResetAndClearsOnReset() throws {
        let box = try Sandbox()
        try box.giveAppData()
        try installModeAndFPSSettings(in: box)
        let envURL = box.appData.appendingPathComponent(Fixtures.orbit + "/env.txt")
        // DM_FPS_TARGET built-in default is "0".
        try box.write("DM_FPS_TARGET=0\n", to: envURL)

        let model = ShellHostModel(config: box.config())
        let fpsRow = try row(model, env: "DM_FPS_TARGET")
        #expect(fpsRow.fromEnvFile)
        let detail = try #require(model.details.first { $0.id == Fixtures.orbit })
        #expect(detail.hasModifiedSettings)

        model.resetDefaults(Fixtures.orbit)
        #expect(try !row(model, env: "DM_FPS_TARGET").fromEnvFile)
        let afterReset = try #require(model.details.first { $0.id == Fixtures.orbit })
        #expect(!afterReset.hasModifiedSettings)
        let updated = try String(contentsOf: envURL, encoding: .utf8)
        #expect(GameEnvFileSync.parseOverrides(updated).isEmpty)
    }
}
