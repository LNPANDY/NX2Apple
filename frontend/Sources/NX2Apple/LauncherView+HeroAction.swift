import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// The hero's primary action and the built version beside it (#868, #849). The version is the package Play opens, one secondary 13 pt
/// label. When the hero is too narrow for it beside the button it sits below the button, in the same action block, and the
/// button's label keeps its size.
extension LauncherView {
    @ViewBuilder func heroPrimary(_ game: LibraryGame, compact: Bool) -> some View {
        let button = Button { primaryAction(game) } label: {
            LauncherHeroActionLabel(
                title: game.primary == .play ? loc.t("library.play")
                    : (game.primary == .openOnDevice ? String(format: loc.t("dev.open"), devices.deviceName(game.installedDevice))
                       : loc.t("library.setUpBuild")),
                symbol: game.primary == .play ? "play.fill" : (game.primary == .openOnDevice ? "iphone" : "hammer.fill"))
        }
        .buttonStyle(.plain).launcherHover(enabled: artworkEditor == nil)
        .disabled(launching || (m.running && !game.isReady) || artworkEditor != nil)
        .keyboardShortcut(.return, modifiers: [])
        .padTarget("hero.play", scope: "main", radius: 30) { if !launching { primaryAction(game) } }
        if let version = game.playVersion {
            let label = Text(String(format: loc.t("console.version"), version))
                .font(.manrope(13)).foregroundStyle(.secondary).lineLimit(1)
            if compact {
                VStack(alignment: .leading, spacing: 6) { button; label }
            } else {
                HStack(spacing: 12) { button; label }
            }
        } else {
            button
        }
    }
}
