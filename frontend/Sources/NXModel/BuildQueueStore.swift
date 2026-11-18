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
    private struct QueueKey: Hashable {
        let titleID: String
        let target: String

        init(titleID: String, target: String) {
            self.titleID = titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            self.target = BuildTarget.normalized(target)
        }
    }

    @Published package private(set) var entries: [QueueEntry]
    /// Entries from before a restart are waiting: nothing starts until the player confirms (`resume`) or drops them.
    @Published package private(set) var awaitingResume: Bool
    /// The player stopped the running build: the queue waits and starts nothing until `resume`. It survives a restart.
    @Published package private(set) var paused: Bool

    /// True once the player explicitly starts or resumes the queue, until the batch finishes, pauses, or is cancelled.
    @Published package private(set) var active = false
    private let file: URL?
    private let engineID: () -> String
    /// Starts the entry's build. nil: started. A string: why it cannot, which becomes the entry's reason.
    private let start: (QueueEntry) -> String?
    /// A shared-app batch ended with these successful entries: package them once.
    private let packageBatch: ([QueueEntry]) -> Bool
    /// A build or another operation is running, so nothing starts.
    private let busy: () -> Bool
    private let engineChangedReason: () -> String
    private let packageFailureReason: () -> String

    package init(file: URL?, engineID: @escaping () -> String, busy: @escaping () -> Bool,
                 start: @escaping (QueueEntry) -> String?, packageBatch: @escaping ([QueueEntry]) -> Bool = { _ in false },
                 engineChangedReason: @escaping () -> String = { "The engine changed since this game was queued" },
                 packageFailureReason: @escaping () -> String = { L10n.string("queue.cannotPackage", .en) }) {
        self.file = file; self.engineID = engineID; self.busy = busy; self.start = start; self.packageBatch = packageBatch
        self.engineChangedReason = engineChangedReason
        self.packageFailureReason = packageFailureReason
        let stored = file.map(BuildQueueFile.load) ?? (entries: [QueueEntry](), paused: false)
        var loaded = stored.entries
        for index in loaded.indices { loaded[index].target = BuildTarget.normalized(loaded[index].target) }
        let wasRunning = loaded.contains { $0.status == .running }
        let wasPackaging = loaded.contains { $0.packagePending != nil }
        for index in loaded.indices where loaded[index].packagePending != nil {
            loaded[index].packagePending = nil
            loaded[index].status = .queued
            loaded[index].reason = nil
        }
        // A build that was running when the app quit goes first again. Its folder keeps the finished stages.
        for index in loaded.indices where loaded[index].status == .running { loaded[index].status = .queued }
        let waiting = loaded.contains { $0.status == .queued }
        entries = loaded
        paused = stored.paused && waiting
        awaitingResume = !stored.paused && (wasRunning || wasPackaging)
    }

    package var games: [QueueGame] { QueueGame.grouped(entries) }
    package var packaging: [QueueEntry] { entries.filter { $0.packagePending == true } }
    package var hasIOS: Bool { queued.contains { BuildTarget.normalized($0.target) != BuildTarget.mac } }
    package var queued: [QueueEntry] { entries.filter { $0.status == .queued } }
    package var running: QueueEntry? { entries.first { $0.status == .running } }
    package var isEmpty: Bool { entries.isEmpty }
    package var hasWaiting: Bool { !queued.isEmpty }
    private var settledEntryIDs: Set<UUID> {
        Set(games.filter { $0.entries.allSatisfy { $0.finished && $0.packagePending == nil } }
            .flatMap(\.entries).map(\.id))
    }
    package var hasFinished: Bool { !settledEntryIDs.isEmpty }
    /// Includes the gap between automatically advancing jobs, but not a staged or paused queue.
    package var isAdvancing: Bool { active && !paused && !awaitingResume }

    // MARK: Changing the queue

    /// Adds entries without starting an idle queue: the player reviews the queue and target settings, then starts it explicitly.
    /// Duplicate game/platform requests merge without changing the running job.
    package func canEnqueue(_ titleID: String, target: String) -> Bool {
        let key = QueueKey(titleID: titleID, target: target)
        let group = entries.filter { $0.titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == key.titleID }
        guard let entry = group.first(where: { QueueKey(titleID: $0.titleID, target: $0.target) == key }) else { return true }
        return entry.finished && entry.packagePending == nil &&
            (entry.status != .done || group.allSatisfy { $0.status == .done && $0.packagePending == nil })
    }

    package func enqueue(_ new: [QueueEntry]) {
        guard !new.isEmpty else { return }
        for var entry in new {
            entry.target = BuildTarget.normalized(entry.target)
            entry.status = .queued; entry.reason = nil
            let key = QueueKey(titleID: entry.titleID, target: entry.target)
            let group = entries.filter { QueueKey(titleID: $0.titleID, target: $0.target).titleID == key.titleID }
            if let index = entries.firstIndex(where: { QueueKey(titleID: $0.titleID, target: $0.target) == key }) {
                let existing = entries[index]
                guard canEnqueue(entry.titleID, target: entry.target) else { continue }
                entry.id = existing.id
                entries[index] = entry
            } else if let first = entries.firstIndex(where: { QueueKey(titleID: $0.titleID, target: $0.target).titleID == key.titleID }) {
                let last = entries.lastIndex(where: { QueueKey(titleID: $0.titleID, target: $0.target).titleID == key.titleID })!
                let macFirst = entry.target == BuildTarget.mac && group.allSatisfy { $0.status == .queued }
                entries.insert(entry, at: macFirst ? first : last + 1)
            } else {
                entries.append(entry)
            }
        }
        persist()
        if active { processNext() }
    }

    package func remove(_ id: UUID) {
        guard let group = games.first(where: { $0.entries.contains { $0.id == id } }), !group.running else { return }
        let ids = Set(group.entries.filter { $0.packagePending == nil && (group.waiting ? $0.status == .queued : true) }.map(\.id))
        entries.removeAll { ids.contains($0.id) }
        if !hasWaiting {
            awaitingResume = false
            paused = false
            if running == nil { active = false }
        }
        persist()
    }

    private var movable: [QueueGame] { games.filter { $0.waiting && !$0.running } }
    package func canMoveUp(_ id: UUID) -> Bool { movable.firstIndex { $0.id == id }.map { $0 > 0 } ?? false }
    package func canMoveDown(_ id: UUID) -> Bool { movable.firstIndex { $0.id == id }.map { $0 < movable.count - 1 } ?? false }
    package func moveUp(_ id: UUID) { move(id, by: -1) }
    package func moveDown(_ id: UUID) { move(id, by: 1) }
    private func move(_ id: UUID, by step: Int) {
        guard let q = movable.firstIndex(where: { $0.id == id }), movable.indices.contains(q + step) else { return }
        let other = movable[q + step].id
        var groups = games
        guard let a = groups.firstIndex(where: { $0.id == id }), let b = groups.firstIndex(where: { $0.id == other }) else { return }
        groups.swapAt(a, b)
        entries = groups.flatMap(\.entries)
        persist()
    }

    /// Insert one waiting game beside another, preserving platform pairs and every non-movable row's position.
    package func move(_ id: UUID, relativeTo target: UUID, after: Bool) {
        var waiting = movable
        guard id != target, let from = waiting.firstIndex(where: { $0.id == id }),
              waiting.contains(where: { $0.id == target }) else { return }
        let source = waiting.remove(at: from)
        guard let destination = waiting.firstIndex(where: { $0.id == target }) else { return }
        waiting.insert(source, at: destination + (after ? 1 : 0))
        let ids = Set(waiting.map(\.id))
        var next = waiting.makeIterator()
        let reordered = games.map { ids.contains($0.id) ? (next.next() ?? $0) : $0 }
        entries = reordered.flatMap(\.entries)
        persist()
    }

    /// Retry failed, skipped, or stopped platform jobs under the current engine, keeping successful work intact.
    package func retry(_ id: UUID) {
        guard let group = games.first(where: { $0.id == id }), group.retryable else { return }
        let ids = Set(group.entries.filter { $0.status == .failed || $0.status == .skipped || $0.status == .stopped }.map(\.id))
        for index in entries.indices where ids.contains(entries[index].id) {
            entries[index].status = .queued; entries[index].reason = nil
            entries[index].engineID = engineID()
            entries[index].target = BuildTarget.normalized(entries[index].target)
        }
        persist()
    }

    /// Clears settled history without removing queued or shared-app packaging work.
    package func clearFinished() {
        let settled = settledEntryIDs
        entries.removeAll { settled.contains($0.id) }
        if !hasWaiting && running == nil && packaging.isEmpty {
            awaitingResume = false
            paused = false
            active = false
        }
        persist()
    }

    /// "Cancel queued builds": the waiting entries go, the running one and the results stay. When nothing runs, a shared-app batch
    /// has no job left, so its built games are packaged now, as Stop does (`buildEnded(stopped:)`). The build store holds them in
    /// `deferredShell` and would package them with the next batch otherwise. A running batch packages them when its build ends.
    package func cancelQueued() {
        entries.removeAll { $0.status == .queued }
        awaitingResume = false
        paused = false
        guard running == nil else { persist(); return }
        active = false
        persist()
        var ended: [UUID] = []
        for entry in entries where entry.packagePending == false && !ended.contains(entry.batch) { ended.append(entry.batch) }
        for batch in ended { batchEnded(batch) }
    }

    // MARK: Running

    /// Starts each job on its own platform, applying shared iOS delivery options to waiting iOS jobs.
    package func start(target: String? = nil, packageAfter: Bool? = nil, exportIPA: Bool? = nil, exportFramework: Bool? = nil, destinationName: String? = nil) {
        guard hasWaiting else { return }
        let normalizedStartTarget = target.map(BuildTarget.normalized)
        if target != nil || packageAfter != nil || exportIPA != nil || exportFramework != nil || destinationName != nil {
            let batch = UUID()
            let callerPassedMacOnlyDefaults = normalizedStartTarget == BuildTarget.mac
                && (packageAfter == nil || packageAfter == false)
                && exportIPA == nil
                && exportFramework == nil
                && destinationName == nil
            for index in entries.indices where entries[index].status == .queued {
                if !entries[index].locksTarget, let normalizedStartTarget {
                    entries[index].target = normalizedStartTarget
                }
                entries[index].target = BuildTarget.normalized(entries[index].target)
                entries[index].batch = batch
                guard entries[index].target != BuildTarget.mac else {
                    entries[index].packageAfter = false
                    entries[index].exportIPA = nil
                    entries[index].exportFramework = nil
                    entries[index].destinationName = nil
                    continue
                }
                if callerPassedMacOnlyDefaults && entries[index].locksTarget { continue }
                if let packageAfter { entries[index].packageAfter = packageAfter }
                if let exportIPA { entries[index].exportIPA = exportIPA }
                if let exportFramework { entries[index].exportFramework = exportFramework }
                entries[index].destinationName = destinationName
            }
        } else {
            for index in entries.indices where entries[index].status == .queued {
                entries[index].target = BuildTarget.normalized(entries[index].target)
                if entries[index].target == BuildTarget.mac {
                    entries[index].packageAfter = false
                    entries[index].exportIPA = nil
                    entries[index].exportFramework = nil
                    entries[index].destinationName = nil
                }
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
        entries[index].status = succeeded ? .done : (stopped ? .stopped : .failed)
        entries[index].reason = succeeded || stopped ? nil : reason
        if succeeded && entries[index].target != BuildTarget.mac && entries[index].packageAfter {
            entries[index].packagePending = false
        }
        let batch = entries[index].batch
        let titleID = entries[index].titleID
        if stopped && !succeeded {
            paused = hasWaiting
            active = false
        }
        persist()
        if stopped || !entries.contains(where: { $0.batch == batch && ($0.status == .queued || $0.status == .running) }) { batchEnded(batch) }
        processNext(preferredTitleID: titleID)
        if running == nil && !hasWaiting && packaging.isEmpty { active = false }
    }

    /// The next waiting entry starts when nothing runs. An entry that cannot start is skipped with its reason, and the next one tries.
    package func processNext(preferredTitleID: String? = nil) {
        var preferred = preferredTitleID
        guard active, !awaitingResume, !paused, running == nil, packaging.isEmpty, !busy() else { return }
        while let index = entries.firstIndex(where: { $0.status == .queued && $0.titleID.caseInsensitiveCompare(preferred ?? "") == .orderedSame })
            ?? entries.firstIndex(where: { $0.status == .queued }) {
            guard !busy(), packaging.isEmpty else { return }
            let entry = entries[index]
            preferred = entry.titleID
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
        if running == nil && !hasWaiting && packaging.isEmpty { active = false }
    }

    private func skip(_ index: Int, _ reason: String) {
        entries[index].status = .skipped
        entries[index].reason = reason
        let batch = entries[index].batch
        persist()
        if !entries.contains(where: { $0.batch == batch && ($0.status == .queued || $0.status == .running) }) { batchEnded(batch) }
    }

    private func batchEnded(_ batch: UUID) {
        let good = entries.filter { $0.batch == batch && $0.status == .done && $0.packagePending == false }
        guard !good.isEmpty else { return }
        let ids = Set(good.map(\.id))
        for index in entries.indices where ids.contains(entries[index].id) { entries[index].packagePending = true }
        persist()
        if !packageBatch(good) { packageEnded(succeeded: false) }
    }

    package func packageEnded(succeeded: Bool, reason: String? = nil, stopped: Bool = false) {
        for index in entries.indices where entries[index].packagePending == true {
            entries[index].packagePending = nil
            entries[index].status = succeeded ? .done : (stopped ? .stopped : .failed)
            entries[index].reason = succeeded || stopped ? nil : (reason ?? packageFailureReason())
        }
        if stopped { paused = hasWaiting; active = false }
        persist()
        processNext()
        if running == nil && !hasWaiting && packaging.isEmpty { active = false }
    }

    private func persist() { if let file { BuildQueueFile.save(entries, paused: paused, to: file) } }
}
