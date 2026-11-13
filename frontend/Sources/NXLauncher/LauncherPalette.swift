import SwiftUI
import AppKit

/// The launcher's colors as meanings (LNPANDY/NX2Apple#683). Dark is the palette the launcher always had. Light has its own values
/// for the same meanings, not an inversion: a color is picked by the appearance of the view that draws it (the window follows the
/// System, Light or Dark choice, see `LauncherAppearance`). Artwork and the console mode do not use these in Light.
package enum LauncherPalette {
    /// A color with one value per appearance, resolved when it is drawn.
    package static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua ? light : dark
        })
    }

    private static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    private static let darkBackground = NSColor(srgbRed: 0.055, green: 0.055, blue: 0.06, alpha: 1)
    private static let darkSurface = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1)
    private static let darkCream = NSColor(srgbRed: 1, green: 0.94, blue: 0.84, alpha: 1)
    private static func white(_ a: CGFloat) -> NSColor { NSColor.white.withAlphaComponent(a) }
    private static func black(_ a: CGFloat) -> NSColor { NSColor.black.withAlphaComponent(a) }

    // Surfaces
    package static let background = dynamic(dark: darkBackground, light: rgb(0xF2F1EE))
    package static let surface = dynamic(dark: darkSurface, light: rgb(0xFFFFFF))
    /// The AppKit twin of `background`, for the window itself.
    package static func backgroundNSColor(light: Bool) -> NSColor { light ? rgb(0xF2F1EE) : darkBackground }
    /// A card of rows (CardGroup and every card like it): the surface at 0.75 in Dark, white in Light.
    package static let card = dynamic(dark: darkSurface.withAlphaComponent(0.75), light: rgb(0xFFFFFF))
    /// A card's hairline.
    package static let cardBorder = dynamic(dark: white(0.06), light: black(0.08))
    /// The line under the top bar in Light (Dark keeps its divider).
    package static let topBarRule = dynamic(dark: white(0.06), light: black(0.08))

    // The primary action: the cream capsule in Dark, near-black with white text in Light. The library's hero stays dark in both.
    package static let cream = dynamic(dark: darkCream, light: rgb(0x18181B))
    /// Text on the primary action's fill.
    package static let onCream = dynamic(dark: .black, light: rgb(0xFFFFFF))
    /// The primary action under the pointer and pressed (Light only, Dark keeps the cream).
    package static let primaryHover = dynamic(dark: darkCream, light: rgb(0x2A2A2E))
    package static let primaryPressed = dynamic(dark: darkCream, light: rgb(0x000000))
    /// Text on an amber fill (Stop): black on the Dark amber, white on the darker Light one.
    package static let onBuilding = dynamic(dark: .black, light: .white)
    /// The cream as a line, a mark or a tint on a surface: cream in Dark, the primary text color in Light, where cream on white has no contrast.
    package static let accent = dynamic(dark: darkCream, light: rgb(0x18181B))
    /// No border around the primary action in either appearance.
    /// The controller's focus ring (PadFocus) and the underline of the selected tile in the collection. Dark keeps the cream it always
    /// had. Light uses the primary at 0.55: solid near-black read as a heavy outline on the light page.
    package static let focusRing = dynamic(dark: darkCream, light: rgb(0x18181B, alpha: 0.55))
    package static var focusRingWidth: CGFloat { 2 }
    package static let selectionUnderline = focusRing
    package static var selectionUnderlineHeight: CGFloat { 3 }
    package static let actionBorder = dynamic(dark: .clear, light: .clear)

    // A secondary button, a menu button or a pop-up.
    package static let secondaryFill = dynamic(dark: white(0.055), light: rgb(0xF4F3F0))
    package static let secondaryHover = dynamic(dark: white(0.055), light: rgb(0xECEBE7))
    package static let secondaryPressed = dynamic(dark: white(0.13), light: rgb(0xE4E3DF))
    package static let secondaryBorder = dynamic(dark: white(0.10), light: black(0.10))
    /// The top bar's buttons (New build, the player chip) and a closed pop-up: their own Dark fills, the secondary fill in Light.
    package static let menuFill = dynamic(dark: white(0.07), light: rgb(0xF4F3F0))
    package static let dropdownFill = dynamic(dark: white(0.06), light: rgb(0xF4F3F0))
    package static let dropdownOpenBorder = dynamic(dark: white(0.18), light: black(0.10))

    // LauncherSegmented: the track, the chosen pill and the texts.
    package static let segmentTrack = dynamic(dark: white(0.06), light: rgb(0xE9E8E4))
    package static let segmentTrackBorder = dynamic(dark: white(0.08), light: .clear)
    package static let segmentSelected = dynamic(dark: darkCream, light: rgb(0xFFFFFF))
    package static let segmentSelectedBorder = dynamic(dark: .clear, light: black(0.10))
    package static let segmentSelectedText = dynamic(dark: .black, light: rgb(0x18181B))
    package static let segmentText = dynamic(dark: white(0.75), light: rgb(0x5F6068))

    // The 40 x 24 switch.
    package static let switchOnTrack = dynamic(dark: darkCream, light: rgb(0x18181B))
    package static let switchOnKnob = dynamic(dark: .black, light: rgb(0xFFFFFF))
    package static let switchOffTrack = dynamic(dark: white(0.14), light: rgb(0xD9D8D4))
    package static let switchOffKnob = dynamic(dark: white(0.85), light: rgb(0xFFFFFF))

    // A selectable card or row (the Builds page's destinations): its fill, border and radio, chosen or not.
    package static let selectableFill = card
    package static let selectableBorder = dynamic(dark: white(0.06), light: black(0.10))
    package static let selectedFill = dynamic(dark: darkCream.withAlphaComponent(0.05), light: rgb(0xFFFFFF))
    /// The onboarding's chosen platform card (a little stronger tint in Dark).
    package static let selectedFillStrong = dynamic(dark: darkCream.withAlphaComponent(0.07), light: rgb(0xFFFFFF))
    package static let selectedBorder = dynamic(dark: darkCream.withAlphaComponent(0.7), light: rgb(0x18181B))
    package static let radioOff = dynamic(dark: white(0.25), light: rgb(0xA1A1A6))
    package static let radioOn = accent

    // Status. Always shown with words.
    package static let ready = dynamic(dark: NSColor(srgbRed: 0.25, green: 0.84, blue: 0.47, alpha: 1), light: rgb(0x167646))
    package static let building = dynamic(dark: NSColor(srgbRed: 1, green: 0.78, blue: 0.24, alpha: 1), light: rgb(0x875600))
    package static let danger = dynamic(dark: NSColor(srgbRed: 1, green: 0.42, blue: 0.40, alpha: 1), light: rgb(0xB42328))
    package static let unbuilt = dynamic(dark: NSColor(srgbRed: 0.57, green: 0.58, blue: 0.61, alpha: 1), light: rgb(0x5F6068))
    /// A small marked word beside a status (the Switch 2 badge): cream in Dark, the attention color in Light.
    package static let notice = dynamic(dark: darkCream.withAlphaComponent(0.85), light: rgb(0x875600))
    package static let noticeBorder = dynamic(dark: darkCream.withAlphaComponent(0.35), light: rgb(0x875600, alpha: 0.35))

    // Text
    package static let text = dynamic(dark: .labelColor, light: rgb(0x18181B))
    package static let secondaryText = dynamic(dark: .secondaryLabelColor, light: rgb(0x5F6068))
    /// Text that is plain white in Dark (the onboarding, the controllers sheet), the primary text color in Light.
    package static let textStrong = dynamic(dark: .white, light: rgb(0x18181B))
    /// Placeholders and the quietest notes.
    package static let tertiaryText = dynamic(dark: .tertiaryLabelColor, light: rgb(0x8E8E93))

    /// A hairline, a hover or a pressed fill, a quiet field: white at `opacity` in Dark, black at the same opacity in Light.
    package static func ink(_ opacity: Double) -> Color {
        dynamic(dark: NSColor.white.withAlphaComponent(opacity), light: NSColor.black.withAlphaComponent(opacity))
    }
    /// A field's inside (a log, a path): darker than the card in Dark, a quiet tint in Light.
    package static let well = dynamic(dark: NSColor.black.withAlphaComponent(0.22), light: NSColor.black.withAlphaComponent(0.05))
    /// Floating popovers and menus (LauncherDropdown, ManageMenu): a deep shadow in Dark, a light elevation shadow in Light.
    package static let dropdownShadow = dynamic(dark: black(0.5), light: black(0.12))
    package static let hairline = ink(0.10)
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
    /// Every text and background pair of Light. Each keeps WCAG 4.5 (PaletteTests).
    package static let lightValues: [(name: String, color: NSColor, on: NSColor)] = [
        ("text", rgb(0x18181B), rgb(0xF2F1EE)), ("text on card", rgb(0x18181B), rgb(0xFFFFFF)),
        ("secondary", rgb(0x5F6068), rgb(0xFFFFFF)), ("secondary on page", rgb(0x5F6068), rgb(0xF2F1EE)),
        ("ready", rgb(0x167646), rgb(0xFFFFFF)), ("ready on page", rgb(0x167646), rgb(0xF2F1EE)),
        ("attention", rgb(0x875600), rgb(0xFFFFFF)), ("attention on page", rgb(0x875600), rgb(0xF2F1EE)),
        ("destructive", rgb(0xB42328), rgb(0xFFFFFF)), ("destructive on page", rgb(0xB42328), rgb(0xF2F1EE)),
        ("on primary", rgb(0xFFFFFF), rgb(0x18181B)), ("on primary hover", rgb(0xFFFFFF), rgb(0x2A2A2E)),
        ("on primary pressed", rgb(0xFFFFFF), rgb(0x000000)),
        ("secondary button", rgb(0x18181B), rgb(0xF4F3F0)), ("secondary button hover", rgb(0x18181B), rgb(0xECEBE7)),
        ("secondary button pressed", rgb(0x18181B), rgb(0xE4E3DF)),
        ("segment selected", rgb(0x18181B), rgb(0xFFFFFF)), ("segment", rgb(0x5F6068), rgb(0xE9E8E4)),
    ]
}

/// System, Light or Dark for the launcher's windows and sheets. The first launch follows the System. The choice is kept in the
/// app's defaults as one of these words.
package enum LauncherAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    package var id: String { rawValue }
    package static let defaultsKey = "appearance"
    package var labelKey: String { "appearance." + rawValue }
    package var scheme: ColorScheme? { self == .system ? nil : (self == .light ? .light : .dark) }

    package static func load(_ defaults: UserDefaults = .standard) -> LauncherAppearance {
        LauncherAppearance(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .system
    }
    package func save(_ defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: Self.defaultsKey) }
}

private struct LauncherAppearanceModifier: ViewModifier {
    @AppStorage(LauncherAppearance.defaultsKey) private var stored = LauncherAppearance.system.rawValue
    let forceDark: Bool
    func body(content: Content) -> some View {
        content.preferredColorScheme(LauncherAppearance.scheme(stored: stored, forceDark: forceDark))
    }
}

extension LauncherAppearance {
    /// The scheme a window gets: the player's choice, or Dark while the console mode shows, which is dark whatever the choice.
    package static func scheme(stored: String, forceDark: Bool) -> ColorScheme? {
        forceDark ? .dark : (LauncherAppearance(rawValue: stored) ?? .system).scheme
    }
}

extension View {
    /// The window or sheet follows the player's appearance choice. `forceDark` keeps it Dark (the console mode).
    package func launcherAppearance(forceDark: Bool = false) -> some View { modifier(LauncherAppearanceModifier(forceDark: forceDark)) }

    /// The console mode and what it shows: Dark in every appearance, its tokens resolved to their Dark values.
    package func consoleDarkAppearance() -> some View { environment(\.colorScheme, .dark).preferredColorScheme(.dark) }
}
