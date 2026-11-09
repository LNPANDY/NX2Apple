import Foundation

/// The stick deadzones of the Controls settings (#1025): "Use custom deadzones", then a left and a right stick in whole percent of the
/// travel (0 to 50). Off keeps what the engine does today, which is nothing beyond the controller's own report. On, the launcher starts
/// the game with DM_STICK_DEADZONE_L and DM_STICK_DEADZONE_R (dm/host/stick_deadzone.h, applied to every physical controller).
package struct StickDeadzoneSettings: Codable, Equatable, Sendable {
    package static let range = 0...50
    /// What the engine applies to a stick when nothing is set: no deadzone of its own, the controller's report goes through as it is.
    package static let engineDefault = 0

    package var custom: Bool
    package var left: Int
    package var right: Int

    package init(custom: Bool = false, left: Int = engineDefault, right: Int = engineDefault) {
        self.custom = custom
        self.left = Self.clamp(left)
        self.right = Self.clamp(right)
    }

    package static func clamp(_ percent: Int) -> Int { min(max(percent, range.lowerBound), range.upperBound) }

    /// The launch environment. Nothing while custom deadzones are off or both are 0, so a start without them is the start of today.
    package var environment: [String: String] {
        guard custom else { return [:] }
        var env: [String: String] = [:]
        if left > 0 { env["DM_STICK_DEADZONE_L"] = String(left) }
        if right > 0 { env["DM_STICK_DEADZONE_R"] = String(right) }
        return env
    }

    /// Back to the engine's behaviour: custom off and both sticks at the default.
    package static let reset = StickDeadzoneSettings()
    package var isDefault: Bool { self == Self.reset }

    /// What the engine does to a stick position (x and y in -1...1): the same radial rescale as dm/host/stick_deadzone.h, so the preview shows
    /// the real output. Inside the deadzone the stick reads centred, outside it the rest of the travel is spread over the full range,
    /// and a square-range diagonal beyond a full radius is left alone.
    package static func output(x: Double, y: Double, percent: Int) -> (x: Double, y: Double) {
        guard percent > 0 else { return (x, y) }
        let dz = Double(percent) / 100, radius = (x * x + y * y).squareRoot()
        if radius <= dz { return (0, 0) }
        if radius >= 1 { return (x, y) }
        let scale = (radius - dz) / ((1 - dz) * radius)
        return (max(-1, min(1, x * scale)), max(-1, min(1, y * scale)))
    }
}
