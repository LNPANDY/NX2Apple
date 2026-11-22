import SwiftUI
import AppKit

/// The launcher's colors as meanings (LNPANDY/NX2Apple#683). The launcher is dark only (LNPANDY/NX2Apple#1458): every window and
/// sheet is drawn in Dark, so each token has one value. The cream is the one accent, for the primary action and the focus ring.
/// The values live in frontend/design-tokens/tokens.json (`DS`): these names are aliases kept while screens move to `DS`.
package enum LauncherPalette {
    private static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    private static let darkBackground = NSColor(srgbRed: 0.055, green: 0.055, blue: 0.06, alpha: 1)
    private static let darkSurface = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1)
    private static let darkCream = NSColor(srgbRed: 1, green: 0.94, blue: 0.84, alpha: 1)
    private static func white(_ a: CGFloat) -> NSColor { NSColor.white.withAlphaComponent(a) }
    private static func black(_ a: CGFloat) -> NSColor { NSColor.black.withAlphaComponent(a) }

    // Surfaces
    package static let background = DS.Color.background
    package static let surface = DS.Color.surface
    /// The AppKit twin of `background`, for the window itself.
    package static let backgroundNSColor = DS.Color.nsBackground
    /// A card of rows (CardGroup and every card like it): the surface at 0.75.
    package static let card = Color(nsColor: darkSurface.withAlphaComponent(0.75))
    /// A card's hairline.
    package static let cardBorder = Color(nsColor: white(0.06))
    /// The line under the top bar.
    package static let topBarRule = Color(nsColor: white(0.06))

    // The primary action: the cream.
    package static let cream = DS.Color.accent
    /// Text on the primary action's fill.
    package static let onCream = DS.Color.accentOn
    /// The primary action under the pointer and pressed: the cream, the glass gives the feedback.
    package static let primaryHover = Color(nsColor: darkCream)
    package static let primaryPressed = Color(nsColor: darkCream)
    /// Text on an amber fill (Stop).
    package static let onBuilding = Color(nsColor: .black)
    /// The cream as a line, a mark or a tint on a surface.
    package static let accent = DS.Color.accent
    /// No border around the primary action.
    /// The controller's focus ring (PadFocus) and the underline of the selected tile in the collection: the cream.
    package static let focusRing = Color(nsColor: darkCream)
    package static var focusRingWidth: CGFloat { 2 }
    package static let selectionUnderline = focusRing
    package static var selectionUnderlineHeight: CGFloat { 3 }
    package static let actionBorder = Color(nsColor: .clear)

    // A secondary button, a menu button or a pop-up.
    package static let secondaryFill = Color(nsColor: rgb(0x202023))
    package static let secondaryHover = Color(nsColor: rgb(0x2A2A2E))
    package static let secondaryPressed = Color(nsColor: rgb(0x353539))
    package static let secondaryBorder = Color(nsColor: white(0.10))
    /// The top bar's buttons and a closed pop-up.
    package static let menuFill = Color(nsColor: rgb(0x202023))
    package static let dropdownFill = Color(nsColor: rgb(0x202023))
    package static let dropdownOpenBorder = Color(nsColor: white(0.18))

    // LauncherSegmented: the track, the chosen pill and the texts.
    package static let segmentTrack = Color(nsColor: rgb(0x242427))
    package static let segmentTrackBorder = Color(nsColor: white(0.08))
    package static let segmentSelected = Color(nsColor: darkCream)
    package static let segmentSelectedBorder = Color(nsColor: .clear)
    package static let segmentSelectedText = Color(nsColor: .black)
    package static let segmentText = Color(nsColor: white(0.75))

    // The 40 x 24 switch.
    package static let switchOnTrack = Color(nsColor: darkCream)
    package static let switchOnKnob = Color(nsColor: .black)
    package static let switchOffTrack = Color(nsColor: white(0.14))
    package static let switchOffKnob = Color(nsColor: white(0.85))

    // A selectable card or row (the Builds page's destinations): its fill, border and radio, chosen or not.
    package static let selectableFill = card
    package static let selectableBorder = Color(nsColor: white(0.06))
    package static let selectedFill = Color(nsColor: darkCream.withAlphaComponent(0.05))
    /// The onboarding's chosen platform card (a little stronger tint).
    package static let selectedFillStrong = Color(nsColor: darkCream.withAlphaComponent(0.07))
    package static let selectedBorder = Color(nsColor: darkCream.withAlphaComponent(0.7))
    package static let radioOff = Color(nsColor: white(0.25))
    package static let radioOn = accent

    // Status. Always shown with words.
    /// A quiet advisory beside a status (an older iOS build): the info tone.
    package static let advisory = DS.Color.statusInfo
    package static let ready = DS.Color.statusReady
    package static let building = DS.Color.statusWarning
    package static let danger = DS.Color.statusError
    package static let unbuilt = Color(nsColor: NSColor(srgbRed: 0.57, green: 0.58, blue: 0.61, alpha: 1))
    /// A small marked word beside a status (the Switch 2 badge).
    package static let notice = Color(nsColor: darkCream.withAlphaComponent(0.85))
    package static let noticeBorder = Color(nsColor: darkCream.withAlphaComponent(0.35))

    // Text
    package static let text = DS.Color.textPrimary
    package static let secondaryText = DS.Color.textSecondary
    /// Text that is plain white (the onboarding, the controllers sheet).
    package static let textStrong = Color(nsColor: .white)
    /// Placeholders and the quietest notes.
    package static let tertiaryText = DS.Color.textTertiary

    /// A hairline, a hover or a pressed fill, a quiet field: white at `opacity`.
    package static func ink(_ opacity: Double) -> Color {
        Color(nsColor: NSColor.white.withAlphaComponent(opacity))
    }
    /// A field's inside (a log, a path): darker than the card.
    package static let well = Color(nsColor: NSColor.black.withAlphaComponent(0.22))
    /// Floating popovers and menus (LauncherDropdown, ManageMenu): a deep shadow.
    package static let dropdownShadow = Color(nsColor: black(0.5))
    package static let hairline = DS.Color.separator
    package static let hover = ink(0.035)
    package static let pressed = ink(0.07)

    /// WCAG contrast of two sRGB colors, for the tests that keep the palette readable.
    package static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        func luminance(_ c: NSColor) -> Double {
            let c = c.usingColorSpace(.sRGB) ?? c
            func channel(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
        }
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}

extension View {
    /// Every window and sheet of the launcher is Dark. A light or system value an older version kept under "appearance" in the
    /// defaults is ignored (LNPANDY/NX2Apple#1458).
    package func launcherAppearance() -> some View { environment(\.colorScheme, .dark).preferredColorScheme(.dark) }

    /// The console mode and what it shows: Dark, as the rest of the launcher.
    package func consoleDarkAppearance() -> some View { launcherAppearance() }
}
