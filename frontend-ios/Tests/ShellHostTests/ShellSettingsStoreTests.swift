import Foundation
import Testing
@testable import ShellHost
import ShellUI

@Suite struct ShellSettingsStoreTests {
    private func shell() -> ShellSettingsStore { ShellSettingsStore(defaults: UserDefaults(suiteName: "t-shell-\(UUID().uuidString)")!) }

    @Test func padMapPersistsAndResetsWithoutChangingOtherSettings() {
        let store = shell()
        #expect(store.padMap.envValue == nil)
        store.storePerformanceHUD(true)
        store.setPadSwapAB(true)
        store.setPadButton("X", to: "none")
        let again = ShellSettingsStore(defaults: store.defaults)
        #expect(again.padMap.envValue == "A=B,B=A,X=none")
        #expect(again.gameDefaults["DM_PAD_MAP"] == nil)
        store.setPadSwapAB(false)
        #expect(again.padMap.envValue == "X=none")
        store.setPadButton("X", to: "X")
        #expect(again.padMap.envValue == nil)
        store.setPadButton("A", to: "Y")
        store.resetPadMap()
        #expect(again.padMap.entries.isEmpty && again.performanceHUD == true)
        #expect(store.defaults.object(forKey: ShellSettingsStore.padMapKey) == nil)
    }

    @Test func theOverlayChoiceIsNilUntilThePlayerMakesOne() {
        let store = shell()
        #expect(store.performanceHUD == nil && store.gameDefaults.isEmpty)
        store.storePerformanceHUD(true)
        #expect(store.performanceHUD == true && store.gameDefaults == ["DM_METAL_HUD": "1"])
        store.storePerformanceHUD(false)
        #expect(store.gameDefaults == ["DM_METAL_HUD": "0"])
    }

    @Test func theTouchSizeGoesToEveryGameAndMediumIsNotStored() {
        let store = shell()
        #expect(store.touchSize == "medium" && store.gameDefaults["DM_TOUCH_SIZE"] == nil)
        store.storeTouchSize("large")
        #expect(ShellSettingsStore(defaults: store.defaults).touchSize == "large")
        #expect(store.gameDefaults == ["DM_TOUCH_SIZE": "large"])
        store.storeTouchSize("huge")
        #expect(store.touchSize == "large", "a size the engine does not know is not stored")
        store.storeTouchSize("small")
        #expect(store.gameDefaults["DM_TOUCH_SIZE"] == "small")
        store.storeTouchSize("medium")
        #expect(store.defaults.object(forKey: ShellSettingsStore.touchSizeKey) == nil && store.gameDefaults.isEmpty)
        store.defaults.set("giant", forKey: ShellSettingsStore.touchSizeKey)
        #expect(store.touchSize == "medium" && store.gameDefaults.isEmpty, "a stored value nobody knows reads as medium")
    }

    @Test func theFolderNamesAreKept() {
        let store = shell()
        store.storeDataFolderName("Switch")
        store.storeCloudSavesFolderName("Game Saves")
        #expect(store.dataFolderName == "Switch" && store.cloudSavesFolderName == "Game Saves")
    }

    @Test func aGameChoiceWinsTheShellDefaultWinsTheBuiltInOne() throws {
        let box = try Sandbox()
        let profile = try LauncherProfile.parse(Data(contentsOf: Fixtures.gamesURL.appendingPathComponent(Fixtures.orbit).appendingPathComponent("launcher.json")))
        let defaults = box.defaults(Fixtures.orbit)
        let shellDefaults = ["DM_SHOW_FPS": "1"]
        var store = GameSettingsStore(profile: profile, defaults: defaults, shell: shellDefaults)
        #expect(store.values()["DM_SHOW_FPS"] == "1", "the shell's value over the built-in default")
        #expect(!store.hasModifiedSettings, "a shell default is not a change the player made in this game")
        let fps = try #require(profile.settings.first { $0.env == "DM_SHOW_FPS" })
        #expect(store.isFromShell(fps))
        store.set("DM_SHOW_FPS", to: "0")
        #expect(store.values()["DM_SHOW_FPS"] == "0", "the game's own choice, though it equals the built-in default")
        #expect(!store.isFromShell(fps))
        #expect(store.hasModifiedSettings, "the saved off has to be resettable")
        store.reset()
        #expect(store.isFromShell(fps) && !store.hasModifiedSettings)
        store.set("DM_SHOW_FPS", to: "0")
        #expect(defaults.object(forKey: "launcher.DM_SHOW_FPS") as? String == "0")
        store.set("DM_SHOW_FPS", to: "1")
        #expect(defaults.object(forKey: "launcher.DM_SHOW_FPS") == nil, "a choice equal to the shell's value follows the shell again")
        store = GameSettingsStore(profile: profile, defaults: defaults, shell: ["DM_OPMODE": "7"])
        #expect(store.values()["DM_OPMODE"] == "1", "a value the game does not offer is ignored")
    }
}
