import SwiftUI

/// Liquid Glass for the launcher's buttons, as the iPhone app has them (LNPANDY/NX2Apple#1458). The button styles keep their own
/// label metrics (the 36 pt row height, the shared control width that LauncherControlWidthTests checks), so they draw the system's
/// glass material behind the label instead of handing the button to `.buttonStyle(.glass)`, which sizes the label itself.
package enum LauncherGlass {
    /// Whether the live material is drawn: macOS 26 and later, outside the test runner. AppKit's bitmap caching (`cacheDisplay`,
    /// which every render test and capture uses) cannot rasterize Liquid Glass and leaves the window blank, so tests draw the
    /// static stand-in below, which is also what macOS before 26 shows.
    package static var live: Bool { supported && !forceStatic }
    private static let supported: Bool = {
        guard #available(macOS 26, *) else { return false }
        return NSClassFromString("XCTestCase") == nil && ProcessInfo.processInfo.environment["NX_LAUNCHER_STATIC_GLASS"] == nil
    }()
    /// Set while the state gallery renders a PNG (GalleryRenderer): views built then draw the stand-in.
    package static var forceStatic = false
    /// The stand-in of clear glass on the dark page: a light veil, brighter at the top edge as the material catches light.
    package static let veil = LauncherPalette.ink(0.08)
    package static let rim = LinearGradient(colors: [LauncherPalette.ink(0.22), LauncherPalette.ink(0.06)], startPoint: .top, endPoint: .bottom)
}

extension View {
    /// The glass of a secondary button or an icon button: clear glass, or glass tinted with `tint` for the one primary action of
    /// a screen. `fallback` and `border` are the stand-in's fill and line where the material is not drawn (nil: the glass veil).
    @ViewBuilder package func launcherGlass<S: InsettableShape>(in shape: S, tint: Color? = nil, fallback: Color? = nil, border: Color? = nil) -> some View {
        if #available(macOS 26, *), LauncherGlass.live {
            glassEffect(tint.map { Glass.regular.tint($0).interactive() } ?? Glass.regular.interactive(), in: shape)
        } else if let tint {
            background(tint, in: shape)
                .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center)))
        } else {
            background(fallback ?? LauncherGlass.veil, in: shape)
                .overlay { if let border { shape.strokeBorder(border) } else { shape.strokeBorder(LauncherGlass.rim) } }
        }
    }
}

private struct LauncherGlassLayerKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True inside the navigation layer that floats above the content (the top bar, the controls over the library hero, the
    /// carousel arrows, the wizard footer). Only there do the button styles draw Liquid Glass. Everywhere else, in lists, cards,
    /// rows, sheets and notices, they are flat (Apple HIG for Liquid Glass on macOS 26, #1458).
    package var launcherGlassLayer: Bool {
        get { self[LauncherGlassLayerKey.self] }
        set { self[LauncherGlassLayerKey.self] = newValue }
    }
}

extension View {
    /// Marks this view as the navigation layer: its buttons are glass. DesignTokenGuardTests allows it only in the
    /// navigation-layer components.
    package func launcherGlassLayer() -> some View { environment(\.launcherGlassLayer, true) }

    /// A button style's surface: glass in the navigation layer, flat in the content layer (the surface fill with a hairline, or
    /// the accent fill for a primary action). A disabled primary has the disabled look: the raised surface without the accent.
    package func launcherControlSurface<S: InsettableShape>(in shape: S, tint: Color? = nil, fallback: Color? = nil, border: Color? = nil) -> some View {
        modifier(LauncherControlSurface(shape: shape, tint: tint, fallback: fallback, border: border))
    }
}

private struct LauncherControlSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color?
    let fallback: Color?
    let border: Color?
    @Environment(\.launcherGlassLayer) private var glassLayer
    @Environment(\.isEnabled) private var enabled
    @ViewBuilder func body(content: Content) -> some View {
        if glassLayer {
            content.launcherGlass(in: shape, tint: enabled ? tint : nil, fallback: fallback, border: border)
        } else if let tint, enabled {
            content.background(tint, in: shape)
        } else {
            content.background(fallback ?? DS.Color.surfaceRaised, in: shape)
                .overlay(shape.strokeBorder(border ?? DS.Color.separator))
        }
    }
}

/// Glass buttons that sit together share one container, so their glass blends and morphs as one group.
package struct LauncherGlassGroup<Content: View>: View {
    package init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) { self.spacing = spacing; self.content = content() }
    let spacing: CGFloat
    let content: Content
    package var body: some View {
        if #available(macOS 26, *), LauncherGlass.live { GlassEffectContainer(spacing: spacing) { content } } else { content }
    }
}

/// A round glass button with a symbol: the top bar's search, update and Settings buttons, a notice's dismiss. `selected` gives it the
/// accent tint (Settings while it is open).
package struct LauncherIconButtonStyle: ButtonStyle {
    package init(size: CGFloat = LauncherControl.height, selected: Bool = false) { self.size = size; self.selected = selected }
    package let size: CGFloat
    package let selected: Bool
    package func makeBody(configuration: Configuration) -> some View {
        LauncherIconButton(configuration: configuration, size: size, selected: selected)
    }
}

private struct LauncherIconButton: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    let selected: Bool
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        configuration.label
            .font(.system(size: size * 0.42, weight: .medium))
            .dsButtonContent(!enabled ? DSButtonForeground.disabled : selected ? DSButtonForeground.primary : DSButtonForeground.flat)
            .frame(width: size, height: size)
            .contentShape(Circle())
            .launcherControlSurface(in: DSPill(), tint: selected ? LauncherPalette.cream : nil)
            .launcherHover()
    }
}
