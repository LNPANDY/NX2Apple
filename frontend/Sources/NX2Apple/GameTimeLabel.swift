import SwiftUI
import NXCore
import NXModel

struct GameTimeLabel: View {
    let game: LibraryGame
    @ObservedObject var library: GameLibrary
    @ObservedObject var settings: SaveSettingsStore
    @ObservedObject var players: PlayerProfileStore
    @EnvironmentObject private var loc: Localizer
    @Environment(\.scenePhase) private var scenePhase
    private var location: String { "\(game.id)|\(game.appPath)|\(settings.revision)|\(players.active.id)|\(scenePhase == .active)" }

    var body: some View {
        Group {
            if let value = game.playTime?.totalMilliseconds, value > 0 {
                Text(String(format: loc.t("library.playTime"), GameTimeMetrics.duration(value, locale: Locale(identifier: loc.lang.code))))
                    .font(.manrope(13)).foregroundStyle(.secondary).accessibilityIdentifier("game.playTime")
            }
        }
        .task(id: location) {
            guard scenePhase == .active else { return }
            await library.refreshPlayTime(game, settings: settings, players: players)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleURL?.standardizedFileURL == URL(fileURLWithPath: game.appPath).standardizedFileURL else { return }
            Task { await library.refreshPlayTime(game, settings: settings, players: players) }
        }
    }
}
