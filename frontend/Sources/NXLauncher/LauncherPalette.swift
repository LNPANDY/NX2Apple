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

    // Surfaces
    package static let background = dynamic(dark: NSColor(srgbRed: 0.055, green: 0.055, blue: 0.06, alpha: 1), light: rgb(0xF6F5F2))
    package static let surface = dynamic(dark: NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1), light: rgb(0xFFFFFF))
    /// The AppKit twin of `background`, for the window itself.
    package static func backgroundNSColor(light: Bool) -> NSColor { light ? rgb(0xF6F5F2) : NSColor(srgbRed: 0.055, green: 0.055, blue: 0.06, alpha: 1) }

    // The cream action: a fill with dark text on it in both appearances.
    package static let cream = dynamic(dark: NSColor(srgbRed: 1, green: 0.94, blue: 0.84, alpha: 1), light: rgb(0xFFF0D6))
    /// Text on a cream fill.
    package static let onCream = dynamic(dark: .black, light: rgb(0x18181B))
    /// Text on an amber fill (Stop): black on the Dark amber, white on the darker Light one.
    package static let onBuilding = dynamic(dark: .black, light: .white)
    /// The cream as a line, a mark or a tint on a surface: cream in Dark, the primary text color in Light, where cream on white has no contrast.
    package static let accent = dynamic(dark: NSColor(srgbRed: 1, green: 0.94, blue: 0.84, alpha: 1), light: rgb(0x18181B))

    // Status. Always shown with words.
    package static let ready = dynamic(dark: NSColor(srgbRed: 0.25, green: 0.84, blue: 0.47, alpha: 1), light: rgb(0x167646))
    package static let building = dynamic(dark: NSColor(srgbRed: 1, green: 0.78, blue: 0.24, alpha: 1), light: rgb(0x875600))
    package static let danger = dynamic(dark: NSColor(srgbRed: 1, green: 0.42, blue: 0.40, alpha: 1), light: rgb(0xB42328))
    package static let unbuilt = dynamic(dark: NSColor(srgbRed: 0.57, green: 0.58, blue: 0.61, alpha: 1), light: rgb(0x5F6068))

    // Text
    package static let text = dynamic(dark: .labelColor, light: rgb(0x18181B))
    package static let secondaryText = dynamic(dark: .secondaryLabelColor, light: rgb(0x5F6068))

    /// A hairline, a hover or a pressed fill, a quiet field: white at `opacity` in Dark, black at the same opacity in Light.
    package static func ink(_ opacity: Double) -> Color {
        dynamic(dark: NSColor.white.withAlphaComponent(opacity), light: NSColor.black.withAlphaComponent(opacity))
    }
    /// A field's inside (a log, a path): darker than the card in Dark, a quiet tint in Light.
    package static let well = dynamic(dark: NSColor.black.withAlphaComponent(0.22), light: NSColor.black.withAlphaComponent(0.05))
    package static let hairline = ink(0.10)
    package static let hover = ink(0.035)
    package static let pressed = ink(0.07)
    /// The border of the primary action in Light (black at 0.14), none in Dark.
    package static let actionBorder = dynamic(dark: .clear, light: NSColor.black.withAlphaComponent(0.14))

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
    package static let lightValues: [(name: String, color: NSColor, on: NSColor)] = [
        ("text", rgb(0x18181B), rgb(0xF6F5F2)), ("text on card", rgb(0x18181B), rgb(0xFFFFFF)),
        ("secondary", rgb(0x5F6068), rgb(0xFFFFFF)), ("secondary on page", rgb(0x5F6068), rgb(0xF6F5F2)),
        ("ready", rgb(0x167646), rgb(0xFFFFFF)), ("attention", rgb(0x875600), rgb(0xFFFFFF)),
        ("destructive", rgb(0xB42328), rgb(0xFFFFFF)), ("on cream", rgb(0x18181B), rgb(0xFFF0D6)),
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
    func body(content: Content) -> some View {
        content.preferredColorScheme((LauncherAppearance(rawValue: stored) ?? .system).scheme)
    }
}

extension View {
    /// The window or sheet follows the player's appearance choice.
    package func launcherAppearance() -> some View { modifier(LauncherAppearanceModifier()) }
}
