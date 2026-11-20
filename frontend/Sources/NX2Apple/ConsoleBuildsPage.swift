import SwiftUI
import NXCore
import NXLauncher

/// The Builds page's content column (ConsolePageLayout puts the building game's artwork, title and progress on the left and
/// "Ⓑ Back, Ⓧ Stop build" in the hint bar): the queue as grouped lists, the running and waiting games first, the finished ones under
/// them. Each row: the game's icon, its name, its state and, while it builds, its progress. Nothing is building: a notice says so.
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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: DS.Console.Space.xl) {
                    let rows = builds.orderedQueue
                    let open = rows.filter { $0.outcome != .success }
                    let done = rows.filter { $0.outcome == .success }
                    if rows.isEmpty {
                        ConsoleNoticeCard(tone: .info, title: t("console.builds.emptyTitle"), detail: t("console.builds.emptyDetail"))
                    }
                    if !open.isEmpty { ConsoleGroupedList(title: t("console.builds.queue")) { list(open, all: rows) } }
                    if !done.isEmpty {
                        ConsoleGroupedList(title: t(open.isEmpty ? "console.queue.recent" : "console.queue.complete")) { list(done, all: rows) }
                    }
                }
                .padding(.horizontal, DS.Console.Space.xl).padding(.bottom, DS.Console.Space.xl)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(reduceMotion ? nil : LibraryHeroTransition.queue(reduceMotion: false), value: builds.orderedQueue.map { "\($0.id)-\($0.outcome == .success)" })
    }

    private func list(_ rows: [ConsoleBuilds.QueueRow], all: [ConsoleBuilds.QueueRow]) -> some View {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            if index > 0 { ConsoleRowDivider() }
            queueRow(row, all: all)
        }
    }

    /// A row's state in words: "Building · 40 %", "Waiting", "Done", "Failed".
    static func state(_ row: ConsoleBuilds.QueueRow, lang: Lang) -> String {
        if row.active || row.outcome != nil { return ConsoleBuildIndicator.label(row, lang: lang) }
        return L10n.string(row.statusKey, lang)
    }

    private func queueRow(_ row: ConsoleBuilds.QueueRow, all rows: [ConsoleBuilds.QueueRow]) -> some View {
        let id = "console.builds.queue." + row.id.uuidString
        let stateColor: Color = row.outcome == .failure ? DS.Color.statusError : row.outcome == .warning ? DS.Color.statusWarning : DS.Color.textSecondary
        return ConsoleFocused(id: id) { focused in
            HStack(spacing: DS.Console.Space.m) {
                Group {
                    if let icon = row.icon ?? row.artwork { Image(nsImage: icon).resizable().scaledToFill() }
                    else { Image(systemName: "hammer.fill").font(.system(size: 20)).foregroundStyle(DS.Color.symbolDefault).frame(maxWidth: .infinity, maxHeight: .infinity).background(DS.Color.surfaceRaised) }
                }
                .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(row.name).font(DS.Console.Font.body).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                    (Text(Self.state(row, lang: lang)).foregroundColor(stateColor)
                     + Text(row.platformKey.map { " \u{00b7} " + t($0) } ?? "").foregroundColor(DS.Color.textSecondary))
                        .font(DS.Console.Font.callout).monospacedDigit().lineLimit(1)
                    if row.active { ConsoleProgressBar(fraction: row.progress ?? 0).frame(maxWidth: 360).padding(.top, DS.Space.xxs) }
                }
                Spacer(minLength: DS.Console.Space.s)
                symbol(row)
            }
            .padding(.horizontal, DS.Console.Space.l).padding(.vertical, DS.Console.Space.s)
            .frame(maxWidth: .infinity, minHeight: DS.Console.Control.rowHeight, alignment: .leading)
            .background(focused ? DS.Color.surfaceRaised : .clear, in: RoundedRectangle(cornerRadius: DS.Console.Radius.row))
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(row.name)
        .accessibilityValue(([row.platformKey.map(t), Self.state(row, lang: lang)]).compactMap { $0 }.joined(separator: ", "))
        .consoleFocus(id, scope: Self.scope, vertical: { direction in
            guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return false }
            let next = index + direction
            guard rows.indices.contains(next) else { return true }
            pad.focused = "console.builds.queue." + rows[next].id.uuidString
            return true
        })
    }

    @ViewBuilder private func symbol(_ row: ConsoleBuilds.QueueRow) -> some View {
        switch row.outcome {
        case .success?: Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Color.statusSuccess).font(.system(size: 22)).accessibilityHidden(true)
        case .failure?: Image(systemName: "xmark.octagon.fill").foregroundStyle(DS.Color.statusError).font(.system(size: 22)).accessibilityHidden(true)
        case .warning?: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Color.statusWarning).font(.system(size: 22)).accessibilityHidden(true)
        case nil:
            if !row.active { Image(systemName: "clock").foregroundStyle(DS.Color.symbolDefault).font(.system(size: 20)).accessibilityHidden(true) }
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
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: DS.Console.Space.xl) {
                ConsoleGroupedList(title: t("console.controllers")) {
                    if state.controllers.isEmpty { ConsoleInfoRow(title: t("console.noControllers"), value: "") }
                    ForEach(state.controllers) { controller in
                        ConsoleInfoRow(title: controller.name, value: [((state.padMerge ? 1 : controller.player).map { String(format: t("console.player"), $0) }),
                                                                    controller.batteryPercent.map { String(format: t("console.batteryPercent"), $0) }]
                            .compactMap { $0 }.joined(separator: " \u{00b7} "))
                        ConsoleRowDivider()
                    }
                    ConsoleListRow(id: "console.quick.controllers", scope: Self.scope, title: t("console.quick.manageControllers")) { driver.openControllers() }
                }
                ConsoleGroupedList(title: t("console.options.launch"), footer: Self.hud(Self.game(state)) == nil ? nil : t("console.quick.nextLaunch")) { overlay }
            }
            .padding(.horizontal, compact ? DS.Console.Space.l : DS.Console.Space.xl).padding(.bottom, DS.Console.Space.xl)
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
            ConsoleToggleListRow(id: "console.quick.hud", scope: Self.scope, title: hud.label, isOn: on) {
                if let next = ConsoleOption.stepped(hud, value: game.value(hud), by: 1) { driver.setOption(gameID: game.id, setting: hud.env, value: next) }
            }
        } else {
            ConsoleInfoRow(title: t("console.quick.noOverlay"), value: "")
        }
    }
}
