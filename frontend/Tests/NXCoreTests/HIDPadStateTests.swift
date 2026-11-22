import XCTest
@testable import NXCore

final class HIDPadStateTests: XCTestCase {
    func testButtonUsagesFollowThe8BitDoBluetoothDescriptor() {
        // SDL's database for the 2dc8:301b pad over Bluetooth: a 1, b 2, x 4, y 5 (verified live on
        // macOS 27.2: pressing X read usage 4 and Y read usage 5, twice each).
        XCTAssertEqual(Self.state(afterPress: 1).a, true)
        XCTAssertEqual(Self.state(afterPress: 2).b, true)
        XCTAssertEqual(Self.state(afterPress: 4).x, true)
        XCTAssertEqual(Self.state(afterPress: 5).y, true)
        XCTAssertEqual(Self.state(afterPress: 7).l, true)
        XCTAssertEqual(Self.state(afterPress: 8).r, true)
        XCTAssertEqual(Self.state(afterPress: 11).back, true)
        XCTAssertEqual(Self.state(afterPress: 12).start, true)
        // The paddles (3, 6), the triggers (9, 10) and the stick clicks (14, 15) carry no launcher action.
        for usage in [3, 6, 9, 10, 14, 15] {
            XCTAssertEqual(Self.state(afterPress: usage), HIDPadState(), "usage \(usage) must stay unmapped")
        }
    }

    func testPressAndReleaseRoundTrip() {
        var state = HIDPadState()
        XCTAssertTrue(state.update(page: 9, usage: 1, value: 1, min: 0, max: 1))
        XCTAssertTrue(state.a)
        XCTAssertTrue(state.update(page: 9, usage: 1, value: 0, min: 0, max: 1))
        XCTAssertFalse(state.a)
    }

    func testOutsideTheLayoutReturnsFalse() {
        var state = HIDPadState()
        // The pad's motion sensors report through the simulation pages.
        XCTAssertFalse(state.update(page: 2, usage: 0xC4, value: 128, min: 0, max: 255))
        XCTAssertFalse(state.update(page: 2, usage: 0xC5, value: 128, min: 0, max: 255))
        // Button 16 and axes outside the descriptor never move the menu either.
        XCTAssertFalse(state.update(page: 9, usage: 16, value: 1, min: 0, max: 1))
        XCTAssertFalse(state.update(page: 1, usage: 0x36, value: 128, min: 0, max: 255))
        XCTAssertEqual(state, HIDPadState())
    }

    func testSticksNormalizeAndInvertY() {
        var state = HIDPadState()
        XCTAssertTrue(state.update(page: 1, usage: 0x30, value: 255, min: 0, max: 255))
        XCTAssertTrue(state.update(page: 1, usage: 0x31, value: 255, min: 0, max: 255))
        XCTAssertEqual(state.lx, 1)
        XCTAssertEqual(state.ly, -1, "HID y reads down as the larger value; the launcher reads up as +1")
        XCTAssertTrue(state.update(page: 1, usage: 0x32, value: 0, min: 0, max: 255))
        XCTAssertTrue(state.update(page: 1, usage: 0x35, value: 0, min: 0, max: 255))
        XCTAssertEqual(state.rx, -1)
        XCTAssertEqual(state.ry, 1)
        XCTAssertTrue(state.update(page: 1, usage: 0x30, value: 128, min: 0, max: 255))
        XCTAssertEqual(state.lx, 0.003921_829, accuracy: 0.001)
    }

    func testHatSwitchDirectionsAndNeutral() {
        var state = HIDPadState()
        XCTAssertTrue(state.update(page: 1, usage: 0x39, value: 0, min: 0, max: 7))
        XCTAssertEqual(state.dpadX, 0); XCTAssertEqual(state.dpadY, 1, "0 is up")
        XCTAssertTrue(state.update(page: 1, usage: 0x39, value: 2, min: 0, max: 7))
        XCTAssertEqual(state.dpadX, 1); XCTAssertEqual(state.dpadY, 0)
        XCTAssertTrue(state.update(page: 1, usage: 0x39, value: 4, min: 0, max: 7))
        XCTAssertEqual(state.dpadX, 0); XCTAssertEqual(state.dpadY, -1)
        XCTAssertTrue(state.update(page: 1, usage: 0x39, value: 6, min: 0, max: 7))
        XCTAssertEqual(state.dpadX, -1); XCTAssertEqual(state.dpadY, 0)
        XCTAssertTrue(state.update(page: 1, usage: 0x39, value: 7, min: 0, max: 7))
        XCTAssertEqual(state.dpadX, -1); XCTAssertEqual(state.dpadY, 1, "7 is up-left")
        // Anything outside 0...7 is neutral: the descriptor has no in-range rest value.
        XCTAssertTrue(state.update(page: 1, usage: 0x39, value: 8, min: 0, max: 7))
        XCTAssertEqual(state.dpadX, 0); XCTAssertEqual(state.dpadY, 0)
        XCTAssertTrue(state.update(page: 1, usage: 0x39, value: -1, min: 0, max: 7))
        XCTAssertEqual(state.dpadX, 0); XCTAssertEqual(state.dpadY, 0)
    }

    func testDiagonalHatReadsBothAxes() {
        var state = HIDPadState()
        XCTAssertTrue(state.update(page: 1, usage: 0x39, value: 1, min: 0, max: 7))
        XCTAssertEqual(state.dpadX, 1); XCTAssertEqual(state.dpadY, 1)
    }

    private static func state(afterPress usage: Int) -> HIDPadState {
        var state = HIDPadState()
        _ = state.update(page: 9, usage: usage, value: 1, min: 0, max: 1)
        return state
    }
}
