import SwiftUI
import NXCore

/// Puts the Settings > Controls layout into every ready game's own preferences (#454), so a start from Finder, the Dock or Launchpad has it
/// too. Only for apps that read the saved layout themselves (Info.plist DMControllerMappings). Nothing is written for a game the player
/// customised or reset in the game.
enum ControlSync {
    @MainActor static func run(library: GameLibrary, controls: ControlLayout) {
        let env = controls.environment
        for game in library.games where game.isReady && !game.appPath.isEmpty && SavedChoices.appReadsControllerMappings(app: game.appPath) {
            let savingEnabled = game.controllerSavingEnabled(environment: env)
            game.controllerPreferences().syncGlobal(env, savingEnabled: savingEnabled)
        }
    }
}

extension View {
    /// Runs the sync when the window opens, when the layout changes and when the library's games change.
    @MainActor func syncControllerLayouts(library: GameLibrary, controls: ControlLayout) -> some View {
        self.onAppear { ControlSync.run(library: library, controls: controls) }
            .onChange(of: controls.changeCount) { _ in ControlSync.run(library: library, controls: controls) }
            .onChange(of: library.games.count) { _ in ControlSync.run(library: library, controls: controls) }
    }
}
