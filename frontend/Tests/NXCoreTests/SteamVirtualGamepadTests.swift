import XCTest
@testable import NXCore

final class SteamVirtualGamepadTests: XCTestCase {
    func testOnlySteamVirtualXboxSlotsMatch() {
        XCTAssertEqual(SteamVirtualGamepad.slot(vendor: 0x045e, product: 0x028e, name: "GamePad-1", virtual: true, synthetic: false), 0)
        XCTAssertEqual(SteamVirtualGamepad.slot(vendor: 0x045e, product: 0x028e, name: "GamePad-4", virtual: true, synthetic: false), 3)
        for name in ["Xbox 360 Controller", "GamePad-0", "GamePad--1", "GamePad-1 extra", "GamePad-01"] {
            XCTAssertNil(SteamVirtualGamepad.slot(vendor: 0x045e, product: 0x028e, name: name, virtual: true, synthetic: false))
        }
        XCTAssertNil(SteamVirtualGamepad.slot(vendor: 0x054c, product: 0x028e, name: "GamePad-1", virtual: true, synthetic: false))
        XCTAssertNil(SteamVirtualGamepad.slot(vendor: 0x045e, product: 0x028f, name: "GamePad-1", virtual: true, synthetic: false))
        XCTAssertNil(SteamVirtualGamepad.slot(vendor: 0x045e, product: 0x028e, name: "GamePad-1", virtual: false, synthetic: false))
        XCTAssertNil(SteamVirtualGamepad.slot(vendor: 0x045e, product: 0x028e, name: "GamePad-1", virtual: true, synthetic: true))
    }

    func testMacXboxButtonsAndOpposingDirectionsReleaseIndependently() {
        var pad = SteamVirtualGamepad()
        for button in [1, 2, 3, 4, 5, 6, 9, 10, 12, 15] { _ = pad.update(page: 9, usage: button, value: 1, min: 0, max: 1) }
        XCTAssertEqual(pad.buttons, Set([1, 2, 3, 4, 5, 6, 9, 10, 12, 15]))
        XCTAssertEqual(pad.dpadX, 1)
        XCTAssertEqual(pad.dpadY, 1)
        _ = pad.update(page: 9, usage: 14, value: 1, min: 0, max: 1)
        XCTAssertEqual(pad.dpadX, 0)
        _ = pad.update(page: 9, usage: 15, value: 0, min: 0, max: 1)
        XCTAssertEqual(pad.dpadX, -1)
    }

    func testStickUsesDescriptorRangeAndMacPositiveYIsUp() {
        var pad = SteamVirtualGamepad()
        _ = pad.update(page: 1, usage: 0x30, value: -32768, min: -32768, max: 32767)
        _ = pad.update(page: 1, usage: 0x31, value: 32767, min: -32768, max: 32767)
        XCTAssertEqual(pad.x, -1)
        XCTAssertEqual(pad.y, 1)
        _ = pad.update(page: 1, usage: 0x30, value: 128, min: 0, max: 255)
        XCTAssertEqual(pad.x, 0, accuracy: 0.004)
        _ = pad.update(page: 1, usage: 0x30, value: 1000, min: 0, max: 255)
        XCTAssertEqual(pad.x, 1)
    }

    func testUnknownOrMalformedValuesCannotGenerateMenuActions() {
        var pad = SteamVirtualGamepad()
        XCTAssertFalse(pad.update(page: 1, usage: 0x30, value: 1, min: 0, max: 0))
        XCTAssertFalse(pad.update(page: 1, usage: 0x32, value: 32767, min: -32768, max: 32767))
        XCTAssertFalse(pad.update(page: 7, usage: 1, value: 1, min: 0, max: 1))
        XCTAssertFalse(pad.update(page: 9, usage: 16, value: 1, min: 0, max: 1))
        XCTAssertTrue(pad.buttons.isEmpty)
        XCTAssertEqual(pad.x, 0)
    }
}
