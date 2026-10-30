import AppKit
import Foundation

/// What Play starts a Mac game with, in one place: the desktop launcher's Play button and the console mode both use it, so a
/// game gets the same environment from either (the saved choices for an app that does not read them itself, the mods, the Controls
/// page's layout, DM_PAD_MERGE, DM_SCREEN and DM_LAUNCHER=0). Console mode plays on a TV-sized screen with a controller, so it asks for
/// `fullscreen`, which forces DM_FULLSCREEN on whatever the game's Display setting says.
enum GameStart {
    @MainActor static func environment(for game: LibraryGame, library: GameLibrary, controls: ControlLayout, repo: String,
                                       labels: (String) -> String, fullscreen: Bool = false,
                                       screen: NSScreen? = NSApp?.keyWindow?.screen ?? NSScreen.main) -> [String: String] {
        library.migrateLaunchOptions()
        CloudSavesMigration.run()   // before the app reads its env.txt: DM_SAVE_SYNC=icloud keeps the folder the iPhone app uses
        let settings = LaunchSetting.forMac(app: game.appPath, titleID: game.titleID, repo: repo, labels: labels) ?? []
        let mods = GameMod.list(in: GameMod.folder(for: game, library: library.folder), titleID: game.titleID)
        var environment = game.startEnvironment(controls: controls.environment, settings: settings, mods: mods,
                                                store: SavedChoices(app: game.appPath, titleID: game.titleID),
                                                appReadsStore: SavedChoices.appReadsStore(app: game.appPath))
        if fullscreen, settings.contains(where: { $0.env == "DM_FULLSCREEN" }) { environment["DM_FULLSCREEN"] = "1" }
        if let id = displayID(of: screen) { environment["DM_SCREEN"] = String(id) }
        return environment
    }

    /// The display the game's window should open on: the launcher window's screen (front_mac.m DM_SCREEN reads this NSScreenNumber).
    static func displayID(of screen: NSScreen?) -> UInt32? {
        (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
