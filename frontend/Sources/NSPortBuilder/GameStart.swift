import Foundation

/// What Play starts a Mac game with, in one place: the desktop launcher's Play button and the console mode both use it, so a
/// game gets the same environment from either (the saved choices for an app that does not read them itself, the mods, the Controls
/// page's layout, DM_PAD_MERGE, and DM_LAUNCHER=0).
enum GameStart {
    @MainActor static func environment(for game: LibraryGame, library: GameLibrary, controls: ControlLayout, repo: String,
                                       labels: (String) -> String) -> [String: String] {
        library.migrateLaunchOptions()
        let settings = LaunchSetting.forMac(app: game.appPath, titleID: game.titleID, repo: repo, labels: labels) ?? []
        let mods = GameMod.list(in: GameMod.folder(for: game, library: library.folder), titleID: game.titleID)
        return game.startEnvironment(controls: controls.environment, settings: settings, mods: mods,
                                     store: SavedChoices(app: game.appPath, titleID: game.titleID),
                                     appReadsStore: SavedChoices.appReadsStore(app: game.appPath))
    }
}
