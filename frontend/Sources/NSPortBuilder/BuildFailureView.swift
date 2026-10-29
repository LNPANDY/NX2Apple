import SwiftUI

/// Under the build button after a stop the script's early checks explain: what happened in plain words, the next step, and the
/// button that does it (a dependency's own install command, or "Build anyway" for the three stops that have an override).
struct BuildFailureCard: View {
    @ObservedObject var m: BuildModel

    var body: some View {
        if let f = m.failure {
            VStack(alignment: .leading, spacing: 10) {
                Text(m.t("fail.section")).font(.manrope(15, .semibold)).foregroundStyle(.secondary).padding(.leading, 2)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(LauncherPalette.building).frame(width: 7, height: 7)
                        Text(m.failureWhat(f)).font(.manrope(14, .semibold)).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(m.t(f.kind.nextKey)).font(.manrope(13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.leading, 17)
                    buttons(f.kind).padding(.leading, 17).padding(.top, 2)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LauncherPalette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.06)))
            }
            .alert(m.t("fail.confirm.title"), isPresented: Binding(get: { m.confirmingOverride != nil }, set: { if !$0 { m.cancelBuildAnyway() } })) {
                Button(m.t("fail.confirm.go")) { m.confirmBuildAnyway() }
                Button(m.t("fail.confirm.cancel"), role: .cancel) { m.cancelBuildAnyway() }
            } message: {
                Text(m.confirmingOverride.map { m.t("fail.\($0.rawValue).risk") } ?? "")
            }
        }
    }

    @ViewBuilder private func buttons(_ kind: BuildFailureKind) -> some View {
        HStack(spacing: 10) {
            switch kind {
            case .translator:
                fix(kind, "fail.translator.button")
            case .iosSDK:
                fix(kind, "fail.iosSDK.button")
            case .cltSelected:
                if BuildModel.installedXcode() != nil { fix(kind, "fail.cltSelected.button") }
            case .keys:
                fix(kind, "fail.keys.button")
            case .severalGames, .noTitleID, .diskFull:
                fix(kind, "fail.showFolder")
            case .teamTaken, .noSigningAccount:
                if BuildModel.installedXcode() != nil { fix(kind, "fail.openXcode") }
            case .deviceTransfer:
                fix(kind, "fail.retry")
            default: EmptyView()
            }
            if kind.overrideFlag != nil {
                Button(m.t("fail.buildAnyway")) { m.requestBuildAnyway() }.disabled(m.running)
            }
        }
        .buttonStyle(LauncherSecondaryButtonStyle())
    }

    private func fix(_ kind: BuildFailureKind, _ key: String) -> some View {
        Group {
            if m.fixBusy(kind) {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(m.t("dep.installing")).font(.manrope(12)).foregroundStyle(LauncherPalette.building) }
            } else {
                Button(m.t(key)) { m.fixBuildFailure(kind) }.disabled(m.running)
            }
        }
    }
}
