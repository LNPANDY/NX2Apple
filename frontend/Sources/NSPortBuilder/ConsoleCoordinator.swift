import SwiftUI
import AppKit

/// Enters and leaves the console mode: the window content switches (RootView) and the window goes full screen for the mode, then
/// back to what it was. A window that was already full screen is left that way.
@MainActor final class ConsoleCoordinator: ObservableObject {
    @Published private(set) var active = false
    /// The launcher is showing (not the guided setup), so the mode can be entered.
    @Published var available = false
    private var enteredFullScreen = false
    private let window: () -> NSWindow?
    private let setFullScreen: (NSWindow, Bool) -> Void

    init(window: @escaping () -> NSWindow? = { NSApp.keyWindow ?? NSApp.windows.first { $0.canBecomeMain } },
         setFullScreen: @escaping (NSWindow, Bool) -> Void = { w, _ in w.toggleFullScreen(nil) }) {
        self.window = window
        self.setFullScreen = setFullScreen
    }

    func enter() {
        guard available, !active else { return }
        active = true
        if let w = window(), !w.styleMask.contains(.fullScreen) { enteredFullScreen = true; setFullScreen(w, true) }
    }

    func exit() {
        guard active else { return }
        active = false
        if enteredFullScreen, let w = window(), w.styleMask.contains(.fullScreen) { setFullScreen(w, false) }
        enteredFullScreen = false
    }

    func toggle() { active ? exit() : enter() }
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
