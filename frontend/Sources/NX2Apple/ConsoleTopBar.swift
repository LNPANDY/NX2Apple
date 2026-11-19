import SwiftUI
import NXCore
import NXLauncher

/// The home screen's top controls, console mode's navigation layer (Liquid Glass, LNPANDY/NX2Apple#1458): the build that runs, the
/// players, Controllers, Search and the menu. Every control is one glass capsule or circle of DS.Console.Control.topBar. The focus is
/// the cream ring, nothing grows.
private struct ConsoleTopSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let focused: Bool
    func body(content: Content) -> some View {
        content
            .launcherControlSurface(in: shape)
            .overlay { if focused { shape.strokeBorder(DS.Color.accent, lineWidth: DS.Console.Control.focusRing) } }
            .launcherGlassLayer()
    }
}

/// A round symbol button of the top bar (Search, the menu), or a capsule with a label (Controllers).
struct ConsoleHeaderButton: View {
    let symbol: String
    let id: String
    let label: String
    let compact: Bool
    var showsLabel = false
    @EnvironmentObject private var pad: PadFocus
    private var focused: Bool { pad.visible && pad.focused == id }
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Console.Space.xs) {
                Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(DS.Color.symbolDefault)
                    .frame(width: 24, height: 24)
                if showsLabel { Text(label).font(DS.Console.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary).lineLimit(1) }
            }
            .padding(.horizontal, showsLabel ? DS.Console.Space.l : 0)
            .frame(width: showsLabel ? nil : DS.Console.Control.topBar, height: DS.Console.Control.topBar)
            .modifier(ConsoleTopSurface(shape: Capsule(), focused: focused))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).accessibilityLabel(label)
        .padTarget(id, scope: "console", activate: action)
        .environment(\.padRingStyle, .none)
    }
}

/// Controllers, with the players to its left in the same capsule height: one entry per controller, its kind, its player and battery.
struct ConsoleControllerButton: View {
    let controllers: [ConsoleController]
    let merged: Bool
    let lang: Lang
    var compact = false
    var showsPlayers = true
    let openControllers: () -> Void
    private func t(_ key: String) -> String { L10n.string(key, lang) }

    private var summary: String {
        guard !controllers.isEmpty else { return t("console.noControllers") }
        return controllers.map { controller in
            let player = (merged ? 1 : controller.player).map { String(format: t("console.player"), $0) } ?? t("console.unassigned")
            var parts = [controller.name, t(controller.kind.labelKey), player]
            if let percent = controller.batteryPercent {
                parts.append(String(format: t(controller.charging ? "console.batteryCharging" : "console.batteryLevel"), percent))
            }
            return parts.joined(separator: ", ")
        }.joined(separator: "\n")
    }

    var body: some View {
        HStack(spacing: DS.Console.Space.s) {
            if showsPlayers, !controllers.isEmpty { ConsolePlayersChip(controllers: controllers, merged: merged, lang: lang, open: openControllers) }
            ConsoleHeaderButton(symbol: "gamecontroller.fill", id: "console.chip.controllers", label: t("console.controllers"), compact: compact, showsLabel: true, action: openControllers)
                .accessibilityValue(summary).help(summary)
        }
    }
}

/// The players, left of Controllers: "P1 76 %" per controller in one glass capsule. A click opens the Controllers page, the
/// controller reaches it through Controllers (it is no extra focus stop).
struct ConsolePlayersChip: View {
    let controllers: [ConsoleController]
    let merged: Bool
    let lang: Lang
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: DS.Console.Space.m) {
                ForEach(controllers.prefix(4)) { controller in
                    HStack(spacing: DS.Console.Space.xs) {
                        Image(systemName: controller.kind.symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(DS.Color.symbolDefault)
                        Text((merged ? 1 : controller.player).map { String(format: L10n.string("console.playerShort", lang), $0) } ?? "?")
                            .font(DS.Console.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary)
                        ConsoleBattery(controller: controller, lang: lang, compact: false)
                    }
                }
            }
            .padding(.horizontal, DS.Console.Space.l)
            .frame(height: DS.Console.Control.topBar)
            .modifier(ConsoleTopSurface(shape: Capsule(), focused: false))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)   // Controllers carries the same summary for VoiceOver
    }
}

/// The build that runs, in the top bar: the game's square app icon with a thin ring for its progress, then "Building · 40 %" and
/// "+2" when more games wait. A finished or failed build says so in the same place until it expires. A opens the Builds page.
struct ConsoleBuildIndicator: View {
    let builds: ConsoleBuilds
    let row: ConsoleBuilds.QueueRow
    let lang: Lang
    let open: () -> Void
    @EnvironmentObject private var pad: PadFocus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let id = "console.build.activity"
    private var focused: Bool { pad.visible && pad.focused == Self.id }
    private func t(_ key: String) -> String { L10n.string(key, lang) }

    /// The others that still wait after this one.
    static func waiting(_ builds: ConsoleBuilds, besides row: ConsoleBuilds.QueueRow) -> Int {
        builds.queue.filter { $0.id != row.id && $0.outcome == nil && !$0.active }.count
    }
    /// "Building · 40 %", "Building" before the first share, "Done", "Failed", "Skipped".
    static func label(_ row: ConsoleBuilds.QueueRow, lang: Lang) -> String {
        func t(_ key: String) -> String { L10n.string(key, lang) }
        switch row.outcome {
        case .success?: return t("queue.status.done")
        case .failure?: return t("queue.status.failed")
        case .warning?: return t("queue.status.skipped")
        case nil:
            guard let progress = row.progress else { return t("queue.status.running") }
            return String(format: t("console.builds.percent"), Int((ConsoleValueBar.clamped(progress) * 100).rounded()))
        }
    }
    private var ringColor: Color {
        switch row.outcome {
        case .failure?: return DS.Color.statusError
        case .warning?: return DS.Color.statusWarning
        case .success?: return DS.Color.statusSuccess
        case nil: return DS.Color.accent
        }
    }
    private var fraction: Double { row.outcome != nil ? 1 : ConsoleValueBar.clamped(row.progress ?? 0) }

    var body: some View {
        let waiting = Self.waiting(builds, besides: row)
        Button(action: open) {
            HStack(spacing: DS.Console.Space.s) {
                ZStack {
                    Circle().stroke(DS.Color.separator, lineWidth: 2.5)
                    Circle().trim(from: 0, to: fraction).stroke(ringColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
                    Group {
                        if let image = row.icon ?? row.artwork { Image(nsImage: image).resizable().scaledToFill() }
                        else { Image(systemName: "hammer.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.symbolDefault) }
                    }
                    .frame(width: DS.Console.Control.buildIcon, height: DS.Console.Control.buildIcon)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip))
                }
                .frame(width: DS.Console.Control.buildIcon + 12, height: DS.Console.Control.buildIcon + 12)
                Text(Self.label(row, lang: lang)).font(DS.Console.Font.callout).foregroundStyle(DS.Color.textSecondary).monospacedDigit().lineLimit(1)
                if waiting > 0 {
                    Text(String(format: t("console.builds.more"), waiting)).font(DS.Console.Font.footnote).foregroundStyle(DS.Color.textSecondary).monospacedDigit()
                }
            }
            .padding(.leading, DS.Console.Space.xxs + 2).padding(.trailing, DS.Console.Space.l)
            .frame(height: DS.Console.Control.topBar)
            .fixedSize()
            .modifier(ConsoleTopSurface(shape: Capsule(), focused: focused))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t("console.builds") + ", " + row.name)
        .accessibilityValue(Self.label(row, lang: lang))
        .animation(reduceMotion ? nil : .easeOut(duration: DS.Motion.standard), value: fraction)
    }
}
