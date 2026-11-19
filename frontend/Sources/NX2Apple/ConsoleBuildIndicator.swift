import SwiftUI
import NXCore
import NXLauncher

/// The queue's compact monitor shares its measured progress, artwork and outcome with the queue panel.
struct ConsoleBuildIndicator: View {
    let row: ConsoleBuilds.QueueRow
    let lang: Lang
    let gutter: CGFloat
    let compact: Bool
    var completedAt: Date? = nil
    let open: () -> Void
    @EnvironmentObject private var pad: PadFocus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func height(compact: Bool) -> CGFloat { ConsoleClock.fontSize(compact: compact) + (compact ? 12 : 16) }
    private var height: CGFloat { Self.height(compact: compact) }
    private var artSize: CGFloat { ConsoleClock.fontSize(compact: compact) }
    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                               bottomTrailingRadius: height / 2, topTrailingRadius: height / 2)
    }
    private var borderWidth: CGFloat { pad.visible && pad.focused == "console.build.activity" ? 4 : 2 }
    private var progress: Double { row.outcome == .failure ? 0 : row.outcome == .success ? 1 : min(max(row.progress ?? 0, 0), 1) }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Group {
                    if let icon = row.icon { Image(nsImage: icon).resizable().scaledToFill() }
                    else { Image(systemName: "gamecontroller.fill").frame(maxWidth: .infinity, maxHeight: .infinity).background(LauncherPalette.surface) }
                }
                .frame(width: artSize, height: artSize).clipShape(RoundedRectangle(cornerRadius: 6))
                .saturation(row.outcome == .failure ? 0 : 1)
                .overlay(alignment: .bottomTrailing) {
                    if let outcome = row.outcome {
                        ArtworkOutcomeBadge(outcome == .success ? .success : outcome == .warning ? .warning : .failure, artworkSize: artSize)
                            .offset(x: -artSize * 0.06, y: -artSize * 0.06)
                    }
                }
                .id(row.id).transition(.opacity)
                Spacer(minLength: 0)
                Group {
                    if row.outcome == .failure { Image(systemName: "xmark").foregroundStyle(LauncherPalette.danger) }
                    else if row.outcome == .warning { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(LauncherPalette.building) }
                    else if row.progress != nil || row.outcome == .success {
                        Text(String(format: L10n.string("console.batteryPercent", lang), Int(progress * 100))).monospacedDigit()
                    } else { ProgressView().controlSize(.small).tint(.white) }
                }.font(.manrope(artSize * 0.55, .bold)).lineLimit(1).minimumScaleFactor(0.85).frame(maxWidth: compact ? 70 : 76, alignment: .trailing)
            }
            .padding(.leading, gutter).padding(.trailing, 16)
            .frame(height: height)
            .background {
                if let image = row.artwork ?? row.icon { BuildFooterReveal(image: image, progress: progress).saturation(row.outcome == .failure ? 0 : 1).id(row.id).transition(.opacity) }
                else { LauncherPalette.surface }
            }
            .clipShape(shape)
            .overlay {
                if pad.visible && pad.focused == "console.build.activity" {
                    ConsoleEdgeOutline(inset: borderWidth / 2).stroke(LauncherPalette.cream, lineWidth: borderWidth)
                }
            }
            .overlay { if let completedAt { BuildCompletionTimerStroke(startedAt: completedAt, console: true, lineWidth: borderWidth) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel(L10n.string("console.builds", lang) + ", " + row.name)
        .accessibilityValue(row.outcome.map { L10n.string($0 == .success ? "queue.status.done" : $0 == .warning ? "queue.status.skipped" : "queue.status.failed", lang) }
            ?? row.progress.map { String(format: L10n.string("console.batteryPercent", lang), Int(min(max($0, 0), 1) * 100)) } ?? L10n.string("library.preparing", lang))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: row.outcome)
        .animation(LibraryHeroTransition.queue(reduceMotion: reduceMotion), value: row.id)
    }
}

/// Open at the display edge so neither the border nor its timer draws a left seam.
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

/// The clock alone determines width, including its leading gutter.
struct ConsoleClockBuildLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let clock = subviews[0].sizeThatFits(.unspecified)
        let indicator = subviews[1].sizeThatFits(.init(width: clock.width, height: nil))
        return CGSize(width: clock.width, height: clock.height + 19 + indicator.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let clock = subviews[0].sizeThatFits(.unspecified)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: .init(clock))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + clock.height + 19), anchor: .topLeading,
                          proposal: .init(width: clock.width, height: nil))
    }
}

struct ConsoleIndicatorMotion: ViewModifier {
    let opacity: Double
    let blur: CGFloat
    func body(content: Content) -> some View { content.opacity(opacity).blur(radius: blur) }
    static let transition = AnyTransition.asymmetric(
        insertion: .move(edge: .leading).combined(with: .modifier(active: Self(opacity: 0.6, blur: 8), identity: Self(opacity: 1, blur: 0))),
        removal: .move(edge: .leading).combined(with: .modifier(active: Self(opacity: 0.4, blur: 8), identity: Self(opacity: 1, blur: 0))))
}
