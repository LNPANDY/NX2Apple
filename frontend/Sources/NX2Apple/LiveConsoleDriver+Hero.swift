import AppKit
import NXCore

/// The home screen's backdrop: the focused game's large artwork (the hero slot, decoded at screen size). Only the focused game's is
/// loaded, off the main thread. `ArtworkImages` keeps what it decoded, so coming back to a game draws at once.
extension LiveConsoleDriver {
    /// A console tile is up to 470 pt wide, 940 pixels on a Retina screen: the desktop card's 640 pixel decode is too soft for it.
    static let tilePixels = 1024
    func loadHero() {
        guard let id = state.focusedGame?.id, state.games.first(where: { $0.id == id })?.hero == nil, let game = libraryGame(id) else { return }
        let repo = repo(), banners = library.artworkDirectory, focus = game.artwork.focus(for: .hero)
        DispatchQueue.global(qos: .userInitiated).async {
            // the same source and size as the desktop's hero decodes (hero slot, ArtworkImages.heroPixels): the full-size banner
            let image = GameLibrary.artwork(for: game, slot: .hero, repo: repo, banners: banners)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    // the focus may have moved on meanwhile: the image goes to its own game, which keeps it while it stays in the list
                    guard let self, let image, let i = self.state.games.firstIndex(where: { $0.id == id }), self.state.games[i].hero == nil else { return }
                    self.state.games[i].hero = image
                    self.state.games[i].heroFocus = focus
                }
            }
        }
    }
}
