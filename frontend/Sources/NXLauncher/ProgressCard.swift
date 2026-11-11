import SwiftUI
import NXCore
import NXModel

/// The script's own stages once a build has run. Observes the build store.
package struct ProgressCard: View {
    @ObservedObject var build: BuildStore
    @EnvironmentObject var loc: Localizer

    package init(build: BuildStore) { self.build = build }

    private var displayedOverall: Double? {
        if build.done, build.failure == nil {
            return 1.0
        }
        return build.overallProgress
    }

    package var body: some View {
        if build.running || !build.stages.isEmpty {
            CardGroup(loc.t("section.progress")) {
                if let message = build.staleShadersMessageKey {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "info.circle").foregroundStyle(LauncherPalette.secondaryText)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(loc.t("msg.shadersStale.title")).font(.manrope(14, .semibold))
                            Text(loc.t(message)).font(.manrope(13)).foregroundStyle(LauncherPalette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    CardDivider()
                }
                if let pos = build.currentStagePosition {
                    HStack(spacing: 12) {
                        Text(String(format: loc.t("prog.stageBadge"), pos.current, pos.total))
                            .font(.manrope(12, .bold)).monospacedDigit()
                            .foregroundStyle(build.done && build.failure == nil ? LauncherPalette.ready : LauncherPalette.cream)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(LauncherPalette.ink(0.08), in: Capsule())
                            .overlay(Capsule().strokeBorder(LauncherPalette.ink(0.14)))
                        Text(loc.t("prog.overallTitle"))
                            .font(.manrope(13.5, .semibold))
                            .foregroundStyle(LauncherPalette.secondaryText)
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        if let overall = displayedOverall {
                            LauncherProgressBar(value: overall, height: 7).frame(width: 200)
                            Text("\(Int((overall * 100).rounded(.down)))%")
                                .font(.manrope(13, .semibold)).monospacedDigit()
                                .foregroundStyle(build.done && build.failure == nil ? LauncherPalette.ready : LauncherPalette.cream)
                                .frame(width: 42, alignment: .trailing)
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    if !build.stages.isEmpty || build.running {
                        CardDivider()
                    }
                }
                ForEach(Array(build.stages.enumerated()), id: \.element.id) { index, s in
                    if index > 0 { CardDivider() }
                    HStack(spacing: 12) {
                        if s.state == .running { ProgressView().controlSize(.small).frame(width: 14) }
                        else { Circle().fill(s.state.color).frame(width: 7, height: 7).frame(width: 14) }
                        Text(s.name).font(.manrope(14)).lineLimit(1)
                        Spacer(minLength: 12)
                        if s.state == .running {
                            TimelineView(.periodic(from: Date(), by: 1)) { context in
                                Text([s.detail, s.clock(at: context.date, left: loc.t("prog.etaEstimate"))].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.manrope(12)).monospacedDigit().foregroundStyle(LauncherPalette.secondaryText).lineLimit(1)
                            }
                        } else if !s.detail.isEmpty { Text(s.detail).font(.manrope(12)).foregroundStyle(LauncherPalette.secondaryText).lineLimit(1) }
                        if s.state == .running {
                            LauncherProgressBar(value: s.percent.map { $0 / 100 }, height: 6).frame(width: 180)
                            Text(s.percent.map { "\(Int($0))%" } ?? "").font(.manrope(13, .semibold)).monospacedDigit()
                                .foregroundStyle(LauncherPalette.secondaryText).frame(width: 40, alignment: .trailing)
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    if s.state == .running && s.isScanningLastShaderFiles {
                        Text(loc.t("prog.lastShaderFiles")).font(.manrope(13)).fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 18).padding(.bottom, 12)
                    }
                }
                if build.stages.isEmpty && build.running {
                    CardRow(loc.t("library.preparing")) { ProgressView().controlSize(.small) }
                }
            }
        }
    }
}
