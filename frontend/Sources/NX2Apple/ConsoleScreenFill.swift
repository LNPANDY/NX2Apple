import AppKit
import ObjectiveC

/// Console mode on a screen with a camera housing (a notch). The system's full screen puts the window below the housing and leaves
/// the band on either side of it black. There the window instead covers the whole screen, the band included, with the menu bar and
/// the Dock hidden and the title bar out of sight, so the console fills the screen around the notch. Leaving puts back the window's
/// frame, its title bar and the menu bar. Any other screen keeps the system's full screen (ConsoleCoordinator.toggleFullScreen).
///
/// Two things kept the window below the notch at first. AppKit constrains a titled window's frame whenever its size changes
/// (`constrainFrameRect(_:to:)`), and on a notched screen that keeps it out of the band even with the menu bar hidden: while filling,
/// the window's class is a subclass made at run time that returns the frame unchanged, and the original class comes back on leaving.
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
    private static var originalClass: [ObjectIdentifier: AnyClass] = [:]
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
        window.setFrame(screen.frame, display: true, animate: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + window.animationResizeTime(screen.frame)) {
            if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }   // once more, should the animation have stopped short
            done()
        }
    }

    private static func restore(_ window: NSWindow, _ s: Saved, done: @escaping () -> Void) {
        NSApp.presentationOptions = s.options
        window.styleMask = s.style
        window.titleVisibility = s.titleVisibility
        window.titlebarAppearsTransparent = s.titlebarTransparent
        window.isMovable = s.movable
        for b in buttons { window.standardWindowButton(b)?.isHidden = false }
        window.setFrame(s.frame, display: true, animate: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + window.animationResizeTime(s.frame)) {
            reconstrain(window)
            if s.wasFullScreen { ConsoleCoordinator.toggleFullScreen(window, true, done) } else { done() }
        }
    }

    /// The window's class becomes a subclass of it, made once per class at run time, whose `constrainFrameRect(_:to:)` returns the
    /// frame as given, so AppKit lets the window reach the top of a notched screen. The SwiftUI window's own class stays its superclass,
    /// so nothing else changes.
    private static func unconstrain(_ window: NSWindow) {
        guard let original = object_getClass(window), originalClass[ObjectIdentifier(window)] == nil else { return }
        let name = "NXConsoleFill_" + NSStringFromClass(original)
        var sub: AnyClass? = NSClassFromString(name)
        if sub == nil, let made = objc_allocateClassPair(original, name, 0) {
            let sel = #selector(NSWindow.constrainFrameRect(_:to:))
            let block: @convention(block) (AnyObject, NSRect, NSScreen?) -> NSRect = { _, rect, _ in rect }
            if let method = class_getInstanceMethod(NSWindow.self, sel) {
                class_addMethod(made, sel, imp_implementationWithBlock(block), method_getTypeEncoding(method))
            }
            objc_registerClassPair(made)
            sub = made
        }
        guard let sub else { return }
        originalClass[ObjectIdentifier(window)] = original
        object_setClass(window, sub)
    }

    /// The window's own class again. Left as it is if something else has changed the class since (key-value observing makes a
    /// subclass of its own): the override then stays, which only lets the window keep the frame it is given.
    private static func reconstrain(_ window: NSWindow) {
        guard let original = originalClass.removeValue(forKey: ObjectIdentifier(window)) else { return }
        if let now = object_getClass(window), NSStringFromClass(now).hasPrefix("NXConsoleFill_") { object_setClass(window, original) }
    }
}
