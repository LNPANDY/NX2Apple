import SwiftUI
import NXCore
import NXLauncher

/// Before the shared app's game data goes over USB or Wi-Fi: how much, over which connection, and what to do about it. A cable
/// gets one short note. Wi-Fi gets an estimate with Continue and a way to wait for a cable (the copy then starts by itself when the
/// device shows up wired). While it waits, the card says so and offers to stop.
struct ShellCopyCard: View {
    @ObservedObject var m: BuildModel

    var body: some View {
        if let plan = m.shellCopy {
            card {
                Text(m.t("shell.copyTitle")).font(.manrope(14, .semibold))
                Text(plan.sizeText).font(.manrope(13)).foregroundStyle(.secondary)
                Text(plan.connectionText).font(.manrope(13)).fixedSize(horizontal: false, vertical: true)
                Text(m.t("shell.copyExternalNote")).font(.manrope(12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 1)
                HStack(spacing: 10) {
                    Button(m.t("shell.copyStart")) { m.answerShellCopy(.copy) }
                    if plan.canWaitForCable { Button(m.t("shell.copyWaitCable")) { m.answerShellCopy(.waitForCable) } }
                    Button(m.t("shell.copySkip")) { m.answerShellCopy(.skip) }
                }
                .buttonStyle(LauncherSecondaryButtonStyle()).padding(.top, 2)
            }
        } else if m.shellWaiting {
            card {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(format: m.t("shell.copyWaiting"), m.deviceName(m.installDevice))).font(.manrope(13))
                }
                Button(m.t("shell.copyStopWaiting")) { m.cancelShellWait() }
                    .buttonStyle(LauncherSecondaryButtonStyle()).padding(.top, 2)
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LauncherPalette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.06)))
    }
}
