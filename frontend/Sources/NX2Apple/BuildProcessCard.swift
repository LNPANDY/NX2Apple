import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// The running build's progress section (#1458): one prominent bar with the percent, then the stage checklist. With one stage
/// the bar carries the stage's name and there is no second row. Sits directly under the compact header.
struct BuildProcessCard: View {
    @ObservedObject var build: BuildStore
    var availableHeight: CGFloat = 0
    let logOpen: Bool
    @EnvironmentObject private var loc: Localizer

    private var stages: [Stage] { build.stages.isEmpty ? [Stage(id: -1, name: loc.t("library.preparing"))] : build.stages }
    private var single: Bool { stages.count == 1 }
    private var current: Stage? { stages.last { $0.state == .running } ?? stages.last { $0.state != .pending } ?? stages.first }
    private var fraction: Double? {
        if single { return current?.percent.map { min(max($0 / 100, 0), 1) } ?? build.overallProgress }
        return build.overallProgress.map { min(max($0, 0), 1) }
    }

    var body: some View {
        CardGroup(loc.t("section.progress")) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                if let key = build.staleShadersMessageKey {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text(loc.t("msg.shadersStale.title")).font(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary)
                        Text(loc.t(key)).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                    }
                }
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    HStack {
                        Text(single ? (current?.displayName(loc.t) ?? "") : loc.t("prog.overallTitle"))
                            .font(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                        Spacer(minLength: DS.Space.xs)
                        if let fraction { Text("\(Int(fraction * 100))%").font(DS.Font.bodyStrong).monospacedDigit().foregroundStyle(DS.Color.textPrimary) }
                    }
                    LauncherProgressBar(value: fraction, height: 8, tint: DS.Color.textPrimary)
                }
                .accessibilityElement(children: .combine)
                if !single { BuildProcessRows(stages: stages) }
                if build.stages.contains(where: { $0.state == .running && $0.isScanningLastShaderFiles }) {
                    Text(loc.t("prog.lastShaderFiles")).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                }
            }
            .padding(DS.Space.m).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The games waiting after the running one: icon, name, platform, "Waiting", and a "…" menu to take one out of the queue.
struct BuildUpNextSection: View {
    @ObservedObject var queue: BuildQueueStore
    let artwork: (QueueEntry) -> NSImage?
    @EnvironmentObject private var loc: Localizer

    var body: some View {
        let waiting = queue.games.filter { $0.waiting && !$0.running }
        if !waiting.isEmpty {
            CardGroup(loc.t("queue.upNext")) {
                VStack(spacing: 0) {
                    ForEach(Array(waiting.enumerated()), id: \.element.id) { index, game in
                        if index > 0 { CardDivider() }
                        HStack(spacing: DS.Space.s) {
                            Group {
                                if let image = artwork(game.entries[0]) { Image(nsImage: image).resizable().scaledToFill() }
                                else { Image(systemName: "gamecontroller.fill").foregroundStyle(DS.Color.symbolDefault).frame(maxWidth: .infinity, maxHeight: .infinity).background(DS.Color.surfaceRaised) }
                            }.frame(width: DS.Control.thumbnail, height: DS.Control.thumbnail).clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip)).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(game.name).font(DS.Font.body).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                                Text(game.entries.map { BuildHeaderLine.platform($0.target, loc.t) }.joined(separator: " · "))
                                    .font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                            }
                            Spacer(minLength: DS.Space.xs)
                            Text(loc.t("onboarding.queued")).font(DS.Font.callout).foregroundStyle(DS.Color.textTertiary)
                            DSOverflowMenu(label: String(format: loc.t("queue.removeNamed"), game.name),
                                           options: [("remove", loc.t("queue.remove"))], padID: "set.build.upnext." + game.titleID) { _ in
                                for entry in game.entries where entry.status == .queued { queue.remove(entry.id) }
                            }
                        }
                        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
                        .accessibilityElement(children: .contain)
                    }
                }
            }
        }
    }
}

/// The log as a closed disclosure row at the end of a build page ("Show log"), opening to the log view.
struct BuildLogDisclosure: View {
    @ObservedObject var build: BuildStore
    @Binding var isOpen: Bool
    @EnvironmentObject private var loc: Localizer

    var body: some View {
        CardGroup("") {
            VStack(alignment: .leading, spacing: 0) {
                Button { isOpen.toggle() } label: {
                    HStack(spacing: DS.Space.s) {
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Color.symbolDefault)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                        Text(loc.t(isOpen ? "log.hide" : "log.show")).font(DS.Font.body).foregroundStyle(DS.Color.textPrimary)
                        Spacer()
                    }.contentShape(Rectangle()).padding(.horizontal, DS.Space.m).frame(height: 44)
                }
                .buttonStyle(.plain)
                .padTarget("set.build.log", scope: "main", activate: { isOpen.toggle() })
                .accessibilityValue(loc.t(isOpen ? "log.hide" : "log.show"))
                if isOpen {
                    CardDivider()
                    BuildLogView(log: build.log, placeholder: loc.t("log.placeholder"), height: 220).padding(DS.Space.s)
                }
            }
        }
    }
}

struct BuildProcessRows: View {
    let stages: [Stage]
    @EnvironmentObject private var loc: Localizer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 0) {
            ForEach(stages) { stage in
                HStack(spacing: DS.Space.s) {
                    Group {
                        switch stage.state {
                        case .running: ProgressView().controlSize(.small).accessibilityLabel(stage.displayName(loc.t))
                        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Color.statusSuccess)
                        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(DS.Color.statusError)
                        case .pending: Image(systemName: "circle").foregroundStyle(DS.Color.textTertiary)
                        }
                    }.font(.system(size: 15)).frame(width: DS.Control.leadingSlot, height: DS.Control.leadingSlot)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: stage.state)
                    Text(stage.displayName(loc.t)).font(DS.Font.body).lineLimit(1)
                        .foregroundStyle(stage.state == .pending ? DS.Color.textTertiary : stage.state == .done ? DS.Color.textSecondary : DS.Color.textPrimary)
                    Spacer(minLength: DS.Space.xs)
                    TimelineView(.periodic(from: Date(), by: 1)) { context in
                        Text(stage.state == .running ? stage.clock(at: context.date, left: loc.t("prog.etaEstimate")) : "")
                            .font(DS.Font.callout).monospacedDigit().foregroundStyle(DS.Color.textSecondary).lineLimit(1)
                    }
                    Text(stage.state == .running ? stage.percent.map { "\(Int($0))%" } ?? "" : "")
                        .font(DS.Font.body).monospacedDigit().foregroundStyle(DS.Color.textPrimary).frame(width: 44, alignment: .trailing)
                }.frame(height: 36)
                    .id(stage.id)
                    .help([stage.displayName(loc.t), stage.detail].filter { !$0.isEmpty }.joined(separator: "\n"))
                    .accessibilityElement(children: .combine)
            }
        }
    }
}
struct BuildProcessStepsSheet: View {
    @ObservedObject var build: BuildStore
    let close: () -> Void
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var pad: PadFocus
    @State private var rowIndex = 0
    var body: some View {
        VStack(alignment: .leading, spacing: DSSheetInsets.gap) {
            DSSheetHeader(title: loc.t("section.progress"))
            ScrollViewReader { proxy in
                ScrollView {
                    DSCard { BuildProcessRows(stages: build.stages.isEmpty ? [Stage(id: -1, name: loc.t("library.preparing"))] : build.stages) }
                }
                .padTarget("build.steps.rows", scope: "build.steps", radius: 10, vertical: { direction in
                    let rows = build.stages
                    guard !rows.isEmpty else { return false }
                    rowIndex = min(max(0, rowIndex + direction), rows.count - 1)
                    proxy.scrollTo(rows[rowIndex].id, anchor: .center)
                    return true
                })
            }
            DSSheetButtonRow {
                DSSheetPrimaryButton(loc.t("free.done"), action: close)
                    .padTarget("build.steps.cancel", scope: "build.steps", focusColor: DS.Color.accentOn, activate: close)
            }
            .padding(.top, DSSheetInsets.buttons - DSSheetInsets.gap)
        }
        .padding(.horizontal, DSSheetInsets.horizontal).padding(.vertical, DSSheetInsets.vertical)
        .frame(width: 600, height: 440)
            .dsSheetSurface()
            .padScope("build.steps", pad)
            .onAppear { pad.scope = "build.steps"; if pad.visible { pad.focused = "build.steps.cancel" } }
            .onExitCommand(perform: close)
    }
}
