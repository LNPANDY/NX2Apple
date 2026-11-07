import SwiftUI

/// Pointer feedback adds no size or movement, and leaves the control's selection and keyboard focus alone.
private struct LauncherHover: ViewModifier {
    let allowed: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .brightness(allowed && enabled && hovered ? 0.045 : 0)
            .background(LauncherHoverRegion(enabled: allowed && enabled) { hovered = $0 })
            .onDisappear { hovered = false }
    }
}

extension View {
    package func launcherHover(enabled: Bool = true) -> some View { modifier(LauncherHover(allowed: enabled)) }
}

/// AppKit owns the hand cursor's lifetime. Cursor rectangles are discarded when a control is removed or clipped,
/// without a push/pop stack that could leave the wrong cursor after a menu or search button disappears.
struct LauncherHoverRegion: NSViewRepresentable {
    let enabled: Bool
    let hover: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView { TrackingView() }
    func updateNSView(_ view: TrackingView, context: Context) {
        view.hover = hover
        if view.enabled != enabled {
            view.enabled = enabled
            view.window?.invalidateCursorRects(for: view)
        }
    }

    class TrackingView: NSView {
        var enabled = true
        var hover: (Bool) -> Void = { _ in }
        private var area: NSTrackingArea?

        override init(frame: NSRect) {
            super.init(frame: frame)
            // Modern AppKit can extend visibleRect beyond bounds. Each region belongs only to its own control.
            clipsToBounds = true
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            clipsToBounds = true
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func resetCursorRects() {
            super.resetCursorRects()
            if enabled { addCursorRect(visibleRect.intersection(bounds), cursor: .pointingHand) }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(next)
            area = next
        }

        override func mouseEntered(with event: NSEvent) { hover(true) }
        override func mouseExited(with event: NSEvent) { hover(false) }
    }
}
