import SwiftUI

/// The controller moves the selection row by row, and a row it reaches may be outside the list's visible part. The list
/// hands its scroll view's proxy here, and `reveal` scrolls the row into view by the least distance, as the table did.
final class BuildTableNavigation: ObservableObject {
    var scroll: ((UUID) -> Void)?
    func reveal(_ id: UUID) { scroll?(id) }
}

/// Arrow keys on the Builds list. Up and down move the selection one row and stop at the ends. With no row selected,
/// down selects the first row and up the last.
enum BuildListKeys {
    static func moved(from selection: UUID?, by step: Int, in ids: [UUID]) -> UUID? {
        guard !ids.isEmpty else { return nil }
        guard let selection, let at = ids.firstIndex(of: selection) else { return step > 0 ? ids.first : ids.last }
        return ids[min(max(at + step, 0), ids.count - 1)]
    }
}
