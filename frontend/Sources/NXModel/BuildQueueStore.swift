import Foundation
import Combine
import NXCore

/// The one build queue (LNPANDY/NX2Apple#943, #997): games the player added, built one after the other. It follows `AppUpdateStore`
/// (`frontend/ARCHITECTURE.md`, "Stores"): what it needs from the app comes through `init` as closures.
///
/// - Every entry is a snapshot (`QueueEntry`). The queue never reads the Build form, never changes the engine selection, and never
///   adds anything by itself: an engine update does not queue a rebuild (#945 is not part of the product).
/// - It lives in a file. After a restart the unfinished entries are back and `awaitingResume` asks the player before one starts.
/// - Stop (of the running build) ends that entry only. `cancelQueued` removes the waiting ones and leaves the results.
@MainActor package final class BuildQueueStore: ObservableObject {
    @Published package private(set) var entries: [QueueEntry]
    /// Entries from before a restart are waiting: nothing starts until the player confirms (`resume`) or drops them.
    @Published package private(set) var awaitingResume: Bool
    /// The player stopped the running build: the queue waits and starts nothing until `resume`. It survives a restart.
    @Published package private(set) var paused: Bool

    /// True once the player explicitly starts or resumes the queue, until the batch finishes, pauses, or is cancelled.
    private var active = false
    private let file: URL?
    private let engineID: () -> String
    /// Starts the entry's build. nil: started. A string: why it cannot, which becomes the entry's reason.
    private let start: (QueueEntry) -> String?
    /// A shared-app batch ended with these successful entries: package them once.
    private let packageBatch: ([QueueEntry]) -> Void
    /// A build or another operation is running, so nothing starts.
    private let busy: () -> Bool
    private let engineChangedReason: () -> String

    package init(file: URL?, engineID: @escaping () -> String, busy: @escaping () -> Bool,
                 start: @escaping (QueueEntry) -> String?, packageBatch: @escaping ([QueueEntry]) -> Void = { _ in },
                 engineChangedReason: @escaping () -> String = { "The engine changed since this game was queued" }) {
        self.file = file; self.engineID = engineID; self.busy = busy; self.start = start; self.packageBatch = packageBatch
        self.engineChangedReason = engineChangedReason
        let stored = file.map(BuildQueueFile.load) ?? (entries: [QueueEntry](), paused: false)
        var loaded = stored.entries
        let wasRunning = loaded.contains { $0.status == .running }
        // A build that was running when the app quit goes first again. Its folder keeps the finished stages.
        for index in loaded.indices where loaded[index].status == .running { loaded[index].status = .queued }
        let waiting = loaded.contains { $0.status == .queued }
        entries = loaded
        paused = stored.paused && waiting
        awaitingResume = !stored.paused && wasRunning
    }

    package var queued: [QueueEntry] { entries.filter { $0.status == .queued } }
    package var running: QueueEntry? { entries.first { $0.status == .running } }
    package var isEmpty: Bool { entries.isEmpty }
    package var hasWaiting: Bool { !queued.isEmpty }

    // MARK: Changing the queue

    /// Adds entries without starting an idle queue: the player reviews the queue and target settings, then starts it explicitly.
    /// Entries added while a batch is already running join the active batch.
    package func enqueue(_ new: [QueueEntry]) {
        guard !new.isEmpty else { return }
        if running == nil, !paused, !awaitingResume {
            entries.removeAll { $0.finished }
        }
        let currentBatch = running
        // A game that is already waiting is not queued twice.
        let waiting = Set(queued.map(\.titleID) + (running.map { [$0.titleID] } ?? []))
        var seen = waiting
        for var entry in new where !seen.contains(entry.titleID) {
            seen.insert(entry.titleID)
            entry.status = .queued; entry.reason = nil
            if active, !paused, !awaitingResume, let currentBatch {
                entry.target = currentBatch.target
                entry.batch = currentBatch.batch
                entry.packageAfter = currentBatch.packageAfter
                entry.exportIPA = currentBatch.exportIPA
                entry.destinationName = currentBatch.destinationName
            }
            entries.append(entry)
        }
        persist()
        if active { processNext() }
    }

    package func remove(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }), entry.status != .running else { return }
        entries.removeAll { $0.id == id }
        if !hasWaiting {
            awaitingResume = false
            paused = false
            if running == nil { active = false }
        }
        persist()
    }

    package func canMoveUp(_ id: UUID) -> Bool { queuedIndex(id).map { $0 > 0 } ?? false }
    package func canMoveDown(_ id: UUID) -> Bool { queuedIndex(id).map { $0 < queued.count - 1 } ?? false }

    package func moveUp(_ id: UUID) { move(id, by: -1) }
    package func moveDown(_ id: UUID) { move(id, by: 1) }

    private func queuedIndex(_ id: UUID) -> Int? { queued.firstIndex { $0.id == id } }

    private func move(_ id: UUID, by step: Int) {
        guard let q = queuedIndex(id), (0..<queued.count).contains(q + step) else { return }
        let other = queued[q + step].id
        guard let a = entries.firstIndex(where: { $0.id == id }), let b = entries.firstIndex(where: { $0.id == other }) else { return }
        entries.swapAt(a, b)
        persist()
    }

    /// "Cancel queued builds": the waiting entries go, the running one and the results stay.
    package func cancelQueued() {
        entries.removeAll { $0.status == .queued }
        awaitingResume = false
        paused = false
        if running == nil { active = false }
        persist()
    }

    // MARK: Running

    /// Starts the waiting queue, optionally applying the player's current target and shared-app packaging choice to the queued batch.
    package func start(target: String? = nil, packageAfter: Bool? = nil, exportIPA: Bool? = nil, destinationName: String? = nil) {
        guard hasWaiting else { return }
        if target != nil || packageAfter != nil || exportIPA != nil {
            let existingDoneBatch = entries.last(where: { $0.status == .done })?.batch
            let batch = existingDoneBatch ?? UUID()
            for index in entries.indices where entries[index].status == .queued {
                if let target { entries[index].target = target }
                if let packageAfter { entries[index].packageAfter = packageAfter }
                if let exportIPA { entries[index].exportIPA = exportIPA }
                entries[index].destinationName = destinationName
                entries[index].batch = batch
            }
        }
        active = true
        awaitingResume = false
        paused = false
        persist()
        processNext()
    }

    /// The player confirmed the queue from before the restart, or resumed a paused queue.
    package func resume() {
        active = true
        awaitingResume = false
        paused = false
        persist()
        processNext()
    }

    /// The running entry's build ended. `reason` names a failure, nil is success. `stopped`: the player pressed Stop, which ends this
    /// build and pauses the queue, so the next game does not start by itself.
    package func buildEnded(succeeded: Bool, reason: String? = nil, stopped: Bool = false) {
        guard let index = entries.firstIndex(where: { $0.status == .running }) else { return }
        entries[index].status = succeeded ? .done : .failed
        entries[index].reason = succeeded ? nil : reason
        let batch = entries[index].batch
        if stopped && !succeeded && hasWaiting {
            paused = true
            active = false
        }
        persist()
        if !entries.contains(where: { $0.batch == batch && ($0.status == .queued || $0.status == .running) }) { batchEnded(batch) }
        processNext()
        if running == nil && !hasWaiting { active = false }
    }

    /// The next waiting entry starts when nothing runs. An entry that cannot start is skipped with its reason, and the next one tries.
    package func processNext() {
        guard active, !awaitingResume, !paused, running == nil, !busy() else { return }
        while let index = entries.firstIndex(where: { $0.status == .queued }) {
            let entry = entries[index]
            if entry.engineID != engineID() {
                skip(index, engineChangedReason())
                continue
            }
            entries[index].status = .running
            persist()
            if let problem = start(entry) {
                guard let again = entries.firstIndex(where: { $0.id == entry.id }) else { continue }
                skip(again, problem)
                continue
            }
            return
        }
        if running == nil && !hasWaiting { active = false }
    }

    private func skip(_ index: Int, _ reason: String) {
        entries[index].status = .skipped
        entries[index].reason = reason
        let batch = entries[index].batch
        persist()
        if !entries.contains(where: { $0.batch == batch && ($0.status == .queued || $0.status == .running) }) { batchEnded(batch) }
    }

    private func batchEnded(_ batch: UUID) {
        let members = entries.filter { $0.batch == batch }
        let good = members.filter { $0.status == .done }
        guard members.contains(where: \.packageAfter), !good.isEmpty else { return }
        packageBatch(good)
    }

    private func persist() { if let file { BuildQueueFile.save(entries, paused: paused, to: file) } }
}
