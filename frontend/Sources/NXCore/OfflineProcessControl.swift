import Foundation

/// Synchronizes Stop with a signer that starts on the preparation queue.
package final class OfflineProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var leader: Int32?
    private let end: @Sendable (Int32) -> Void
    package init(end: @escaping @Sendable (Int32) -> Void = { ProcessGroups.endGroup($0) }) { self.end = end }
    package func reset() { lock.lock(); stopped = false; leader = nil; lock.unlock() }
    package func started(_ pid: Int32) {
        lock.lock(); leader = pid; let cancel = stopped; lock.unlock()
        if cancel { end(pid) }
    }
    package func ended() { lock.lock(); leader = nil; lock.unlock() }
    package func stop() {
        lock.lock(); stopped = true; let pid = leader; lock.unlock()
        if let pid { end(pid) }
    }
}
