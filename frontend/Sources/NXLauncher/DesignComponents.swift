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
