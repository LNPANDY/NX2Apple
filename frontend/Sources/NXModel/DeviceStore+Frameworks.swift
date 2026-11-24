import Foundation
import NXCore

extension DeviceStore {
    /// Picks the reachable paired device to inspect: `preferredDevice` when reachable, else `installDevice`, else first reachable.
    package func activeFrameworkDevice(preferredDevice: String? = nil) -> AppleDevice? {
        if let preferred = preferredDevice?.trimmingCharacters(in: .whitespacesAndNewlines),
           !preferred.isEmpty,
           let match = devices.first(where: { $0.id == preferred && $0.reachable }) {
            return match
        }
        if !installDevice.isEmpty,
           let match = devices.first(where: { $0.id == installDevice && $0.reachable }) {
            return match
        }
        return devices.first(where: \.reachable)
    }

    /// Returns the discovered device framework entry for a Title ID when present on the active connected device.
    package func deviceFramework(for titleID: String) -> DeviceFrameworkEntry? {
        let tid = titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !tid.isEmpty else { return nil }
        return deviceFrameworks[tid]
    }

    /// Discovers hot-loaded `DmGame<TID>.framework` directories on the active reachable iOS device off the main thread.
    /// Revalidates `frameworkProbeGeneration` and active device identity before committing results to `@Published` state.
    @discardableResult
    package func refreshDeviceFrameworks(
        preferredDevice: String? = nil,
        preferredBundleID: String = ""
    ) -> Task<Void, Never> {
        frameworkProbeGeneration &+= 1
        let generation = frameworkProbeGeneration

        guard let target = activeFrameworkDevice(preferredDevice: preferredDevice) else {
            deviceFrameworks = [:]
            deviceFrameworksDeviceID = ""
            deviceFrameworksDeviceName = ""
            deviceFrameworksShellBundleID = ""
            deviceFrameworksState = .idle
            return Task { @MainActor in }
        }

        if deviceFrameworksDeviceID != target.id {
            deviceFrameworks = [:]
            deviceFrameworksShellBundleID = ""
        }
        deviceFrameworksDeviceID = target.id
        deviceFrameworksDeviceName = target.name
        deviceFrameworksState = .probing

        let probe = discoverDeviceFrameworks
        let targetID = target.id
        let targetName = target.name
        let bundleHint = preferredBundleID

        let work = Task.detached(priority: .userInitiated) { () -> DeviceFrameworkDiscoveryResult in
            probe(targetID, targetName, bundleHint)
        }

        return Task { @MainActor in
            let result = await work.value
            guard self.frameworkProbeGeneration == generation else { return }
            guard let currentTarget = self.activeFrameworkDevice(preferredDevice: preferredDevice),
                  currentTarget.id == targetID else {
                self.deviceFrameworks = [:]
                self.deviceFrameworksDeviceID = ""
                self.deviceFrameworksDeviceName = ""
                self.deviceFrameworksShellBundleID = ""
                self.deviceFrameworksState = .idle
                return
            }

            self.deviceFrameworksDeviceID = result.deviceUDID
            self.deviceFrameworksDeviceName = result.deviceName
            self.deviceFrameworksShellBundleID = result.bundleID
            self.deviceFrameworksState = result.state
            if result.state == .ready {
                var mapped: [String: DeviceFrameworkEntry] = [:]
                for entry in result.entries {
                    mapped[entry.titleID.uppercased()] = entry
                }
                self.deviceFrameworks = mapped
            } else {
                self.deviceFrameworks = [:]
            }
        }
    }
}
