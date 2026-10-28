import SwiftUI

/// The desktop integration only reports an intent. The application coordinator will supply it later.
struct ConsoleEntryButton: View {
    let lang: Lang
    var compact = false
    let enterConsole: () -> Void
    var body: some View {
        Button(action: enterConsole) {
            Group {
                if compact { Image(systemName: "gamecontroller") }
                else { Label(L10n.string("console.entry", lang), systemImage: "gamecontroller") }
            }
                .font(.manrope(13, .semibold)).padding(.horizontal, 12).padding(.vertical, 8)
                .background(.white.opacity(0.07), in: Capsule()).contentShape(Capsule())
        }
        .buttonStyle(.plain).accessibilityLabel(L10n.string("console.entry", lang)).help(L10n.string("console.entry", lang))
        .padTarget("top.console", scope: "main", radius: 24, activate: enterConsole)
    }
}

/// The cream button of a dialog: the launcher's secondary button's size and radius, filled.
struct LauncherPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.manrope(13, .bold)).lineLimit(1)
            .padding(.horizontal, 15).padding(.vertical, 9)
            .background(LauncherPalette.cream.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 9))
            .foregroundStyle(LauncherPalette.background)
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

struct ConsoleConnectionPrompt: View {
    let lang: Lang
    let enterConsole: () -> Void
    let dismissPrompt: () -> Void
    @EnvironmentObject private var pad: PadFocus
    @AppStorage(ConsolePrompt.defaultsKey) private var promptOn = true   // the same switch as Settings
    private func t(_ key: String) -> String { L10n.string(key, lang) }
    private var glyphs: ConsoleGlyphs { .current() }
    var body: some View {
        ZStack {
            Color.black.opacity(0.65).ignoresSafeArea()   // the whole window, the area behind the hidden title bar too
            VStack(alignment: .leading, spacing: 14) {
                Label(t("console.connectionTitle"), systemImage: "gamecontroller").font(.manrope(22, .bold))
                Text(t("console.connectionNote")).font(.manrope(14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                do {   // how to switch from the desktop any time
                    HStack(spacing: 6) {
                        Text(t("console.promptSelectBefore"))
                        ConsoleGlyphView(glyph: glyphs.glyph(for: .select), size: 16)
                        Text(t("console.promptSelectAfter"))
                    }.font(.manrope(14)).foregroundStyle(.secondary)
                }
                // one row, macOS order: the way out on the left of the main choice, both of the launcher's standard size
                HStack(spacing: 10) {
                    Toggle(t("console.promptNever"), isOn: Binding(get: { !promptOn }, set: { promptOn = !$0 }))
                        .toggleStyle(.checkbox).font(.manrope(12)).foregroundStyle(.secondary)
                        .padTarget("console.entry.never", scope: "console.entry", radius: 6, activate: { promptOn.toggle() })
                    Spacer(minLength: 12)
                    Button(action: dismissPrompt) {
                        HStack(spacing: 7) { ConsoleGlyphView(glyph: glyphs.glyph(for: .back), size: 15); Text(t("console.later")) }
                    }
                    .buttonStyle(LauncherSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                    .padTarget("console.entry.later", scope: "console.entry", activate: dismissPrompt)
                    Button(action: enterConsole) {
                        HStack(spacing: 7) { ConsoleGlyphView(glyph: glyphs.glyph(for: .activate), size: 15).foregroundStyle(LauncherPalette.background); Text(t("console.entry")) }
                    }
                    .buttonStyle(LauncherPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .padTarget("console.entry.enter", scope: "console.entry", activate: enterConsole)
                }
                .padding(.top, 6)
            }
            .padding(26).frame(maxWidth: 560).background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.10)))
            .padding(24)
        }
        .padScope("console.entry", pad)
        .environment(\.padRingStyle, .hug)
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
