import XCTest
@testable import NXModel

@MainActor final class LibrarySelectionStoreTests: XCTestCase {
    func testPinUpdatesPinnedIDAndIncrementsPinVersion() {
        let store = LibrarySelectionStore()
        XCTAssertNil(store.pinnedID)
        XCTAssertEqual(store.pinVersion, 0)

        let first = UUID()
        store.pin(first)
        XCTAssertEqual(store.pinnedID, first)
        XCTAssertEqual(store.pinVersion, 1)

        // Pinning the same ID again still bumps pinVersion so the row scrolls back to leading.
        store.pin(first)
        XCTAssertEqual(store.pinnedID, first)
        XCTAssertEqual(store.pinVersion, 2)

        let second = UUID()
        store.pin(second)
        XCTAssertEqual(store.pinnedID, second)
        XCTAssertEqual(store.pinVersion, 3)
    }

    func testClearPinResetsPinnedID() {
        let store = LibrarySelectionStore()
        store.pin(UUID())
        XCTAssertNotNil(store.pinnedID)
        store.clearPin()
        XCTAssertNil(store.pinnedID)
    }

    func testRevalidateClearsStalePinAndPreservesValidPin() {
        let valid = UUID()
        let missing = UUID()
        let store = LibrarySelectionStore()

        store.pin(valid)
        store.revalidate(validIDs: [valid, UUID()])
        XCTAssertEqual(store.pinnedID, valid)

        store.revalidate(validIDs: [missing])
        XCTAssertNil(store.pinnedID)
    }

    func testStoreStateIsTransientAcrossInstances() {
        let firstInstance = LibrarySelectionStore()
        firstInstance.pin(UUID())
        let freshLaunch = LibrarySelectionStore()
        XCTAssertNil(freshLaunch.pinnedID)
        XCTAssertEqual(freshLaunch.pinVersion, 0)
    }
}
