import SwiftUI
import NXCore
import NXModel

package struct ProgressStageSample: Equatable {
    package enum Part: Equatable { case detail, clock }
    package let stageID: Int
    package let part: Part
    package let labelWidth: CGFloat
    package let room: CGFloat
}

package struct ProgressStageSamples: PreferenceKey {
    package static var defaultValue: [ProgressStageSample] = []
    package static func reduce(value: inout [ProgressStageSample], nextValue: () -> [ProgressStageSample]) { value += nextValue() }
}

private struct MeasuresProgressStagesKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    package var measuresProgressStages: Bool {
        get { self[MeasuresProgressStagesKey.self] }
        set { self[MeasuresProgressStagesKey.self] = newValue }
    }
}

private struct ProgressStagePartMeasure: ViewModifier {
    let stageID: Int
    let part: ProgressStageSample.Part
    let text: String
    @Environment(\.measuresProgressStages) private var measures

    @ViewBuilder func body(content: Content) -> some View {
        if measures {
            content.background(GeometryReader { box in
                Text(text).font(.manrope(12)).monospacedDigit().fixedSize().hidden()
                    .background(GeometryReader { ideal in
                        Color.clear.preference(
                            key: ProgressStageSamples.self,
                            value: [ProgressStageSample(stageID: stageID, part: part, labelWidth: ideal.size.width, room: box.size.width)]
                        )
                    })
            })
        } else {
            content
        }
    }
}

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
                        Text(s.name).font(.manrope(14)).lineLimit(1).layoutPriority(2)
                        Spacer(minLength: 12)
                        if s.state == .running {
                            TimelineView(.periodic(from: Date(), by: 1)) { context in
                                let clock = s.clock(at: context.date, left: loc.t("prog.etaEstimate"))
                                if !s.detail.isEmpty || !clock.isEmpty {
                                    let clockText = (s.detail.isEmpty ? "" : " · ") + clock
                                    HStack(spacing: 0) {
                                        if !s.detail.isEmpty {
                                            Text(s.detail).lineLimit(1).truncationMode(.middle)
                                                .modifier(ProgressStagePartMeasure(stageID: s.id, part: .detail, text: s.detail))
                                        }
                                        if !clock.isEmpty {
                                            Text(clockText).lineLimit(1).layoutPriority(1)
                                                .modifier(ProgressStagePartMeasure(stageID: s.id, part: .clock, text: clockText))
                                        }
                                    }
                                    .font(.manrope(12)).monospacedDigit().foregroundStyle(LauncherPalette.secondaryText)
                                    .accessibilityElement(children: .combine)
                                }
                            }
                        } else if !s.detail.isEmpty { Text(s.detail).font(.manrope(12)).foregroundStyle(LauncherPalette.secondaryText).lineLimit(1) }
                        if s.state == .running {
                            LauncherProgressBar(value: s.percent.map { $0 / 100 }, height: 6).frame(width: 92)
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
