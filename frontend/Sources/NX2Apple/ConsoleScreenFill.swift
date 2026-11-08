import AppKit

/// Console mode on a screen with a camera housing (a notch). The system's full screen puts the window below the housing and leaves
/// the band on either side of it black. There the window instead covers the whole screen, the band included, with the menu bar and
/// the Dock hidden and the title bar out of sight, so the console fills the screen around the notch. Leaving puts back the window's
/// frame, its title bar and the menu bar. Any other screen keeps the system's full screen (ConsoleCoordinator.toggleFullScreen).
@MainActor enum ConsoleScreenFill {
    private struct Saved {
        let frame: NSRect
        let style: NSWindow.StyleMask
        let titleVisibility: NSWindow.TitleVisibility
        let titlebarTransparent: Bool
        let movable: Bool
        let options: NSApplication.PresentationOptions
    }
    private static var saved: [ObjectIdentifier: Saved] = [:]
    private static let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    /// The screen has a camera housing: the top of its safe area is inset.
    static func hasNotch(_ screen: NSScreen?) -> Bool { (screen?.safeAreaInsets.top ?? 0) > 0 }

    /// The window covers its screen this way now.
    static func isFilling(_ window: NSWindow) -> Bool { saved[ObjectIdentifier(window)] != nil }

    /// Full screen either way: the system's, or covering a notched screen.
    static func isFull(_ window: NSWindow) -> Bool { window.styleMask.contains(.fullScreen) || isFilling(window) }

    /// ConsoleCoordinator's `setFullScreen`: covers a notched screen, else the system's full screen. `done` runs when the window
    /// has finished moving.
    static func set(_ window: NSWindow, _ enter: Bool, _ done: @escaping () -> Void) {
        if enter {
            guard !window.styleMask.contains(.fullScreen), !isFilling(window), let screen = window.screen, hasNotch(screen) else {
                ConsoleCoordinator.toggleFullScreen(window, enter, done); return
            }
            fill(window, screen: screen, done: done)
        } else if let s = saved.removeValue(forKey: ObjectIdentifier(window)) {
            restore(window, s, done: done)
        } else {
            ConsoleCoordinator.toggleFullScreen(window, enter, done)
        }
    }

    private static func fill(_ window: NSWindow, screen: NSScreen, done: @escaping () -> Void) {
        saved[ObjectIdentifier(window)] = Saved(frame: window.frame, style: window.styleMask, titleVisibility: window.titleVisibility,
                                                titlebarTransparent: window.titlebarAppearsTransparent, movable: window.isMovable,
                                                options: NSApp.presentationOptions)
        // the menu bar can only be hidden together with the Dock; hidden, it leaves the band beside the notch to the window
        NSApp.presentationOptions = NSApp.presentationOptions.union([.hideDock, .hideMenuBar])
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovable = false
        for b in buttons { window.standardWindowButton(b)?.isHidden = true }
        window.setFrame(screen.frame, display: true, animate: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + window.animationResizeTime(screen.frame)) { done() }
    }

    private static func restore(_ window: NSWindow, _ s: Saved, done: @escaping () -> Void) {
        NSApp.presentationOptions = s.options
        window.styleMask = s.style
        window.titleVisibility = s.titleVisibility
        window.titlebarAppearsTransparent = s.titlebarTransparent
        window.isMovable = s.movable
        for b in buttons { window.standardWindowButton(b)?.isHidden = false }
        window.setFrame(s.frame, display: true, animate: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + window.animationResizeTime(s.frame)) { done() }
    }
}
