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

    @Test func theStickPlaceGoesToEveryGameAndTheCornerIsNotStored() {
        let store = shell()
        #expect(store.touchStick == "corner" && store.gameDefaults["DM_TOUCH_STICK"] == nil)
        store.storeTouchStick("inward")
        store.storeTouchSize("small")
        #expect(store.gameDefaults == ["DM_TOUCH_STICK": "inward", "DM_TOUCH_SIZE": "small"])
        store.storeTouchStick("left")
        #expect(store.touchStick == "inward", "a place the engine does not know is not stored")
        store.storeTouchStick("corner")
        #expect(store.defaults.object(forKey: ShellSettingsStore.touchStickKey) == nil && store.gameDefaults == ["DM_TOUCH_SIZE": "small"])
    }

    /// The arrangement (#414) is stored as the engine's value and goes to every game as DM_TOUCH_LAYOUT. Reset removes it per layout.
    @Test func theArrangementGoesToEveryGameAndResetRemovesIt() {
        let store = shell()
        #expect(store.touchLayout.isEmpty && store.gameDefaults["DM_TOUCH_LAYOUT"] == nil, "settings saved before the editor: the built-in layout")
        var layout = TouchLayout()
        layout[.twoD, .stick] = TouchLayout.Offset(dx: 1, dy: -2)
        layout[.threeD, .a] = TouchLayout.Offset(dx: -1, dy: 0)
        store.storeTouchLayout(layout)
        #expect(store.defaults.string(forKey: ShellSettingsStore.touchLayoutKey) == "1;2d/stick:1,-2;3d/a:-1,0")
        #expect(ShellSettingsStore(defaults: store.defaults).touchLayout == layout)
        #expect(store.gameDefaults == ["DM_TOUCH_LAYOUT": "1;2d/stick:1,-2;3d/a:-1,0"])
        store.resetTouchLayout(.twoD)
        #expect(store.gameDefaults == ["DM_TOUCH_LAYOUT": "1;3d/a:-1,0"])
        store.resetTouchLayout(.threeD)
        #expect(store.defaults.object(forKey: ShellSettingsStore.touchLayoutKey) == nil && store.gameDefaults.isEmpty)
        store.defaults.set("1;2d/a:99,0", forKey: ShellSettingsStore.touchLayoutKey)
        #expect(store.touchLayout.isEmpty && store.gameDefaults.isEmpty, "a stored value the engine would ignore is not passed")
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

    @Test func aSavedGamePadLayoutWinsTheGlobalTouchMode() throws {
        let profile = try LauncherProfile.parse(Data("""
        {"schema":1,"game":"0100000000010000","settings":[{"env":"DM_PROF_PAD_LAYOUT","kind":"choice","section":"Touch","label":"Layout","note":"","default":"2","options":[["0","2D"],["1","3D"],["2","Tap"]]}]}
        """.utf8))
        let defaults = UserDefaults(suiteName: "t-game-touch-\(UUID().uuidString)")!
        let shell = shell()
        shell.storeTouchMode("3d")
        let game = GameSettingsStore(profile: profile, defaults: defaults, shell: shell.gameDefaults)
        let layout = try #require(profile.settings.first { $0.env == "DM_PROF_PAD_LAYOUT" })

        #expect(game.values()[layout.env] == "1" && game.isFromShell(layout))
        game.set(layout.env, to: "0")
        #expect(game.values()[layout.env] == "0" && !game.isFromShell(layout))
        game.reset()
        #expect(game.values()[layout.env] == "1" && game.isFromShell(layout))
        #expect(GameSettingsStore(profile: profile, defaults: defaults).values()[layout.env] == "2", "an unset shell mode preserves the game's Tap default")
    }
}
