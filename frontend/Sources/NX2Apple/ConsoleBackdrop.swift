import SwiftUI
import NXLauncher

/// The console's background. Home: the focused game's artwork sharp in the top right corner, about three quarters of the screen,
/// fading out towards the left and the bottom into the page, and darker at the bottom left, where the title, the row and the hints
/// are, so nothing in the art competes with them. Starting: the cover fills the window, darkened, the Starting text in the middle.
/// No blur and no material (LNPANDY/NX2Apple#1458): the art is dimmed with gradients, as in the desktop library.
struct ConsoleBackdrop: View {
    let game: ConsoleGame?
    let starting: Bool
    let size: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let bg = LauncherPalette.background

    /// The sharp art's share of the screen, from the top right corner.
    static let artWidth: CGFloat = 0.74
    static let artHeight: CGFloat = 0.8

    var body: some View {
        ZStack(alignment: .topTrailing) {
            bg
            if let game {
                Group {
                    if starting { cover(game).overlay(Color.black.opacity(0.55)) }   // a scrim keeps the Starting text readable on any cover
                    else { home(game) }
                }
                .saturation(LibraryArtworkTone.saturation(muted: game.needsMutedArtworkTone))
                // The same game's large image arriving later replaces its cover with a short fade. Inside the game's identity, so it
                // runs only for that game, and a switch to another one keeps the cross-fade below.
                .animation(ConsoleHomeMotion.heroArrival(reduceMotion: reduceMotion), value: game.hero != nil)
                .id(game.id).transition(ConsoleHomeMotion.artworkTransition)
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .top) {
            if !starting {   // the clock and the buttons on top stay readable on bright art
                LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: min(300, size.height * 0.32)).allowsHitTesting(false)
            }
        }
        .dsAnimation(ConsoleHomeMotion.artwork(reduceMotion: reduceMotion), value: game?.id)   // the art cross-fades, short and quiet
        .clipped().ignoresSafeArea().accessibilityHidden(true)
    }

    private func image(_ game: ConsoleGame) -> NSImage? { game.hero ?? game.artwork }
    private func focus(_ game: ConsoleGame) -> UnitPoint { game.hero != nil ? game.heroFocus : game.artworkFocus }

    /// The whole screen in the art: the starting screen.
    private func cover(_ game: ConsoleGame) -> some View {
        Group {
            if let image = image(game) { ArtworkFill(image: image, focus: focus(game)) }
            else { LinearGradient(colors: ConsolePlaceholder.colors(for: game.title), startPoint: .topLeading, endPoint: .bottomTrailing) }
        }
        .frame(width: size.width, height: size.height).clipped()
    }

    @ViewBuilder private func home(_ game: ConsoleGame) -> some View {
        let width = size.width * Self.artWidth, height = size.height * Self.artHeight
        ZStack(alignment: .topTrailing) {
            // The art itself, sharp, in the top right corner, fading into the page towards the left and the bottom.
            Group {
                if let image = image(game) { ArtworkFill(image: image, focus: focus(game)) }
                else { LinearGradient(colors: ConsolePlaceholder.colors(for: game.title), startPoint: .topTrailing, endPoint: .bottomLeading).opacity(0.6) }
            }
            .frame(width: width, height: height)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.7), location: 0.28),
                                         .init(color: .black, location: 0.5)], startPoint: .leading, endPoint: .trailing))
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.55),
                                         .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            // The bottom left, where the text is: darker, and the darkest under the row and the hints.
            RadialGradient(stops: [.init(color: bg.opacity(0.92), location: 0), .init(color: bg.opacity(0.6), location: 0.45),
                                   .init(color: bg.opacity(0), location: 1)],
                           center: .bottomLeading, startRadius: 0, endRadius: max(size.width, size.height) * 0.85)
            LinearGradient(stops: [.init(color: bg.opacity(0), location: 0.6), .init(color: bg.opacity(0.85), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .frame(width: size.width, height: size.height)
    }
}
