import AppKit

// The launcher comes back to the front when a game it started quits. Play opens the game's own app and the
// launcher stayed wherever it was: after a session (often played with a controller) there was nothing in front to
// pick the next game with, and the launcher had to be found in the Dock. One watcher serves both ways of starting a
// game, the desktop Play button (LauncherView) and console mode (LiveConsoleDriver), so they behave the same: each
// registers the process it opened, by its process ID (an app opened from Finder is left alone), and one Settings
// switch (Settings > App) decides whether the launcher comes forward.

enum ReturnAfterPlay {
    static let defaultsKey = "returnAfterPlay"

    /// On unless switched off in Settings.
    static var enabled: Bool { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }

    /// The launcher's windows forward: unhidden, active, its main window in front.
    static func bringForward() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }
}

/// The games the launcher started, by process ID, and what each start wants done when its game quits.
@MainActor final class GameReturnWatcher {
    static let shared = GameReturnWatcher()
    private var started: [Int32: () -> Void] = [:]
    private var observer: NSObjectProtocol?
    private let observesSystem: Bool

    /// `observesSystem` false: no NSWorkspace observer, `quit(pid:)` is called by hand (the tests).
    init(observesSystem: Bool = true) { self.observesSystem = observesSystem }

    /// Called once the game's app has been opened; `onQuit` is the caller's own bookkeeping (console mode ends its
    /// Starting state there), run whether or not the launcher comes forward.
    func didStart(pid: Int32, onQuit: @escaping () -> Void = {}) {
        started[pid] = onQuit
        guard observesSystem, observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                                     object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { if let pid { self?.quit(pid: pid) } }
        }
    }

    /// A process quit. Returns whether it was a game the launcher started: its `onQuit` ran, and the launcher came
    /// forward if the switch is on.
    @discardableResult
    func quit(pid: Int32, enabled: Bool = ReturnAfterPlay.enabled, bringForward: () -> Void = ReturnAfterPlay.bringForward) -> Bool {
        guard let onQuit = started.removeValue(forKey: pid) else { return false }
        onQuit()
        if enabled { bringForward() }
        return true
    }
}
