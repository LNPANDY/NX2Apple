import Foundation
import os

/// Everything the engine needs to start one game, resolved by the host. The real launcher (Route C, M2: `DmShell.app`
/// dlopens the game's `DmGame.framework`, #144) turns it into the environment and `dm_main` arguments.
public struct LaunchableGame: Equatable, Sendable {
    public var titleID: String
    public var name: String
    public var manifest: GameManifest
    /// The game's bundle folder: manifest, launcher.json, framework.
    public var directory: URL
    public var frameworkURL: URL
    /// The folder with the game's data (romfs.img or romfs/), picked or the app's own.
    public var dataURL: URL
    /// The app's `Documents/games/<title ID>/`: save, temp, log.txt.
    public var appFolder: URL
    /// Every `DM_*` switch with the player's value or the tested default, as `launcher.<VAR>` would set it.
    public var environment: [String: String]
    /// The picked cloud-save folder, when cloud saves are on.
    public var cloudSavesURL: URL?
}

/// The seam between the shell and the engine. The shell calls `launch` when the player presses Play on a playable game.
/// It returns when the game has started (or never, if the process becomes the game), and throws a localized error the
/// shell shows.
public protocol GameLauncher: Sendable {
    @MainActor func launch(_ game: LaunchableGame) async throws
}

public enum GameLaunchError: LocalizedError, Equatable, Sendable {
    case notAvailable
    public var errorDescription: String? {
        switch self {
        case .notAvailable: hostText("Launching is not available yet.")
        }
    }
}

/// Only logs and reports that launching is not available yet. The real implementation arrives with M2.
public struct StubGameLauncher: GameLauncher {
    private let log: @Sendable (String) -> Void
    public init(log: @escaping @Sendable (String) -> Void = { Logger(subsystem: "dev.nx2apple.shell", category: "launch").info("\($0, privacy: .public)") }) {
        self.log = log
    }
    public func launch(_ game: LaunchableGame) async throws {
        log("launch requested for \(game.titleID) (\(game.name)), data at \(game.dataURL.path), \(game.environment.count) settings. The stub does not start it.")
        throw GameLaunchError.notAvailable
    }
}
