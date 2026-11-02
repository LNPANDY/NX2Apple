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

    package init(build: BuildStore, devices: DeviceStore, onViewGame: @escaping () -> Void) {
        self.build = build
        self.devices = devices
        self.onViewGame = onViewGame
    }

    package var body: some View {
        if build.done && build.target == BuildTarget.mac {
            CardGroup(loc.t("section.done")) {
                CardRow(loc.t("library.ready"), detail: build.shortPath(build.macAppPath), dot: LauncherPalette.ready, help: build.macAppPath) {
                    Button(loc.t("install.reveal")) { revealInFinder(build.macAppPath) }
                    Button(loc.t("build.showLibrary"), action: onViewGame)
                }
            }
        }
        if build.done && !build.installedOn.isEmpty {
            CardGroup(String(format: loc.t("dev.installed"), devices.deviceName(build.installedOn))) {
                CardRow(loc.t("dev.installedNote"), dot: LauncherPalette.ready) {
                    Button(String(format: loc.t("dev.open"), devices.deviceName(build.installedOn))) {
                        build.openOnDevice(udid: build.installedOn, app: build.installedAppPath) { error in if let error { build.doneNote = error } }
                    }
                }
                // The game files were copied (or, after a skipped transfer, await a manual copy — a
                // fast external drive handed to the device is quicker than USB): show where they are.
                if !build.archivePath.isEmpty {
                    CardDivider()
                    CardRow(loc.t("dev.gameData"), detail: build.shortPath(build.archivePath), dot: LauncherPalette.ready, help: build.archivePath) {
                        Button(loc.t("install.reveal")) { revealInFinder(build.archivePath) }
                    }
                }
            }
        }
    }
}
