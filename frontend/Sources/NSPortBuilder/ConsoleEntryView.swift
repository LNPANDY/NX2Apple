import SwiftUI

/// The desktop integration only reports an intent. The application coordinator will supply it later.
struct ConsoleEntryButton: View {
    let lang: Lang
    var compact = false
    let enterConsole: () -> Void
    var body: some View {
        Button(action: enterConsole) {
            Group {
                if compact { Image(systemName: "tv") }
                else { Label(L10n.string("console.entry", lang), systemImage: "tv") }
            }
                .font(.manrope(13, .semibold)).padding(.horizontal, 12).padding(.vertical, 8)
                .background(.white.opacity(0.07), in: Capsule()).contentShape(Capsule())
        }
        .buttonStyle(.plain).accessibilityLabel(L10n.string("console.entry", lang)).help(L10n.string("console.entry", lang))
        .padTarget("top.console", scope: "main", radius: 24, activate: enterConsole)
    }
}

struct ConsoleConnectionPrompt: View {
    let lang: Lang
    let enterConsole: () -> Void
    let dismissPrompt: () -> Void
    @EnvironmentObject private var pad: PadFocus
    private func t(_ key: String) -> String { L10n.string(key, lang) }
    var body: some View {
        ZStack {
            Color.black.opacity(0.65)
            VStack(alignment: .leading, spacing: 20) {
                Label(t("console.connectionTitle"), systemImage: "gamecontroller").font(.manrope(26, .bold))
                Text(t("console.connectionNote")).font(.manrope(18)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 16) {
                    Button(t("console.later"), action: dismissPrompt).buttonStyle(LauncherSecondaryButtonStyle())
                        .keyboardShortcut(.cancelAction)
                        .padTarget("console.entry.later", scope: "console.entry", activate: dismissPrompt)
                    Button(action: enterConsole) {
                        Text(t("console.entry")).font(.manrope(17, .bold)).foregroundStyle(LauncherPalette.background)
                            .padding(.horizontal, 24).padding(.vertical, 14).background(LauncherPalette.cream, in: Capsule())
                    }
                    .buttonStyle(.plain).keyboardShortcut(.defaultAction)
                    .padTarget("console.entry.enter", scope: "console.entry", radius: 30, activate: enterConsole)
                }
            }
            .padding(36).frame(maxWidth: 530).background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.10)))
            .padding(24)
        }
        .padScope("console.entry", pad)
        .background(ConsoleKeyboardInput { input in
            pad.show(default: "console.entry.enter")
            switch input {
            case .back: dismissPrompt()
            case .activate: pad.activate()
            case .left: pad.horizontal(-1)
            case .right: pad.horizontal(1)
            case .up: pad.move(dx: 0, dy: -1)
            case .down: pad.move(dx: 0, dy: 1)
            default: break
            }
        })
        .onAppear { pad.scope = "console.entry"; pad.focused = "console.entry.enter" }
        .accessibilityAddTraits(.isModal)
    }
}

/// The demo reads covers from the repository's docs/images (BuildModel.findRepo, as the launcher does) and is otherwise isolated from ContentView: no BuildModel, library discovery, controller adapter or process is made.
@MainActor struct ConsoleDemoView: View {
    @StateObject private var driver: MockConsoleDriver
    init(scenario: MockConsoleDriver.Scenario) { _driver = StateObject(wrappedValue: MockConsoleDriver(scenario: scenario, artworkRepo: Optional(BuildModel.findRepo()).flatMap { $0.isEmpty ? nil : $0 })) }
    var body: some View { ConsoleView(driver: driver).frame(minWidth: 360, minHeight: 600) }
}
