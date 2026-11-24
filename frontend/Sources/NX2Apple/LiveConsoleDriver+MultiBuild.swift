import Foundation
import NXCore

/// Multi-engine default switching and per-engine launch support for `LiveConsoleDriver`.
extension LiveConsoleDriver {
    func applyMultiBuildInfo(_ console: inout ConsoleGame, from game: LibraryGame) {
        console.activeMacEngine = game.activeMacUpstream(defaults: library.defaults)
        console.builtMacEngines = game.sortedMacBuilds.map(\.upstream)
    }

    func clearLaunchOverrideAndFail(_ message: String) {
        pendingLaunchUpstreamOverride = nil
        state.returnFromGame()
        gameEnded()
        showToast(message, kind: "error")
    }

    func setDefaultMacEngine(_ gameID: String, upstream: EngineUpstreamKind) {
        guard let uuid = UUID(uuidString: gameID),
              library.games.contains(where: { $0.id == uuid }) else { return }
        library.setPreferredMacUpstream(upstream, for: uuid)
        refresh()
    }

    func launchWithMacEngine(_ gameID: String, upstream: EngineUpstreamKind) {
        guard state.startingGameID == nil,
              let game = libraryGame(gameID),
              game.macBuild(for: upstream) != nil else { return }
        pendingLaunchUpstreamOverride = (gameID, upstream)
        play(gameID)
    }

    func resolvedLaunchGame(for gameID: String, fallback: LibraryGame? = nil) -> LibraryGame? {
        guard let base = library.games.first(where: { $0.id.uuidString == gameID }) ?? fallback else { return nil }
        if let override = pendingLaunchUpstreamOverride,
           override.gameID == gameID,
           let targeted = base.targetingMacBuild(override.upstream) {
            return targeted
        }
        return base
    }
}
