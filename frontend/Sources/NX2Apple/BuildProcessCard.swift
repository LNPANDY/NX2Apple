import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// Active work only. Completion and error recovery retain the release presentation.
struct BuildProcessCard: View {
    @ObservedObject var build: BuildStore
    let availableHeight: CGFloat
    let logOpen: Bool
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var pad: PadFocus

    private var compact: Bool { logOpen || availableHeight < CGFloat(max(1, build.stages.count)) * 60 + 150 + (build.staleShadersMessageKey == nil ? 0 : 100) }
    private var stages: [Stage] {
        let rows = build.stages.isEmpty ? [Stage(id: -1, name: loc.t("library.preparing"))] : build.stages
        return compact ? Array((rows.last { $0.state == .running } ?? rows.last { $0.state != .pending } ?? rows.first).map { [$0] } ?? []) : rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if logOpen {
                CardGroup(loc.t("section.log")) {
                    BuildLogView(log: build.log, placeholder: loc.t("log.placeholder"), height: max(80, min(220, availableHeight - 340))).padding(14)
                }
            }
            HStack {
                Text(loc.t("section.progress")).font(.manrope(30, .bold))
                Spacer()
                Button(role: .destructive) { build.stop() } label: { Text(loc.t(build.stopping ? "library.stopping" : "build.stop")) }
                    .buttonStyle(LauncherSecondaryButtonStyle(accent: LauncherPalette.danger)).disabled(build.stopping)
                    .keyboardShortcut(pad.scope == "main" ? KeyboardShortcut(.return, modifiers: .command) : nil)
                    .padTarget("set.build.action", scope: "main", enabled: !build.stopping) { if !build.stopping { build.stop() } }
            }
            VStack(alignment: .leading, spacing: 16) {
                if let key = build.staleShadersMessageKey {
                    Text(loc.t("msg.shadersStale.title")).font(DS.Font.bodyStrong)
                    Text(loc.t(key)).font(DS.Font.body).foregroundStyle(DS.Color.textSecondary)
                }
                if !logOpen {
                    HStack {
                        if let position = build.currentStagePosition {
                            Text(String(format: loc.t("prog.stageBadge"), position.current, position.total))
                        }
                        Text(loc.t("prog.overallTitle")).foregroundStyle(.secondary)
                        Spacer()
                        if let overall = build.overallProgress { Text("\(Int(min(max(overall, 0), 1) * 100))%").monospacedDigit() }
                    }.font(DS.Font.callout)
                }
                BuildProcessRows(stages: stages)
                    .frame(minHeight: compact ? 44 : CGFloat(max(1, build.stages.count)) * 60 - 16, alignment: .top)
                if build.stages.contains(where: { $0.state == .running && $0.isScanningLastShaderFiles }) {
                    Text(loc.t("prog.lastShaderFiles")).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                }
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(LauncherPalette.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LauncherPalette.cardBorder))
        }
        // Balance the 176pt hero above when centering progress in the window.
        .padding(.bottom, logOpen ? 0 : min(176, max(0, availableHeight - CGFloat(stages.count) * 60 - 150)))
        .frame(maxWidth: .infinity, minHeight: max(0, availableHeight - 64), alignment: .center)
    }
}

struct BuildProcessRows: View {
    let stages: [Stage]
    @EnvironmentObject private var loc: Localizer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 16) {
            ForEach(stages) { stage in
                HStack(spacing: 12) {
                    Group {
                        switch stage.state {
                        case .running: ProgressView().controlSize(.small).accessibilityLabel(stage.displayName(loc.t))
                        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(LauncherPalette.ready)
                        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(LauncherPalette.danger)
                        case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
                        }
                    }.font(.system(size: 18)).frame(width: 20, height: 20)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: stage.state)
                    Text(stage.displayName(loc.t)).font(.manrope(14)).lineLimit(1)
                        .opacity(stage.state == .done ? 0.5 : stage.state == .pending ? 0.65 : 1)
                    Spacer(minLength: 8)
                    TimelineView(.periodic(from: Date(), by: 1)) { context in
                        Text(stage.state == .running ? stage.clock(at: context.date, left: loc.t("prog.etaEstimate")) : "")
                            .font(DS.Font.callout).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    }.frame(width: 100, alignment: .trailing)
                    Text(stage.state == .running ? stage.percent.map { "\(Int($0))%" } ?? "" : "")
                        .font(DS.Font.body).monospacedDigit().frame(width: 44, alignment: .trailing)
                }.frame(height: 44)
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
        VStack(alignment: .leading, spacing: 20) {
            Text(loc.t("section.progress")).font(.manrope(26, .bold))
            ScrollViewReader { proxy in
                ScrollView {
                    BuildProcessRows(stages: build.stages.isEmpty ? [Stage(id: -1, name: loc.t("library.preparing"))] : build.stages).padding(16)
                }
                .padTarget("build.steps.rows", scope: "build.steps", radius: 10, vertical: { direction in
                    let rows = build.stages
                    guard !rows.isEmpty else { return false }
                    rowIndex = min(max(0, rowIndex + direction), rows.count - 1)
                    proxy.scrollTo(rows[rowIndex].id, anchor: .center)
                    return true
                })
            }
            HStack { Spacer(); Button(loc.t("free.done"), action: close)
                .buttonStyle(LauncherSecondaryButtonStyle()).keyboardShortcut(.defaultAction)
                .padTarget("build.steps.cancel", scope: "build.steps", activate: close) }
        }.padding(28).frame(width: 600, height: 440)
            .padScope("build.steps", pad)
            .onAppear { pad.scope = "build.steps"; if pad.visible { pad.focused = "build.steps.cancel" } }
            .onExitCommand(perform: close)
    }
}
