import SwiftUI
import NXLauncher

/// The bar participates in the scroll view's safe area so the system owns its backdrop and progressive edge.
struct LibraryHeaderBar<Header: View>: ViewModifier {
    let header: Header
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.safeAreaBar(edge: .top, spacing: 0) { header }
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content.safeAreaInset(edge: .top, spacing: 0) {
                header.background(LauncherPalette.background)
            }
        }
    }
}

struct LibraryScrollUnderlap: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *) { content.ignoresSafeArea(.container, edges: .top) }
        else { content }
    }
}

/// Preserve space for readable titles and actions when a short window cannot accommodate the normal reduction.
enum LibraryHeroLayout {
    struct Content {
        let scale: CGFloat
        var iconSize: CGFloat { 144 * scale }
        var titleSize: CGFloat { 36 * scale }
        var columnGap: CGFloat { 24 * scale }
        var titleActionGap: CGFloat { 14 * scale }
        var badgeTitleGap: CGFloat { 10 * scale }
    }

    static func content(width: CGFloat, height: CGFloat, headerHeight: CGFloat) -> Content {
        let horizontalScale = max(0, width - 68) / 1000
        let verticalScale = max(0, height - headerHeight - 24) / 144
        return Content(scale: max(5 / 6, min(4 / 3, min(horizontalScale, verticalScale))))
    }

    static func height(available: CGFloat, hasDeviceActions: Bool) -> CGFloat {
        max(hasDeviceActions ? 340 : 300, available * 0.7)
    }
}
