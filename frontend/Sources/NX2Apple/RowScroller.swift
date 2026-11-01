import SwiftUI

/// The collection row's scroll state, read from its NSScrollView: SwiftUI's horizontal ScrollView does not
/// report its offset on macOS 13, so the pager chevrons follow the clip view's bounds instead.
final class RowScroller: ObservableObject {
    @Published private(set) var canBack = false
    @Published private(set) var canForward = false
    private weak var scrollView: NSScrollView?
    private var observers: [NSObjectProtocol] = []

    func attach(_ view: NSScrollView) {
        guard view !== scrollView else { return update() }
        observers.forEach(NotificationCenter.default.removeObserver)
        scrollView = view
        let clip = view.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        view.documentView?.postsFrameChangedNotifications = true
        observers = [(NSView.boundsDidChangeNotification, clip), (NSView.frameDidChangeNotification, clip),
                     (NSView.frameDidChangeNotification, view.documentView as Any)].map { name, object in
            NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in self?.update() }
        }
        update()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func update() {
        guard let view = scrollView, let document = view.documentView else { return }
        let x = view.contentView.bounds.minX, end = document.frame.width - view.contentView.bounds.width
        if canBack != (x > 1) { canBack = x > 1 }
        if canForward != (x < end - 1) { canForward = x < end - 1 }
    }

    /// Scroll by the whole cards that fit in the row.
    func page(_ direction: CGFloat, step: CGFloat) {
        guard let view = scrollView, let document = view.documentView else { return }
        let clip = view.contentView
        let distance = max(step, (clip.bounds.width / step).rounded(.down) * step)
        let target = min(max(0, clip.bounds.minX + direction * distance), max(0, document.frame.width - clip.bounds.width))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clip.animator().setBoundsOrigin(NSPoint(x: target, y: clip.bounds.minY))
        }
        view.reflectScrolledClipView(clip)
    }
}

/// Hands the NSScrollView around this background view to the row's scroller once it is in a window.
struct EnclosingScrollView: NSViewRepresentable {
    let row: RowScroller
    final class Probe: NSView {
        var row: RowScroller?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                if let view = self?.enclosingScrollView { self?.row?.attach(view) }
            }
        }
    }
    func makeNSView(context: Context) -> Probe { let probe = Probe(); probe.row = row; return probe }
    func updateNSView(_ probe: Probe, context: Context) {
        probe.row = row
        DispatchQueue.main.async { if let view = probe.enclosingScrollView { row.attach(view) } }
    }
}

/// The library's collection row reports its height, so the hero above it fills exactly what is left.
struct CollectionHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
