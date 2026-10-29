import Foundation

/// Wires a pipe's read end to a callback and detaches at end of output.
///
/// A `readabilityHandler` fires whenever the descriptor is readable, and at end of output (every writer has
/// closed) it stays readable forever: `availableData` returns empty data at once, the handler returns, and
/// the dispatch source fires again, which pins a CPU core (#201). So the handler removes itself the moment it
/// reads empty data.
enum PipeReader {
    /// `onData` gets each non-empty chunk on a background queue. Returns when nothing more will arrive: the
    /// handler is nil by then.
    static func attach(to handle: FileHandle, onData: @escaping (Data) -> Void) {
        handle.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            onData(d)
        }
    }
}
