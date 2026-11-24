import Foundation

/// Arranges the library's Recently played row with an optional temporary pinned selection at the front.
package enum LibraryPinOrder {
    /// Returns up to `limit` items in `ordered` with `pinnedID` placed first when present in `ordered`, deduplicated.
    package static func arrange<Element>(
        ordered: [Element],
        pinnedID: UUID?,
        limit: Int,
        id: (Element) -> UUID
    ) -> [Element] {
        guard limit > 0 else { return [] }
        guard let pinnedID,
              let pinned = ordered.first(where: { id($0) == pinnedID }) else {
            return Array(ordered.prefix(limit))
        }
        var result: [Element] = [pinned]
        result.reserveCapacity(min(limit, ordered.count))
        for item in ordered {
            if id(item) == pinnedID { continue }
            result.append(item)
            if result.count == limit { break }
        }
        return result
    }
}
