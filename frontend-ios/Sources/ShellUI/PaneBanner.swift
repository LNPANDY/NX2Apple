import SwiftUI

/// The top of the settings: the game's banner, whole and fading into the panel, then its state and title below it,
/// so the banner's own logo and the title never overlap. Capped in height for a phone on its side.
struct PaneBanner: View {
    let game: GameTile
    let width: CGFloat
    var body: some View {
        let hasBanner = game.banner != nil && game.icon == nil
        let bannerHeight = hasBanner ? min(max(0, width) * 9 / 16, 176) : 0
        if hasBanner, let banner = game.banner {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottom) {
                    Image(decorative: banner.image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: bannerHeight)
                        .saturation(game.state == .playable ? 1 : 0)
                        .clipped()
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.2),
                            .init(color: ShellPalette.background.opacity(0.72), location: 0.72),
                            .init(color: ShellPalette.background, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: bannerHeight * 0.65)
                }
                .frame(maxWidth: .infinity)
                .frame(height: bannerHeight)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                )
                .accessibilityHidden(true)

                words(title: game.title).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // Centred on the artwork like the title in the game detail header, not sitting on its lower edge.
            HStack(alignment: .center, spacing: 22) {
                CoverThumbnail(game: game, showsShadow: false).frame(width: 96, height: 96)
                words(title: game.title).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func words(title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).shellType(ShellType.pageTitle).lineLimit(2)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("detail.title")
            AlertStateChip(state: game.state)
            // #696: the manifest's console, beside the state as the hidden detail header had it, with its memory note
            if game.isSwitch2 {
                ConsoleBadge().accessibilityIdentifier("detail.switch2")
                Text(ShellStrings.text("A Switch 2 game. It needs a lot of memory and may not start on every device."))
                    .shellText(12.5).foregroundStyle(.white.opacity(0.62)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A square app icon beside metadata, or an uncropped banner when no icon is available.
struct CoverThumbnail: View {
    let game: GameTile
    var showsShadow = true
    var cornerRadius: CGFloat = 18
    var body: some View {
        Group {
            if let icon = game.icon {
                Image(decorative: icon.image, scale: 1).resizable().interpolation(.high).scaledToFit()
            } else if let banner = game.banner {
                Image(decorative: banner.image, scale: 1).resizable().interpolation(.high).scaledToFit()
            } else {
                PlaceholderArt(title: game.title, seed: game.id)
            }
        }
        .saturation(game.state == .playable ? 1 : 0)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.white.opacity(0.14)))
        .shadow(color: showsShadow ? .black.opacity(0.4) : .clear, radius: 16, y: 6)
        .accessibilityHidden(true)
    }
}

/// Request a native side only when the system reports a vertical division; flat iPhone/iPad sheets stay adaptive.
struct MenuPlacement: ViewModifier {
    var divided: Bool
    var secondary: Bool
    @ViewBuilder func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 27.0, *), divided {
            content.presentationPlacement(secondary ? .trailing : .leading)
        } else { content }
        #else
        content
        #endif
    }
}

struct LauncherMenuSizing: PresentationSizing {
    var mapping: Bool
    func proposedSize(for root: PresentationSizingRoot, context: PresentationSizingContext) -> ProposedViewSize {
        if mapping { return PagePresentationSizing.page.proposedSize(for: root, context: context) }
        return FormPresentationSizing.form.proposedSize(for: root, context: context)
    }
}
