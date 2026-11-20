import Foundation

/// How the device is connected to this Mac, from `devicectl list devices` (connectionProperties.transportType: "wired" for a
/// cable, "localNetwork" for Wi-Fi, absent when the device is not reachable). A device the list does not show, or shows
/// unpaired, was never paired with this Mac.
package enum ShellConnection: Equatable, Sendable {
    case wired, network, other, notConnected, notPaired
}

/// What the player is told before the game data goes over: how much, and over which connection. The GUI shows it with its
/// buttons, the terminal prints it and copies.
package struct ShellCopyPlan: Equatable, Sendable {
    package var files: Int
    package var bytes: Int64
    package var connection: ShellConnection
    package var linkProfile: DeviceLinkProfile
    package var deviceName: String
    /// Set only when this Mac remembers a successful copy of a different image for this game and device.
    package var versionNote: String?
    /// "15 GB in 2 files."
    package var sizeText: String
    /// The cable note, USB speed recommendation, or the Wi-Fi hint with its estimate.
    package var connectionText: String
    /// Whether waiting for a cable (or a high-speed cable when currently on USB 2.0) is offered.
    package var canWaitForCable: Bool {
        switch linkProfile {
        case .wifi, .disconnected, .usb2:
            return true
        case .highSpeedUSB, .wiredUnknown:
            return false
        }
    }
    /// True when the device is currently wired over USB 2.0 and waiting targets a USB 3 / Thunderbolt upgrade.
    package var waitsForHighSpeedCable: Bool { linkProfile.isUSB2 }

    package init(
        files: Int,
        bytes: Int64,
        connection: ShellConnection,
        linkProfile: DeviceLinkProfile? = nil,
        deviceName: String,
        sizeText: String,
        connectionText: String
    ) {
        self.files = files
        self.bytes = bytes
        self.connection = connection
        self.linkProfile = linkProfile ?? USBLinkSpeed.profile(connection: connection, usbSpeedBps: nil)
        self.deviceName = deviceName
        self.sizeText = sizeText
        self.connectionText = connectionText
    }
}

package enum ShellCopyDecision: Equatable, Sendable { case copy, skip, waitForCable }

extension ShellInstaller {
    /// Resolves the live `DeviceLinkProfile` using the current `devicectl` connection and IOKit USB link speed.
    func linkProfile(for connection: ShellInstall.Connection) -> DeviceLinkProfile {
        let speed: Int64? = (connection == .wired || connection == .other) ? usbSpeedLookup(device) : nil
        return USBLinkSpeed.profile(connection: connection, usbSpeedBps: speed)
    }

    /// Builds a copy plan with real-time link speed, duration estimate, and connection-specific advice.
    func copyPlan(files: Int, bytes: Int64, connection: ShellInstall.Connection, linkProfile: DeviceLinkProfile? = nil) -> ShellCopyPlan {
        let profile = linkProfile ?? self.linkProfile(for: connection)
        let size = ShellInstall.sizeText(bytes)
        let connectionText: String
        switch profile {
        case .highSpeedUSB(let bps):
            let rate = USBLinkSpeed.formatRate(bps)
            let est = USBLinkSpeed.estimateMinutes(bytes: bytes, profile: profile) ?? (1, 1)
            if est.high == 1 {
                connectionText = fmt("shell.copyHighSpeedMinute", rate, size, deviceName)
            } else if est.low == est.high {
                connectionText = fmt("shell.copyHighSpeedOne", rate, size, est.low, deviceName)
            } else {
                connectionText = fmt("shell.copyHighSpeed", rate, size, est.low, est.high, deviceName)
            }
        case .usb2(let bps):
            let rate = USBLinkSpeed.formatRate(bps)
            let est = USBLinkSpeed.estimateMinutes(bytes: bytes, profile: profile) ?? (1, 1)
            if est.high == 1 {
                connectionText = fmt("shell.copyUSB2Minute", rate, size)
            } else if est.low == est.high {
                connectionText = fmt("shell.copyUSB2One", rate, size, est.low)
            } else {
                connectionText = fmt("shell.copyUSB2", rate, size, est.low, est.high)
            }
        case .wifi:
            let e = ShellInstall.wifiEstimate(bytes: bytes)
            connectionText = e.high == 1 ? fmt("shell.copyWifiMinute", size)
                : e.low == e.high ? fmt("shell.copyWifiOne", size, e.low) : fmt("shell.copyWifi", size, e.low, e.high)
        case .disconnected:
            connectionText = fmt("shell.copyNotConnected", deviceName)
        case .wiredUnknown:
            connectionText = fmt("shell.copyWired", deviceName)
        }
        return ShellCopyPlan(
            files: files,
            bytes: bytes,
            connection: connection,
            linkProfile: profile,
            deviceName: deviceName,
            sizeText: fmt("shell.copySize", size, files),
            connectionText: connectionText
        )
    }

    /// Polls until a cable (or a high-speed USB 3 / Thunderbolt cable if starting from USB 2.0) connects or the wait is cancelled.
    func waitForCable(initialProfile: DeviceLinkProfile) -> ShellCopyDecision {
        let needsHighSpeed = initialProfile.isUSB2
        log(fmt(needsHighSpeed ? "shell.copyWaitingHighSpeed" : "shell.copyWaiting", deviceName) + "\n")
        waiting(true)
        var satisfied = false
        while !waitCancelled() {
            var remaining = max(0, pollInterval)
            while remaining > 0 && !waitCancelled() {
                let slice = min(0.2, remaining)
                Thread.sleep(forTimeInterval: slice)
                remaining -= slice
            }
            if waitCancelled() { break }
            let currentLink = connection()
            if currentLink == .wired {
                if needsHighSpeed {
                    if linkProfile(for: currentLink).isHighSpeedUSB {
                        satisfied = true
                        break
                    }
                } else {
                    satisfied = true
                    break
                }
            }
        }
        waiting(false)
        return satisfied && !waitCancelled() ? .copy : .skip
    }

    /// The identity of the file we are about to send. The build's existing reader checks the image size and index
    /// without reading the multi-GB payload. Include the framework's version for updates with an identical index.
    func imageIdentity(archive: String, titleID: String) -> String? {
        let tool = EngineLayout.root(repo) + "/" + RepoLayout.romfsImageTool
        guard FileManager.default.fileExists(atPath: tool) else { return nil }
        let game = ShellLibrary.load(root: root).games.first { $0.titleID == titleID }
        let manifest = game.flatMap { FileManager.default.contents(atPath: $0.framework + "/game.manifest.json") }
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        let imagePath = RomFSArchive.primaryImagePath(in: archive) ?? (archive + "/romfs.img")
        let args = ["-I", tool, "--identity", imagePath, titleID,
                    manifest?["display_version"] as? String ?? "", manifest?["package_version"] as? String ?? ""]
        let result = runner.capture(ProcessLaunch(executable: python, arguments: args))
        let line = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.ok && line.hasPrefix("DMROMFSID1 ") ? line : nil
    }
}
