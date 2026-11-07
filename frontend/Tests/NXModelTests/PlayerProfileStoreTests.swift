import XCTest
import NXCore
@testable import NXModel

@MainActor final class PlayerProfileStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        (suite, defaults) = TestDefaults.suite("PlayerProfileStoreTests")
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testStartsWithTheDefaultPlayer() {
        let store = PlayerProfileStore(defaults: defaults)
        XCTAssertEqual(store.profiles.map(\.id), [PlayerProfile.defaultID])
        XCTAssertTrue(store.active.isDefault)
        XCTAssertEqual(store.displayName(store.active), "Player 1")
    }

    func testCreateSelectsAndPersists() {
        let store = PlayerProfileStore(defaults: defaults)
        XCTAssertNotNil(store.create(name: "  Ana "))
        XCTAssertEqual(store.active.name, "Ana")
        XCTAssertNil(store.create(name: "ana"), "names are unique, ignoring case")
        XCTAssertNil(store.create(name: "   "))
        let again = PlayerProfileStore(defaults: defaults)
        XCTAssertEqual(again.profiles.count, 2)
        XCTAssertEqual(again.active.id, "ana")
    }

    func testRenameKeepsTheFolder() {
        let store = PlayerProfileStore(defaults: defaults)
        store.create(name: "Ana")
        store.rename("ana", to: "Anna")
        XCTAssertEqual(store.active.id, "ana")
        XCTAssertEqual(store.active.name, "Anna")
    }

    func testRemoveFallsBackToDefaultAndKeepsDefault() {
        let store = PlayerProfileStore(defaults: defaults)
        store.create(name: "Ana")
        store.remove(PlayerProfile.defaultID)
        XCTAssertEqual(store.profiles.count, 2)
        store.remove("ana")
        XCTAssertTrue(store.active.isDefault)
        XCTAssertEqual(store.profiles.count, 1)
    }
}
