import Foundation

/// Steam's macOS virtual Xbox 360 device, not the physical Steam Controller.
/// Identity: SDL_iokitjoystick.c GetSteamVirtualGamepadSlot. Button/axis layout:
/// SDL_gamepad_db.h, macOS Xbox 360 entry (SDL commit 00d1538484d3c958b0d589ba16af775d4c033564).
package struct SteamVirtualGamepad {
    package static func slot(vendor: Int, product: Int, name: String, virtual: Bool, synthetic: Bool) -> Int? {
        guard vendor == 0x045e, product == 0x028e, virtual, !synthetic,
              name.hasPrefix("GamePad-"), let number = Int(name.dropFirst(8)),
              number > 0, name == "GamePad-\(number)" else { return nil }
        return number - 1
    }
    package var buttons: Set<Int> = []
    package var x: Float = 0, y: Float = 0
    package var dpadX: Float { (buttons.contains(15) ? 1 : 0) - (buttons.contains(14) ? 1 : 0) }
    package var dpadY: Float { (buttons.contains(12) ? 1 : 0) - (buttons.contains(13) ? 1 : 0) }
    package init() {}
    /// Returns false for elements outside the supported layout. Unrelated axes (including triggers)
    /// must not move menu focus. Descriptor ranges are used instead of assuming a signed 16-bit axis.
    package mutating func update(page: Int, usage: Int, value: Int, min: Int, max: Int) -> Bool {
        if page == 9, (1...15).contains(usage), min == 0, max == 1 {
            if value != 0 { buttons.insert(usage) } else { buttons.remove(usage) }
            return true
        }
        guard page == 1, usage == 0x30 || usage == 0x31, max > min else { return false }
        let normalized = Float(Swift.max(-1, Swift.min(1, 2 * (Double(value) - Double(min)) / (Double(max) - Double(min)) - 1)))
        if usage == 0x30 { x = normalized } else { y = normalized }
        return true
    }
}
