import XCTest
@testable import NXCore

final class LibraryPinOrderTests: XCTestCase {
    private struct Item: Equatable {
        let id: UUID
        let label: String
    }

    private func makeItems(_ count: Int) -> [Item] {
        (0..<count).map { Item(id: UUID(), label: "Game \($0)") }
    }

    func testWithoutPinPreservesPersistentOrderUpToLimit() {
        let items = makeItems(12)
        let arranged = LibraryPinOrder.arrange(ordered: items, pinnedID: nil, limit: 10, id: \.id)
        XCTAssertEqual(arranged, Array(items.prefix(10)))
    }

    func testPinningItemBeyondLimitPlacesItFirstAndTrimsTail() {
        let items = makeItems(12)
        let pinned = items[11]
        let arranged = LibraryPinOrder.arrange(ordered: items, pinnedID: pinned.id, limit: 10, id: \.id)
        XCTAssertEqual(arranged.count, 10)
        XCTAssertEqual(arranged.first, pinned)
        XCTAssertEqual(Array(arranged.dropFirst()), Array(items.prefix(9)))
        XCTAssertEqual(Set(arranged.map(\.id)).count, 10)
    }

    func testPinningItemAlreadyInsideRowMovesItFirstWithoutDuplication() {
        let items = makeItems(12)
        let pinned = items[3]
        let arranged = LibraryPinOrder.arrange(ordered: items, pinnedID: pinned.id, limit: 10, id: \.id)
        XCTAssertEqual(arranged.count, 10)
        XCTAssertEqual(arranged.first, pinned)
        XCTAssertEqual(arranged.filter { $0.id == pinned.id }.count, 1)
        let expectedTail = Array(items[0..<3]) + Array(items[4..<10])
        XCTAssertEqual(Array(arranged.dropFirst()), expectedTail)
    }

    func testReplacingPinRestoresPreviousPinnedItemToPersistentOrder() {
        let items = makeItems(12)
        let first = LibraryPinOrder.arrange(ordered: items, pinnedID: items[11].id, limit: 10, id: \.id)
        XCTAssertEqual(first.first, items[11])

        // Pinning an item inside the row drops the out-of-range item (items[11]) back out of the row
        let second = LibraryPinOrder.arrange(ordered: items, pinnedID: items[4].id, limit: 10, id: \.id)
        XCTAssertEqual(second.first, items[4])
        XCTAssertFalse(second.contains(items[11]))

        // Pinning item 10 keeps item 4 at its persistent position (after items 0..3)
        let third = LibraryPinOrder.arrange(ordered: items, pinnedID: items[10].id, limit: 10, id: \.id)
        XCTAssertEqual(third.first, items[10])
        XCTAssertEqual(third[5], items[4])
    }

    func testMissingOrStalePinnedIDFallsBackToPersistentOrder() {
        let items = makeItems(5)
        let arranged = LibraryPinOrder.arrange(ordered: items, pinnedID: UUID(), limit: 10, id: \.id)
        XCTAssertEqual(arranged, items)
    }

    func testZeroLimitReturnsEmpty() {
        let items = makeItems(3)
        XCTAssertEqual(LibraryPinOrder.arrange(ordered: items, pinnedID: items[0].id, limit: 0, id: \.id), [])
    }
}
