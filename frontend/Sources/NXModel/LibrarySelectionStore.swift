import Combine
import Foundation
import NXCore

/// Holds the session-only temporary pinned selection for the library's Recently played row.
/// Never persisted to disk so restarts return to the persistent play-recency order.
@MainActor package final class LibrarySelectionStore: ObservableObject {
    @Published package private(set) var pinnedID: UUID?
    @Published package private(set) var pinVersion: UInt64 = 0

    package init(pinnedID: UUID? = nil) {
        self.pinnedID = pinnedID
    }

    /// Pins `id` to the front of the Recently played row and requests a scroll back to the leading edge.
    package func pin(_ id: UUID) {
        pinnedID = id
        pinVersion &+= 1
    }

    /// Clears any temporary pin (for example after launching a game records it in play history).
    package func clearPin() {
        guard pinnedID != nil else { return }
        pinnedID = nil
    }

    /// Clears the temporary pin when the pinned game is no longer valid in the current library or filter.
    package func revalidate(validIDs: Set<UUID>) {
        guard let pinnedID, !validIDs.contains(pinnedID) else { return }
        self.pinnedID = nil
    }
}
