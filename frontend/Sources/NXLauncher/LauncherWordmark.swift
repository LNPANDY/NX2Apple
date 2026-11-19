import SwiftUI

/// The product's name at the top left of the main window (LNPANDY/NX2Apple#1458): the "NX2Apple" of the brand header before #1405,
/// in Manrope bold and the cream, at the size of a title bar's text rather than a banner.
package struct LauncherWordmark: View {
    package init() {}
    package static let text = "NX2Apple"
    package var body: some View {
        Text(Self.text)
            .font(.manrope(17, .bold)).tracking(-0.4)
            .foregroundStyle(DS.Color.textPrimary)   // cream is for the selected and the primary only (#1458)
            .lineLimit(1).fixedSize()
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("launcher.wordmark")
            .allowsHitTesting(false)
    }
}
