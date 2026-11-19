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
    let select: () -> Void
    @EnvironmentObject private var loc: Localizer
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: LibraryCardLayout.titleSpacing) {
                ZStack {
                    if let image { ArtworkFill(image: image, focus: focus) }
                    else {
                        LauncherPalette.surface
                        Image(systemName: "gamecontroller").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                    }
                }
                .opacity(state.monochrome ? 0.85 : 1)   // in colour, dimmed a little when it needs attention (#1458)
                .frame(width: width, height: width / LibraryCardLayout.aspect).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(alignment: .topLeading) { LibraryArtworkChip(state: state).padding(8) }
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? LauncherPalette.cream : LauncherPalette.cardBorder,
                                                                                     lineWidth: selected ? 2 : 1))
                Text(title).font(DS.Font.headline).lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
            .padding(LibraryCardLayout.inset)
            .background(hovered ? LauncherPalette.ink(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .scaleEffect(hovered && !reduceMotion ? 1.025 : 1)
            .offset(y: hovered && !reduceMotion ? -4 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).launcherHover()
        .onHover { hovered = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(state.chipKey.map { loc.t($0) } ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The populated and placeholder cards share the same artwork and title footprint.
enum LibraryCardLayout {
    static let aspect: CGFloat = 1.8
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
