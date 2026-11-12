import Foundation
import NXCore
import NXModel

extension GameLibrary {
    @MainActor func refreshPlayTime(_ game: LibraryGame, player: PlayerProfile, global: SaveGlobalSettings, override: SaveGameOverride,
                                    synchronize: Bool = true, current: @escaping @MainActor () -> Bool = { true }) async {
        let own = GameCloudSaves(titleID: game.titleID, appPath: game.appPath)
        let effective = SaveLocations.effectiveSave(titleID: game.titleID, appPath: game.appPath, global: global, game: override)
        let base = player.isDefault && effective.source == .standard ? own.savePath(default: effective.path) : effective.path
        let save = player.saveFolder(base: base)
        let cloud = player.isDefault ? SaveLocations.effectiveCloud(global: global, game: override, own: own.setting).folder : nil
        let cached = await timeIndex.cached(save: save, cloudFolder: cloud, titleID: game.titleID)
        guard !Task.isCancelled, current() else { return }
        applyPlayTime(cached, to: game.id)
        let value = await timeIndex.refresh(save: save, cloudFolder: cloud, titleID: game.titleID, synchronize: synchronize)
        guard !Task.isCancelled, current() else { return }
        applyPlayTime(value, to: game.id)
    }

    @MainActor func refreshPlayTime(_ game: LibraryGame, settings: SaveSettingsStore, players: PlayerProfileStore, synchronize: Bool = true) async {
        let player = players.active, revision = settings.revision
        await refreshPlayTime(game, player: player, global: settings.global, override: settings.game(game.titleID), synchronize: synchronize,
                              current: { player.id == players.active.id && revision == settings.revision })
    }
}
