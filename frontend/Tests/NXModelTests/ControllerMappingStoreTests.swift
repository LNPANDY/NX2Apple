import XCTest
@testable import NXCore
@testable import NXModel

@MainActor final class ControllerMappingStoreTests: XCTestCase {
    func testPartialEditsReloadExternalStateWithoutClobberingOtherFields() {
        let memory = MappingMemory()
        let preferences = ControllerPreferences(storage: memory)
        let store = ControllerMappingStore(preferences: preferences)
        memory.values[ControllerPreferences.steamKey] = ["future": "keep", "buttons": ["16": 63], "pads": [0, 2]]
        memory.values["launcher.DM_PAD_MAP"] = "A=Shake"
        store.setGyro(false)
        XCTAssertEqual(store.steam.buttons, [16: 63])
        XCTAssertEqual(store.steam.pads, [0, 2])
        XCTAssertFalse(store.steam.gyro)
        XCTAssertEqual(store.padMap, "A=Shake")
        store.setButton(17, target: 4)
        store.setPad(1, mode: 3)
        XCTAssertEqual(store.steam.buttons, [16: 63, 17: 4])
        XCTAssertEqual(store.steam.pads, [0, 3])
        memory.values["launcher.DM_KEYMAP"] = "A=40"
        store.refresh()
        XCTAssertEqual(store.keyMap, "A=40")
        store.setMap("DM_KEYMAP", value: nil)
        XCTAssertEqual(memory.values["launcher.DM_PAD_MAP"] as? String, "A=Shake")
        XCTAssertEqual((memory.values[ControllerPreferences.steamKey] as? [String: Any])?["future"] as? String, "keep")
    }
    func testCopyGlobalOverwritesOnlyStandardMapsAndRetainsExtras() {
        let memory = MappingMemory()
        memory.values[ControllerPreferences.steamKey] = ["buttons": ["16": 63], "pads": [2, 3], "future": "keep"]
        memory.values["launcher.DM_FPS_TARGET"] = "60"
        let store = ControllerMappingStore(preferences: ControllerPreferences(storage: memory))
        store.copyStandardMaps(["DM_KEYMAP": "A=40", "DM_PAD_MAP": "A=B", "DM_PAD_MERGE": "1"])
        XCTAssertEqual(store.keyMap, "A=40")
        XCTAssertEqual(store.padMap, "A=B")
        XCTAssertEqual(store.steam.buttons, [16: 63])
        XCTAssertEqual(store.steam.pads, [2, 3])
        XCTAssertEqual(memory.values["launcher.DM_FPS_TARGET"] as? String, "60")
        XCTAssertNil(memory.values["launcher.DM_PAD_MERGE"])
        store.copyStandardMaps([:])
        XCTAssertNil(store.keyMap)
        XCTAssertNil(store.padMap)
        XCTAssertEqual(store.steam.buttons, [16: 63])
    }
    func testRetainedActionsRespectSavingDisabledAfterOpening() {
        let memory = MappingMemory()
        var allowed = true
        let store = ControllerMappingStore(preferences: ControllerPreferences(storage: memory), canSave: { allowed })
        store.setButton(16, target: 0)
        let retainedButtonAction = { store.setButton(16, target: 63) }
        let before = NSDictionary(dictionary: memory.values)
        memory.writeCount = 0
        allowed = false
        retainedButtonAction()
        store.setPad(0, mode: 2)
        store.setGyro(false)
        store.resetSteam()
        store.setMap("DM_KEYMAP", value: "A=40")
        store.copyStandardMaps(["DM_PAD_MAP": "A=B"])
        XCTAssertEqual(memory.writeCount, 0)
        XCTAssertEqual(NSDictionary(dictionary: memory.values), before)
        XCTAssertEqual(store.steam.buttons, [16: 0])
        allowed = true
        retainedButtonAction()
        XCTAssertEqual(store.steam.buttons, [16: 63])
        XCTAssertGreaterThan(memory.writeCount, 0)
    }
    func testSaveFailureIsVisibleAndSuccessfulRetryClearsIt() {
        let memory = MappingMemory()
        let store = ControllerMappingStore(preferences: ControllerPreferences(storage: memory))
        memory.syncOK = false
        store.setButton(16, target: 63)
        XCTAssertTrue(store.saveFailed)
        memory.syncOK = true
        store.setButton(16, target: -1)
        XCTAssertFalse(store.saveFailed)
        XCTAssertTrue(store.steam.buttons.isEmpty)
    }
}
private final class MappingMemory: ControllerPreferenceStorage {
    var values: [String: Any] = [:]
    var syncOK = true
    var writeCount = 0
    func read(_ key: String) -> Any? { values[key] }
    func write(_ key: String, value: Any?) { writeCount += 1; values[key] = value }
    func synchronize() -> Bool { syncOK }
}
