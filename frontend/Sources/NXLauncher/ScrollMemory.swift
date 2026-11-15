import SwiftUI
import AppKit

/// Remembers where a page was scrolled to, per key (the Settings categories each keep their own, #678). Put it in the background of the
/// scrolled content: it finds the enclosing scroll view, saves its offset as it moves, and puts the offset of the new key back when
/// the key changes. A key it has never seen starts at the top.
package struct ScrollMemory: NSViewRepresentable {
    package let key: String
    package let pinnedOffset: CGFloat
    package let onPinChange: ((Bool) -> Void)?

    package init(key: String, pinnedOffset: CGFloat = 0, onPinChange: ((Bool) -> Void)? = nil) {
        self.key = key
        self.pinnedOffset = pinnedOffset
        self.onPinChange = onPinChange
    }

    package final class Coordinator {
        var offsets: [String: CGFloat] = [:]
        var key = ""
        var pinnedOffset: CGFloat = 0
        var onPinChange: ((Bool) -> Void)?
        var lastPinned: Bool?
        var observer: NSObjectProtocol?
        weak var scrollView: NSScrollView?
        var restoring = false

        private static func groupPrefix(of key: String) -> Substring? {
            guard let dot = key.firstIndex(of: ".") else { return nil }
            return key[..<dot]
        }

        func updatePinState(in view: NSScrollView) {
            let top = ScrollMemory.topOffset(of: view)
            let scrolled = view.contentView.bounds.origin.y - top
            let pinned = pinnedOffset > 0 && scrolled >= pinnedOffset - 2
            if lastPinned != pinned {
                lastPinned = pinned
                let callback = onPinChange
                DispatchQueue.main.async { callback?(pinned) }
            }
        }

        func attach(_ scrollView: NSScrollView) {
            if pinnedOffset > 0 {
                scrollView.automaticallyAdjustsContentInsets = false
                scrollView.contentInsets = NSEdgeInsets()
            }
            guard self.scrollView !== scrollView else { return }
            self.scrollView = scrollView
            if let observer { NotificationCenter.default.removeObserver(observer) }
            scrollView.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
                guard let self, let view = self.scrollView else { return }
                if !self.restoring {
                    self.offsets[self.key] = view.contentView.bounds.origin.y
                }
                self.updatePinState(in: view)
            }
        }

        private func apply(_ wanted: CGFloat, in view: NSScrollView) {
            view.contentView.scroll(to: NSPoint(x: 0, y: wanted))
            view.reflectScrolledClipView(view.contentView)
            updatePinState(in: view)
        }

        func restore(_ key: String) {
            guard self.key != key else {
                if let view = self.scrollView { updatePinState(in: view) }
                return
            }
            let previousKey = self.key
            self.key = key
            restoring = true

            let computeWanted: (NSScrollView) -> CGFloat = { [weak self] view in
                guard let self else { return ScrollMemory.topOffset(of: view) }
                let top = ScrollMemory.topOffset(of: view)
                let currentY = view.contentView.bounds.origin.y
                let sameGroup = !previousKey.isEmpty && Self.groupPrefix(of: previousKey) != nil
                    && Self.groupPrefix(of: previousKey) == Self.groupPrefix(of: key)
                if sameGroup && self.pinnedOffset > 0 {
                    let currentScrolled = currentY - top
                    if currentScrolled >= self.pinnedOffset - 2 {
                        let pinY = top + self.pinnedOffset
                        return max(self.offsets[key] ?? pinY, pinY)
                    } else {
                        return currentY
                    }
                }
                return self.offsets[key] ?? top
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, let view = self.scrollView else { return }
                let wanted = computeWanted(view)
                self.apply(wanted, in: view)
                self.offsets[key] = view.contentView.bounds.origin.y
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
        context.coordinator.pinnedOffset = pinnedOffset
        context.coordinator.onPinChange = onPinChange
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
