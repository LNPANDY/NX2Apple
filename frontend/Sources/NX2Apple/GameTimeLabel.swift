import SwiftUI
import NXCore
import NXModel

struct GameTimeLabel: View {
    let game: LibraryGame
    @ObservedObject var settings: SaveSettingsStore
    @ObservedObject var players: PlayerProfileStore
    @EnvironmentObject private var loc: Localizer
    @Environment(\.scenePhase) private var scenePhase
    @State private var milliseconds: UInt64?

    private var location: String {
        "\(game.id)|\(settings.revision)|\(players.active.id)|\(scenePhase == .active)"
    }
    var body: some View {
        Group {
            if let milliseconds, milliseconds > 0 {
                Text(String(format: loc.t("library.playTime"), GameTimeMetrics.duration(milliseconds, locale: Locale(identifier: loc.lang.code))))
                    .font(.manrope(13)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("game.playTime")
            }
        }
        .task(id: location) {
            guard scenePhase == .active else { return }
            let own = GameCloudSaves(titleID: game.titleID, appPath: game.appPath)
            let override = settings.game(game.titleID)
            let effective = SaveLocations.effectiveSave(titleID: game.titleID, appPath: game.appPath, global: settings.global, game: override)
            let base = players.active.isDefault && effective.source == .standard ? own.savePath(default: effective.path) : effective.path
            let save = players.active.saveFolder(base: base)
            let cloud = players.active.isDefault ? SaveLocations.effectiveCloud(global: settings.global, game: override, own: own.setting).folder : nil
            let title = game.titleID
            let cached = await Task.detached(priority: .utility) { GameTimeMetrics.cached(save: save, cloudFolder: cloud, titleID: title) }.value
            guard !Task.isCancelled else { return }
            milliseconds = cached
            guard cloud != nil else { return }
            let value = await Task.detached(priority: .utility) { GameTimeMetrics.refresh(save: save, cloudFolder: cloud, titleID: title) }.value
            guard !Task.isCancelled else { return }
            milliseconds = value
        }
    }
}
