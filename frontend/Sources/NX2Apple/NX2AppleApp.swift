import SwiftUI
import NXCore
import NXLauncher

/// The terminal switches run before any window exists: `--install-shell` is the shell install of Route C without the GUI
/// (ShellInstall.swift). Everything else starts the app.
@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--install-shell") {
            exit(ShellCLI.run(Array(CommandLine.arguments.dropFirst())))
        }
        // A shared app's folder that an older version made inside the output folder moves to Application Support once (#427).
        // Here and not in the stores: a test that builds the stores must never move a folder in the real home.
        ShellRootMigration.migrateSavedRoot()
        NX2AppleApp.main()
    }
}

struct NX2AppleApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var console = ConsoleCoordinator()
    @StateObject private var session = LauncherSession()

    var body: some Scene {
        WindowGroup("NX2Apple") {
            if let name = ProcessInfo.processInfo.environment["NSPB_ONBOARDING_DEMO"],
               let scenario = MockOnboardingDriver.Scenario(rawValue: name) {
                OnboardingDemoHost(scenario: scenario)
            } else if let scenario = ProcessInfo.processInfo.environment["NSPB_CONSOLE_DEMO"].flatMap(MockConsoleDriver.Scenario.init(rawValue:)) {
                ConsoleDemoView(scenario: scenario)
            } else { RootView(shared: session, console: console) }
        }
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 1280, height: 900)
            .windowResizability(.automatic)
            .commands {
                // View → Console Mode. Command-Option-K: Control-Command-F is the system's full screen, and the others are taken by Find and Show Colors.
                CommandGroup(after: .toolbar) {
                    Button(L10n.string(console.active ? "console.menuLeave" : "console.entry", Lang.initial())) { console.toggle() }
                        .keyboardShortcut("k", modifiers: [.command, .option]).disabled(!console.available && !console.active)
                }
            }
    }
}

/// `swift run` starts a bare executable with no Info.plist, which macOS does not treat as a
/// regular app: no Dock icon, and the window can stay hidden behind the terminal. Inside the
/// .app bundle this changes nothing.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// True when the quit waits: console mode asks before a game paused in the background quits, and quits the launcher once it has (#952).
    @MainActor static var deferTermination: () -> Bool = { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { Self.deferTermination() } ? .terminateCancel : .terminateNow
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The Dock icon once the last window was closed. The app stays running on purpose (a build and its log outlive the window
    /// that started them), but on macOS 27.2 SwiftUI's own reopen makes no window for this app: it comes forward with no window
    /// at all, so the app looked dead from the Dock. The File menu's New Window does open one, so the reopen performs that item
    /// unless SwiftUI made a window by itself in the meantime.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }), let main = NSApp.mainMenu else { return }
            Self.performNewWindow(in: main)
        }
        return true
    }

    /// Performs the first menu item with the Command-N key equivalent that has an action: SwiftUI's New Window of the launcher's
    /// WindowGroup, whose title follows the interface language and so cannot be matched by its text. Returns whether one was found.
    @discardableResult
    static func performNewWindow(in menu: NSMenu) -> Bool {
        for top in menu.items {
            guard let submenu = top.submenu else { continue }
            for (index, item) in submenu.items.enumerated() where item.keyEquivalent == "n" && item.action != nil {
                submenu.performActionForItem(at: index)
                return true
            }
        }
        return false
    }
}
