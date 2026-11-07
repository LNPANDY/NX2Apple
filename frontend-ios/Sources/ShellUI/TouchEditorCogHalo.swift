import SwiftUI

/// A brief reminder after inactivity; the glass button and its hit target never animate.
struct TouchEditorCogHalo: View {
    var active: Bool
    var activity: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = 0

    private struct Glow {
        var scale: CGFloat = 1
        var opacity: Double = 0
    }

    var body: some View {
        let reduced = reduceMotion
        Circle()
            .stroke(ShellPalette.cream, lineWidth: 5)
            .frame(width: 44, height: 44)
            .blur(radius: 2)
            .keyframeAnimator(initialValue: Glow(), trigger: pulse) { halo, value in
                halo.scaleEffect(reduced ? 1.15 : value.scale)
                    .opacity(reduced ? 0.65 : value.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    SpringKeyframe(1.6, duration: 1, spring: .smooth)
                    MoveKeyframe(1)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1, duration: 0.15)
                    LinearKeyframe(0, duration: 0.85)
                }
            }
            .opacity(active ? 1 : 0)
            .task(id: active && !reduceMotion ? activity : nil) {
                guard active, !reduceMotion else { return }
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(2))
                        pulse &+= 1
                    }
                } catch { /* Leaving the editor or interacting cancels the idle wait. */ }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
