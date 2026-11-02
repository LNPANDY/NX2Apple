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
