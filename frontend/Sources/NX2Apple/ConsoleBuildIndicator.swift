import SwiftUI

/// Open at the display edge so neither the border nor its timer draws a left seam (the desktop's build footer timer, BuildCompletionDismissal).
/// The console's build indicator is in ConsoleTopBar.swift.
struct ConsoleEdgeOutline: Shape {
    var inset: CGFloat = 1
    func path(in rect: CGRect) -> Path {
        let radius = max(0, (rect.height - 2 * inset) / 2)
        return Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + inset))
            path.addLine(to: CGPoint(x: rect.maxX - radius - inset, y: rect.minY + inset))
            path.addArc(center: CGPoint(x: rect.maxX - radius - inset, y: rect.midY), radius: radius,
                        startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - inset))
        }
    }
}
