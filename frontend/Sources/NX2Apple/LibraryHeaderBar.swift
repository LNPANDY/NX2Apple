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

/// Two groups share a row when their ideal widths fit, otherwise the second starts on the leading edge below.
struct LibraryCollectionHeaderLayout: Layout {
    let spacing: CGFloat
    var spread = false
    private let rowSpacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let first = subviews[0].sizeThatFits(.unspecified)
        let second = subviews[1].sizeThatFits(.unspecified)
        let idealWidth = first.width + spacing + second.width
        guard let width = proposal.width else {
            return CGSize(width: idealWidth, height: max(first.height, second.height))
        }
        if idealWidth <= width {
            return CGSize(width: spread ? width : idealWidth, height: max(first.height, second.height))
        }
        let row = ProposedViewSize(width: width, height: nil)
        let height = subviews[0].sizeThatFits(row).height + rowSpacing + subviews[1].sizeThatFits(row).height
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let first = subviews[0].sizeThatFits(.unspecified)
        let second = subviews[1].sizeThatFits(.unspecified)
        if first.width + spacing + second.width <= bounds.width {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
            let secondX = spread ? bounds.maxX - second.width : bounds.minX + first.width + spacing
            subviews[1].place(at: CGPoint(x: secondX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
        } else {
            let row = ProposedViewSize(width: bounds.width, height: nil)
            let firstHeight = subviews[0].sizeThatFits(row).height
            subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: row)
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + firstHeight + rowSpacing),
                              anchor: .topLeading, proposal: row)
        }
    }
}
