import Foundation

/// One entry of the build queue (LNPANDY/NX2Apple#943): a snapshot of what to build, taken when the player adds it. Nothing in it
/// follows the Build form, the library or the engine selection afterwards, so the queue builds what was asked for.
package struct QueueEntry: Codable, Identifiable, Equatable, Sendable {
    package enum Status: String, Codable, Sendable { case queued, running, done, failed, skipped }

    package var id: UUID
    /// The library entry, nil when the game is not in the library (a build from the form).
    package var gameID: UUID?
    package var titleID: String
    package var name: String
    /// BuildTarget.mac or BuildTarget.ios, as of adding.
    package var target: String
    /// Slot id (base, update, dlc, keys) to paths, as the library keeps them.
    package var inputs: [String: [String]]
    /// A game folder (GameLibrary.folderInput) the inputs came from, else nil.
    package var gameFolder: String?
    package var outputDirectory: String
    /// The engine the entry was added under (`EngineSyncStore` selection). A queue never builds with another one.
    package var engineID: String
    /// Entries added together share a batch. A shared-app batch packages its successful games once when it ends (#997).
    package var batch: UUID
    package var packageAfter: Bool
    /// Whether an iPhone/iPad batch exports an unsigned IPA (true) or installs directly on a device (false), nil before start or on Mac.
    package var exportIPA: Bool?
    package var status: Status
    /// Why the entry failed or was skipped, shown in the summary.
    package var reason: String?
    /// The name of the device or the folder it goes to, as chosen when it was added, nil for "This Mac" or an unsigned IPA.
    package var destinationName: String?

    package init(id: UUID = UUID(), gameID: UUID? = nil, titleID: String, name: String, target: String, inputs: [String: [String]],
                 gameFolder: String? = nil, outputDirectory: String, engineID: String, batch: UUID = UUID(), packageAfter: Bool = false,
                 exportIPA: Bool? = nil, status: Status = .queued, reason: String? = nil, destinationName: String? = nil) {
        self.id = id; self.gameID = gameID; self.titleID = titleID; self.name = name; self.target = target; self.inputs = inputs
        self.gameFolder = gameFolder; self.outputDirectory = outputDirectory; self.engineID = engineID; self.batch = batch
        self.packageAfter = packageAfter; self.exportIPA = exportIPA; self.status = status; self.reason = reason
        self.destinationName = destinationName
    }

    package var finished: Bool { status == .done || status == .failed || status == .skipped }

    /// The inputs in one line: which rows have files ("Base game, Update, 2 DLC"), a game folder as such.
    package func inputSummary(_ t: (String) -> String) -> String {
        if gameFolder != nil { return t("queue.inputFolder") }
        var parts: [String] = []
        for (id, key) in [("base", "data.base"), ("update", "data.update"), ("dlc", "data.dlc")] {
            guard let paths = inputs[id], !paths.isEmpty else { continue }
            parts.append(paths.count > 1 ? "\(paths.count) × \(t(key))" : t(key))
        }
        return parts.joined(separator: ", ")
    }
}

/// The file the queue lives in, so it survives a restart. A failed read is an empty queue, a failed write is left to the next change.
package enum BuildQueueFile {
    private struct Stored: Codable { var entries: [QueueEntry]; var paused: Bool }

    /// The entries and whether the player's Stop paused the queue.
    package static func load(_ url: URL) -> (entries: [QueueEntry], paused: Bool) {
        guard let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return ([], false) }
        return (stored.entries, stored.paused)
    }

    package static func save(_ entries: [QueueEntry], paused: Bool = false, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Stored(entries: entries, paused: paused)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
