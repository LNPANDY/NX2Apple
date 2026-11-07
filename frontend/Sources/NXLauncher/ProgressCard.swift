import SwiftUI
import NXCore
import NXModel

/// The script's own stages once a build has run. Observes the build store.
package struct ProgressCard: View {
    @ObservedObject var build: BuildStore
    @EnvironmentObject var loc: Localizer

    package init(build: BuildStore) { self.build = build }

    package var body: some View {
        if build.running || !build.stages.isEmpty {
            CardGroup(loc.t("section.progress")) {
                if let message = build.staleShadersMessageKey {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(loc.t("msg.shadersStale.title")).font(.manrope(14, .semibold))
                            Text(loc.t(message)).font(.manrope(13)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    CardDivider()
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
                                Text([s.detail, s.clock(at: context.date, left: loc.t("prog.eta"))].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.manrope(12)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                            }
                        } else if !s.detail.isEmpty { Text(s.detail).font(.manrope(12)).foregroundStyle(.secondary).lineLimit(1) }
                        if s.state == .running {
                            LauncherProgressBar(value: s.percent.map { $0 / 100 }, height: 6).frame(width: 180)
                            Text(s.percent.map { "\(Int($0))%" } ?? "").font(.manrope(13, .semibold)).monospacedDigit()
                                .foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
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
