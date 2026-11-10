import SwiftUI
import NXLauncher

/// The console's background. Home: the focused game's artwork sharp in the top right corner, about three quarters of the screen,
/// fading out towards the left and the bottom; under it the same art blurred and dimmed across the whole screen, and a soft, darker
/// blur over the bottom left, where the title, the row and the hints are, so nothing in the art competes with them. Starting: the
/// cover fills the window, soft and darkened, the Starting text in the middle.
struct ConsoleBackdrop: View {
    let game: ConsoleGame?
    let starting: Bool
    let size: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let bg = LauncherPalette.background

    /// The sharp art's share of the screen, from the top right corner.
    static let artWidth: CGFloat = 0.74
    static let artHeight: CGFloat = 0.8
    /// How far the top bar's scrim reaches down.
    static let scrimHeight: CGFloat = 160

    var body: some View {
        ZStack(alignment: .topTrailing) {
            bg
            if let game {
                Group {
                    if starting { blurred(game).overlay(Color.black.opacity(0.32)) }   // a scrim keeps the Starting text readable on any cover
                    else { home(game) }
                }
                .id(game.id).transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(.easeInOut(duration: reduceMotion ? 0.01 : 0.38), value: game?.id)   // the art cross-fades, slowly and softly
        .animation(.easeInOut(duration: reduceMotion ? 0.01 : 0.25), value: game?.hero != nil)   // the large image replaces the cover
        .clipped().ignoresSafeArea().accessibilityHidden(true)
    }

    private func image(_ game: ConsoleGame) -> NSImage? { game.hero ?? game.artwork }
    private func focus(_ game: ConsoleGame) -> UnitPoint { game.hero != nil ? game.heroFocus : game.artworkFocus }

    /// The whole screen in the art's colours, blurred: the starting screen, and the home screen's base.
    private func blurred(_ game: ConsoleGame) -> some View {
        Group {
            if let image = image(game) { Image(nsImage: image).resizable().scaledToFill() }
            else { LinearGradient(colors: ConsolePlaceholder.colors(for: game.title), startPoint: .topLeading, endPoint: .bottomTrailing) }
        }
        .frame(width: size.width, height: size.height).blur(radius: 36).drawingGroup().clipped()
    }

    @ViewBuilder private func home(_ game: ConsoleGame) -> some View {
        let width = size.width * Self.artWidth, height = size.height * Self.artHeight
        ZStack(alignment: .topTrailing) {
            // The base: the art blurred and dimmed, so the bottom left keeps its colours without its detail.
            blurred(game).opacity(0.7)
            bg.opacity(0.35)
            // The art itself, sharp, in the top right corner, fading into the base towards the left and the bottom.
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
            // The top edge, where the controllers, the clock, Search and the menu sit: a dark scrim over the full width, so the status
            // stays readable on bright art (the sharp art is brightest there). Clear after about 160 pt.
            LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.scrimHeight).frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: size.width, height: size.height)
    }
}
