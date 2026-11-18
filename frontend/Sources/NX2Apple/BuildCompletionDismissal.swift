import SwiftUI
import NXLauncher

@MainActor final class BuildCompletionDismissal: ObservableObject {
    nonisolated static let duration: TimeInterval = 10
    @Published private(set) var startedAt: Date?
    @Published private(set) var expired = false
    private var key: String?

    // Keep the deadline when a sheet temporarily hides the indicator.
    func monitor(_ key: String?, duration: TimeInterval = 10) async {
        if self.key != key {
            self.key = key
            startedAt = key == nil ? nil : Date()
            expired = false
        }
        guard key != nil, let startedAt, !expired else { return }
        let remaining = max(0, duration - Date().timeIntervalSince(startedAt))
        do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
        guard !Task.isCancelled, self.key == key else { return }
        expired = true
    }
}

struct BuildCompletionTimerStroke: View {
    let startedAt: Date
    var console = false
    var lineWidth: CGFloat = 2
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let progress = min(1, max(0, context.date.timeIntervalSince(startedAt) / BuildCompletionDismissal.duration))
            GeometryReader { geometry in
                if console {
                    ConsoleEdgeOutline(inset: lineWidth / 2).trim(from: 0, to: progress).stroke(LauncherPalette.cream, lineWidth: lineWidth)
                } else {
                    Rectangle().fill(LauncherPalette.cream).frame(width: geometry.size.width * progress, height: 3)
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct BuildFooterExit: ViewModifier {
    let hidden: Bool
    func body(content: Content) -> some View { content.blur(radius: hidden ? 12 : 0) }
}
