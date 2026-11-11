import Foundation
import NXCore

extension LibraryGame {
    /// Whether macOS Game Mode should be active for this Mac game bundle (`launchOptions["MAC_GAME_MODE"]`, else `Info.plist`).
    var macGameModeDesired: Bool {
        MacGameMode.shared.effectiveEnabled(forApp: appPath, storedOption: launchOptions[MacGameMode.optionEnv])
    }

    /// Whether any launcher-owned option differs from its tested default (including an external `LSSupportsGameMode = true` in `Info.plist`).
    var hasLauncherOptions: Bool {
        !launchOptions.isEmpty || macGameModeDesired
    }
}

extension GameLibrary {
    /// Schedules an asynchronous `Info.plist` + `codesign` update for `MAC_GAME_MODE`, rolling back the saved option if signing fails
    /// while no newer toggle has superseded it.
    func applyMacGameModeOption(enabled: Bool, for id: UUID, appPath: String) {
        guard !appPath.isEmpty else { return }
        MacGameMode.shared.scheduleApply(enabled, toApp: appPath) { [weak self] err in
            DispatchQueue.main.async {
                guard let self,
                      var current = self.games.first(where: { $0.id == id }),
                      current.appPath == appPath else { return }
                let expectedChoice = enabled ? "1" : nil
                guard current.launchOptions[MacGameMode.optionEnv] == expectedChoice else { return }
                let actual = MacGameMode.isEnabled(inApp: appPath)
                current.launchOptions[MacGameMode.optionEnv] = actual ? "1" : nil
                self.upsert(current)
                self.error = err.localizedDescription
            }
        }
    }
}
