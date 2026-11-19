import SwiftUI

// The launcher's components on top of the design tokens (DS, Generated/DesignTokens.swift), LNPANDY/NX2Apple#1458. Screens
// compose these instead of styling text, colours and paddings themselves. frontend/README.md, "Design tokens and components",
// says which one to use for what.

/// A page's title and its one-line subtitle.
package typealias DSPageHeading = CardPageHeading
/// A section: the header over one card of rows, and a footnote under it.
package typealias DSSection = CardGroup
/// A row of a section: a reserved leading slot (status dot), the title, one secondary line and the trailing control column.
package typealias DSRow = CardRow
/// The hairline between two rows, aligned with the row titles.
package typealias DSRowDivider = CardDivider
/// The one primary action of a screen: the accent. Glass in the navigation layer (`launcherGlassLayer()`), a flat accent fill in
/// the content. Disabled, it is the raised surface with tertiary text.
package typealias DSPrimaryButtonStyle = LauncherActionButtonStyle
/// Every other button. Glass in the navigation layer, flat in the content (raised surface, hairline). In a row it is as wide as
/// the control column.
package typealias DSSecondaryButtonStyle = LauncherSecondaryButtonStyle
/// A row's button ("Choose…", "Change…", "Copy", a notice's action): always in the content layer, so always flat.
package typealias DSRowButtonStyle = LauncherSecondaryButtonStyle
/// A round button with a symbol, glass only in the navigation layer.
package typealias DSIconButtonStyle = LauncherIconButtonStyle
/// A status chip: a state that needs attention (Missing data, Not built), never a quiet property.
package typealias DSChip = ArtworkStatusChip
/// A notice under the top bar: the one way to tell the player something outside a sheet.
package typealias DSNotice = LauncherNotice

/// A plain card: the surface, the card radius and the hairline, with the standard inner padding.
package struct DSCard<Content: View>: View {
    package init(padding: CGFloat = DS.Space.m, @ViewBuilder _ content: () -> Content) { self.padding = padding; self.content = content() }
    let padding: CGFloat
    let content: Content
    package var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LauncherPalette.card, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(LauncherPalette.cardBorder))
    }
}

/// The bar under a wizard (the build wizard, the onboarding): Back on the leading side, where the player is ("Step 2 of 4") in the
/// middle, the primary action on the trailing side, over a hairline, in the page's content column.
package struct DSWizardFooter<Leading: View, Trailing: View>: View {
    package init(progress: String?, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.progress = progress; self.leading = leading(); self.trailing = trailing()
    }
    let progress: String?
    let leading: Leading
    let trailing: Trailing
    package var body: some View {
        VStack(spacing: 0) {
            DS.Color.separator.frame(height: 1)
            ZStack {
                HStack(spacing: DS.Space.s) {
                    leading
                    Spacer(minLength: DS.Space.s)
                    trailing
                }
                if let progress {
                    Text(progress).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary).lineLimit(1)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, DS.Space.xl).padding(.vertical, DS.Space.m)
            .frame(maxWidth: DS.Control.contentWidth).frame(maxWidth: .infinity)
        }
        .background(DS.Color.background)
        .launcherGlassLayer()   // the footer bar stays over the scrolling content: its buttons are glass (#1458)
    }
}

/// The "…" beside a row's control column: the row's second and further actions, in the launcher's menu, so the column keeps one
/// button. A controller's A on it runs `padDefault` (the first option), as the menu cannot be walked with the pad.
package struct DSOverflowMenu: View {
    package init(label: String, options: [(value: String, label: String)], padID: String, choose: @escaping (String) -> Void) {
        self.label = label; self.options = options; self.padID = padID; self.choose = choose
    }
    let label: String
    let options: [(value: String, label: String)]
    let padID: String
    let choose: (String) -> Void
    @Environment(\.launcherDropdownHost) private var dropdowns
    @EnvironmentObject private var pad: PadFocus
    @State private var menuID = UUID()

    package var body: some View {
        Button(action: open) { Image(systemName: "ellipsis") }
            .buttonStyle(LauncherIconButtonStyle())
            .help(label).accessibilityLabel(label)
            .anchorPreference(key: LauncherDropdownAnchorKey.self, value: .bounds) { [menuID: $0] }
            .padTarget(padID, scope: "main") { if let first = options.first { choose(first.value) } }
    }

    private func open() {
        dropdowns?.request = LauncherDropdownRequest(id: menuID, options: options, selection: "", label: label) { value in
            dropdowns?.close(); pad.scope = "main"
            choose(value)
        }
    }
}

/// A warning inside a card, under the row it is about: a symbol in the warning colour and the text in the row's secondary style.
package struct DSInlineWarning: View {
    package init(_ text: String) { self.text = text }
    let text: String
    package var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.statusWarning)
                .accessibilityHidden(true)
            Text(text).font(DS.Font.callout).foregroundStyle(DS.Color.textPrimary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DS.Space.s).padding(.vertical, DS.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.statusWarning.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.Radius.chip))
        .accessibilityElement(children: .combine)
    }
}

/// Where a row's title starts inside its card: a note under a row lines up with it.
package enum DSRowInset {
    package static let title = DS.Space.xs + DS.Control.leadingSlot + DS.Space.s
}

/// The label of a wizard's forward button: its title with a trailing chevron.
package struct DSContinueLabel: View {
    package init(_ title: String) { self.title = title }
    let title: String
    package var body: some View {
        HStack(spacing: DS.Space.xs) {
            Text(title)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
        }
        .font(DS.Font.bodyStrong)
        .padding(.horizontal, DS.Space.m + DS.Space.xxs).frame(height: DS.Control.height)
    }
}

/// A capsule (a circle in a square frame) drawn from its own path. Use it for every capsule or round control with a hairline:
/// SwiftUI turns `Capsule().strokeBorder` into a layer border, and AppKit's bitmap caching (the captures, the gallery's export)
/// draws that border with straight bars past the round ends, so a button's or a chip's outline looked cut at its left and right.
package struct DSPill: InsettableShape {
    package init() {}
    private var inset: CGFloat = 0
    package func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        guard r.width > 0, r.height > 0 else { return Path() }
        return Path(roundedRect: r, cornerRadius: min(r.width, r.height) / 2, style: .circular)
    }
    package func inset(by amount: CGFloat) -> DSPill { var pill = self; pill.inset += amount; return pill }
}

// MARK: Card interaction

/// A state of a card forced for a capture or the state gallery, where no pointer or controller is there to make it.
package enum DSCardPreview { case hover, pressed, focus }

private struct DSCardHoverKey: EnvironmentKey { static let defaultValue = false }
private struct DSCardPressedKey: EnvironmentKey { static let defaultValue = false }
private struct DSCardPreviewKey: EnvironmentKey { static let defaultValue: DSCardPreview? = nil }

extension EnvironmentValues {
    /// Set by DSCardButtonStyle: the pointer is over the card.
    package var dsCardHovered: Bool {
        get { self[DSCardHoverKey.self] }
        set { self[DSCardHoverKey.self] = newValue }
    }
    /// Set by DSCardButtonStyle: the card is pressed.
    package var dsCardPressed: Bool {
        get { self[DSCardPressedKey.self] }
        set { self[DSCardPressedKey.self] = newValue }
    }
    /// A forced state for captures (DSCardPreview).
    package var dsCardPreview: DSCardPreview? {
        get { self[DSCardPreviewKey.self] }
        set { self[DSCardPreviewKey.self] = newValue }
    }
}

/// The button of a card (a game in the Recently played row or the All games grid, the Show all card). It draws nothing itself:
/// it tells the artwork (`dsCardArt`) whether the pointer is over it and whether it is pressed. The title and the layout never
/// change. The console mode's cards keep their own focus look.
package struct DSCardButtonStyle: ButtonStyle {
    package init() {}
    package func makeBody(configuration: Configuration) -> some View { DSCardButton(configuration: configuration) }
}

private struct DSCardButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    var body: some View {
        configuration.label
            .environment(\.dsCardHovered, hovered && enabled)
            .environment(\.dsCardPressed, configuration.isPressed && enabled)
            .onHover { hovered = $0 }
            .launcherHover()   // the hand cursor only: launcherHover adds no size, plate or movement
    }
}

extension View {
    /// The interaction of a card, on its artwork only (tokens `interaction.*`): under the pointer a white veil of
    /// `hoverOverlay`, pressed a stronger one, selected (the hero's game) a 2 pt accent ring, focused by the controller or the
    /// keyboard the focus ring outside the artwork and a scale of `focusScale` around its centre. Nothing else moves: no plate,
    /// no shadow, no frame change, so the neighbours and the title stay put. Give the row room for the focused scale and ring.
    package func dsCardArt(radius: CGFloat, selected: Bool, focused: Bool) -> some View {
        modifier(DSCardArt(radius: radius, selected: selected, focused: focused))
    }
}

private struct DSCardArt: ViewModifier {
    let radius: CGFloat
    let selected: Bool
    let focused: Bool
    @Environment(\.dsCardHovered) private var hovered
    @Environment(\.dsCardPressed) private var pressed
    @Environment(\.dsCardPreview) private var preview
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let isPressed = pressed || preview == .pressed
        let isHovered = hovered || preview == .hover
        let isFocused = focused || preview == .focus
        let veil = isPressed ? DS.Interaction.pressedOverlay : (isHovered ? DS.Interaction.hoverOverlay : 0)
        let shape = RoundedRectangle(cornerRadius: radius)
        let ringOut = DS.Interaction.focusRingGap + DS.Interaction.focusRing
        return content
            .overlay(shape.fill(Color.white.opacity(veil)).allowsHitTesting(false))
            .overlay(shape.strokeBorder(selected ? DS.Color.accent : DS.Color.separator, lineWidth: selected ? DS.Interaction.selectedRing : 1))
            .overlay {
                RoundedRectangle(cornerRadius: radius + ringOut)
                    .strokeBorder(LauncherPalette.focusRing, lineWidth: DS.Interaction.focusRing)
                    .padding(-ringOut)
                    .opacity(isFocused ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .scaleEffect(isFocused && !reduceMotion ? DS.Interaction.focusScale : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: DS.Motion.quick), value: veil)
            .animation(reduceMotion ? nil : .easeOut(duration: DS.Motion.quick), value: isFocused)
    }
}

/// The room a row or grid of cards keeps around each card, so the focused artwork (its scale and its ring) is never clipped.
package enum DSCardRoom {
    package static func around(width: CGFloat) -> CGFloat {
        ceil(width * (DS.Interaction.focusScale - 1) / 2 + DS.Interaction.focusRingGap + DS.Interaction.focusRing + 1)
    }
}

/// A row's hover (DSRow and list items): the raised surface over the whole row, no scale.
extension View {
    package func dsRowHover(radius: CGFloat = DS.Radius.chip) -> some View { modifier(DSRowHover(radius: radius)) }
}

private struct DSRowHover: ViewModifier {
    let radius: CGFloat
    @State private var hovered = false
    @Environment(\.dsCardPreview) private var preview
    func body(content: Content) -> some View {
        content
            .background((hovered || preview == .hover) ? DS.Color.surfaceRaised : .clear, in: RoundedRectangle(cornerRadius: radius))
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: DS.Motion.quick), value: hovered)
    }
}
