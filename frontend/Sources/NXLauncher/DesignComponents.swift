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
/// The one primary action of a screen: Liquid Glass tinted with the accent.
package typealias DSPrimaryButtonStyle = LauncherActionButtonStyle
/// Every other button: clear Liquid Glass. In a row it is as wide as the control column.
package typealias DSSecondaryButtonStyle = LauncherSecondaryButtonStyle
/// A round glass button with a symbol.
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
