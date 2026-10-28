import SwiftUI

@main
struct NSPortBuilderApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var console = ConsoleCoordinator()

    var body: some Scene {
        WindowGroup("NX2Apple") {
            if let name = ProcessInfo.processInfo.environment["NSPB_ONBOARDING_DEMO"],
               let scenario = MockOnboardingDriver.Scenario(rawValue: name) {
                OnboardingDemoHost(scenario: scenario)
            } else if let scenario = ProcessInfo.processInfo.environment["NSPB_CONSOLE_DEMO"].flatMap(MockConsoleDriver.Scenario.init(rawValue:)) {
                ConsoleDemoView(scenario: scenario)
            } else { RootView(console: console) }
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
