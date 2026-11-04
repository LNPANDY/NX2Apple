import SwiftUI

/// iPhone Duo (#622) keeps a column on one side of the screen for the status bar and the system's vertical bars: the Dynamic
/// Island and the status bar at the top, then the app's toolbar and tab bar. The column lies outside the safe area, so the library
/// leaves it empty. Apple's design guide counts the app's own controls among the controls on the side, and
/// `toolbarVerticalEdge` (iOS 27.1) is there to place custom bars beside the system's. So where the system uses that column,
/// the Controllers and Settings chips go into it, at its bottom end, away from the status bar at the top.
/// Nothing here knows the device: only the edge the system names, the safe area and the occluded areas decide.
public struct SideBar: Equatable, Sendable {
    /// The edge of the system's vertical bar, nil where the system never places one (every other iPhone and iPad).
    public var edge: HorizontalEdge?
    /// Areas a camera or the Dynamic Island covers, in the screen's coordinates (`reservedRegions(kind: .occlusion)`).
    public var occlusions: [CGRect]

    public init(edge: HorizontalEdge?, occlusions: [CGRect] = []) {
        self.edge = edge
        self.occlusions = occlusions
    }

    /// A chip in the column: this wide, and the Controllers chip a little taller for its count under the symbol.
    public static let chipWidth: CGFloat = 52
    public static let heights: [CGFloat] = [56, 44]
    public static let gap: CGFloat = 10
    public static let margin: CGFloat = 12

    /// The column's frame in the screen's coordinates for chips of `heights`, or nil to keep them in the header: no vertical
    /// bar, a column too narrow for a chip, or no room below the status bar's half of the column. The chips sit at the bottom of
    /// the column above the home indicator, and move up past any occluded area they would touch.
    public func column(screen: CGSize, insets: EdgeInsets, heights: [CGFloat] = SideBar.heights) -> CGRect? {
        guard let edge, !heights.isEmpty else { return nil }
        let side = edge == .trailing ? insets.trailing : insets.leading
        guard side >= Self.chipWidth else { return nil }
        let height = heights.reduce(0, +) + Self.gap * CGFloat(heights.count - 1)
        let x = (edge == .trailing ? screen.width - side : 0) + (side - Self.chipWidth) / 2
        var frame = CGRect(x: x, y: screen.height - insets.bottom - Self.margin - height, width: Self.chipWidth, height: height)
        for _ in 0...occlusions.count {
            guard let top = occlusions.filter({ $0.intersects(frame) }).map(\.minY).min() else { break }
            frame.origin.y = top - Self.margin - height
        }
        if occlusions.contains(where: { $0.intersects(frame) }) { return nil }
        // The top half belongs to the Dynamic Island and the status bar, which no API reports as an area to avoid.
        return frame.minY >= screen.height / 2 ? frame : nil
    }
}

extension EnvironmentValues {
    /// The side column as the shell sees it. Nil reads it from the system (iOS 27.1). The captures set it to simulate iPhone Duo.
    @Entry public var shellSideBar: SideBar? = nil
}

/// Reads the system's vertical-bar edge and the occluded areas, in the coordinates of the view it is the background of.
struct SideBarProbe: View {
    let report: (SideBar) -> Void
    var body: some View {
        #if canImport(SwiftUI, _version: 8.1)
        if #available(iOS 27.1, macOS 27.1, *) { SideBarReader(report: report) } else { Color.clear }
        #else
        Color.clear
        #endif
    }
}

#if canImport(SwiftUI, _version: 8.1)
@available(iOS 27.1, macOS 27.1, *)
private struct SideBarReader: View {
    let report: (SideBar) -> Void
    @Environment(\.toolbarVerticalEdge) private var edge
    var body: some View {
        GeometryReader { proxy in
            let bar = SideBar(edge: edge, occlusions: proxy.reservedRegions(kind: .occlusion).map(\.frame))
            Color.clear.onChange(of: bar, initial: true) { _, new in report(new) }
        }
    }
}
#endif

/// The Controllers and Settings chips stacked in the side column.
struct SideBarChips: View {
    let controllers: Int
    let openControllers: () -> Void
    let openShellSettings: () -> Void
    var body: some View {
        VStack(spacing: SideBar.gap) {
            ControllerChip(count: controllers, vertical: true, action: openControllers)
            ShellSettingsChip(vertical: true, action: openShellSettings)
        }
    }
}
