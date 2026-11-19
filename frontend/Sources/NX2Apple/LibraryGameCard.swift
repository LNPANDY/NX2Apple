import SwiftUI
import AppKit
import NXCore
import NXModel
import NXLauncher

struct LibraryGameCard: View {
    let title: String
    let image: NSImage?
    let focus: UnitPoint
    let state: LibraryArtworkState
    let width: CGFloat
    let selected: Bool
    /// The controller or the keyboard is on this card: the focus ring and the focus scale on the artwork (dsCardArt).
    var focused = false
    let select: () -> Void
    @EnvironmentObject private var loc: Localizer
    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: LibraryCardLayout.titleSpacing) {
                ZStack {
                    if let image { ArtworkFill(image: image, focus: focus) }
                    else {
                        LauncherPalette.surface
                        Image(systemName: "gamecontroller").font(.system(size: 30, weight: .light)).foregroundStyle(DS.Color.symbolDefault)
                    }
                }
                .opacity(state.monochrome ? 0.85 : 1)   // in colour, dimmed a little when it needs attention (#1458)
                .frame(width: width, height: width / LibraryCardLayout.aspect).clipped()
                .clipShape(RoundedRectangle(cornerRadius: LibraryCardLayout.radius))
                // the chip above the clip, inset from the top and leading edge, clear of the corner radius
                .overlay(alignment: .topLeading) { LibraryArtworkChip(state: state).padding(DS.Interaction.chipInset) }
                .dsCardArt(radius: LibraryCardLayout.radius, selected: selected, focused: focused)
                Text(title).font(DS.Font.headline).lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
            .padding(LibraryCardLayout.inset)
            .contentShape(Rectangle())
        }
        .buttonStyle(DSCardButtonStyle())
        .accessibilityLabel(title)
        .accessibilityValue(state.chipKey.map { loc.t($0) } ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The populated and placeholder cards share the same artwork and title footprint.
enum LibraryCardLayout {
    static let aspect: CGFloat = 1.8
    /// The artwork's corner radius. A chip on it sits DS.Interaction.chipInset in, clear of it.
    static let radius: CGFloat = 5
    static let inset: CGFloat = 6
    static let titleSpacing: CGFloat = 8
    static let gridSpacing: CGFloat = 16
    static func columns(in available: CGFloat) -> Int {
        max(1, Int((max(0, available - 68) + gridSpacing) / (240 + 2 * inset + gridSpacing)))
    }
    static func width(in available: CGFloat) -> CGFloat {
        let count = CGFloat(columns(in: available))
        return max(1, (max(0, available - 68) - gridSpacing * (count - 1)) / count - 2 * inset)
    }
}
