import SwiftUI
import NXCore
import NXLauncher

/// The button mapping in console mode, as a page over the whole screen, the iPhone app's mapping card (frontend-ios PadMappingView)
/// at the console's size. On the left the controller drawn (ConsolePadDiagram), each changed button ringed in cream and the one the
/// focus is on filled, a click on a button opening its choices. On the right, for all games: Swap A and B in menus (console mode's own
/// buttons, ConsoleButtons), the layout (Auto, Standard, By label, Custom) as the Controls page has it (`ControlLayout`), then, as for
/// a game's own mapping: Swap A and B in games and the 16 buttons in four groups (face buttons, shoulders and triggers, D-pad, more),
/// each row the button's glyph, where it sits and what it sends, a cream dot on a row that differs. Reset stays in a footer under the
/// list. A row picked shows the buttons it can send as a grid of glyphs in the same groups (for a game first the same as all games),
/// None last. The D-pad moves through `console.map.` targets, A picks, left / right on a row step through what it sends, B goes back
/// to the rows (ConsoleState.back) and then closes. Changes are kept only on Save: leaving after one asks "Save changes?", and Discard
/// puts back what the page opened with (ConsoleState.mappingOrigin). Swap A and B in menus applies on Save, so the menus keep their
/// buttons while the page is open.
@MainActor struct ConsolePadMappingSheet<Driver: ConsoleDriver>: View {
    @ObservedObject var driver: Driver
    let lang: Lang
    let compact: Bool
    @EnvironmentObject private var pad: PadFocus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The row whose choices were open last, so the focus goes back to it with the list.
    @State private var lastRow: String?

    static var scope: String { "console.mapping" }
    /// What a button can send, in the sheet's order: the 16 buttons, then nothing.
    static var choices: [String] { ConsolePadLayout.buttons + ["none"] }

    private var layout: ConsolePadLayout { driver.state.padLayout }
    private var isGame: Bool { layout.gameTitle != nil }
    private var inset: CGFloat { compact ? 24 : 64 }
    private func t(_ key: String) -> String { L10n.string(key, lang) }
    /// A button's name as the Controls page writes it ("A", "Left stick press", "None").
    private func name(_ button: String) -> String { button == "none" ? t("controls.none") : t("controls.fn." + button) }
    private func place(_ button: String) -> String { t("console.mapping.place." + button) }
    /// A and B swapped in games: the right button sends B and the bottom one A.
    private var swapped: Bool { layout.output("A") == "B" && layout.output("B") == "A" }
    /// The button the drawing fills: the one whose choices are open, else the row the focus is on.
    private var highlighted: String? {
        if let row = driver.state.mappingRow { return row }
        guard let id = pad.focused, id.hasPrefix("console.map.row.") else { return nil }
        return String(id.dropFirst("console.map.row.".count))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ConsolePageHeader(title: t(isGame ? "console.mapping.game" : "console.mapping"), subtitle: layout.gameTitle ?? t("console.mapping.allGames"),
                              compact: compact, closeLabel: t("console.close"), closeID: "console.map.close", scope: Self.scope) { driver.back() }
            if compact {
                drawing.frame(maxHeight: 170).padding(.horizontal, inset).padding(.bottom, 12)
                panel
            } else {
                HStack(alignment: .top, spacing: 56) {
                    drawing.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)   // the drawing sits in the middle of its column, not above an empty half
                    panel.frame(maxWidth: 680)
                }
                .padding(.leading, inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LauncherPalette.background)
        .onChange(of: driver.state.mappingRow) { row in
            if let row {
                lastRow = row
                pad.focused = "console.map.opt." + layout.output(row)
            } else if let lastRow {
                pad.focused = "console.map.row." + lastRow
            }
        }
    }

    // MARK: The drawing

    /// The controller, and under it the button the focus is on: where it sits and what it sends, or how to use the drawing.
    private var drawing: some View {
        let marked = Set(ConsolePadLayout.buttons.filter(layout.changed))
        return VStack(spacing: compact ? 10 : 28) {
            ConsolePadDiagram(marked: marked, highlighted: highlighted, tap: { driver.openMappingRow($0) })
                .frame(maxWidth: 720)
            if !compact {
                Group {
                    if let button = highlighted {
                        let output = layout.output(button)
                        HStack(spacing: 16) {
                            ConsolePadGlyph(button: button, size: 1.5)
                            Text(place(button)).font(.manrope(24, .semibold))
                            Image(systemName: "arrow.right").font(.system(size: 16, weight: .bold)).foregroundStyle(.white.opacity(0.45))
                            ConsolePadGlyph(button: output, lit: layout.changed(button), size: 1.5)
                            Text(name(output)).font(.manrope(24, .semibold)).foregroundStyle(layout.changed(button) ? LauncherPalette.cream : .white)
                        }
                        .lineLimit(1).minimumScaleFactor(0.7)
                    } else {
                        Text(t("console.mapping.tapHint")).font(.manrope(18)).foregroundStyle(.white.opacity(0.5))
                    }
                }
                .frame(height: 44)
                .animation(.easeOut(duration: 0.12), value: highlighted)
            }
        }
        .padding(.top, compact ? 0 : 24)
    }

    // MARK: The panel

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                    Group {
                        if let row = driver.state.mappingRow { options(row) } else { list }
                    }
                    .padding(.horizontal, compact ? inset : 0).padding(.trailing, compact ? 0 : inset).padding(.top, 4).padding(.bottom, 20)
                    }.consoleScrollContent()
                }
                .consoleScrollFade()
                .onChange(of: pad.focused) { id in
                    guard let id, id.hasPrefix("console.map.") else { return }
                    withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.18)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            if driver.state.mappingRow == nil {
                Rectangle().fill(.white.opacity(0.10)).frame(height: 1).padding(.leading, compact ? inset : 0).padding(.trailing, inset)
                footer
            }
        }
    }

    // MARK: The list

    private var list: some View {
        VStack(alignment: .leading, spacing: compact ? 22 : 28) {
            if !isGame {
                VStack(alignment: .leading, spacing: 10) {
                    ConsoleSectionHeading(title: t("console.mapping.group.menus"), compact: compact)
                    toggleCard(id: "console.map.menuSwap", title: t("console.mapping.menuSwap"), note: t("console.mapping.menuSwapNote"),
                               isOn: driver.state.shownMenuSwapAB, changed: driver.state.shownMenuSwapAB) { driver.setMenuSwapAB(!driver.state.shownMenuSwapAB) }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                ConsoleSectionHeading(title: t("console.mapping.group.games"), compact: compact)
                // A game's own mapping: no layouts, its buttons start as all games' and the dot marks what differs from them.
                Text(t(isGame ? "console.mapping.gameNote" : "console.mapping.note")).font(.manrope(compact ? 14 : 16)).foregroundStyle(LauncherPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4).padding(.bottom, 4)
                if !isGame { modes }
                toggleCard(id: "console.map.swap", title: t("console.mapping.swap"), note: t("console.mapping.swapNote"), isOn: swapped,
                           changed: layout.changed("A") || layout.changed("B")) {
                    let on = !swapped
                    driver.setPadSends(button: "A", to: on ? "B" : "A")
                    driver.setPadSends(button: "B", to: on ? "A" : "B")
                }
            }
            ForEach(ConsolePadLayout.groups, id: \.key) { group in
                VStack(alignment: .leading, spacing: 10) {
                    ConsoleSectionHeading(title: t(group.key), compact: compact)
                    VStack(spacing: 0) {
                        ForEach(Array(group.buttons.enumerated()), id: \.element) { index, button in
                            if index > 0 { Rectangle().fill(.white.opacity(0.06)).frame(height: 1).padding(.leading, compact ? 62 : 70) }
                            row(button)
                        }
                    }
                    .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.06)))
                    if group.buttons.first == "A" {
                        Text(t("console.mapping.namedNote")).font(.manrope(compact ? 13 : 15)).foregroundStyle(.white.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
                    }
                }
            }
        }
    }

    /// A switch on its own card: its name, a dot when it differs, the switch, and what it does under them. A flips it.
    private func toggleCard(id: String, title: String, note: String, isOn: Bool, changed: Bool, flip: @escaping () -> Void) -> some View {
        Button(action: flip) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(title).font(.manrope(compact ? 17 : 20, .semibold))
                    if changed { ChangedDot() }
                    Spacer(minLength: 8)
                    ConsoleSwitch(isOn: isOn, compact: compact)
                }
                Text(note).font(.manrope(compact ? 13 : 15)).foregroundStyle(LauncherPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.06)))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title).accessibilityValue(t(isOn ? "console.on" : "console.off")).accessibilityHint(note)
        .padTarget(id, scope: Self.scope, radius: 14, activate: flip, adjust: { _ in flip() })
        .id(id)
    }

    /// The layout as four equal segments, the chosen one cream, with the Controls page's note on it below.
    private var modes: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(t("controls.modeRow")).font(.manrope(compact ? 17 : 20, .semibold))
                if layout.mode != .standard { ChangedDot() }
            }
            HStack(spacing: 8) {
                ForEach(PadMode.allCases, id: \.self) { mode in segment(mode) }
            }
            Text(t("controls.modeNote." + layout.mode.rawValue)).font(.manrope(compact ? 13 : 15)).foregroundStyle(LauncherPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.06)))
    }

    private func segment(_ mode: PadMode) -> some View {
        let chosen = layout.mode == mode
        let pick = { driver.setPadMode(mode) }
        let label = t("controls.mode." + mode.rawValue)
        return Button(action: pick) {
            Text(label).font(.manrope(compact ? 14 : 16, chosen ? .bold : .semibold))
                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.75)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: compact ? 44 : 50)
                .foregroundStyle(chosen ? LauncherPalette.background : .white.opacity(0.85))
                .background(chosen ? LauncherPalette.cream : .white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(chosen ? 0 : 0.08)))
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t("controls.modeRow") + ", " + label)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .padTarget("console.map.mode." + mode.rawValue, scope: Self.scope, radius: 10, activate: pick)
        .id("console.map.mode." + mode.rawValue)
    }

    private func row(_ button: String) -> some View {
        let output = layout.output(button)
        let changed = layout.changed(button)
        let open = { driver.openMappingRow(button) }
        let step: (Int) -> Void = { by in
            let all = Self.choices
            let at = all.firstIndex(of: output) ?? 0
            driver.setPadSends(button: button, to: all[(at + by + all.count) % all.count])
        }
        return Button(action: open) {
            HStack(spacing: 12) {
                ConsolePadGlyph(button: button, size: compact ? 1 : 1.15).frame(width: compact ? 38 : 44)
                Text(place(button)).font(.manrope(compact ? 16 : 19, .medium))
                    .foregroundStyle(.white.opacity(changed ? 1 : 0.85)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if changed { ChangedDot() }
                Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(changed ? 0.5 : 0.25))
                ConsolePadGlyph(button: output, lit: changed, dim: !changed, size: compact ? 1 : 1.15).frame(minWidth: compact ? 38 : 44)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(.white.opacity(0.3))
            }
            .padding(.horizontal, 14).padding(.vertical, 6).frame(minHeight: compact ? 54 : 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name(button) + ", " + place(button))
        .accessibilityValue(name(output) + (changed ? ", " + t("console.mapping.changed") : ""))
        .accessibilityAdjustableAction { step($0 == .increment ? 1 : -1) }
        .padTarget("console.map.row." + button, scope: Self.scope, radius: 12, activate: open, adjust: step)
        .id("console.map.row." + button)
    }

    /// The key to the cream dot, and Reset, which is there whatever the list scrolls to. Reset goes back to the standard layout and
    /// can be focused only when something differs from it.
    private var footer: some View {
        // Reset goes away with what it resets, so the focus moves to the layout it chose.
        let reset = {
            driver.resetPadMapping()
            pad.focused = layout.gameTitle == nil ? "console.map.mode." + PadMode.standard.rawValue : "console.map.swap"
        }
        return HStack(spacing: 12) {
            HStack(spacing: 8) {
                ChangedDot()
                Text(t("console.mapping.changed")).font(.manrope(compact ? 14 : 16)).foregroundStyle(.white.opacity(0.55))
            }
            .opacity(layout.isDefault ? 0 : 1)
            .accessibilityHidden(true)
            Spacer(minLength: 8)
            if layout.isDefault {
                resetLabel(enabled: false)
            } else {
                Button(action: reset) { resetLabel(enabled: true) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(resetTitle)
                    .padTarget("console.map.reset", scope: Self.scope, radius: 24, activate: reset)
            }
        }
        .padding(.leading, compact ? inset : 0).padding(.trailing, inset).padding(.vertical, compact ? 14 : 18)
    }

    /// Reset, or for a game: the same as all games again.
    private var resetTitle: String { t(layout.gameTitle == nil ? "console.mapping.reset" : "console.mapping.sameAsAll") }

    private func resetLabel(enabled: Bool) -> some View {
        Text(resetTitle).font(.manrope(compact ? 15 : 18, .semibold))
            .padding(.horizontal, 22).frame(minHeight: compact ? 44 : 48)
            .foregroundStyle(.white.opacity(enabled ? 0.9 : 0.3))
            .background(.white.opacity(enabled ? 0.09 : 0.04), in: Capsule())
            .contentShape(Capsule())
            .accessibilityHidden(!enabled)
    }

    // MARK: A row's choices

    private func options(_ button: String) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)
        return VStack(alignment: .leading, spacing: compact ? 20 : 24) {
            HStack(spacing: 14) {
                ConsolePadGlyph(button: button, size: compact ? 1.2 : 1.4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(place(button)).font(.manrope(compact ? 20 : 24, .bold)).lineLimit(2)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityLabel(name(button) + ", " + place(button))
                    Text(t("console.mapping.sendsInGames")).font(.manrope(compact ? 14 : 16)).foregroundStyle(.white.opacity(0.5))
                }
            }
            if isGame { follow(button) }
            ForEach(ConsolePadLayout.groups, id: \.key) { group in
                VStack(alignment: .leading, spacing: 10) {
                    ConsoleSectionHeading(title: t(group.key), compact: compact)
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(group.buttons, id: \.self) { option in chip(button, option: option) }
                    }
                }
            }
            noneOption(button)
        }
    }

    private func pick(_ button: String, _ option: String) {
        driver.setPadSends(button: button, to: option)
        driver.openMappingRow(nil)
    }

    private func chip(_ button: String, option: String) -> some View {
        let chosen = layout.output(button) == option
        let isDefault = option == button
        return Button { pick(button, option) } label: {
            ConsolePadGlyph(button: option, inverted: chosen, size: compact ? 1.05 : 1.2)
                .frame(maxWidth: .infinity, minHeight: compact ? 56 : 64)
                .background(chosen ? LauncherPalette.cream : .white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(chosen ? 0 : 0.08)))
                .overlay(alignment: .topTrailing) {
                    // The button's own place: what it sends when nothing is changed.
                    if isDefault { Circle().fill(chosen ? .black.opacity(0.5) : .white.opacity(0.35)).frame(width: 6, height: 6).padding(8) }
                }
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name(option) + ", " + place(option))
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .padTarget("console.map.opt." + option, scope: Self.scope, radius: 12) { pick(button, option) }
        .id("console.map.opt." + option)
    }

    /// A game's button back to what it does in all games: shown first in its choices, chosen while the button follows them.
    private func follow(_ button: String) -> some View {
        let chosen = !layout.changed(button)
        let to = layout.baseline[button] ?? button
        return Button { pick(button, to) } label: {
            HStack(spacing: 12) {
                Text(t("console.mapping.sameAsAll")).font(.manrope(compact ? 16 : 19, chosen ? .bold : .medium))
                Spacer(minLength: 8)
                ConsolePadGlyph(button: to, inverted: chosen, size: compact ? 1 : 1.15)
                if chosen { Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).accessibilityHidden(true) }
            }
            .padding(.horizontal, 18).frame(minHeight: compact ? 56 : 64)
            .foregroundStyle(chosen ? LauncherPalette.background : .white.opacity(0.85))
            .background(chosen ? LauncherPalette.cream : .white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(chosen ? 0 : 0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t("console.mapping.sameAsAll")).accessibilityValue(name(to))
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .padTarget("console.map.opt.follow", scope: Self.scope, radius: 12) { pick(button, to) }
        .id("console.map.opt.follow")
    }

    private func noneOption(_ button: String) -> some View {
        let chosen = layout.output(button) == "none"
        return Button { pick(button, "none") } label: {
            HStack(spacing: 12) {
                Text(t("console.mapping.none")).font(.manrope(compact ? 16 : 19, chosen ? .bold : .medium))
                Spacer(minLength: 8)
                ConsolePadGlyph(button: "none", inverted: chosen, size: compact ? 1 : 1.15)
                if chosen { Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).accessibilityHidden(true) }
            }
            .padding(.horizontal, 18).frame(minHeight: compact ? 56 : 64)
            .foregroundStyle(chosen ? LauncherPalette.background : .white.opacity(0.85))
            .background(chosen ? LauncherPalette.cream : .white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(chosen ? 0 : 0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t("console.mapping.none"))
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .padTarget("console.map.opt.none", scope: Self.scope, radius: 12) { pick(button, "none") }
        .id("console.map.opt.none")
    }
}

/// The cream dot on what differs from the standard layout.
private struct ChangedDot: View {
    var body: some View { Circle().fill(LauncherPalette.cream).frame(width: 8, height: 8).accessibilityHidden(true) }
}

/// A controller button drawn as it looks on a Switch controller: the face buttons and + and − round, the shoulders and
/// triggers as a rounded bar, the D-pad as its arrow, the stick presses as a stick, None as a crossed circle. `lit` draws it in
/// cream (a changed value), `inverted` dark for a cream background (the chosen chip), `dim` quieter (an unchanged value).
/// `size` scales it for the console's larger type.
struct ConsolePadGlyph: View {
    let button: String
    var lit = false
    var inverted = false
    var dim = false
    var size: CGFloat = 1
    var body: some View {
        let ink: Color = inverted ? LauncherPalette.background : lit ? LauncherPalette.cream : .white.opacity(dim ? 0.45 : 0.9)
        let line: Color = inverted ? LauncherPalette.background.opacity(0.55) : lit ? LauncherPalette.cream.opacity(0.9) : .white.opacity(dim ? 0.2 : 0.4)
        let s = size
        Group {
            switch button {
            case "A", "B", "X", "Y":
                Text(verbatim: button).font(.manrope(13 * s, .heavy)).frame(width: 28 * s, height: 28 * s)
                    .overlay(Circle().strokeBorder(line, lineWidth: 1.5))
            case "Plus", "Minus":
                Image(systemName: button == "Plus" ? "plus" : "minus").font(.system(size: 11 * s, weight: .heavy)).frame(width: 24 * s, height: 24 * s)
                    .overlay(Circle().strokeBorder(line, lineWidth: 1.5))
            case "Up", "Down", "Left", "Right":
                // The arm's direction alone: the whole cross with one arm filled reads alike at this size.
                Image(systemName: "arrowtriangle.\(button.lowercased()).fill").font(.system(size: 11 * s, weight: .bold)).frame(width: 26 * s, height: 26 * s)
                    .overlay(RoundedRectangle(cornerRadius: 6 * s).strokeBorder(line, lineWidth: 1.5))
            case "LS", "RS":
                Image(systemName: button == "LS" ? "l.joystick.press.down" : "r.joystick.press.down").font(.system(size: 21 * s, weight: .regular))
                    .frame(width: 28 * s, height: 28 * s)
            case "none":
                Image(systemName: "nosign").font(.system(size: 17 * s, weight: .semibold)).frame(width: 28 * s, height: 28 * s)
            default:
                Text(verbatim: button).font(.manrope(12 * s, .heavy)).padding(.horizontal, 8 * s).frame(minWidth: 34 * s, minHeight: 24 * s)
                    .overlay(RoundedRectangle(cornerRadius: 7 * s, style: .continuous).strokeBorder(line, lineWidth: 1.5))
            }
        }
        .foregroundStyle(ink)
        .accessibilityHidden(true)
    }
}
