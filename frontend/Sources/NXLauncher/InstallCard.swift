import SwiftUI
import NXCore
import NXModel

/// Where an iPhone build goes: exported as an IPA (as before), or signed and installed on a paired device. Shown for the iPhone
/// target only. Observes the device store, and the build store for the target and whether a build runs.
package struct InstallCard: View {
    @ObservedObject var devices: DeviceStore
    @ObservedObject var build: BuildStore
    @EnvironmentObject var loc: Localizer

    package init(devices: DeviceStore, build: BuildStore) {
        self.devices = devices
        self.build = build
    }

    package var body: some View {
        if build.target != BuildTarget.mac { card.disabled(build.running) }
    }

    private var card: some View {
        let options = [(value: "", label: loc.t("dev.none"))] + devices.devices.map { d in
            (value: d.id, label: d.name + (d.reachable ? "" : " (" + loc.t("dev.notConnected") + ")"))
        }
        let teams = devices.teams.map { (value: $0.id, label: $0.label(personalTeam: loc.t("dev.personalTeam"))) }
        let needsCertificate = devices.teams.first { $0.id == devices.signingTeam }.map { !$0.hasCertificate } ?? false
        return CardGroup(loc.t("dev.section"), footnote: devices.installDevice.isEmpty ? "" : (needsCertificate ? loc.t("dev.teamNoCert") + " " : "") + loc.t("dev.note")) {
            CardRow(loc.t("dev.target"), detail: devices.checked && devices.devices.isEmpty ? loc.t("dev.noDevices") : "") {
                if !devices.checked { ProgressView().controlSize(.small) }
                Button(loc.t("dev.refresh")) { _ = devices.refresh() }.buttonStyle(.plain).font(.manrope(13)).foregroundStyle(.secondary)
                LauncherDropdown(options: options, selection: devices.installDevice, label: loc.t("dev.target")) { devices.installDevice = $0 }
            }
            if !devices.installDevice.isEmpty {
                CardDivider()
                if teams.isEmpty {
                    CardRow(loc.t("dev.team"), detail: loc.t("dev.noTeam"), dot: LauncherPalette.building) { EmptyView() }
                } else {
                    CardRow(loc.t("dev.team")) {
                        LauncherDropdown(options: teams, selection: devices.signingTeam, label: loc.t("dev.team")) { devices.signingTeam = $0 }
                    }
                }
            }
        }
        .onAppear { if !devices.checked { _ = devices.refresh() } }
    }
}
