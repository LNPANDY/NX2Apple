import Foundation

/// A physical HID gamepad's state, read by the launcher's raw-HID fallback (`HIDGamepads`) for pads that
/// macOS 27's GameController does not list (an 8BitDo Ultimate 2C pairs over Bluetooth, is seen by IOKit,
/// yet `GCController.controllers()` stays empty: moonlight-stream/moonlight-qt#2017). Button usages follow
/// the pad's XInput-style descriptor (SDL's database, 2dc8:301b): a 1, b 2, x 4, y 5, lb 7, rb 8, lt 9,
/// rt 10, back 11, start 12, guide 13, l3 14, r3 15; the paddles are 3 and 6 and carry no launcher action.
/// The D-pad is the hat switch, 0 up and round clockwise to 7. HID y axes read up as a smaller value, the
/// launcher reads up as +1 (GameController's convention), so y is inverted here.
package struct HIDPadState: Equatable {
    package var a = false, b = false, x = false, y = false
    package var l = false, r = false
    package var back = false, start = false
    package var lx: Float = 0, ly: Float = 0, rx: Float = 0, ry: Float = 0
    /// The hat switch's last value: 0 up, 2 right, 4 down, 6 left, odd values the diagonals, anything
    /// outside 0...7 neutral.
    package var hat = -1
    package init() {}

    package var dpadX: Float {
        (0...7).contains(hat) ? Self.hatX[hat] : 0
    }
    package var dpadY: Float {
        (0...7).contains(hat) ? Self.hatY[hat] : 0
    }
    private static let hatX: [Float] = [0, 1, 1, 1, 0, -1, -1, -1]
    private static let hatY: [Float] = [1, 1, 0, -1, -1, -1, 0, 1]

    /// Returns false for elements outside the layout, so the pad's motion sensors (which report through
    /// the simulation pages) and any extra axes never move menu focus.
    package mutating func update(page: Int, usage: Int, value: Int, min: Int, max: Int) -> Bool {
        if page == 9, min == 0, max == 1, (1...15).contains(usage) {
            let down = value != 0
            switch usage {
            case 1: a = down
            case 2: b = down
            case 4: x = down
            case 5: y = down
            case 7: l = down
            case 8: r = down
            case 11: back = down
            case 12: start = down
            default: break   // paddles (3, 6), triggers (9, 10) and stick clicks (14, 15) have no launcher action
            }
            return true
        }
        guard page == 1, max > min else { return false }
        if usage == 0x39 {
            hat = (0...7).contains(value) ? value : -1
            return true
        }
        guard [0x30, 0x31, 0x32, 0x35].contains(usage) else { return false }
        let normalized = Float(Swift.max(-1, Swift.min(1, 2 * (Double(value) - Double(min)) / (Double(max) - Double(min)) - 1)))
        switch usage {
        case 0x30: lx = normalized
        case 0x31: ly = -normalized   // HID y reads up as a smaller value; the launcher reads up as +1
        case 0x32: rx = normalized
        case 0x35: ry = -normalized
        default: break
        }
        return true
    }
}
