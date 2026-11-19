import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// Active work only. Completion and error recovery retain the release presentation.
struct BuildProcessCard: View {
    @ObservedObject var build: BuildStore
    var availableHeight: CGFloat = 0
    var logOpen: Bool = false
    var onShowSteps: (() -> Void)? = nil
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var pad: PadFocus
    @Environment(\.launcherSectionTitleFont) private var titleFont

    private var stages: [Stage] {
        build.stages.isEmpty ? [Stage(id: -1, name: loc.t("library.preparing"))] : build.stages
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(loc.t("section.progress")).font(titleFont)
                    .foregroundStyle(LauncherPalette.secondaryText).padding(.leading, 2)
                Spacer(minLength: 8)
                if let onShowSteps, build.stages.count > 1 {
                    Button(loc.t("prog.showAllSteps"), action: onShowSteps)
                        .buttonStyle(LauncherSecondaryButtonStyle()).fixedSize()
                        .padTarget("set.build.steps", scope: "main", activate: onShowSteps)
                }
                Button(role: .destructive) { build.stop() } label: { Text(loc.t(build.stopping ? "library.stopping" : "build.stop")) }
                    .buttonStyle(LauncherSecondaryButtonStyle(accent: LauncherPalette.danger)).fixedSize().disabled(build.stopping)
                    .keyboardShortcut(pad.scope == "main" ? KeyboardShortcut(.return, modifiers: .command) : nil)
                    .padTarget("set.build.action", scope: "main", enabled: !build.stopping) { if !build.stopping { build.stop() } }
            }
            VStack(alignment: .leading, spacing: 16) {
                if let key = build.staleShadersMessageKey {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(loc.t("msg.shadersStale.title")).font(.manrope(14, .semibold))
                        Text(loc.t(key)).font(.manrope(13)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 10) {
                    if let position = build.currentStagePosition {
                        Text(String(format: loc.t("prog.stageBadge"), position.current, position.total))
                            .font(.manrope(12, .semibold)).monospacedDigit()
                    }
                    Text(loc.t("prog.overallTitle")).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if let overall = build.overallProgress {
                        LauncherProgressBar(value: min(max(overall, 0), 1), height: 6).frame(width: 140)
                        Text("\(Int(min(max(overall, 0), 1) * 100))%")
                            .font(.manrope(12.5, .semibold)).monospacedDigit().frame(minWidth: 38, alignment: .trailing)
                    }
                }.font(.manrope(12))
                BuildProcessRows(stages: stages)
                if build.stages.contains(where: { $0.state == .running && $0.isScanningLastShaderFiles }) {
                    Text(loc.t("prog.lastShaderFiles")).font(.manrope(12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(LauncherPalette.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LauncherPalette.cardBorder))
        }
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
                    Text(stage.displayName(loc.t)).font(.manrope(14)).lineLimit(1).truncationMode(.tail)
                        .opacity(stage.state == .done ? 0.5 : stage.state == .pending ? 0.65 : 1)
                    Spacer(minLength: 8)
                    TimelineView(.periodic(from: Date(), by: 1)) { context in
                        let clock = stage.state == .running ? stage.clock(at: context.date, left: loc.t("prog.etaEstimate")) : ""
                        let detail = stage.state == .running ? stage.detail : ""
                        let trailingText = [detail, clock].filter { !$0.isEmpty }.joined(separator: " · ")
                        Text(trailingText)
                            .font(.manrope(12)).monospacedDigit().foregroundStyle(.secondary)
                            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    }.layoutPriority(1)
                    if stage.state == .running, let pct = stage.percent {
                        Text("\(Int(pct))%")
                            .font(.manrope(13, .semibold)).monospacedDigit()
                            .frame(minWidth: 40, alignment: .trailing)
                            .fixedSize(horizontal: true, vertical: false)
                    }
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
