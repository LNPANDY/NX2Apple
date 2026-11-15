import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// The artwork of the Library page: what the hero and the cards draw, and the panel that changes it (ArtworkPanel.swift). A move out of
/// LauncherView.swift to keep it under the size limit, the state stays in LauncherView.
extension LauncherView {
    /// The game as the library draws it: with the artwork panel open, the editor's draft instead of what is saved.
    func displayed(_ game: LibraryGame) -> LibraryGame {
        guard let draft = artworkPreview, artworkEditor?.gameID == game.id else { return game }
        var shown = game
        shown.artwork = draft
        return shown
    }

    func refreshArtwork() {
        previewGeneration += 1
        artwork = Dictionary(uniqueKeysWithValues: library.games.compactMap { game in
            GameLibrary.artwork(for: displayed(game), slot: .thumbnail, repo: stores.repo.path, banners: library.artworkDirectory, maxPixel: ArtworkImages.cardPixels).map { (game.id, $0) }
        })
        refreshHeroArtwork()
    }

    func refreshHeroArtwork() {
        previewGeneration += 1   // a preview still decoding is for the game shown before
        heroArtwork = heroGame.flatMap { game in
            GameLibrary.artwork(for: displayed(game), repo: stores.repo.path, banners: library.artworkDirectory).map { (game.id, $0) }
        }
    }

    /// What the hero draws: its own decode at the hero's size, never the card's 640 pixel thumbnail (stretched over a 2880 pixel
    /// wide hero it was blurred). Until `refreshHeroArtwork` has run for this game it decodes here (ArtworkImages keeps it).
    func heroImage(for game: LibraryGame) -> NSImage? {
        GameLibrary.heroImage(for: game.id, decoded: heroArtwork) {
            GameLibrary.artwork(for: displayed(game), repo: stores.repo.path, banners: library.artworkDirectory)
        }
    }

    /// The eShop key art of the games that have none yet, in the launcher's language: the cards and the hero redraw as it arrives.
    /// A change of language picks every banner again (ArtworkStore.fetchMissing).
    func fetchArtwork() {
        let ids = library.games.map(\.titleID), language = loc.lang.code, store = artworkStore
        artworkFetchGeneration &+= 1
        let generation = artworkFetchGeneration
        Task {
            let added = await store.fetchMissing(ids, language: language)
            guard !added.isEmpty else { return }
            await MainActor.run {
                guard artworkFetchGeneration == generation, loc.lang.code == language else { return }
                refreshArtwork()
            }
        }
    }

    /// 1 for the part of the library the panel is editing (and with no panel), dimmed for the other.
    func dimmed(_ part: ArtworkSlot) -> Double { artworkSlot == nil || artworkSlot == part ? 1 : 0.35 }

    func openArtwork(_ game: LibraryGame, slot: ArtworkSlot = .hero) {
        guard page == .library else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            artworkEditor = ArtworkEditor(game: game, slot: slot, artworkDirectory: library.artworkDirectory, env: .live(store: artworkStore), labels: loc.t)
            artworkEditor?.heroAspect = artworkHeroAspect
        }
        artworkSlot = slot
    }

    /// Closing the panel writes the draft to the library (Save) or leaves it as it was (Cancel, Esc, B, leaving the Library page).
    /// A Save the library could not write keeps the panel open with its error.
    func closeArtwork(save: Bool) {
        guard let editor = artworkEditor else { return }
        if save { guard editor.save(to: library) || !editor.isDirty else { return } } else { editor.cancel() }
        withAnimation(.easeOut(duration: 0.18)) { artworkEditor = nil }
        artworkSlot = nil
        artworkPreview = nil
        refreshArtwork()
    }

    /// The draft arrived: the hero and the game's card draw it, decoded at their own sizes. The hero is up to 4K, so the decode runs
    /// off the main thread and its result is kept only if no later draft, refresh or selection came meanwhile.
    func refreshPreview(_ draft: GameArtwork) {
        artworkPreview = draft
        guard let id = artworkEditor?.gameID, let game = library.games.first(where: { $0.id == id }) else { return }
        let shown = displayed(game), repo = stores.repo.path, banners = library.artworkDirectory
        let withHero = heroGame?.id == id
        previewGeneration += 1
        let generation = previewGeneration
        Task.detached(priority: .userInitiated) {
            let card = GameLibrary.artwork(for: shown, slot: .thumbnail, repo: repo, banners: banners, maxPixel: ArtworkImages.cardPixels)
            let hero = withHero ? GameLibrary.artwork(for: shown, repo: repo, banners: banners) : nil
            await MainActor.run {
                guard previewGeneration == generation else { return }
                artwork[id] = card
                if withHero { heroArtwork = hero.map { (id, $0) } }
            }
        }
    }

    var artworkPadFocus: String? { artworkEditor.flatMap { $0.tiles.first(where: \.isSelected) }.map { "artwork.tile." + $0.id } }
}
