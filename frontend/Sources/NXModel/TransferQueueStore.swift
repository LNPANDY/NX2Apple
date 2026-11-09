import Foundation
import Combine
import NXCore

/// The transfer queue (LNPANDY/NX2Apple#1036): game data sent to devices one transfer at a time per device, beside any build.
/// What it needs from the app comes through `init`: `perform` sends one entry (it reports progress, then its result) and `cancelRunning`
/// asks the running send to stop. A transfer of a device that is not connected waits (`.waiting`) and goes on when `deviceConnected`
/// says the device is back. It never touches the build's stages or its `running` flag.
@MainActor package final class TransferQueueStore: ObservableObject {
    @Published package private(set) var entries: [TransferEntry]

    private let file: URL?
    private let perform: (TransferEntry, @escaping @MainActor (Int64, Int64) -> Void, @escaping @MainActor (TransferResult) -> Void) -> Void
    private let cancelRunning: (UUID) -> Void

    package init(file: URL?,
                 perform: @escaping (TransferEntry, @escaping @MainActor (Int64, Int64) -> Void, @escaping @MainActor (TransferResult) -> Void) -> Void,
                 cancelRunning: @escaping (UUID) -> Void = { _ in }) {
        self.file = file; self.perform = perform; self.cancelRunning = cancelRunning
        var loaded = (file.map(TransferQueueFile.load) ?? []).filter { $0.status != .cancelling }   // its send died with the app
        // A send the app quit in goes on from the verified parts: it waits for its device like any other.
        for i in loaded.indices where loaded[i].status == .sending { loaded[i].status = .waiting }
        entries = loaded
    }

    package var isEmpty: Bool { entries.isEmpty }

    /// Adds transfers. A game already queued, sending or waiting for the same device is not added twice. Finished and failed entries of
    /// the same game and device are replaced by the new one.
    package func enqueue(_ new: [TransferEntry]) {
        for entry in new {
            if entries.contains(where: { $0.active && $0.titleID == entry.titleID && $0.deviceID == entry.deviceID }) { continue }
            entries.removeAll { !$0.active && $0.titleID == entry.titleID && $0.deviceID == entry.deviceID }
            var added = entry; added.status = .queued; added.reason = nil
            entries.append(added)
        }
        persist()
        processNext()
    }

    /// Retry of a failed entry: it goes to the end of the line again and continues from the parts the device has.
    package func retry(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].status == .failed else { return }
        entries[i].status = .queued; entries[i].reason = nil
        persist()
        processNext()
    }

    /// Cancel removes a waiting, failed or finished entry at once. A running send is asked to stop and the row says "Cancelling" until
    /// the tool returns, then goes: it is never reported stopped before it was.
    package func cancel(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        if entries[i].status == .cancelling { return }
        if entries[i].status == .sending {
            entries[i].status = .cancelling
            persist()
            cancelRunning(id)
            return
        }
        entries.remove(at: i)
        persist()
        processNext()
    }

    /// The listing of devices says these are connected now: the entries that waited for them go on.
    package func deviceConnected(_ ids: Set<String>) {
        var changed = false
        for i in entries.indices where entries[i].status == .waiting && ids.contains(entries[i].deviceID) {
            entries[i].status = .queued; changed = true
        }
        if changed { persist() }
        processNext()
    }

    /// Whether any entry waits for a device, so the app knows to keep looking at the device list.
    package var hasWaiting: Bool { entries.contains { $0.status == .waiting } }

    package func processNext() {
        for i in entries.indices where entries[i].status == .queued {
            let device = entries[i].deviceID
            if entries.contains(where: { $0.status == .sending && $0.deviceID == device }) { continue }   // one at a time per device
            entries[i].status = .sending
            persist()
            let entry = entries[i], id = entry.id
            perform(entry, { [weak self] done, total in
                guard let self, let j = self.entries.firstIndex(where: { $0.id == id }), self.entries[j].status == .sending || self.entries[j].status == .cancelling else { return }
                self.entries[j].doneBytes = done; self.entries[j].totalBytes = total
            }, { [weak self] result in self?.finish(id, result) })
        }
    }

    private func finish(_ id: UUID, _ result: TransferResult) {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].status == .sending || entries[i].status == .cancelling else { return }
        if entries[i].status == .cancelling {   // the send returned: whatever it ended with, the player cancelled it
            entries.remove(at: i)
            persist()
            processNext()
            return
        }
        switch result {
        case .done:
            entries[i].status = .done; entries[i].doneBytes = max(entries[i].doneBytes, entries[i].totalBytes); entries[i].reason = nil
        case .deviceAbsent:
            entries[i].status = .waiting
        case .failed(let why):
            entries[i].status = .failed; entries[i].reason = why
        }
        persist()
        processNext()
    }

    private func persist() { if let file { TransferQueueFile.save(entries, to: file) } }
}
