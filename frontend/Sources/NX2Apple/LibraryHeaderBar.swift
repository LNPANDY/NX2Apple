import SwiftUI
import NXLauncher

/// The library's top bar: a solid surface in the page colour with the hairline under it, on every macOS (#1458). No blur, no
/// material and no scroll edge effect: the hero starts below the bar and nothing scrolls visibly under it.
struct LibraryHeaderBar<Header: View>: ViewModifier {
    let header: Header
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                header
                LauncherTopBarRule()
            }
            .background(DS.Color.background)
        }
    }
}

/// The library used to scroll under a translucent bar on macOS 26. The bar is solid now, so the content starts below it.
struct LibraryScrollUnderlap: ViewModifier {
    func body(content: Content) -> some View { content }
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
