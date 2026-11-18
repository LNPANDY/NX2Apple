import SwiftUI
import NXCore
import NXLauncher

/// Console build monitoring: glanceable overall progress on the active game and a read-only queue.
@MainActor struct ConsoleBuildsPage<Driver: ConsoleDriver>: View {
    @ObservedObject var driver: Driver
    let lang: Lang
    let compact: Bool
    var embedded = false
    @EnvironmentObject private var pad: PadFocus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static var scope: String { "console.builds" }
    private var builds: ConsoleBuilds { driver.state.builds }
    private func t(_ key: String) -> String { L10n.string(key, lang) }
    private var inset: CGFloat { embedded ? 40 : compact ? 24 : 64 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !embedded {
                ConsolePageHeader(title: t("console.builds"), compact: compact, closeLabel: t("console.close"),
                                  closeID: "console.builds.close", scope: Self.scope) { driver.back() }
            }
            ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: compact ? 20 : 32) {
                    if !builds.queue.isEmpty { queue }
                }
                .padding(.horizontal, inset).padding(.bottom, 24)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .consoleScrollContent()
            }
            .consoleScrollFade()
            .onChange(of: builds.orderedQueue.map(\.id)) { _ in
                if let id = pad.focused, id.hasPrefix("console.builds.queue.") {
                    withAnimation(reduceMotion ? nil : LibraryHeroTransition.queue(reduceMotion: false)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .onChange(of: pad.focused) { id in
                if let id, id.hasPrefix("console.builds.queue.") {
                    withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.18)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LauncherPalette.background)
        .onChange(of: builds.running) { running in
            if !running && pad.focused == "console.builds.stop" { pad.focused = "console.builds.close" }
        }
    }

    private var queue: some View {
        let rows = builds.orderedQueue
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(rows) { row in
                if row.id == rows.first(where: { $0.outcome == .success })?.id {
                    Text(t(rows.allSatisfy { $0.outcome == .success } ? "console.queue.recent" : "console.queue.complete")).font(.manrope(20, .semibold))
                        .foregroundStyle(LauncherPalette.secondaryText).accessibilityAddTraits(.isHeader)
                        .padding(.top, row.id == rows.first?.id ? 0 : 16)
                }
                HStack(spacing: 20) {
                    Group {
                        if let icon = row.icon { Image(nsImage: icon).resizable().scaledToFill() }
                        else { Image(systemName: "hammer.fill").font(.system(size: 28)).frame(maxWidth: .infinity, maxHeight: .infinity).background(LauncherPalette.surface) }
                    }
                    .frame(width: 80, height: 80).clipShape(RoundedRectangle(cornerRadius: 14))
                    .saturation(row.outcome == .success ? 1 : 0)
                    .overlay(alignment: .bottomTrailing) {
                        if let outcome = row.outcome {
                            ArtworkOutcomeBadge(outcome == .success ? .success : outcome == .warning ? .warning : .failure, artworkSize: 80)
                        }
                    }.accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 10) {
                        if let platform = row.platformKey {
                            ArtworkStatusChip(title: t(platform), symbol: row.platformSymbol, color: ArtworkStatusChip.neutralColor, fontSize: 15, showsIndicator: false)
                        }
                        Text(row.name).font(.manrope(22, .semibold)).fixedSize(horizontal: false, vertical: true)
                        if row.outcome == nil, !["queue.status.queued", "queue.status.running", "queue.status.stopped"].contains(row.statusKey) {
                            Text(t(row.statusKey)).font(.manrope(18, .semibold))
                                .foregroundStyle(row.outcome == .failure ? LauncherPalette.danger : row.outcome == .warning ? LauncherPalette.building : LauncherPalette.secondaryText)
                        }
                    }
                    Spacer(minLength: 0)
                    if !row.active, row.statusKey == "queue.status.queued" {
                        Image(systemName: "clock.fill").font(.system(size: 26))
                            .foregroundStyle(LauncherPalette.secondaryText).accessibilityHidden(true)
                    }
                    if row.active {
                        if let progress = row.progress {
                            Text(String(format: t("console.batteryPercent"), Int(progress * 100)))
                                .font(.manrope(compact ? 34 : 44, .bold)).monospacedDigit()
                                .frame(width: compact ? 100 : 130, alignment: .trailing)
                        } else { ProgressView().controlSize(.large).tint(.white) }
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 13)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .background {
                    if row.active, let image = row.artwork ?? row.icon {
                        BuildFooterReveal(image: image, progress: row.progress ?? 0)
                    } else { LauncherPalette.surface.opacity(0.6) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .opacity(row.outcome == .success ? 0.72 : 1)
                .accessibilityElement(children: .ignore).accessibilityLabel(row.name)
                .accessibilityValue(([row.platformKey.map(t), t(row.statusKey)] + [row.active ? row.progress.map { String(format: t("console.batteryPercent"), Int($0 * 100)) } : nil]).compactMap { $0 }.joined(separator: ", "))
                .padTarget("console.builds.queue." + row.id.uuidString, scope: Self.scope, radius: 14, vertical: { direction in
                    guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return false }
                    let next = index + direction
                    pad.focused = rows.indices.contains(next) ? "console.builds.queue." + rows[next].id.uuidString : "console.builds.close"
                    return true
                })
                .id("console.builds.queue." + row.id.uuidString)
            }
        }
        .animation(reduceMotion ? nil : LibraryHeroTransition.queue(reduceMotion: false), value: rows.map { "\($0.id)-\($0.outcome == .success)" })
    }
}

/// The quick menu (#816, − or View): the connected controllers and the way to their page, and the frame rate overlay (the game's own
/// Performance HUD option, DM_METAL_HUD) of the focused game, or of the paused one.
@MainActor struct ConsoleQuickMenu<Driver: ConsoleDriver>: View {
    @ObservedObject var driver: Driver
    let lang: Lang
    let compact: Bool
    @EnvironmentObject private var pad: PadFocus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static var scope: String { "console.quickMenu" }
    static var hudEnv: String { "DM_METAL_HUD" }
    private var state: ConsoleState { driver.state }
    private func t(_ key: String) -> String { L10n.string(key, lang) }

    /// The game whose overlay the menu switches: the paused one, else the focused one.
    static func game(_ state: ConsoleState) -> ConsoleGame? { state.pausedGame ?? state.focusedGame }
    static func hud(_ game: ConsoleGame?) -> LaunchSetting? { game?.visibleSettings.first { $0.env == hudEnv } }
    static func firstTarget(_ state: ConsoleState) -> String { "console.quick.controllers" }

    var body: some View {
        ScrollViewReader { proxy in
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
                               note: "", compact: compact) { driver.openControllers() }
                ConsoleSectionHeading(title: t("console.options.launch"), compact: compact).padding(.top, 14)
                overlay
            }
            .padding(.horizontal, compact ? 24 : 40).padding(.bottom, compact ? 24 : 40)
            .consoleScrollContent()
        }
        .consoleScrollFade()
        .onChange(of: pad.focused) { id in
            guard let id, id.hasPrefix("console.quick.") else { return }
            withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.18)) { proxy.scrollTo(id, anchor: .center) }
        }
        }

    }

    @ViewBuilder private var overlay: some View {
        let game = Self.game(state)
        if let game, let hud = Self.hud(game) {
            let on = game.value(hud) == hud.onValue
            ConsoleSwitchRow(id: "console.quick.hud", scope: Self.scope, title: hud.label,
                             note: t("console.quick.nextLaunch"), isOn: on, compact: compact) {
                if let next = ConsoleOption.stepped(hud, value: game.value(hud), by: 1) { driver.setOption(gameID: game.id, setting: hud.env, value: next) }
            }
        } else {
            Text(t("console.quick.noOverlay")).font(.manrope(compact ? 15 : 18)).foregroundStyle(LauncherPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
