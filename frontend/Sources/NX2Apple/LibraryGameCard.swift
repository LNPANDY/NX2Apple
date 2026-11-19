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
    var doubleClick: () -> Void = {}
    var contextMenuItems: (() -> [ManageItem])? = nil
    @EnvironmentObject private var loc: Localizer
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var isColorActive: Bool { hovered || selected }
    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: LibraryCardLayout.titleSpacing) {
                ZStack {
                    LauncherPalette.surface
                    Group {
                        if let image { ArtworkFill(image: image, focus: focus) }
                        else {
                            Image(systemName: "gamecontroller").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                        }
                    }
                    .saturation(LibraryArtworkTone.saturation(muted: state.monochrome, active: isColorActive))
                    .opacity(LibraryArtworkTone.artworkOpacity(muted: state.monochrome, active: isColorActive))
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isColorActive)
                .frame(width: width, height: width / LibraryCardLayout.aspect).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(alignment: .topLeading) { LibraryArtworkChip(state: state).padding(8) }
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? LauncherPalette.cream : LauncherPalette.cardBorder,
                                                                                     lineWidth: selected ? 2 : 1))
                Text(title)
                    .font(.manrope(16, .semibold))
                    .lineLimit(1)
                    .opacity(LibraryArtworkTone.titleOpacity(muted: state.monochrome, active: isColorActive))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isColorActive)
            }
            .frame(width: width, alignment: .leading)
            .padding(LibraryCardLayout.inset)
            .background(hovered ? LauncherPalette.ink(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .scaleEffect(hovered && !reduceMotion ? 1.025 : 1)
            .offset(y: hovered && !reduceMotion ? -4 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).launcherHover(lightBrightness: 0)
        .onHover { hovered = $0 }
        .simultaneousGesture(TapGesture(count: 2).onEnded { doubleClick() })
        .modifier(LibraryCardContextMenu(select: select, items: contextMenuItems))
        .accessibilityLabel(title)
        .accessibilityValue(state.chipKey.map { loc.t($0) } ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct LibraryCardContextMenu: ViewModifier {
    let select: () -> Void
    let items: (() -> [ManageItem])?

    @ViewBuilder func body(content: Content) -> some View {
        if let items {
            content.contextMenu {
                LibraryCardContextMenuContent(select: select, items: items)
            }
        } else {
            content
        }
    }
}

private struct LibraryCardContextMenuContent: View {
    let select: () -> Void
    let items: () -> [ManageItem]

    var body: some View {
        ForEach(items()) { item in
            if item.separatorBefore { Divider() }
            Button(role: item.destructive ? .destructive : nil) {
                select()
                item.run()
            } label: {
                Label(item.title, systemImage: item.symbol)
            }
            .disabled(!item.enabled)
        }
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
