import SwiftUI
import NXCore
import NXModel

/// Top card on the Builds page: switches between the built-in `nxnative` engine and optional downloadable engines
/// (`MacNativeGames`, `S2Arm`). Uninstalled engines offer a one-click Download button and unlock switching once extracted.
package struct EngineSwitcherCard: View {
    @ObservedObject var build: BuildStore
    @EnvironmentObject var loc: Localizer

    package init(build: BuildStore) {
        self.build = build
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loc.t("engine.title"))
                .font(.manrope(15, .semibold))
                .foregroundStyle(LauncherPalette.secondaryText)
                .padding(.leading, 2)
            HStack(alignment: .top, spacing: 12) {
                nxnativeCard
                if MacNativeGamesBuilder.featureEnabled {
                    externalEngineCard(
                        .macNativeGames,
                        title: "MacNativeGames",
                        noteKey: "upstream.mngCardNote"
                    )
                }
                if S2ArmBuilder.featureEnabled {
                    externalEngineCard(
                        .s2arm,
                        title: "S2Arm",
                        noteKey: "upstream.s2armCardNote"
                    )
                }
            }
        }
    }

    private var nxnativeCard: some View {
        let selected = build.buildUpstream == .nxnative
        return Button {
            build.selectUpstream(.nxnative)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 8) {
                    Text("nxnative")
                        .font(.manrope(15.5, .semibold))
                        .foregroundStyle(LauncherPalette.text)
                    Text(loc.t("upstream.builtinBadge"))
                        .font(.manrope(11, .semibold))
                        .foregroundStyle(selected ? LauncherPalette.accent : LauncherPalette.secondaryText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(LauncherPalette.secondaryFill, in: Capsule())
                    Spacer(minLength: 4)
                    radioCircle(selected: selected)
                }
                Text(loc.t("upstream.nxnativeCardNote"))
                    .font(.manrope(12.5))
                    .foregroundStyle(LauncherPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(loc.t(selected ? "upstream.activeBadge" : "upstream.readySwitch"))
                    .font(.manrope(11.5, .medium))
                    .foregroundStyle(selected ? LauncherPalette.ready : LauncherPalette.secondaryText)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(selected ? LauncherPalette.selectedFill : LauncherPalette.selectableFill, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(selected ? LauncherPalette.selectedBorder : LauncherPalette.selectableBorder, lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(build.running)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func externalEngineCard(_ kind: EngineUpstreamKind, title: String, noteKey: String) -> some View {
        let state = build.upstreamState(kind)
        let selected = build.buildUpstream == kind
        switch state {
        case .builtIn, .installed:
            Button {
                build.selectUpstream(kind)
            } label: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 8) {
                        Text(title)
                            .font(.manrope(15.5, .semibold))
                            .foregroundStyle(LauncherPalette.text)
                        Spacer(minLength: 4)
                        radioCircle(selected: selected)
                    }
                    Text(loc.t(noteKey))
                        .font(.manrope(12.5))
                        .foregroundStyle(LauncherPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(loc.t(selected ? "upstream.activeBadge" : "upstream.readySwitch"))
                        .font(.manrope(11.5, .medium))
                        .foregroundStyle(selected ? LauncherPalette.ready : LauncherPalette.secondaryText)
                }
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
                .background(selected ? LauncherPalette.selectedFill : LauncherPalette.selectableFill, in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(selected ? LauncherPalette.selectedBorder : LauncherPalette.selectableBorder, lineWidth: selected ? 1.5 : 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(build.running)
            .accessibilityAddTraits(selected ? .isSelected : [])

        case .downloading(let fraction, let progressText):
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    Text(title)
                        .font(.manrope(15.5, .semibold))
                        .foregroundStyle(LauncherPalette.text)
                    Spacer(minLength: 4)
                    if fraction == nil {
                        ProgressView().controlSize(.small)
                    }
                }
                if let fraction {
                    ProgressView(value: fraction)
                }
                let line = progressText.isEmpty
                    ? loc.t("upstream.downloading")
                    : String(format: loc.t("upstream.downloadingProgress"), progressText)
                Text(line)
                    .font(.manrope(12))
                    .foregroundStyle(LauncherPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(LauncherPalette.selectableFill, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LauncherPalette.selectableBorder, lineWidth: 1))

        case .extracting:
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    Text(title)
                        .font(.manrope(15.5, .semibold))
                        .foregroundStyle(LauncherPalette.text)
                    Spacer(minLength: 4)
                    ProgressView().controlSize(.small)
                }
                Text(loc.t("upstream.extracting"))
                    .font(.manrope(12.5))
                    .foregroundStyle(LauncherPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(LauncherPalette.selectableFill, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LauncherPalette.selectableBorder, lineWidth: 1))

        case .notInstalled, .failed:
            let failureReason: UpstreamInstallState.FailureReason? = {
                if case .failed(let r) = state { return r }
                return nil
            }()
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    Text(title)
                        .font(.manrope(15.5, .semibold))
                        .foregroundStyle(LauncherPalette.text)
                    Spacer(minLength: 4)
                }
                if let failureReason {
                    Text(loc.t(failureReason == .download ? "upstream.downloadFailed" : "upstream.extractFailed"))
                        .font(.manrope(12))
                        .foregroundStyle(LauncherPalette.building)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(loc.t(noteKey))
                        .font(.manrope(12.5))
                        .foregroundStyle(LauncherPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(loc.t(failureReason != nil ? "fail.retry" : "upstream.download")) {
                    build.downloadUpstream(kind)
                }
                .buttonStyle(LauncherSecondaryButtonStyle())
                .disabled(build.running)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(LauncherPalette.selectableFill, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LauncherPalette.selectableBorder, lineWidth: 1))
        }
    }

    private func radioCircle(selected: Bool) -> some View {
        Circle()
            .strokeBorder(selected ? LauncherPalette.radioOn : LauncherPalette.radioOff, lineWidth: selected ? 5 : 1.5)
            .frame(width: 18, height: 18)
    }
}
