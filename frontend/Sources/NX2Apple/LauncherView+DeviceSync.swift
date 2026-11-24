import SwiftUI
import NXCore
import NXLauncher
import NXModel

/// Keeps `GameLibrary`'s ephemeral on-device framework state synchronized with `DeviceStore` without touching `library.json`.
private struct DeviceFrameworkSyncWiring: ViewModifier {
    @ObservedObject var devices: DeviceStore
    let library: GameLibrary
    @ObservedObject var build: BuildStore
    let performStartupChecks: Bool
    let checkTools: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var lastReachableKey = ""

    private var reachableKey: String {
        let reachable = devices.devices.filter(\.reachable).map(\.id).sorted().joined(separator: ",")
        return "\(devices.installDevice)|\(reachable)"
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: reachableKey) { newKey in
                guard performStartupChecks, newKey != lastReachableKey else { return }
                lastReachableKey = newKey
                let bundleHint = ShellLibrary.load(root: build.shellCachePath).bundleID
                _ = devices.refreshDeviceFrameworks(preferredBundleID: bundleHint)
            }
            .onReceive(devices.$deviceFrameworks) { frameworks in
                library.updateConnectedDeviceFrameworks(frameworks, deviceID: devices.deviceFrameworksDeviceID)
                if performStartupChecks {
                    checkTools()
                }
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active, performStartupChecks {
                    let bundleHint = ShellLibrary.load(root: build.shellCachePath).bundleID
                    _ = devices.refreshDeviceFrameworks(preferredBundleID: bundleHint)
                }
            }
    }
}

extension View {
    func deviceFrameworkSyncWiring(
        devices: DeviceStore,
        library: GameLibrary,
        build: BuildStore,
        performStartupChecks: Bool,
        checkTools: @escaping () -> Void
    ) -> some View {
        modifier(DeviceFrameworkSyncWiring(
            devices: devices,
            library: library,
            build: build,
            performStartupChecks: performStartupChecks,
            checkTools: checkTools
        ))
    }
}

extension LauncherView {
    /// Quiet metadata chip on the Hero indicating the game's `DmGame<TID>.framework` is installed on the connected iOS device.
    @ViewBuilder func deviceFrameworkBadge(_ game: LibraryGame) -> some View {
        if let entry = devices.deviceFramework(for: game.titleID) {
            let deviceTitle = devices.deviceName(entry.deviceUDID)
            ArtworkStatusChip(title: loc.t("dev.onDeviceFrameworkBadge"), symbol: "iphone", color: LauncherPalette.notice)
                .help(String(format: loc.t("dev.onDeviceFrameworkHelp"), deviceTitle))
                .accessibilityIdentifier("hero.deviceFramework")
        }
    }
}
