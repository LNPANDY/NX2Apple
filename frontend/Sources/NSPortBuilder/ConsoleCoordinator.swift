import SwiftUI
import AppKit

/// Enters and leaves the console mode: the window content switches (RootView, with a short calm transition) and the window goes
/// full screen for the mode, then back to what it was. A window that was already full screen is left that way. The two animations
/// are sequenced so they do not fight: on entering, the content switches after the window has finished going full screen, and on
/// leaving, the console fades out first and the window leaves full screen after. A game is started from a window that has left full
/// screen: a game opened from an app in its own full screen Space can come up as a window, so the window goes back to full screen
/// once the game has quit. In the console the pointer hides after a few idle seconds.
@MainActor final class ConsoleCoordinator: ObservableObject {
    @Published private(set) var active = false { didSet { if active != oldValue { active ? pointer.start() : pointer.stop() } } }
    /// The launcher is showing (not the guided setup), so the mode can be entered.
    @Published var available = false
    private var enteredFullScreen = false
    private var entering = false
    private var leftForGame = false
    private var activationObserver: NSObjectProtocol?
    private let appIsActive: () -> Bool
    private let window: () -> NSWindow?
    /// Changes the window's full screen state and calls `done` when that animation has finished.
    private let setFullScreen: @MainActor (NSWindow, Bool, @escaping () -> Void) -> Void
    private let fadeSeconds: TimeInterval
    /// The pointer hides while the console is idle (ConsolePointer.swift).
    private lazy var pointer = ConsolePointer(window: window)

    /// The pointer is hidden right now: a game started from the console gets DM_CURSOR_HIDDEN then.
    var pointerHidden: Bool { pointer.isHidden }

    nonisolated static let transitionSeconds: TimeInterval = 0.4

    init(window: @escaping () -> NSWindow? = { NSApp.keyWindow ?? NSApp.windows.first { $0.canBecomeMain } },
         setFullScreen: @escaping @MainActor (NSWindow, Bool, @escaping () -> Void) -> Void = ConsoleCoordinator.toggleFullScreen,
         fadeSeconds: TimeInterval = ConsoleCoordinator.transitionSeconds + 0.05,
         appIsActive: @escaping () -> Bool = { NSApp?.isActive ?? true }) {
        self.appIsActive = appIsActive
        self.window = window
        self.setFullScreen = setFullScreen
        self.fadeSeconds = fadeSeconds
    }

    /// The system toggle, with `done` called when AppKit reports the window has entered or left full screen (or after 1.5 seconds).
    static func toggleFullScreen(_ window: NSWindow, _ enter: Bool, _ done: @escaping () -> Void) {
        var finished = false
        var token: NSObjectProtocol?
        let finish = { if !finished { finished = true; if let token { NotificationCenter.default.removeObserver(token) }; done() } }
        token = NotificationCenter.default.addObserver(forName: enter ? NSWindow.didEnterFullScreenNotification : NSWindow.didExitFullScreenNotification,
                                                       object: window, queue: .main) { _ in finish() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { finish() }
        window.toggleFullScreen(nil)
    }

    func enter() {
        guard available, !active, !entering else { return }
        if let w = window(), !w.styleMask.contains(.fullScreen) {
            entering = true
            enteredFullScreen = true
            setFullScreen(w, true) { [weak self] in self?.entering = false; self?.active = true }   // the content follows the window
        } else { active = true }
    }

    func exit() {
        guard active else { return }
        active = false   // the console fades out first
        let leave = enteredFullScreen
        enteredFullScreen = false
        guard leave else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeSeconds) { [weak self] in
            if let w = self?.window(), w.styleMask.contains(.fullScreen) { self?.setFullScreen(w, false) {} }
        }
    }

    func toggle() { active ? exit() : enter() }

    /// Takes the window out of full screen and then calls `launch`, which starts the game. A window that is not full screen calls it at once.
    func leaveFullScreenForGame(then launch: @escaping () -> Void) {
        guard active, let w = window(), w.styleMask.contains(.fullScreen) else { launch(); return }
        leftForGame = true
        setFullScreen(w, false) { launch() }
    }

    /// The game has quit or did not start: the window goes back to full screen if it left for the game and the console is still showing.
    /// A launcher that is not the active app waits until it is, so it does not pull the player into a Space from behind another app.
    func resumeFullScreenAfterGame() {
        guard leftForGame else { return }
        leftForGame = false
        guard active else { return }
        if appIsActive() { returnToFullScreen(); return }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let token = self.activationObserver { NotificationCenter.default.removeObserver(token) }
                self.activationObserver = nil
                if self.active { self.returnToFullScreen() }
            }
        }
    }

    /// The launcher can be asked while the game's Space is still going away, and the system drops that request. A window that is
    /// still not full screen when the animation is over is asked again, up to three times.
    private func returnToFullScreen(attempts: Int = 3) {
        guard attempts > 0, active, let w = window(), !w.styleMask.contains(.fullScreen) else { return }
        setFullScreen(w, true) { [weak self] in self?.returnToFullScreen(attempts: attempts - 1) }
    }
}

/// The calm switch between the desktop and the console: opacity with a little scale, blur or movement. Reduce Motion gets a plain fade.
struct CalmTransition: ViewModifier {
    var scale: CGFloat = 1
    var blur: CGFloat = 0
    var offset: CGFloat = 0
    var opacity: Double = 1
    func body(content: Content) -> some View {
        content.scaleEffect(scale).blur(radius: blur).offset(y: offset).opacity(opacity)
    }
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// The console arrives from a soft blur, a few points low. The desktop settles back from 0.97.
    static var console: AnyTransition {
        reduceMotion ? .opacity : .modifier(active: CalmTransition(blur: 8, offset: 10, opacity: 0), identity: CalmTransition())
    }
    static var desktop: AnyTransition {
        reduceMotion ? .opacity : .modifier(active: CalmTransition(scale: 0.97, opacity: 0), identity: CalmTransition())
    }
}

/// The controller-connect prompt: once per session, and never when the player turned it off in Settings.
enum ConsolePrompt {
    static let defaultsKey = "consolePrompt"
    private(set) static var shownThisSession = false
    static var enabled: Bool { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
    static func shouldShow(enabled: Bool, shown: Bool) -> Bool { enabled && !shown }
    static func didShow() { shownThisSession = true }
    static func resetSessionForTests() { shownThisSession = false }
}
