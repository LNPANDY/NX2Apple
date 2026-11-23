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
                            Image(systemName: "gamecontroller").font(.system(size: 30, weight: .light)).foregroundStyle(DS.Color.symbolDefault)
                        }
                    }
                    .saturation(LibraryArtworkTone.saturation(muted: state.monochrome, active: isColorActive))
                    .opacity(LibraryArtworkTone.artworkOpacity(muted: state.monochrome, active: isColorActive))
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isColorActive)
                .frame(width: width, height: width / LibraryCardLayout.aspect).clipped()
                .clipShape(RoundedRectangle(cornerRadius: LibraryCardLayout.radius))
                // the chip above the clip, inset from the top and leading edge, clear of the corner radius
                .overlay(alignment: .topLeading) { LibraryArtworkChip(state: state).padding(DS.Interaction.chipInset) }
                .overlay(alignment: .topTrailing) {
                    // Built with a game-tuned engine, or lists each available game-tuned engine by full name.
                    if let built = state.builtTunedEngine {
                        let help = String(format: loc.t("library.tunedBuilt.help"), built.displayName)
                        DSTag(built.displayName, emphasized: true, width: DSTag.engineWidth)
                            .help(help)
                            .accessibilityLabel(help)
                            .padding(DS.Interaction.chipInset)
                    } else if state.hasTunedEngine {
                        VStack(alignment: .trailing, spacing: DS.Space.xxs) {
                            ForEach(state.tunedEngines, id: \.self) { engine in
                                let help = String(format: loc.t("library.tuned.help"), engine.displayName)
                                DSTag(engine.displayName, emphasized: true, width: DSTag.engineWidth)
                                    .help(help)
                                    .accessibilityLabel(help)
                            }
                        }
                        .padding(DS.Interaction.chipInset)
                    } else if state.isNxkitGeneric {
                        // nxkit built it without a game profile (v0lumehi/nxkit#54): the same quiet tag in the same corner
                        DSTag(loc.t("nxkit.generic.badge"), emphasized: true)
                            .help(loc.t("nxkit.generic.help"))
                            .accessibilityLabel(loc.t("nxkit.generic.help"))
                            .padding(DS.Interaction.chipInset)
                    }
                }
                .dsCardArt(radius: LibraryCardLayout.radius, selected: selected, focused: focused)
                Text(title).font(DS.Font.headline).lineLimit(1)
                    .opacity(LibraryArtworkTone.titleOpacity(muted: state.monochrome, active: isColorActive))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isColorActive)
            }
            .frame(width: width, alignment: .leading)
            .padding(LibraryCardLayout.inset)
            .contentShape(Rectangle())
        }
        .buttonStyle(DSCardButtonStyle())
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
