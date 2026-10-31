import SwiftUI

/// The Dock icon mirrors a running build: a dark tile with the share of the work done, so a build's
/// progress is visible from wherever the launcher was left.
enum DockProgress {
    /// The text the tile shows for a progress fraction; nil clears the tile. Pure, so tests run it.
    static func percentText(_ fraction: Double?) -> String? {
        guard let fraction, fraction.isFinite, fraction >= 0, fraction <= 1 else { return nil }
        return "\(Int((fraction * 100).rounded()))%"
    }

    /// Reflects the running build on the Dock tile; nil restores the plain icon.
    static func update(_ fraction: Double?) {
        let dock = NSApplication.shared.dockTile
        guard let text = percentText(fraction) else {
            dock.contentView = nil
            dock.display()
            return
        }
        let done = min(max(fraction ?? 0, 0), 1)
        let view = NSHostingView(rootView:
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(Color.black)
                VStack(spacing: 6) {
                    Circle().trim(from: 0, to: done).stroke(Color(red: 1.0, green: 0.85, blue: 0.62),
                                                                style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 52, height: 52)
                    Text(text).font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.white)
                }
            }
            .preferredColorScheme(.dark)
        )
        dock.contentView = view
        dock.display()
    }
}
