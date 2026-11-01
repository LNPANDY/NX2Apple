import AppKit

/// When the pointer hides in console mode: after `idleSeconds` without movement, a click or a scroll while it is over the launcher
/// window, and it comes back with the next one (the game's pointer follows the same rule, patch 0032). `hidden` is the one
/// NSCursor.hide the launcher has outstanding, so hide and unhide stay balanced.
struct PointerIdle: Equatable {
    enum Step { case none, hide, show }
    /// The timer looks every `ConsolePointer.pollSeconds`, so the pointer is gone 1.25 to 1.5 seconds after the last movement.
    var idleSeconds: TimeInterval = 1.25
    private(set) var hidden = false
    private var lastLocation: CGPoint?
    private var lastActivity: TimeInterval = 0

    /// One look at the pointer: its position, whether a button is down, and whether it is over the active launcher window.
    mutating func tick(now: TimeInterval, location: CGPoint, buttonDown: Bool, over: Bool) -> Step {
        if location != lastLocation || buttonDown { lastActivity = now }
        lastLocation = location
        if hidden { return lastActivity == now || !over ? show() : .none }
        if over, now - lastActivity >= idleSeconds { hidden = true; return .hide }
        return .none
    }

    /// A click or a scroll that did not move the pointer.
    mutating func activity(now: TimeInterval) -> Step {
        lastActivity = now
        return hidden ? show() : .none
    }

    /// Console mode ended: the pointer is shown if it was hidden.
    mutating func reset() -> Step { hidden ? show() : .none }

    private mutating func show() -> Step { hidden = false; return .show }
}

/// Hides the pointer over the console after about a second and a half of idle time. It watches the pointer position on a short timer, so it needs
/// no tracking area or mouse-moved events from the window.
@MainActor final class ConsolePointer {
    static let pollSeconds: TimeInterval = 0.25
    private var idle = PointerIdle()
    private var timer: Timer?
    private var monitor: Any?
    private let window: () -> NSWindow?
    private let hide: () -> Void
    private let show: () -> Void

    init(window: @escaping () -> NSWindow?, hide: @escaping () -> Void = { NSCursor.hide() }, show: @escaping () -> Void = { NSCursor.unhide() }) {
        self.window = window
        self.hide = hide
        self.show = show
    }

    /// The pointer is hidden right now.
    var isHidden: Bool { idle.hidden }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.look() }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated { self?.apply(self?.idle.activity(now: ProcessInfo.processInfo.systemUptime) ?? .none) }
            return event
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        apply(idle.reset())
    }

    private func look() {
        let location = NSEvent.mouseLocation
        let over = (NSApp?.isActive ?? false) && (window()?.frame.contains(location) ?? false)
        apply(idle.tick(now: ProcessInfo.processInfo.systemUptime, location: location, buttonDown: NSEvent.pressedMouseButtons != 0, over: over))
    }

    private func apply(_ step: PointerIdle.Step) {
        switch step {
        case .hide: hide()
        case .show: show()
        case .none: break
        }
    }
}
