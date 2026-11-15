import SwiftUI
import NXCore
import NXModel

/// What a finished build leaves: the Mac app in Finder, or the app on the device and where its game data is.
/// Observes the build store, and the device store for the device's name.
package struct OutcomeCard: View {
    @ObservedObject var build: BuildStore
    @ObservedObject var devices: DeviceStore
    let onViewGame: () -> Void
    @EnvironmentObject var loc: Localizer
    @State private var trustGuideOpen: Bool

    package init(
        build: BuildStore,
        devices: DeviceStore,
        onViewGame: @escaping () -> Void,
        trustGuideInitiallyOpen: Bool = false
    ) {
        self.build = build
        self.devices = devices
        self.onViewGame = onViewGame
        _trustGuideOpen = State(initialValue: trustGuideInitiallyOpen)
    }

    package var body: some View {
        if build.done && build.runningTarget == BuildTarget.mac {
            CardGroup(loc.t("section.done")) {
                CardRow(loc.t("library.ready"), detail: build.shortPath(build.macAppPath), dot: LauncherPalette.ready, help: build.macAppPath) {
                    Button(loc.t("install.reveal")) { revealInFinder(build.macAppPath) }
                    Button(loc.t("build.showLibrary"), action: onViewGame)
                }
            }
        }
        if build.done && build.runningTarget != BuildTarget.mac && !build.installedOn.isEmpty {
            CardGroup(String(format: loc.t("dev.installed"), devices.deviceName(build.installedOn))) {
                CardRow(loc.t("dev.installedNote"), dot: LauncherPalette.ready) {
                    Button(String(format: loc.t("dev.open"), devices.deviceName(build.installedOn))) {
                        build.openOnDevice(udid: build.installedOn, app: build.installedAppPath) { error in
                            if let error { build.doneNote = error }
                        }
                    }
                }
                if !build.archivePath.isEmpty {
                    CardDivider()
                    CardRow(loc.t("dev.gameData"), detail: build.shortPath(build.archivePath), dot: LauncherPalette.ready, help: build.archivePath) {
                        Button(loc.t("install.reveal")) { revealInFinder(build.archivePath) }
                    }
                }
                CardDivider()
                CardDisclosure(
                    loc.t("dev.firstInstallGuide.title"),
                    detail: loc.t("dev.firstInstallGuide.subtitle"),
                    isOpen: trustGuideOpen
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) { trustGuideOpen.toggle() }
                }
                if trustGuideOpen {
                    VStack(alignment: .leading, spacing: 10) {
                        guideStep(
                            index: "1",
                            title: loc.t("dev.firstInstallGuide.devModeTitle"),
                            bodyText: loc.t("dev.firstInstallGuide.devModeBody")
                        )
                        guideStep(
                            index: "2",
                            title: loc.t("dev.firstInstallGuide.trustTitle"),
                            bodyText: loc.t("dev.firstInstallGuide.trustBody")
                        )
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 2)
                    .padding(.bottom, 14)
                }
            }
        }
    }

    private func guideStep(index: String, title: String, bodyText: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(index)
                .font(.manrope(11.5, .bold)).monospacedDigit()
                .foregroundStyle(LauncherPalette.cream)
                .frame(width: 20, height: 20)
                .background(LauncherPalette.ink(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.manrope(13, .semibold))
                Text(bodyText)
                    .font(.manrope(12.5))
                    .foregroundStyle(LauncherPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
