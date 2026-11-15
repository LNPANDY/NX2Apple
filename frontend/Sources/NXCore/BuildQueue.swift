import Foundation

/// One entry of the build queue (LNPANDY/NX2Apple#943): a snapshot of what to build, taken when the player adds it. Nothing in it
/// follows the Build form, the library or the engine selection afterwards, so the queue builds what was asked for.
package struct QueueEntry: Codable, Identifiable, Equatable, Sendable {
    package enum Status: String, Codable, Sendable { case queued, running, done, failed, skipped, stopped }

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
    /// Whether this entry runs a seed-based fast refresh instead of unpacking original game packages.
    package var fastRefresh: Bool
    /// Whether `target` is pinned per entry (for mixed Mac + iPhone refresh batches) rather than overwritten by the Build page target.
    package var locksTarget: Bool
    /// Existing Mac `.app` path passed to fast refresh when updating a Mac bundle in place.
    package var existingAppPath: String?
    /// External or user-chosen `.img` path used for `--prefill-msl` and in-place trailer update without copying back locally.
    package var externalImgPath: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case gameID
        case titleID
        case name
        case target
        case inputs
        case gameFolder
        case outputDirectory
        case engineID
        case batch
        case packageAfter
        case exportIPA
        case status
        case reason
        case destinationName
        case fastRefresh
        case locksTarget
        case existingAppPath
        case externalImgPath
    }

    package init(
        id: UUID = UUID(),
        gameID: UUID? = nil,
        titleID: String,
        name: String,
        target: String,
        inputs: [String: [String]],
        gameFolder: String? = nil,
        outputDirectory: String,
        engineID: String,
        batch: UUID = UUID(),
        packageAfter: Bool = false,
        exportIPA: Bool? = nil,
        status: Status = .queued,
        reason: String? = nil,
        destinationName: String? = nil,
        fastRefresh: Bool = false,
        locksTarget: Bool = false,
        existingAppPath: String? = nil,
        externalImgPath: String? = nil
    ) {
        self.id = id
        self.gameID = gameID
        self.titleID = titleID
        self.name = name
        self.target = target
        self.inputs = inputs
        self.gameFolder = gameFolder
        self.outputDirectory = outputDirectory
        self.engineID = engineID
        self.batch = batch
        self.packageAfter = packageAfter
        self.exportIPA = exportIPA
        self.status = status
        self.reason = reason
        self.destinationName = destinationName
        self.fastRefresh = fastRefresh
        self.locksTarget = locksTarget
        self.existingAppPath = existingAppPath
        self.externalImgPath = externalImgPath
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.gameID = try c.decodeIfPresent(UUID.self, forKey: .gameID)
        self.titleID = try c.decode(String.self, forKey: .titleID)
        self.name = try c.decode(String.self, forKey: .name)
        self.target = try c.decode(String.self, forKey: .target)
        self.inputs = try c.decodeIfPresent([String: [String]].self, forKey: .inputs) ?? [:]
        self.gameFolder = try c.decodeIfPresent(String.self, forKey: .gameFolder)
        self.outputDirectory = try c.decodeIfPresent(String.self, forKey: .outputDirectory) ?? ""
        self.engineID = try c.decode(String.self, forKey: .engineID)
        self.batch = try c.decode(UUID.self, forKey: .batch)
        self.packageAfter = try c.decodeIfPresent(Bool.self, forKey: .packageAfter) ?? false
        self.exportIPA = try c.decodeIfPresent(Bool.self, forKey: .exportIPA)
        self.status = try c.decode(Status.self, forKey: .status)
        self.reason = try c.decodeIfPresent(String.self, forKey: .reason)
        self.destinationName = try c.decodeIfPresent(String.self, forKey: .destinationName)
        self.fastRefresh = try c.decodeIfPresent(Bool.self, forKey: .fastRefresh) ?? false
        self.locksTarget = try c.decodeIfPresent(Bool.self, forKey: .locksTarget) ?? false
        self.existingAppPath = try c.decodeIfPresent(String.self, forKey: .existingAppPath)
        self.externalImgPath = try c.decodeIfPresent(String.self, forKey: .externalImgPath)
    }

    package var finished: Bool { status == .done || status == .failed || status == .skipped || status == .stopped }

    /// The inputs in one line: fast refresh when seeded, a game folder as such, else which rows have files ("Base game, Update, 2 DLC").
    package func inputSummary(_ t: (String) -> String) -> String {
        if fastRefresh { return t("queue.fastRefreshSummary") }
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
    private struct Stored: Codable {
        var entries: [QueueEntry]
        var paused: Bool
    }

    /// The entries and whether the player's Stop paused the queue.
    package static func load(_ url: URL) -> (entries: [QueueEntry], paused: Bool) {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return ([], false)
        }
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
