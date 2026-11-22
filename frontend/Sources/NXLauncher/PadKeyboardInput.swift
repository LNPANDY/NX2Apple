import AppKit
import SwiftUI

/// Window-local keys for selection sheets, using the same targets as controller navigation.
package struct PadKeyboardInput: NSViewRepresentable {
    let focus: PadFocus
    let scope: String
    let back: () -> Void
    package init(focus: PadFocus, scope: String, back: @escaping () -> Void) {
        self.focus = focus; self.scope = scope; self.back = back
    }
    package final class KeyView: NSView {
        var handle: (UInt16, Bool) -> Bool = { _, _ in false }
        private var monitor: Any?
        package override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window, self.window?.isKeyWindow == true, NSApp.isActive,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      self.handle(event.keyCode, event.modifierFlags.contains(.shift)) else { return event }
                return nil
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
    package func makeNSView(context: Context) -> KeyView { let view = KeyView(); updateNSView(view, context: context); return view }
    package func updateNSView(_ view: KeyView, context: Context) {
        view.handle = { key, shift in
            guard focus.scope == scope else { return false }
            return Self.handle(key, shift: shift, focus: focus, back: back)
        }
    }
    package static func handle(_ key: UInt16, shift: Bool = false, focus: PadFocus, back: () -> Void) -> Bool {
        guard [123, 124, 125, 126, 36, 76, 49, 53, 48].contains(key) else { return false }
        if [36, 76].contains(key) { return false }
        focus.show(default: nil)
        switch key {
        case 123: focus.horizontal(-1)
        case 124: focus.horizontal(1)
        case 125: focus.move(dx: 0, dy: 1)
        case 126: focus.move(dx: 0, dy: -1)
        case 48:
            let targets = focus.frames[focus.scope, default: []].sorted {
                $0.frame.minY == $1.frame.minY ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY
            }
            if let index = targets.firstIndex(where: { $0.id == focus.focused }), !targets.isEmpty {
                focus.focused = targets[(index + (shift ? -1 : 1) + targets.count) % targets.count].id
            }
        case 53: back()
        default: focus.activate()
        }
        return true
    }
}
