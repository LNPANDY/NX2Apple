import Foundation

/// The shell is the only registry writer. Actor isolation serializes intake and
/// launch preparation. Every published generation is immutable for its lifetime.
public actor PayloadStore {
    public static let inboxName = "PayloadInbox"
    public static let bundlesName = "GameBundles"
    public static let receiptsName = "PayloadReceipts"
    public static let registryName = "payload-registry.json"

    /// Relative to Documents. Resource updates stay separate from data used by
    /// loaded code, while saves remain in the title's original folder.
    public static func gameDataPath(titleID: String, generation: String) -> String {
        "games/\(titleID)/payload-data/\(generation)"
    }

    public struct Selection: Codable, Sendable, Equatable {
        public var active: PayloadManifest?
        public var pending: PayloadManifest?
        public var previous: PayloadManifest?
        var lastCompletion: Completion?
    }
    struct Completion: Codable, Sendable, Comparable {
        var date: Date
        var generation: String
        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.date == rhs.date ? lhs.generation < rhs.generation : lhs.date < rhs.date
        }
    }
    struct Registry: Codable {
        var schema = 1
        var games: [String: Selection] = [:]
    }

    public nonisolated let documents: URL
    /// A write failure must not prevent reading an existing game library.
    public nonisolated let startupWriteError: String?
    let host: PayloadCapabilities
    let validator: @Sendable (URL) throws -> Void
    let metadataValidator: @Sendable (URL) throws -> Void
    var registry: Registry
    var loaded = Set<String>()

    public init(documents: URL, host: PayloadCapabilities,
                validator: @escaping @Sendable (URL) throws -> Void = PayloadNativeCode.validate,
                metadataValidator: @escaping @Sendable (URL) throws -> Void = { _ in }) throws {
        self.documents = documents; self.host = host; self.validator = validator
        self.metadataValidator = metadataValidator
        let fm = FileManager.default
        let file = documents.appendingPathComponent(Self.registryName)
        if fm.fileExists(atPath: file.path) {
            registry = try Self.decodeRegistry(Data(contentsOf: file))
        } else { registry = Registry() }
        do {
            try Self.prepareDirectories(documents)
            if !fm.fileExists(atPath: file.path) {
                try PayloadArchive.encode(registry).write(to: file, options: .atomic)
            }
            try PayloadArchive.encode(host).write(to: documents.appendingPathComponent(PayloadCapabilities.fileName), options: .atomic)
            startupWriteError = nil
        } catch {
            startupWriteError = String(describing: error)
        }
    }

    static func decodeRegistry(_ data: Data) throws -> Registry {
        let registry = try JSONDecoder().decode(Registry.self, from: data)
        guard registry.schema == 1 else { throw PayloadError.invalid("registry schema") }
        for (title, selection) in registry.games {
            for manifest in [selection.active, selection.pending, selection.previous].compactMap({ $0 }) {
                try manifest.validate()
                guard manifest.titleID == title else { throw PayloadError.invalid("registry title") }
            }
        }
        return registry
    }

    /// Data-only delivery follows a queued update when one exists, otherwise
    /// the active import. A title absent from the registry remains bundled.
    public static func selectedManifest(in registryData: Data, titleID: String) throws -> PayloadManifest? {
        let selection = try decodeRegistry(registryData).games[titleID]
        return selection?.pending ?? selection?.active
    }

    static func prepareDirectories(_ documents: URL) throws {
        for name in [inboxName, bundlesName, receiptsName] {
            try FileManager.default.createDirectory(at: documents.appendingPathComponent(name), withIntermediateDirectories: true)
        }
    }

    func directory(_ manifest: PayloadManifest) -> URL {
        documents.appendingPathComponent(Self.bundlesName).appendingPathComponent(manifest.titleID).appendingPathComponent(manifest.generation)
    }

    func persist(_ next: Registry) throws {
        try PayloadArchive.encode(next).write(to: documents.appendingPathComponent(Self.registryName), options: .atomic)
        registry = next
    }

    func receiptURL(_ generation: String) -> URL {
        documents.appendingPathComponent(Self.receiptsName).appendingPathComponent(generation + ".json")
    }

    func write(_ receipt: PayloadReceipt) throws {
        try PayloadArchive.encode(receipt).write(to: receiptURL(receipt.generation), options: .atomic)
    }

    /// Called once by a new shell process, before constructing its catalogue.
    /// A foreground refresh must never promote an already-loaded replacement.
    public func activatePending() throws -> [PayloadReceipt] {
        guard loaded.isEmpty else { throw PayloadError.invalid("pending activation after loading code") }
        var next = registry
        var results: [PayloadReceipt] = []
        for title in registry.games.keys.sorted() {
            guard var selection = next.games[title], let pending = selection.pending else { continue }
            do {
                try verify(pending)
                selection.previous = selection.active
                selection.active = pending
                results.append(.init(generation: pending.generation, titleID: title, state: .active))
            } catch {
                results.append(.init(generation: pending.generation, titleID: title, state: .rejected, detail: String(describing: error)))
            }
            selection.pending = nil
            next.games[title] = selection
        }
        guard !results.isEmpty else { return [] }
        try persist(next)
        do { for result in results { try write(result) } }
        catch { throw PayloadProcessingError(receipts: results, detail: String(describing: error)) }
        return results
    }

    public func selections() -> [String: Selection] { registry.games }

    public func hasReadyTransactions() -> Bool {
        let fm = FileManager.default
        let inbox = documents.appendingPathComponent(Self.inboxName)
        return ((try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []).contains { url in
            let generation = url.lastPathComponent
            return UUID(uuidString: generation) != nil && generation == generation.lowercased() &&
                fm.fileExists(atPath: url.appendingPathComponent(PayloadArchive.readyName).path) &&
                !fm.fileExists(atPath: receiptURL(generation).path)
        }
    }

    public func activeFrameworks() -> [String: URL] {
        registry.games.compactMapValues { selection in
            selection.active.map { directory($0).appendingPathComponent($0.framework) }
        }
    }

    func verify(_ manifest: PayloadManifest) throws {
        try manifest.compatible(with: host)
        let root = directory(manifest)
        for file in manifest.files {
            let url = root.appendingPathComponent(file.path)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  try PayloadArchive.size(url) == file.bytes else { throw PayloadError.invalid("installed file") }
            // Revalidate executable bytes before every load. Resource integrity
            // was checked during intake, without hashing GB of shaders per Play.
            if try PayloadNativeCode.isLibrary(url) {
                guard try PayloadArchive.digest(url) == file.sha256 else { throw PayloadError.invalid("installed code changed") }
            }
        }
        try PayloadNativeCode.validateFramework(manifest, directory: root, validate: validator)
        try metadataValidator(root.appendingPathComponent(manifest.framework))
    }

    /// Marks even bundled titles as loaded: an imported update must then wait
    /// for a cold start, since the engine retains framework images after Quit.
    public func prepareLaunch(titleID: String, framework: URL) throws {
        if let active = registry.games[titleID]?.active {
            guard directory(active).appendingPathComponent(active.framework).standardizedFileURL == framework.standardizedFileURL else {
                throw PayloadError.invalid("selection changed before launch")
            }
            try verify(active)
        }
        loaded.insert(titleID)
    }

    public func processInbox() throws -> [PayloadReceipt] {
        let fm = FileManager.default
        try Self.prepareDirectories(documents)
        let inbox = documents.appendingPathComponent(Self.inboxName)
        // Generations are random UUIDs. Process completed transfers in their
        // marker order so an older queued update cannot replace a newer one.
        let incoming = try fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
        var dated: [(url: URL, completed: Date)] = []
        for url in incoming {
            let marker = url.appendingPathComponent(PayloadArchive.readyName)
            let attributes = try? fm.attributesOfItem(atPath: marker.path)
            let completed = attributes?[.modificationDate] as? Date ?? Date.distantPast
            dated.append((url, completed))
        }
        dated.sort {
            $0.completed == $1.completed ? $0.url.lastPathComponent < $1.url.lastPathComponent : $0.completed < $1.completed
        }
        var results: [PayloadReceipt] = []
        for (transaction, completed) in dated {
            let generation = transaction.lastPathComponent
            guard UUID(uuidString: generation) != nil, generation == generation.lowercased(),
                  fm.fileExists(atPath: transaction.appendingPathComponent(PayloadArchive.readyName).path) else { continue }
            // A receipt makes a transaction idempotent, including a rejection.
            // A changed/retried build uses a fresh generation/transaction ID.
            if fm.fileExists(atPath: receiptURL(generation).path) {
                try? fm.removeItem(at: transaction)
                continue
            }
            var title = ""
            let receipt: PayloadReceipt
            do {
                let readyFile = transaction.appendingPathComponent(PayloadArchive.readyName)
                guard try PayloadArchive.size(readyFile) <= 4096 else { throw PayloadError.invalid("completion marker") }
                let ready = try JSONDecoder().decode(PayloadArchive.Ready.self, from: Data(contentsOf: readyFile))
                let archive = transaction.appendingPathComponent(PayloadArchive.fileName)
                guard ready.generation == generation else { throw PayloadError.invalid("completion identity") }
                guard try PayloadArchive.joinParts(in: transaction, ready: ready) else { continue }
                guard try PayloadArchive.size(archive) == ready.bytes,
                      try PayloadArchive.digest(archive) == ready.sha256 else { throw PayloadError.invalid("incomplete transfer") }
                let manifest = try PayloadArchive.manifest(at: archive)
                title = manifest.titleID
                guard manifest.generation == generation else { throw PayloadError.invalid("transaction identity") }
                receipt = try install(archive, manifest: manifest, completion: Completion(date: completed, generation: generation))
            } catch {
                receipt = PayloadReceipt(generation: generation, titleID: title, state: .rejected, detail: String(describing: error))
            }
            results.append(receipt)
            // Receipt I/O cannot turn a committed active import into a rejected
            // one, or discard successful outcomes from earlier in this batch.
            do { try write(receipt) }
            catch { throw PayloadProcessingError(receipts: results, detail: String(describing: error)) }
            // Once the outcome is durable, accepted and rejected archives are
            // disposable. Incomplete transfers and failed receipt writes stay.
            try? fm.removeItem(at: transaction)
        }
        return results
    }

    func install(_ archive: URL, manifest: PayloadManifest, completion: Completion) throws -> PayloadReceipt {
        let fm = FileManager.default
        try manifest.compatible(with: host)
        let current = registry.games[manifest.titleID]
        let selected = current?.active == manifest || current?.pending == manifest
        if !selected, let latest = current?.lastCompletion, completion < latest {
            throw PayloadError.invalid("superseded by a later completed transfer")
        }
        let destination = directory(manifest)
        // A crash can leave a published directory before the atomic registry
        // write. Verify it against the envelope before completing that commit.
        if fm.fileExists(atPath: destination.path) {
            let saved = try JSONDecoder().decode(PayloadManifest.self, from: Data(contentsOf: destination.appendingPathComponent("payload.json")))
            guard saved == manifest else { throw PayloadError.invalid("generation collision") }
            for file in manifest.files {
                guard try PayloadArchive.digest(destination.appendingPathComponent(file.path)) == file.sha256 else {
                    throw PayloadError.invalid("uncommitted generation damaged")
                }
            }
            try verify(manifest)
        } else {
            let stage = documents.appendingPathComponent(Self.bundlesName).appendingPathComponent(".stage-" + UUID().uuidString)
            defer { try? fm.removeItem(at: stage) }
            let extracted = try PayloadArchive.extract(archive, to: stage, host: host)
            try PayloadNativeCode.validateFramework(extracted, directory: stage, validate: validator)
            try metadataValidator(stage.appendingPathComponent(manifest.framework))
            try PayloadArchive.encode(manifest).write(to: stage.appendingPathComponent("payload.json"), options: .atomic)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: stage, to: destination)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var bundleRoot = destination
            try bundleRoot.setResourceValues(values)
        }
        var next = registry
        var selection = next.games[manifest.titleID] ?? Selection()
        // The registry commit can survive termination before its receipt is
        // written. Recreate that receipt without changing selection/history,
        // even if this generation has since been loaded in the same process.
        if selection.active == manifest {
            return .init(generation: manifest.generation, titleID: manifest.titleID, state: .active)
        }
        if selection.pending == manifest {
            return .init(generation: manifest.generation, titleID: manifest.titleID, state: .restartRequired)
        }
        let deferred = loaded.contains(manifest.titleID)
        if deferred {
            selection.pending = manifest
        } else {
            selection.previous = selection.active
            selection.active = manifest
            selection.pending = nil
        }
        selection.lastCompletion = completion
        next.games[manifest.titleID] = selection
        try persist(next)
        return .init(generation: manifest.generation, titleID: manifest.titleID, state: deferred ? .restartRequired : .active)
    }
}
