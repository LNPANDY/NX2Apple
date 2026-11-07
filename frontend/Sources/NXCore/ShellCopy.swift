import Foundation

/// How the device is connected to this Mac, from `devicectl list devices` (connectionProperties.transportType: "wired" for a
/// cable, "localNetwork" for Wi-Fi, absent when the device is not reachable). A device the list does not show, or shows
/// unpaired, was never paired with this Mac.
package enum ShellConnection: Equatable {
    case wired, network, other, notConnected, notPaired
}

/// What the player is told before the game data goes over: how much, and over which connection. The GUI shows it with its
/// buttons, the terminal prints it and copies.
package struct ShellCopyPlan: Equatable {
    package var files: Int
    package var bytes: Int64
    package var connection: ShellConnection
    package var deviceName: String
    /// Set only when this Mac remembers a successful copy of a different image for this game and device.
    package var versionNote: String?
    /// "15 GB in 2 files."
    package var sizeText: String
    /// The cable note, or the Wi-Fi hint with its estimate.
    package var connectionText: String
    /// Whether waiting for a cable is offered (the device is on Wi-Fi, or not connected).
    package var canWaitForCable: Bool { connection == .network || connection == .notConnected }

    package init(files: Int, bytes: Int64, connection: ShellConnection, deviceName: String, sizeText: String, connectionText: String) {
        self.files = files; self.bytes = bytes; self.connection = connection; self.deviceName = deviceName
        self.sizeText = sizeText; self.connectionText = connectionText
    }
}

package enum ShellCopyDecision: Equatable { case copy, skip, waitForCable }

extension ShellInstaller {
    /// The identity of the file we are about to send. The build's existing reader checks the image size and index
    /// without reading the multi-GB payload. Include the framework's version for updates with an identical index.
    func imageIdentity(archive: String, titleID: String) -> String? {
        let tool = EngineLayout.root(repo) + "/" + RepoLayout.romfsImageTool
        guard FileManager.default.fileExists(atPath: tool) else { return nil }
        let game = ShellLibrary.load(root: root).games.first { $0.titleID == titleID }
        let manifest = game.flatMap { FileManager.default.contents(atPath: $0.framework + "/game.manifest.json") }
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        let args = ["-I", tool, "--identity", archive + "/romfs.img", titleID,
                    manifest?["display_version"] as? String ?? "", manifest?["package_version"] as? String ?? ""]
        let result = runner.capture(ProcessLaunch(executable: python, arguments: args))
        let line = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.ok && line.hasPrefix("DMROMFSID1 ") ? line : nil
    }
}
