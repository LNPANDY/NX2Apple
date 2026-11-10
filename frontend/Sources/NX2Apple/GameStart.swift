import AppKit
import Foundation
import NXCore
import NXLauncher

/// What Play starts a Mac game with, in one place: the desktop launcher's Play button and the console mode both use it, so a
/// game gets the same environment from either (the saved choices for an app that does not read them itself, the mods, the Controls
/// page's layout for older builds, shared saved maps for capable builds, DM_PAD_MERGE, DM_SCREEN and DM_LAUNCHER=0). Console mode plays on a TV-sized screen with a controller, so it asks for
/// `fullscreen`, which forces DM_FULLSCREEN on whatever the game's Display setting says, and `homeMenu`, the Home menu's way back to it (#952).
enum GameStart {
    @MainActor static func environment(for game: LibraryGame, library: GameLibrary, controls: ControlLayout, repo: String,
                                       labels: (String) -> String, lang: Lang = Lang.initial(), fullscreen: Bool = false, player: PlayerProfile? = nil,
                                       saves: (global: SaveGlobalSettings, game: SaveGameOverride)? = nil,
                                       sticks: StickDeadzoneSettings? = nil, homeMenu: Bool = false, launcherBundleID: String? = Bundle.main.bundleIdentifier,
                                       screen: NSScreen? = NSApp?.keyWindow?.screen ?? NSScreen.main) -> [String: String] {
        library.migrateLaunchOptions()
        CloudSavesMigration.run()   // before the app reads its env.txt: DM_SAVE_SYNC=icloud keeps the folder the iPhone app uses
        let settings = LaunchSetting.forMac(app: game.appPath, titleID: game.titleID, repo: repo, labels: labels) ?? []
        let overrides = game.launchEnvironment(settings).merging(game.controllerLaunchOverrides) { _, manual in manual }
        let savingEnabled = game.controllerSavingEnabled(environment: overrides)
        let mappings = SavedChoices.appReadsControllerMappings(app: game.appPath) ? game.controllerPreferences() : nil
        let mods = GameMod.list(in: GameMod.folder(for: game, library: library.folder), titleID: game.titleID)
        var environment = game.startEnvironment(controls: controls.environment, settings: settings, mods: mods,
                                                store: SavedChoices(app: game.appPath, titleID: game.titleID),
                                                appReadsStore: SavedChoices.appReadsStore(app: game.appPath),
                                                controllerStore: mappings, savingEnabled: savingEnabled)
        if fullscreen, settings.contains(where: { $0.env == "DM_FULLSCREEN" }) { environment["DM_FULLSCREEN"] = "1" }
        if let id = displayID(of: screen) { environment["DM_SCREEN"] = String(id) }
        environment["DM_HOME_QUIT_TEXT"] = HomeButtonHint.promptText(gameName: game.displayName(lang), labels: labels, homeMenu: homeMenu)   // the game's Home button quit prompt in the launcher's language (#336)
        // Console mode's game: the Home menu's Back to console mode, which pauses it in the background (#952). The desktop's Play passes none.
        if homeMenu { environment.merge(HomeButtonHint.homeMenuEnvironment(launcherBundleID: launcherBundleID)) { $1 } }
        if let sticks { environment.merge(sticks.environment) { _, own in own } }   // DM_STICK_DEADZONE_L / _R: off adds nothing
        // The global setup and this game's own choices (SaveLocation.swift): a save folder and a cloud folder. A game with nothing set adds nothing.
        var base = SaveTransfer.macSave(titleID: game.titleID, appPath: game.appPath).save
        if let saves {
            let own = GameCloudSaves(titleID: game.titleID, appPath: game.appPath).setting
            let save = SaveLocations.effectiveSave(titleID: game.titleID, appPath: game.appPath, global: saves.global, game: saves.game)
            let cloud = SaveLocations.effectiveCloud(global: saves.global, game: saves.game, own: own)
            let saveEnv = SaveLocations.environment(save: save, cloud: cloud)
            if let folder = saveEnv["DM_SAVE"] { try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
            environment.merge(saveEnv) { $1 }
            base = save.path
        }
        // The player's own save folder (PlayerProfile.swift); the default player adds nothing, so their saves stay where they were
        if let player, !player.isDefault {
            let playerEnv = player.environment(base: base, existing: environment)
            if let save = playerEnv["DM_SAVE"] { try? FileManager.default.createDirectory(atPath: save, withIntermediateDirectories: true) }
            environment.merge(playerEnv) { $1 }
        }
        return environment
    }

    /// The display the game's window should open on: the launcher window's screen (front_mac.m DM_SCREEN reads this NSScreenNumber).
    static func displayID(of screen: NSScreen?) -> UInt32? {
        (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
