import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// Before the shared app's game data goes over USB or Wi-Fi: how much, over which connection, and what to do about it. A cable
/// gets one short note. Wi-Fi gets an estimate with Continue and a way to wait for a cable (the copy then starts by itself when the
/// device shows up wired). While it waits, the card says so and offers to stop.
struct ShellCopyCard: View {
    @ObservedObject var devices: DeviceStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        if let plan = devices.shellCopy {
            card {
                Text(loc.t("shell.copyTitle")).font(.manrope(14, .semibold))
                Text(plan.sizeText).font(.manrope(13)).foregroundStyle(.secondary)
                Text(plan.connectionText).font(.manrope(13)).fixedSize(horizontal: false, vertical: true)
                Text(loc.t("shell.copyExternalNote")).font(.manrope(12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 1)
                HStack(spacing: 10) {
                    Button(loc.t("shell.copyStart")) { devices.answerCopy(.copy) }
                    if plan.canWaitForCable { Button(loc.t("shell.copyWaitCable")) { devices.answerCopy(.waitForCable) } }
                    Button(loc.t("shell.copySkip")) { devices.answerCopy(.skip) }
                }
                .buttonStyle(LauncherSecondaryButtonStyle()).padding(.top, 2)
            }
        } else if devices.shellWaiting {
            card {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(format: loc.t("shell.copyWaiting"), devices.deviceName(devices.installDevice))).font(.manrope(13))
                }
                Button(loc.t("shell.copyStopWaiting")) { devices.cancelWait() }
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
