import SwiftUI

/// A brief reminder after inactivity; the glass button and its hit target never animate.
struct TouchEditorCogHalo: View {
    var active: Bool
    var activity: Int
    var center: CGPoint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulseStart: Date?

    var body: some View {
        if !reduceMotion {
            Group {
                if active, let pulseStart {
                    TimelineView(.animation) { timeline in
                        let progress = min(max(timeline.date.timeIntervalSince(pulseStart), 0), 1)
                        let drawing = Self.glow(at: progress)
                        Canvas { context, _ in
                            guard drawing.opacity > 0.001 else { return }
                            let radius = 22 * drawing.scale
                            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                            var blurred = context
                            blurred.opacity = drawing.opacity
                            blurred.addFilter(.blur(radius: 2))
                            blurred.stroke(Path(ellipseIn: rect), with: .color(ShellPalette.cream), lineWidth: 5)
                        }
                    }
                }
            }
            .task(id: active ? activity : nil) {
                guard active else {
                    pulseStart = nil
                    return
                }
                pulseStart = nil
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(2))
                        pulseStart = .now
                        try await Task.sleep(for: .seconds(1))
                        pulseStart = nil
                    }
                } catch {
                    pulseStart = nil
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private static func glow(at t: TimeInterval) -> (scale: CGFloat, opacity: Double) {
        let ease = 1 - pow(1 - min(max(t, 0), 1), 3)
        let scale = 1 + 0.6 * ease
        let opacity = t < 0.15 ? (t / 0.15) : max(0, 1 - (t - 0.15) / 0.85)
        return (scale, opacity)
    }
}
