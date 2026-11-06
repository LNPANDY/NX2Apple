import AppKit
import NXCore

/// Which file a game's hero or thumbnail shows, the same for the library, the panel's live preview and console mode.
extension GameLibrary {
    /// The artwork files there are for a slot, best first. The hero: the player's own choice, then the game's eShop key art
    /// (ArtworkStore, or its first screenshot when it has no banner, as the panel's default), then an existing repository gameplay
    /// screenshot, then the app icon. A thumbnail: its own choice, else exactly the hero's.
    static func artworkURLs(for game: LibraryGame, slot: ArtworkSlot = .hero, repo: String, banners: URL = ArtworkStore.shared.directory) -> [URL] {
        var urls: [URL] = []
        if slot == .thumbnail, let url = file(for: game.artwork.thumbnail, of: game, banners: banners) { urls.append(url) }
        if let url = file(for: game.artwork.hero, of: game, banners: banners) { urls.append(url) }
        if !game.artworkPath.isEmpty, FileManager.default.fileExists(atPath: game.artworkPath) { urls.append(URL(fileURLWithPath: game.artworkPath)) }   // not copied yet
        if let url = ArtworkStore.cachedBanner(game.titleID, in: banners) { urls.append(url) }
        else if let url = ArtworkStore.cachedCandidate(.screenshot(0), titleID: game.titleID, in: banners) { urls.append(url) }   // no banner: the first screenshot, the panel's default
        func normalized(_ s: String) -> String {
            s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .filter { $0.isLetter || $0.isNumber }
        }
        let name = normalized(game.name)
        let images = URL(fileURLWithPath: EngineLayout.root(repo)).appendingPathComponent("docs/images")
        let files = (try? FileManager.default.contentsOfDirectory(at: images, includingPropertiesForKeys: nil)) ?? []
        let matches = files.filter {
            ["jpg", "jpeg", "png", "webp"].contains($0.pathExtension.lowercased()) && name.hasSuffix(normalized($0.deletingPathExtension().lastPathComponent))
        }.sorted { $0.lastPathComponent.count > $1.lastPathComponent.count }
        if let url = matches.first { urls.append(url) }
        let icon = game.appPath + "/Contents/Resources/AppIcon.icns"
        // Extraction icons are small; they are a fallback, never presented as high-resolution artwork.
        if !game.appPath.isEmpty, FileManager.default.fileExists(atPath: icon) { urls.append(URL(fileURLWithPath: icon)) }
        return urls
    }

    /// The file a choice shows, if it has one. A screenshot has none until it is downloaded (ArtworkStore.candidate).
    private static func file(for choice: ArtworkChoice?, of game: LibraryGame, banners: URL) -> URL? {
        let url: URL?
        switch choice?.source {
        case .banner: url = ArtworkStore.cachedBanner(game.titleID, in: banners)
        case .imported(let name) where name == URL(fileURLWithPath: name).lastPathComponent && name != "..":   // a name in the game's folder, never a path
            url = ArtworkStore.customDirectory(for: game.id, in: banners).appendingPathComponent(name)
        case .screenshot?: url = choice.flatMap { ArtworkStore.cachedCandidate($0.source, titleID: game.titleID, in: banners) }
        case .imported, nil: url = nil
        }
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// The artwork, decoded no larger than `maxPixel` on its longer side. The hero needs the large default, a card or a
    /// console cover `ArtworkImages.cardPixels`.
    static func artwork(for game: LibraryGame, slot: ArtworkSlot = .hero, repo: String, banners: URL = ArtworkStore.shared.directory,
                        maxPixel: Int = ArtworkImages.heroPixels) -> NSImage? {
        // A file that is there but does not decode (a damaged download) gives way to the next one
        artworkURLs(for: game, slot: slot, repo: repo, banners: banners).lazy.compactMap { ArtworkImages.shared.image(at: $0, maxPixel: maxPixel) }.first
    }
}
