import SwiftUI
import AppKit

/// Remembers where a page was scrolled to, per key (the Settings categories each keep their own, #678). Put it in the background of the
/// scrolled content: it finds the enclosing scroll view, saves its offset as it moves, and puts the offset of the new key back when
/// the key changes. A key it has never seen starts at the top.
package struct ScrollMemory: NSViewRepresentable {
    package let key: String
    package init(key: String) { self.key = key }

    package final class Coordinator {
        var offsets: [String: CGFloat] = [:]
        var key = ""
        var observer: NSObjectProtocol?
        weak var scrollView: NSScrollView?
        var restoring = false

        func attach(_ scrollView: NSScrollView) {
            guard self.scrollView !== scrollView else { return }
            self.scrollView = scrollView
            if let observer { NotificationCenter.default.removeObserver(observer) }
            scrollView.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
                guard let self, !self.restoring, let view = self.scrollView else { return }
                self.offsets[self.key] = view.contentView.bounds.origin.y
            }
        }

        func restore(_ key: String) {
            guard self.key != key else { return }
            self.key = key
            restoring = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let view = self.scrollView else { return }
                let wanted = self.offsets[key] ?? ScrollMemory.topOffset(of: view)
                view.contentView.scroll(to: NSPoint(x: 0, y: wanted))
                view.reflectScrolledClipView(view.contentView)
                self.restoring = false
            }
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }

    /// The clip view's origin at the page's top. A window with a full-size content view gives its scroll views a top inset (the
    /// hidden title bar), so the top is at minus that inset, not at 0: scrolling to 0 put the first rows under the top bar.
    package static func topOffset(of view: NSScrollView) -> CGFloat {
        guard let document = view.documentView else { return -view.contentView.contentInsets.top }
        if document.isFlipped { return -view.contentView.contentInsets.top }
        return max(0, document.bounds.height - view.contentView.bounds.height)
    }

    package func makeCoordinator() -> Coordinator { Coordinator() }
    package func makeNSView(context: Context) -> NSView { NSView() }
    package func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let scrollView = view.enclosingScrollView else { return }
            context.coordinator.attach(scrollView)
            context.coordinator.restore(key)
        }
    }
}

private struct ScrollToKey: EnvironmentKey { static let defaultValue: ((String) -> Void)? = nil }

extension EnvironmentValues {
    /// Scrolls the page to the view with this `.id` (a row another page asks to show, like Settings' "Show tools").
    package var launcherScrollTo: ((String) -> Void)? {
        get { self[ScrollToKey.self] }
        set { self[ScrollToKey.self] = newValue }
    }
}
