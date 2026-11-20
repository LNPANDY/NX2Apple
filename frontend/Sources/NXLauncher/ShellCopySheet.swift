import SwiftUI
import NXCore
import NXModel

/// Centered modal confirmation shown after a direct-install iOS build finishes and game data needs to be copied.
/// Surfaces live physical USB link speed, duration estimate, and connection-aware guidance regardless of scroll position.
package struct ShellCopySheet: View {
    @ObservedObject var devices: DeviceStore
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject private var pad: PadFocus
    private let previewPlan: ShellCopyPlan?

    package init(devices: DeviceStore, previewPlan: ShellCopyPlan? = nil) {
        self.devices = devices
        self.previewPlan = previewPlan
    }

    package var body: some View {
        Group {
            if let plan = previewPlan ?? devices.shellCopy {
                planContent(plan)
            } else if devices.shellWaiting {
                waitingContent
            }
        }
        .background(PadKeyboardInput(focus: pad, scope: "shellCopy", back: handleCancel))
        .environment(\.padRingStyle, .hug)
        .padScope("shellCopy", pad)
        .interactiveDismissDisabled(true)
        .onAppear {
            pad.scope = "shellCopy"
            if pad.visible {
                let defaultID = devices.shellCopy != nil ? "set.build.copy.start" : "set.build.copy.stopWaiting"
                DispatchQueue.main.async { pad.show(default: defaultID) }
            }
        }
        .onChange(of: devices.shellWaiting) { waiting in
            if waiting && pad.visible {
                DispatchQueue.main.async { pad.show(default: "set.build.copy.stopWaiting") }
            }
        }
    }

    @ViewBuilder private func planContent(_ plan: ShellCopyPlan) -> some View {
        DSSheet(width: 540, title: loc.t("shell.copyTitle")) {
            HStack(spacing: DS.Space.xs) {
                Text(plan.deviceName)
                    .font(DS.Font.bodyStrong)
                    .foregroundStyle(DS.Color.textSecondary)
                linkBadge(plan.linkProfile)
            }

            VStack(alignment: .leading, spacing: DS.Space.s) {
                if let note = plan.versionNote {
                    HStack(alignment: .top, spacing: DS.Space.xs) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DS.Color.statusInfo)
                            .padding(.top, 2)
                            .accessibilityHidden(true)
                        Text(note)
                            .font(DS.Font.body)
                            .foregroundStyle(DS.Color.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text(plan.sizeText)
                    .font(DS.Font.bodyStrong)
                    .foregroundStyle(DS.Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .top, spacing: DS.Space.xs) {
                    Circle()
                        .fill(accentColor(for: plan.linkProfile))
                        .frame(width: 7, height: 7)
                        .padding(.top, 5)
                    Text(plan.connectionText)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Rectangle()
                    .fill(DS.Color.separator)
                    .frame(height: 1)

                Text(loc.t("shell.copyExternalNote"))
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DS.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Color.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.separator))
        } leading: {
            Button(loc.t("shell.copySkip")) { devices.answerCopy(.skip) }
                .buttonStyle(DSSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                .padTarget("set.build.copy.skip", scope: "shellCopy") { devices.answerCopy(.skip) }
        } buttons: {
            if plan.canWaitForCable {
                let waitTitle = loc.t(plan.waitsForHighSpeedCable ? "shell.copyWaitHighSpeed" : "shell.copyWaitCable")
                Button(waitTitle) { devices.answerCopy(.waitForCable) }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .padTarget("set.build.copy.wait", scope: "shellCopy") { devices.answerCopy(.waitForCable) }
            }

            Button {
                devices.answerCopy(.copy)
            } label: {
                Text(loc.t("shell.copyStart"))
                    .font(DS.Font.bodyStrong)
                    .lineLimit(1)
                    .padding(.horizontal, DS.Space.m)
            }
            .buttonStyle(DSPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .padTarget("set.build.copy.start", scope: "shellCopy", focusColor: DS.Color.accentOn) {
                devices.answerCopy(.copy)
            }
        }
    }

    private var waitingContent: some View {
        let message = String(
            format: loc.t(devices.shellWaitingForHighSpeed ? "shell.copyWaitingHighSpeed" : "shell.copyWaiting"),
            devices.deviceName(devices.installDevice)
        )
        return DSSheet(width: 540, title: loc.t("shell.copyTitle"), message: message) {
            HStack(spacing: DS.Space.s) {
                ProgressView()
                    .controlSize(.small)
                Text(devices.deviceName(devices.installDevice))
                    .font(DS.Font.bodyStrong)
                    .foregroundStyle(DS.Color.textPrimary)
            }
            .padding(DS.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Color.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.separator))
        } buttons: {
            Button(loc.t("shell.copyStopWaiting")) { devices.cancelWait() }
                .buttonStyle(DSSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                .padTarget("set.build.copy.stopWaiting", scope: "shellCopy") { devices.cancelWait() }
        }
    }

    private func handleCancel() {
        if devices.shellCopy != nil {
            devices.answerCopy(.skip)
        } else if devices.shellWaiting {
            devices.cancelWait()
        }
    }

    @ViewBuilder private func linkBadge(_ profile: DeviceLinkProfile) -> some View {
        let color = accentColor(for: profile)
        Text(badgeText(for: profile))
            .font(DS.Font.footnote)
            .foregroundStyle(color)
            .padding(.horizontal, DS.Space.xs)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: DSPill())
            .overlay(DSPill().strokeBorder(color.opacity(0.35)))
    }

    private func badgeText(for profile: DeviceLinkProfile) -> String {
        switch profile {
        case .highSpeedUSB(let bps):
            return String(format: loc.t("shell.copyBadgeHighSpeed"), USBLinkSpeed.formatRate(bps))
        case .usb2(let bps):
            return String(format: loc.t("shell.copyBadgeUSB2"), USBLinkSpeed.formatRate(bps))
        case .wifi:
            return loc.t("shell.copyBadgeWifi")
        case .wiredUnknown:
            return loc.t("shell.copyBadgeWired")
        case .disconnected:
            return loc.t("shell.copyBadgeOffline")
        }
    }

    private func accentColor(for profile: DeviceLinkProfile) -> Color {
        switch profile {
        case .highSpeedUSB, .wiredUnknown: return DS.Color.statusReady
        case .usb2: return DS.Color.statusWarning
        case .wifi: return DS.Color.statusInfo
        case .disconnected: return DS.Color.textSecondary
        }
    }
}

package extension View {
    /// Attaches the centered modal game-data copy confirmation sheet to the launcher window.
    func shellCopySheetWiring(
        devices: DeviceStore,
        loc: Localizer,
        pad: PadFocus,
        scope: @escaping () -> String
    ) -> some View {
        let isPresented = Binding<Bool>(
            get: { devices.shellCopy != nil || devices.shellWaiting },
            set: { open in
                if !open {
                    if devices.shellCopy != nil { devices.answerCopy(.skip) }
                    if devices.shellWaiting { devices.cancelWait() }
                }
            }
        )
        return self
            .sheet(isPresented: isPresented, onDismiss: {
                if devices.shellCopy != nil { devices.answerCopy(.skip) }
                if devices.shellWaiting { devices.cancelWait() }
                pad.scope = scope()
            }) {
                ShellCopySheet(devices: devices)
                    .environmentObject(loc)
                    .environmentObject(pad)
            }
            .onChange(of: devices.shellCopy != nil || devices.shellWaiting) { active in
                pad.scope = active ? "shellCopy" : scope()
            }
    }
}
