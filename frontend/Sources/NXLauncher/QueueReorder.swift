import SwiftUI
import NXModel

struct QueueRowFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Keep layout and the queue unchanged until release; only the row faces move during pickup.
struct QueueRowDrag {
    let source: UUID
    let ids: [UUID]
    let movable: Set<UUID>
    let frames: [UUID: CGRect]
    var translation: CGFloat = 0

    var offset: CGFloat {
        guard let frame = frames[source] else { return 0 }
        let centers = ids.filter { movable.contains($0) }.compactMap { frames[$0]?.midY }
        return min(max(frame.midY + translation, centers.min() ?? frame.midY), centers.max() ?? frame.midY) - frame.midY
    }
    var order: [UUID] {
        guard let frame = frames[source] else { return ids }
        var waiting = ids.filter { movable.contains($0) && $0 != source }
        let center = frame.midY + offset
        let index = waiting.firstIndex {
            let midpoint = frames[$0]?.midY ?? .infinity
            return center < midpoint || (translation < 0 && center == midpoint)
        } ?? waiting.count
        waiting.insert(source, at: index)
        var next = waiting.makeIterator()
        return ids.map { movable.contains($0) ? (next.next() ?? $0) : $0 }
    }
    func displacement(_ id: UUID) -> CGFloat {
        if id == source { return offset }
        guard let original = frames[id], let first = ids.first, var y = frames[first]?.minY else { return 0 }
        for (index, item) in order.enumerated() {
            if item == id { return y - original.minY }
            y += frames[item]?.height ?? 0
            if index + 1 < ids.count, let a = frames[ids[index]], let b = frames[ids[index + 1]] {
                y += b.minY - a.maxY
            }
        }
        return 0
    }
}

/// Only real pointer events change input mode; relayout beneath a stationary cursor must not hide controller controls.
struct QueuePointerInput: NSViewRepresentable {
    var cancel: () -> Void = {}
    var autoscrolling = false
    var scrolled: (CGFloat) -> Void = { _ in }
    let changed: (Bool) -> Void
    final class Probe: NSView {
        var changed: (Bool) -> Void = { _ in }
        var cancel: () -> Void = {}
        var autoscrolling = false {
            didSet {
                guard autoscrolling != oldValue else { return }
                if autoscrolling { NSCursor.closedHand.set() }
                else {
                    scrollTimer?.invalidate(); scrollTimer = nil; dragEvent = nil
                    NSCursor.arrow.set()
                    window?.resetCursorRects()
                }
            }
        }
        var scrolled: (CGFloat) -> Void = { _ in }
        private var dragEvent: NSEvent?
        private var scrollTimer: Timer?
        private func scrollDrag() {
            guard autoscrolling, let event = dragEvent, let clip = enclosingScrollView?.contentView else { return }
            guard window?.isKeyWindow == true else { cancel(); return }
            let previous = clip.bounds.origin.y
            _ = autoscroll(with: event)
            let delta = clip.bounds.origin.y - previous
            if delta != 0 { scrolled(delta) }
        }
        private var monitor: Any?
        private weak var trackedWindow: NSWindow?
        private var acceptedMouseMoves = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            trackedWindow?.acceptsMouseMovedEvents = acceptedMouseMoves
            trackedWindow = window
            guard let window else { return }
            acceptedMouseMoves = window.acceptsMouseMovedEvents
            window.acceptsMouseMovedEvents = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
                if let self, let window = self.window, event.window === window, window.isKeyWindow {
                    if event.type == .keyDown && event.keyCode == 53 && self.autoscrolling {
                        self.cancel(); return nil
                    }
                    self.receive(event)
                }
                return event
            }
        }
        func receive(_ event: NSEvent) {
            if event.type == .leftMouseDragged && autoscrolling {
                NSCursor.closedHand.set()
                dragEvent = event
                if scrollTimer == nil {
                    let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.scrollDrag() }
                    scrollTimer = timer
                    RunLoop.main.add(timer, forMode: .common)
                }
            }
            if event.type == .keyDown && event.keyCode == 53 { cancel(); return }
            if event.type == .leftMouseUp { DispatchQueue.main.async { [weak self] in self?.changed(false) } }
            else if event.type == .mouseMoved { changed(false) }
            else if event.type == .keyDown && event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                    [36, 48, 49, 76, 123, 124, 125, 126].contains(event.keyCode) { changed(true) }
        }
        deinit {
            if autoscrolling { NSCursor.arrow.set() }
            scrollTimer?.invalidate()
            if let monitor { NSEvent.removeMonitor(monitor) }
            trackedWindow?.acceptsMouseMovedEvents = acceptedMouseMoves
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.changed = changed; view.cancel = cancel; view.autoscrolling = autoscrolling; view.scrolled = scrolled; return view }
    func updateNSView(_ view: Probe, context: Context) { view.changed = changed; view.cancel = cancel; view.autoscrolling = autoscrolling; view.scrolled = scrolled }
}
