import SwiftUI
import NXCore
import NXLauncher

/// The top of a console page over the whole screen (a game's controller settings, the button mapping): its title, what it is for
/// under it, and the close button, which B does too.
struct ConsolePageHeader: View {
    let title: String
    var subtitle: String?
    /// What the page is for, in a line or two, where there is no subtitle (the cloud saves).
    var note: String?
    let compact: Bool
    let closeLabel: String
    let closeID: String
    let scope: String
    let close: () -> Void
    var inset: CGFloat { compact ? 24 : 64 }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: compact ? 6 : 10) {
                Text(title).font(.manrope(compact ? 30 : 44, .bold)).tracking(-0.8).accessibilityAddTraits(.isHeader)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.manrope(compact ? 16 : 21, .semibold)).foregroundStyle(LauncherPalette.cream).lineLimit(1)
                }
                if let note, !note.isEmpty {
                    Text(note).font(.manrope(compact ? 15 : 19)).foregroundStyle(LauncherPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 20)).frame(width: 52, height: 52)
                    .background(.white.opacity(0.075), in: Circle()).contentShape(Circle())
            }
            .buttonStyle(.plain).accessibilityLabel(closeLabel)
            .padTarget(closeID, scope: scope, radius: 26, activate: close)
        }
        .padding(.horizontal, inset).padding(.top, compact ? 28 : 48).padding(.bottom, compact ? 20 : 32)
    }
}

/// A section's heading on a console page, as the mapping's groups have it.
struct ConsoleSectionHeading: View {
    let title: String
    let compact: Bool
    var body: some View {
        Text(title.uppercased()).font(.manrope(compact ? 12 : 14, .semibold)).tracking(1.5)
            .foregroundStyle(LauncherPalette.cream.opacity(0.7)).padding(.leading, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One of a game's options as a console row, wired to the driver: the render scale reads as a percentage, a slider is picked with A
/// (`editing`, which ConsoleView keeps so A and B can let it go).
@MainActor func consoleOptionRow<Driver: ConsoleDriver>(_ setting: LaunchSetting, game: ConsoleGame, driver: Driver, lang: Lang, compact: Bool,
                                                        scope: String, editing: Binding<String?>) -> ConsoleOptionRow {
    let value = game.value(setting)
    // the render scale and the rumble strength read as percentages (1 is 100 %)
    let percent = setting.env == "DM_RENDER_SCALE" || setting.env == "DM_RUMBLE_GAIN"
    let label = percent ? "\(Int(((Double(value) ?? 1) * 100).rounded()))%" : ConsoleOption.label(setting, value: value, lang: lang)
    let id = "console.option." + setting.env
    return ConsoleOptionRow(setting: setting, value: value, label: label, compact: compact, lang: lang, scope: scope,
                            editing: editing.wrappedValue == id, edit: { editing.wrappedValue = $0 ? id : nil },
                            adjust: { step in
                                if let next = ConsoleOption.stepped(setting, value: value, by: step) {
                                    driver.setOption(gameID: game.id, setting: setting.env, value: next)
                                }
                            },
                            set: { next in driver.setOption(gameID: game.id, setting: setting.env, value: next) })
}

/// A question in the middle of the screen over what it was asked from, two answers side by side, the second the cream one, B
/// closing the question (ConsoleState.back). The focus starts on the safe answer (ConsoleView.resetFocus): Cancel for "Leave console
/// mode?", "Reset this game's options?" and the app's update, so A pressed by habit changes nothing. "Save changes?" on leaving the button mapping:
/// Discard and Save, the focus on Save, B goes on editing.
struct ConsoleQuestion: View {
    let compact: Bool
    let symbol: String
    let title: String
    let message: String
    let scope: String
    /// The quiet answer and the cream one: label, pad id, action.
    let other: (String, String, () -> Void)
    let main: (String, String, () -> Void)

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 16 : 20) {
            Image(systemName: symbol).font(.system(size: compact ? 34 : 42, weight: .light))
                .foregroundStyle(LauncherPalette.cream).accessibilityHidden(true)
            Text(title).font(.manrope(compact ? 26 : 34, .bold)).accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)
            Text(message).font(.manrope(compact ? 16 : 20)).foregroundStyle(LauncherPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                button(other.0, id: other.1, primary: false, action: other.2)
                button(main.0, id: main.1, primary: true, action: main.2)
            }
            .padding(.top, compact ? 8 : 12)
        }
        .padding(compact ? 24 : 36)
        .frame(maxWidth: compact ? .infinity : 560, alignment: .leading)
        .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.10)))
        .padding(24)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private func button(_ label: String, id: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.manrope(compact ? 18 : 20, .bold)).lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(primary ? LauncherPalette.background : .white.opacity(0.9))
                .frame(maxWidth: .infinity, minHeight: compact ? 52 : 58)
                .background(primary ? LauncherPalette.cream : .white.opacity(0.09), in: Capsule()).contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padTarget(id, scope: scope, radius: compact ? 26 : 29, activate: action)   // half the height: a capsule ring (a larger radius draws marks at its ends)
    }
}

/// A game's controller settings as a page of its own over the whole screen: its rumble (the game's Controls rows, and a test that
/// rumbles the connected controllers at the strength set), and beside it the way to the game's own button mapping, with the
/// controller drawn. One column on a narrow window.
@MainActor struct ConsoleGamePadPage<Driver: ConsoleDriver>: View {
    @ObservedObject var driver: Driver
    let game: ConsoleGame
    let lang: Lang
    let compact: Bool
    @Binding var editing: String?
    @EnvironmentObject private var pad: PadFocus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static var scope: String { "console.gamePad" }
    private func t(_ key: String) -> String { L10n.string(key, lang) }
    private var inset: CGFloat { compact ? 24 : 64 }
    private var rumbles: Bool { game.controllerSettings.contains { $0.env.hasPrefix("DM_RUMBLE") } }

    /// Where the focus starts: the first setting, else the test, else the mapping.
    static func firstTarget(_ game: ConsoleGame) -> String {
        if let first = game.controllerSettings.first { return "console.option." + first.env }
        return game.mapsButtons ? "console.gamePad.mapping" : "console.gamePad.close"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ConsolePageHeader(title: t("console.gamePad"), subtitle: game.title, compact: compact, closeLabel: t("console.close"),
                              closeID: "console.gamePad.close", scope: Self.scope) { driver.back() }
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                    Group {
                        if compact || !game.mapsButtons {
                            VStack(alignment: .leading, spacing: 28) { rumble; if game.mapsButtons { buttons } }
                                .frame(maxWidth: 760, alignment: .leading)
                        } else {
                            HStack(alignment: .top, spacing: 48) {
                                rumble.frame(maxWidth: .infinity, alignment: .topLeading)
                                buttons.frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                            .frame(maxWidth: 1400)
                        }
                    }
                    .padding(.horizontal, inset).padding(.bottom, compact ? 24 : 40)
                    .frame(maxWidth: .infinity, alignment: .leading)   // lined up with the title
                    }.consoleScrollContent()
                }
                .consoleScrollFade()
                .onChange(of: pad.focused) { id in
                    guard let id, id.hasPrefix("console.option.") || id.hasPrefix("console.gamePad.") else { return }
                    withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.18)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LauncherPalette.background)
    }

    private var rumble: some View {
        VStack(alignment: .leading, spacing: 12) {
            ConsoleSectionHeading(title: t("console.gamePad.rumble"), compact: compact)
            ForEach(game.controllerSettings) { setting in
                consoleOptionRow(setting, game: game, driver: driver, lang: lang, compact: compact, scope: Self.scope, editing: $editing)
                    .id("console.option." + setting.env)
            }
            if rumbles { test }
            // the hint stays with the rows it is about, not at the far bottom of a mostly empty page
            Text(t(game.controllerSettings.contains { $0.kind == "range" } ? "console.adjustHintSlider" : "console.adjustHint"))
                .font(.manrope(compact ? 13 : 15)).foregroundStyle(LauncherPalette.secondaryText).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        }
    }

    /// Rumbles every connected controller once at the strength set, so a change can be felt before the game starts.
    private var test: some View {
        let run = { driver.testRumble(gameID: game.id) }
        return Button(action: run) {
            HStack(spacing: 16) {
                Image(systemName: "waveform.path").font(.system(size: compact ? 20 : 24, weight: .semibold)).frame(width: 36)
                    .foregroundStyle(LauncherPalette.cream).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("console.gamePad.test")).font(.manrope(compact ? 17 : 20, .semibold))
                    Text(t("console.gamePad.testNote")).font(.manrope(compact ? 13 : 15)).foregroundStyle(LauncherPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 20).padding(.vertical, compact ? 14 : 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t("console.gamePad.test")).accessibilityHint(t("console.gamePad.testNote"))
        .padTarget("console.gamePad.test", scope: Self.scope, radius: 14, activate: run)
        .id("console.gamePad.test")
    }

    /// The way to the game's own mapping: the controller drawn large, what the mapping is for, and A to open it.
    private var buttons: some View {
        let open = { driver.openGameMapping(game.id) }
        return VStack(alignment: .leading, spacing: 12) {
            ConsoleSectionHeading(title: t("console.gamePad.buttons"), compact: compact)
            Button(action: open) {
                VStack(alignment: .leading, spacing: compact ? 14 : 18) {
                    ConsolePadDiagram().frame(maxWidth: .infinity).frame(maxHeight: compact ? 180 : 300)
                        .padding(.top, 8)
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(t("console.mapping.game")).font(.manrope(compact ? 18 : 22, .semibold))
                            Text(t("console.mapping.gameNote")).font(.manrope(compact ? 13 : 15)).foregroundStyle(LauncherPalette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.system(size: 15, weight: .bold)).foregroundStyle(.white.opacity(0.4))
                            .accessibilityHidden(true)
                    }
                }
                .padding(compact ? 18 : 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 18))
                .contentShape(RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(t("console.mapping.game")).accessibilityHint(t("console.mapping.gameNote"))
            .padTarget("console.gamePad.mapping", scope: Self.scope, radius: 18, activate: open)
            .id("console.gamePad.mapping")
        }
    }
}

/// The bottom of a console list that scrolls fades over 24 points into the page's colour, so it does not end in a hard cut. A list
/// that fits shows no fade. `consoleScrollContent()` goes on the scroll view's content, `consoleScrollFade()` on the scroll view.
private struct ConsoleScrollContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ConsoleScrollFade: ViewModifier {
    @State private var contentHeight: CGFloat = 0
    @State private var visibleHeight: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .onPreferenceChange(ConsoleScrollContentHeight.self) { contentHeight = $0 }
            .transformPreference(ConsoleScrollContentHeight.self) { $0 = 0 }   // a list inside another reports to its own fade only
            .background(GeometryReader { g in
                Color.clear.onAppear { visibleHeight = g.size.height }.onChange(of: g.size.height) { visibleHeight = $0 }
            })
            .overlay(alignment: .bottom) {
                if contentHeight > visibleHeight + 1 {
                    LinearGradient(colors: [LauncherPalette.background.opacity(0), LauncherPalette.background], startPoint: .top, endPoint: .bottom)
                        .frame(height: 24).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
    }
}

extension View {
    func consoleScrollContent() -> some View {
        background(GeometryReader { g in Color.clear.preference(key: ConsoleScrollContentHeight.self, value: g.size.height) })
    }
    func consoleScrollFade() -> some View { modifier(ConsoleScrollFade()) }
}
