import SwiftUI

/// How fast the launcher's motion plays: 1 everywhere in the app. The state gallery's Slow motion sets 0.25 on a scene, so a
/// transition can be watched (LNPANDY/NX2Apple#1459). DS.Motion's durations and the animations below read it, nothing else does.
private struct DSMotionSpeedKey: EnvironmentKey {
    static let defaultValue: Double = 1
}

extension EnvironmentValues {
    package var dsMotionSpeed: Double {
        get { self[DSMotionSpeedKey.self] }
        set { self[DSMotionSpeedKey.self] = newValue }
    }
}

extension DS.Motion {
    /// `animation` at the motion speed `speed` (1: unchanged), nil when the view reduces motion.
    package static func animation(_ animation: Animation?, speed: Double, reduceMotion: Bool = false) -> Animation? {
        guard !reduceMotion, let animation else { return nil }
        return speed == 1 ? animation : animation.speed(speed)
    }
    /// A duration of DS.Motion at the motion speed `speed`.
    package static func duration(_ seconds: Double, speed: Double) -> Double { speed > 0 ? seconds / speed : seconds }
}

extension View {
    /// An implicit animation at the scene's motion speed (`.animation(_:value:)` that Slow motion slows down).
    package func dsAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(DSSpeedAnimation(animation: animation, value: value))
    }
    /// The motion speed of the views below: the state gallery's Slow motion. The animations that read it (`dsAnimation`,
    /// `DS.Motion.animation(_:speed:)`) play at it.
    package func dsMotionSpeed(_ speed: Double) -> some View {
        environment(\.dsMotionSpeed, speed)
    }
}

private struct DSSpeedAnimation<V: Equatable>: ViewModifier {
    let animation: Animation?
    let value: V
    @Environment(\.dsMotionSpeed) private var speed
    func body(content: Content) -> some View {
        content.animation(DS.Motion.animation(animation, speed: speed), value: value)
    }
}
