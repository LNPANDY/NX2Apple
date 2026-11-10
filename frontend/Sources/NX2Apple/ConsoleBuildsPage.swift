import SwiftUI
import NXCore
import NXLauncher

/// The Builds page (#816, from the menu): the desktop's running build with its stages as the Builds page shows them (the current
/// stage's own share, never a time or a whole-build percentage), Stop (asked first), and the build queue, read only. Builds start on
/// the desktop.
@MainActor struct ConsoleBuildsPage<Driver: ConsoleDriver>: View {
    @ObservedObject var driver: Driver
    let lang: Lang
    let compact: Bool
    @EnvironmentObject private var pad: PadFocus

    static var scope: String { "console.builds" }
    private var builds: ConsoleBuilds { driver.state.builds }
    private func t(_ key: String) -> String { L10n.string(key, lang) }
    private var inset: CGFloat { compact ? 24 : 64 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ConsolePageHeader(title: t("console.builds"), note: t("console.builds.note"), compact: compact, closeLabel: t("console.close"),
                              closeID: "console.builds.close", scope: Self.scope) { driver.back() }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: compact ? 20 : 32) {
                    current
                    if !builds.queue.isEmpty { queue }
                }
                .padding(.horizontal, inset).padding(.bottom, 24)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .consoleScrollContent()
            }
            .consoleScrollFade()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LauncherPalette.background)
        .onChange(of: builds.running) { running in pad.focused = running ? "console.builds.stop" : "console.builds.close" }
    }

    @ViewBuilder private var current: some View {
        if builds.running {
            VStack(alignment: .leading, spacing: 14) {
                Text(builds.title).font(.manrope(compact ? 19 : 24, .semibold)).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(builds.stages) { stage in stageRow(stage) }
                }
                Button { driver.askStopBuild() } label: {
                    Text(t(builds.stopping ? "library.stopping" : "btn.stop")).font(.manrope(compact ? 17 : 20, .bold))
                        .foregroundStyle(.white.opacity(0.9)).padding(.horizontal, 28).frame(minHeight: compact ? 48 : 54)
                        .background(.white.opacity(0.09), in: Capsule()).contentShape(Capsule())
                }
                .buttonStyle(.plain).disabled(builds.stopping)
                .padTarget("console.builds.stop", scope: Self.scope, radius: compact ? 24 : 27, activate: { if !builds.stopping { driver.askStopBuild() } })
                .padding(.top, 6)
            }
            .padding(compact ? 18 : 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 18))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(t("console.builds.none")).font(.manrope(compact ? 19 : 24, .semibold))
                Text(t("console.builds.noneNote")).font(.manrope(compact ? 15 : 18)).foregroundStyle(LauncherPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func stageRow(_ stage: ConsoleBuilds.StageRow) -> some View {
        let color: Color = {
            switch stage.state {
            case .done: return LauncherPalette.ready
            case .running: return LauncherPalette.building
            case .failed: return LauncherPalette.unbuilt
            case .pending: return .white.opacity(0.4)
            }
        }()
        let symbol: String = {
            switch stage.state {
            case .done: return "checkmark.circle.fill"
            case .running: return "circle.dotted"
            case .failed: return "xmark.octagon.fill"
            case .pending: return "circle"
            }
        }()
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: compact ? 15 : 18, weight: .semibold)).foregroundStyle(color).frame(width: 24)
                    .accessibilityHidden(true)
                Text(stage.name).font(.manrope(compact ? 15 : 18, stage.state == .running ? .semibold : .regular))
                    .foregroundStyle(stage.state == .pending ? LauncherPalette.secondaryText : .white)
                Spacer(minLength: 8)
                if let progress = stage.progress, stage.state == .running {
                    Text(String(format: t("console.batteryPercent"), Int(progress * 100))).font(.manrope(compact ? 14 : 16, .semibold)).monospacedDigit()
                        .foregroundStyle(LauncherPalette.cream)
                }
            }
            if stage.state == .running {
                // the stage's own share, or the calm indeterminate bar when it reports none
                Group {
                    if let progress = stage.progress { LauncherProgressBar(value: progress, height: 6, tint: LauncherPalette.cream) }
                    else { ProgressView().progressViewStyle(.linear).tint(LauncherPalette.cream) }
                }
                .padding(.leading, 36)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: 10) {
            ConsoleSectionHeading(title: t("queue.title"), compact: compact)
            ForEach(builds.queue) { row in
                HStack(spacing: 12) {
                    Text(row.name).font(.manrope(compact ? 16 : 19, .medium)).lineLimit(2)
                    Spacer(minLength: 8)
                    Text(t(row.statusKey)).font(.manrope(compact ? 14 : 16, .semibold)).foregroundStyle(LauncherPalette.secondaryText)
                }
                .padding(.horizontal, 18).padding(.vertical, 13)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .background(LauncherPalette.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// The quick menu (#816, − or View): the connected controllers and the way to their page, and the frame rate overlay (the game's own
/// Performance HUD option, DM_METAL_HUD) of the focused game, or of the paused one.
@MainActor struct ConsoleQuickMenu<Driver: ConsoleDriver>: View {
    @ObservedObject var driver: Driver
    let lang: Lang
    let compact: Bool
    @EnvironmentObject private var pad: PadFocus
    static var scope: String { "console.quickMenu" }
    static var hudEnv: String { "DM_METAL_HUD" }
    private var state: ConsoleState { driver.state }
    private func t(_ key: String) -> String { L10n.string(key, lang) }

    /// The game whose overlay the menu switches: the paused one, else the focused one.
    static func game(_ state: ConsoleState) -> ConsoleGame? { state.pausedGame ?? state.focusedGame }
    static func hud(_ game: ConsoleGame?) -> LaunchSetting? { game?.visibleSettings.first { $0.env == hudEnv } }
    static func firstTarget(_ state: ConsoleState) -> String { "console.quick.controllers" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ConsoleSectionHeading(title: t("console.controllers"), compact: compact)
                if state.controllers.isEmpty {
                    Text(t("console.noControllers")).font(.manrope(compact ? 15 : 18)).foregroundStyle(LauncherPalette.secondaryText)
                }
                ForEach(state.controllers) { controller in
                    HStack(spacing: 14) {
                        Image(systemName: controller.kind.symbol).font(.system(size: compact ? 18 : 22)).frame(width: 32).accessibilityHidden(true)
                        Text(controller.name).font(.manrope(compact ? 16 : 19, .semibold)).lineLimit(1)
                        Spacer(minLength: 8)
                        if let player = state.padMerge ? 1 : controller.player {
                            Text(String(format: t("console.player"), player)).font(.manrope(compact ? 14 : 16, .semibold)).foregroundStyle(LauncherPalette.cream)
                        }
                        if let percent = controller.batteryPercent {
                            Text(String(format: t("console.batteryPercent"), percent)).font(.manrope(compact ? 14 : 16)).monospacedDigit()
                                .foregroundStyle(LauncherPalette.secondaryText)
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(LauncherPalette.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityElement(children: .combine)
                }
                ConsoleMenuRow(id: "console.quick.controllers", scope: Self.scope, symbol: "gamecontroller", title: t("console.controllers"),
                               note: t("console.menu.controllersNote"), compact: compact) { driver.openControllers() }
                ConsoleSectionHeading(title: t("console.quick.overlay"), compact: compact).padding(.top, 14)
                overlay
            }
            .padding(.horizontal, compact ? 24 : 40).padding(.bottom, compact ? 24 : 40)
        }
    }

    @ViewBuilder private var overlay: some View {
        let game = Self.game(state)
        if let game, let hud = Self.hud(game) {
            let on = game.value(hud) == hud.onValue
            ConsoleSwitchRow(id: "console.quick.hud", scope: Self.scope, title: hud.label,
                             note: String(format: t("console.quick.overlayNote"), game.title), isOn: on, compact: compact) {
                if let next = ConsoleOption.stepped(hud, value: game.value(hud), by: 1) { driver.setOption(gameID: game.id, setting: hud.env, value: next) }
            }
        } else {
            Text(t("console.quick.noOverlay")).font(.manrope(compact ? 15 : 18)).foregroundStyle(LauncherPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
