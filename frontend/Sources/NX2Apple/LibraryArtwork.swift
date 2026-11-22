import AppKit
import NXCore

/// Cached listing of `<engine>/docs/images` keyed by directory path and modification date so `artworkURLs(for:)` never rescans
/// the folder with `contentsOfDirectory` on every game lookup or SwiftUI redraw.
private final class RepoDocsImagesIndex: @unchecked Sendable {
    static let shared = RepoDocsImagesIndex()

    private struct Entry {
        let modified: Date
        let items: [(stem: String, url: URL)]
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func match(normalizedGameName name: String, repo: String) -> URL? {
        guard !repo.isEmpty, !name.isEmpty else { return nil }
        let root = EngineLayout.root(repo)
        guard !root.isEmpty else { return nil }
        let folder = URL(fileURLWithPath: root).appendingPathComponent("docs/images")
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: folder.path))?[.modificationDate] as? Date else {
            lock.lock()
            entries.removeValue(forKey: folder.path)
            lock.unlock()
            return nil
        }
        let items: [(stem: String, url: URL)]
        lock.lock()
        let cached = entries[folder.path]
        lock.unlock()
        if let cached, cached.modified == modified {
            items = cached.items
        } else {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            let supported = Set(["jpg", "jpeg", "png", "webp"])
            items = files.compactMap { url -> (String, URL)? in
                guard supported.contains(url.pathExtension.lowercased()) else { return nil }
                let stem = Self.normalize(url.deletingPathExtension().lastPathComponent)
                return stem.isEmpty ? nil : (stem, url)
            }.sorted { $0.1.lastPathComponent.count > $1.1.lastPathComponent.count }
            lock.lock()
            if entries.count > 16 { entries.removeAll() }
            entries[folder.path] = Entry(modified: modified, items: items)
            lock.unlock()
        }
        return items.first { name.hasSuffix($0.stem) }?.url
    }

    static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isLetter || $0.isNumber }
    }
}

/// Which file a game's hero, thumbnail or square icon shows, the same for the library, sheets, the panel's live preview and console mode.
extension GameLibrary {
    /// Candidate icon sources in priority order:
    /// 1. User-imported custom thumbnail artwork
    /// 2. Built Mac app `Contents/Resources/AppIcon.icns` (only when `appPath` is non-empty)
    /// 3. Cached online square metadata icon (`<TITLEID>/icon.jpg`)
    /// 4. Offline Control NCA icon extracted from the ROM (`<TITLEID>/nacp-icon.jpg`)
    /// 5. Cached landscape banner center-cropped to a square thumbnail (when `allowBannerFallback` is true)
    static func appIconCandidates(for game: LibraryGame, banners: URL, allowBannerFallback: Bool = true) -> [(url: URL, squareCrop: Bool)] {
        let fm = FileManager.default
        var candidates: [(URL, Bool)] = []
        if case .imported? = game.artwork.thumbnail?.source,
           let custom = file(for: game.artwork.thumbnail, of: game, banners: banners) {
            candidates.append((custom, true))
        }
        if !game.appPath.isEmpty {
            let app = URL(fileURLWithPath: game.appPath).appendingPathComponent("Contents/Resources/AppIcon.icns")
            if fm.fileExists(atPath: app.path) { candidates.append((app, false)) }
        }
        if let online = BannerCache.iconFile(game.titleID, in: banners), fm.fileExists(atPath: online.path) {
            candidates.append((online, false))
        }
        if let nacp = BannerCache.cachedNacpIcon(game.titleID, in: banners) {
            candidates.append((nacp, false))
        }
        if allowBannerFallback, let banner = ArtworkStore.cachedBanner(game.titleID, in: banners) {
            candidates.append((banner, true))
        }
        return candidates
    }

    /// Whether the game already has a dedicated square icon on disk (custom import, built AppIcon, online icon.jpg or offline nacp-icon.jpg).
    static func hasDedicatedIcon(for game: LibraryGame, banners: URL) -> Bool {
        !appIconCandidates(for: game, banners: banners, allowBannerFallback: false).isEmpty
    }

    /// A game's square icon, downsampled to `maxPixel` (192 px default), following the reliable fallback chain:
    /// custom icon → built AppIcon.icns → cached icon.jpg → offline nacp-icon.jpg → center-cropped cached banner.
    static func appIcon(for game: LibraryGame, banners: URL, maxPixel: Int = ArtworkImages.iconPixels) -> NSImage? {
        for candidate in appIconCandidates(for: game, banners: banners, allowBannerFallback: true) {
            if let image = ArtworkImages.shared.image(at: candidate.url, maxPixel: maxPixel, squareCrop: candidate.squareCrop) {
                return image
            }
        }
        return nil
    }

    /// Loads a game's square icon off the main thread. When no dedicated square icon exists yet and the game has a local Switch
    /// package with keys, extracts its official 256×256 Control NCA icon offline to `<banners>/<TITLEID>/nacp-icon.jpg` before
    /// falling back to a center-cropped landscape banner.
    static func loadAppIcon(
        for game: LibraryGame,
        banners: URL,
        language: String = "en",
        fallbackKeys: String = "",
        maxPixel: Int = ArtworkImages.iconPixels
    ) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            for candidate in appIconCandidates(for: game, banners: banners, allowBannerFallback: false) {
                if let image = ArtworkImages.shared.image(at: candidate.url, maxPixel: maxPixel, squareCrop: candidate.squareCrop) {
                    return image
                }
            }
            if let extracted = PackageControl.extractControlIcon(
                from: game,
                preferredLanguage: language,
                fallbackKeys: fallbackKeys,
                artworkDirectory: banners
            ) {
                ArtworkImages.shared.invalidate(at: extracted)
                if let image = ArtworkImages.shared.image(at: extracted, maxPixel: maxPixel) {
                    return image
                }
            }
            if let banner = ArtworkStore.cachedBanner(game.titleID, in: banners),
               let cropped = ArtworkImages.shared.image(at: banner, maxPixel: maxPixel, squareCrop: true) {
                return cropped
            }
            return nil
        }.value
    }

    /// Loads a square icon off the main thread when only a title ID (and optional Mac `.app` path) is available.
    static func loadAppIcon(
        titleID: String,
        appPath: String = "",
        banners: URL,
        maxPixel: Int = ArtworkImages.iconPixels
    ) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            if !appPath.isEmpty {
                let app = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Resources/AppIcon.icns")
                if fm.fileExists(atPath: app.path),
                   let image = ArtworkImages.shared.image(at: app, maxPixel: maxPixel) {
                    return image
                }
            }
            if let online = BannerCache.iconFile(titleID, in: banners), fm.fileExists(atPath: online.path),
               let image = ArtworkImages.shared.image(at: online, maxPixel: maxPixel) {
                return image
            }
            if let nacp = BannerCache.cachedNacpIcon(titleID, in: banners),
               let image = ArtworkImages.shared.image(at: nacp, maxPixel: maxPixel) {
                return image
            }
            if let banner = ArtworkStore.cachedBanner(titleID, in: banners),
               let cropped = ArtworkImages.shared.image(at: banner, maxPixel: maxPixel, squareCrop: true) {
                return cropped
            }
            return nil
        }.value
    }

    /// The artwork files there are for a slot, best first. The hero: the player's own choice, then the game's eShop key art
    /// (ArtworkStore, or its first screenshot when it has no banner, as the panel's default), then an existing repository gameplay
    /// screenshot, then the app icon (or offline Control NCA icon). A thumbnail: its own choice, else exactly the hero's.
    static func artworkURLs(for game: LibraryGame, slot: ArtworkSlot = .hero, repo: String, banners: URL = ArtworkStore.shared.directory) -> [URL] {
        var urls: [URL] = []
        if slot == .thumbnail, let url = file(for: game.artwork.thumbnail, of: game, banners: banners) { urls.append(url) }
        if let url = file(for: game.artwork.hero, of: game, banners: banners) { urls.append(url) }
        if !game.artworkPath.isEmpty, FileManager.default.fileExists(atPath: game.artworkPath) { urls.append(URL(fileURLWithPath: game.artworkPath)) }   // not copied yet
        if let url = ArtworkStore.cachedBanner(game.titleID, in: banners) { urls.append(url) }
        else if let url = ArtworkStore.cachedCandidate(.screenshot(0), titleID: game.titleID, in: banners) { urls.append(url) }   // no banner: the first screenshot, the panel's default
        let name = RepoDocsImagesIndex.normalize(game.name)
        if let url = RepoDocsImagesIndex.shared.match(normalizedGameName: name, repo: repo) { urls.append(url) }
        let icon = game.appPath + "/Contents/Resources/AppIcon.icns"
        // Extraction icons are small; they are a fallback, never presented as high-resolution artwork.
        if !game.appPath.isEmpty, FileManager.default.fileExists(atPath: icon) { urls.append(URL(fileURLWithPath: icon)) }
        else if let nacp = BannerCache.cachedNacpIcon(game.titleID, in: banners) { urls.append(nacp) }
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

    /// The hero's image for a game: the one decoded for the hero when it is this game's, else a hero-sized decode. Never a card's.
    static func heroImage(for id: UUID, decoded: (id: UUID, image: NSImage)?, decode: () -> NSImage?) -> NSImage? {
        if let decoded, decoded.id == id { return decoded.image }
        return decode()
    }

    /// The artwork, decoded no larger than `maxPixel` on its longer side. The hero needs the large default, a card or a
    /// console cover `ArtworkImages.cardPixels`.
    static func artwork(for game: LibraryGame, slot: ArtworkSlot = .hero, repo: String, banners: URL = ArtworkStore.shared.directory,
                        maxPixel: Int = ArtworkImages.heroPixels) -> NSImage? {
        // A file that is there but does not decode (a damaged download) gives way to the next one
        artworkURLs(for: game, slot: slot, repo: repo, banners: banners).lazy.compactMap { ArtworkImages.shared.image(at: $0, maxPixel: maxPixel) }.first
    }
}
