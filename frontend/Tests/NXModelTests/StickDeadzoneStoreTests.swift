import XCTest
@testable import NXModel
@testable import NXCore

@MainActor final class StickDeadzoneStoreTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "StickDeadzoneStoreTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    func testChangesPersistAndAResetRemovesTheEntry() {
        let d = defaults()
        let store = StickDeadzoneStore(defaults: d)
        XCTAssertTrue(store.settings.isDefault)
        store.setCustom(true); store.setLeft(18); store.setRight(60)
        XCTAssertEqual(store.settings, StickDeadzoneSettings(custom: true, left: 18, right: 50))
        XCTAssertEqual(StickDeadzoneStore(defaults: d).settings, store.settings, "kept for the next start of the launcher")
        store.reset()
        XCTAssertEqual(store.settings.environment, [:], "reset disables the custom values")
        XCTAssertNil(d.data(forKey: StickDeadzoneStore.key))
    }
}
