import AppKit
import ObjectiveC

/// Console mode on a screen with a camera housing (a notch). The system's full screen puts the window below the housing and leaves
/// the band on either side of it black. There the window instead covers the whole screen, the band included, with the menu bar and
/// the Dock hidden and the title bar out of sight, so the console fills the screen around the notch. Leaving puts back the window's
/// frame, its title bar and the menu bar. Any other screen keeps the system's full screen (ConsoleCoordinator.toggleFullScreen).
///
/// Two things kept the window below the notch at first. AppKit constrains a titled window's frame whenever its size changes
/// (`constrainFrameRect(_:to:)`), and on a notched screen that keeps it out of the band even with the menu bar hidden: while filling,
/// that method returns the frame unchanged for this window (`unconstrain`).
/// And a window already in the system's full screen was left there: it now leaves it first, and goes back to it on leaving.
@MainActor enum ConsoleScreenFill {
    private struct Saved {
        let frame: NSRect
        let style: NSWindow.StyleMask
        let titleVisibility: NSWindow.TitleVisibility
        let titlebarTransparent: Bool
        let movable: Bool
        let options: NSApplication.PresentationOptions
        let wasFullScreen: Bool
    }
    private static var saved: [ObjectIdentifier: Saved] = [:]
    /// While filling, the window is put back over the whole screen whenever something moves or resizes it: SwiftUI sizes the window
    /// for the console's content when it comes in, and with AppKit's constraint off that pushed the window off the screen.
    private static var guards: [ObjectIdentifier: [NSObjectProtocol]] = [:]
    private static let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    /// The screen has a camera housing: the top of its safe area is inset.
    static func hasNotch(_ screen: NSScreen?) -> Bool { (screen?.safeAreaInsets.top ?? 0) > 0 }

    /// The window covers its screen this way now.
    static func isFilling(_ window: NSWindow) -> Bool { saved[ObjectIdentifier(window)] != nil }

    /// Full screen either way: the system's, or covering a notched screen.
    static func isFull(_ window: NSWindow) -> Bool { window.styleMask.contains(.fullScreen) || isFilling(window) }

    /// The window is in the system's full screen on a notched screen: entering console mode takes it out of it to cover the notch.
    static func wantsFill(_ window: NSWindow) -> Bool { window.styleMask.contains(.fullScreen) && !isFilling(window) && hasNotch(window.screen) }

    /// ConsoleCoordinator's `setFullScreen`: covers a notched screen, else the system's full screen. `done` runs when the window
    /// has finished moving.
    static func set(_ window: NSWindow, _ enter: Bool, _ done: @escaping () -> Void) {
        if enter {
            guard !isFilling(window), let screen = window.screen, hasNotch(screen) else {
                if !window.styleMask.contains(.fullScreen) { ConsoleCoordinator.toggleFullScreen(window, enter, done) } else { done() }
                return
            }
            if window.styleMask.contains(.fullScreen) {
                ConsoleCoordinator.toggleFullScreen(window, false) { fill(window, screen: window.screen ?? screen, wasFullScreen: true, done: done) }
            } else {
                fill(window, screen: screen, wasFullScreen: false, done: done)
            }
        } else if let s = saved.removeValue(forKey: ObjectIdentifier(window)) {
            restore(window, s, done: done)
        } else {
            ConsoleCoordinator.toggleFullScreen(window, enter, done)
        }
    }

    private static func fill(_ window: NSWindow, screen: NSScreen, wasFullScreen: Bool, done: @escaping () -> Void) {
        saved[ObjectIdentifier(window)] = Saved(frame: window.frame, style: window.styleMask, titleVisibility: window.titleVisibility,
                                                titlebarTransparent: window.titlebarAppearsTransparent, movable: window.isMovable,
                                                options: NSApp.presentationOptions, wasFullScreen: wasFullScreen)
        // the menu bar can only be hidden together with the Dock; hidden, it leaves the band beside the notch to the window
        NSApp.presentationOptions = NSApp.presentationOptions.union([.hideDock, .hideMenuBar])
        unconstrain(window)
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovable = false
        for b in buttons { window.standardWindowButton(b)?.isHidden = true }
        titlebar(of: window)?.isHidden = true   // the band at the top takes no clicks, drags or double-clicks (which would zoom the window)
        let target = screen.frame
        window.setFrame(target, display: true)
        let snap: (Notification) -> Void = { [weak window] _ in
            DispatchQueue.main.async {   // after whatever moved it has finished
                MainActor.assumeIsolated {
                    guard let window, isFilling(window), window.frame != target else { return }
                    window.setFrame(target, display: true)
                }
            }
        }
        let center = NotificationCenter.default
        guards[ObjectIdentifier(window)] = [center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main, using: snap),
                                            center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main, using: snap)]
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { done() }
    }

    private static func restore(_ window: NSWindow, _ s: Saved, done: @escaping () -> Void) {
        for token in guards.removeValue(forKey: ObjectIdentifier(window)) ?? [] { NotificationCenter.default.removeObserver(token) }
        NSApp.presentationOptions = s.options
        window.styleMask = s.style
        window.titleVisibility = s.titleVisibility
        window.titlebarAppearsTransparent = s.titlebarTransparent
        window.isMovable = s.movable
        for b in buttons { window.standardWindowButton(b)?.isHidden = false }
        titlebar(of: window)?.isHidden = false
        window.setFrame(s.frame, display: true, animate: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + window.animationResizeTime(s.frame)) {
            reconstrain(window)
            if s.wasFullScreen { ConsoleCoordinator.toggleFullScreen(window, true, done) } else { done() }
        }
    }

    /// The view that holds the title bar (the close button's view's view), hidden while filling so the console gets the whole top.
    private static func titlebar(of window: NSWindow) -> NSView? { window.standardWindowButton(.closeButton)?.superview?.superview }

    /// The windows that skip AppKit's frame constraint now (read from the patched method, which AppKit calls on the main thread).
    nonisolated(unsafe) private static var unconstrained: Set<ObjectIdentifier> = []
    nonisolated(unsafe) private static var patchedClasses: Set<ObjectIdentifier> = []

    /// `constrainFrameRect(_:to:)` returns the frame as given for this window, so AppKit lets it reach the top of a notched screen.
    /// The window's class keeps its identity: changing a SwiftUI window's class to a subclass made at run time broke its Swift
    /// methods (the window came out 0 x 0). Instead the class's own method is replaced once by one that checks `unconstrained` and
    /// otherwise calls what the class had before, its own or the inherited one, so every other window behaves as it did.
    private static func unconstrain(_ window: NSWindow) {
        guard let cls = object_getClass(window) else { return }
        if !patchedClasses.contains(ObjectIdentifier(cls)) {
            typealias Constrain = @convention(c) (AnyObject, Selector, NSRect, NSScreen?) -> NSRect
            let sel = #selector(NSWindow.constrainFrameRect(_:to:))
            guard let method = class_getInstanceMethod(cls, sel) else { return }
            let previous = unsafeBitCast(method_getImplementation(method), to: Constrain.self)
            let block: @convention(block) (AnyObject, NSRect, NSScreen?) -> NSRect = { window, rect, screen in
                unconstrained.contains(ObjectIdentifier(window)) ? rect : previous(window, sel, rect, screen)
            }
            let imp = imp_implementationWithBlock(block)
            if !class_addMethod(cls, sel, imp, method_getTypeEncoding(method)) { method_setImplementation(method, imp) }
            patchedClasses.insert(ObjectIdentifier(cls))
        }
        unconstrained.insert(ObjectIdentifier(window))
    }

    private static func reconstrain(_ window: NSWindow) { unconstrained.remove(ObjectIdentifier(window)) }
}
