import Foundation

/// One game's data on its way to one device (LNPANDY/NX2Apple#1036). A transfer is not a build: it has its own queue, its own card, and
/// it runs beside an unrelated build. The parts already on the device are checked by identity when it starts again (ShellDataParts), so
/// a retry or a reconnect continues and does not start over.
package struct TransferEntry: Codable, Identifiable, Equatable, Sendable {
    package enum Status: String, Codable, Sendable {
        case queued, sending
        /// The device is not connected. The entry goes on by itself when it is back.
        case waiting
        case failed, done
        /// Cancel was asked while the send runs. The row stays until the tool returns, and then goes.
        case cancelling
    }

    package var id: UUID
    package var titleID: String
    package var name: String
    /// The game's data folder on this Mac (games/<title ID>/): the folder Finder recovery reveals, always this entry's own.
    package var archive: String
    package var deviceID: String
    package var deviceName: String
    /// A shared app copy the player chose when the device has several, else nil.
    package var bundleID: String?
    package var status: Status
    package var doneBytes: Int64
    package var totalBytes: Int64
    /// What went wrong, for a failed entry.
    package var reason: String?

    package init(id: UUID = UUID(), titleID: String, name: String, archive: String, deviceID: String, deviceName: String,
                 bundleID: String? = nil, status: Status = .queued, doneBytes: Int64 = 0, totalBytes: Int64 = 0, reason: String? = nil) {
        self.id = id; self.titleID = titleID; self.name = name; self.archive = archive; self.deviceID = deviceID
        self.deviceName = deviceName; self.bundleID = bundleID; self.status = status; self.doneBytes = doneBytes
        self.totalBytes = totalBytes; self.reason = reason
    }

    package var active: Bool { status == .queued || status == .sending || status == .waiting || status == .cancelling }
}

/// What a transfer attempt ended with.
package enum TransferResult: Equatable, Sendable {
    case done
    /// The device is not connected (it was not when the transfer began, or it went away during it).
    case deviceAbsent
    case failed(String)
}

package enum TransferQueueFile {
    package static func load(_ url: URL) -> [TransferEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([TransferEntry].self, from: data)) ?? []
    }

    package static func save(_ entries: [TransferEntry], to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
