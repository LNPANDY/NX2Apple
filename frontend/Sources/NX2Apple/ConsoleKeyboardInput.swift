import AppKit
import SwiftUI

/// A window-local keyboard adapter. A local monitor keeps navigation working after a click gives a
/// native button first-responder status; it never consumes another window's keys or global shortcuts.
struct ConsoleKeyboardInput: NSViewRepresentable {
    var perform: (ConsoleInput) -> Void
    /// The search is open: letters, digits and space type into it, Delete deletes (#816). The arrows, Return and Escape still move.
    var typing: () -> Bool = { false }
    final class KeyView: NSView {
        var perform: (ConsoleInput) -> Void = { _ in }
        var typing: () -> Bool = { false }
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window, window.isKeyWindow,
                      NSApp.isActive, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      let input = Self.input(event, typing: self.typing()) else { return event }
                self.perform(input)
                return nil
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
        static func input(_ event: NSEvent, typing: Bool = false) -> ConsoleInput? {
            input(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers ?? "", typing: typing)
        }
        static func input(keyCode: UInt16, characters: String, typing: Bool) -> ConsoleInput? {
            switch keyCode {
            case 123: return .left
            case 124: return .right
            case 125: return .down
            case 126: return .up
            case 36, 76: return .activate
            case 49: return typing ? .typed(" ") : .activate
            case 53: return .back
            case 51 where typing: return .deleteBackward
            default:
                if typing, characters.count == 1, let c = characters.first, c.isLetter || c.isNumber { return .typed(String(c)) }
                switch characters.lowercased() {
                case "y", "o": return .options
                case "m", "+", "=": return .menu
                case "x": return .play
                case "q": return .previousTab
                case "e": return .nextTab
                case "v", "-": return .quickMenu
                default: return nil
                }
            }
        }
    }
    func makeNSView(context: Context) -> KeyView { let view = KeyView(); view.perform = perform; view.typing = typing; return view }
    func updateNSView(_ view: KeyView, context: Context) { view.perform = perform; view.typing = typing }
}
