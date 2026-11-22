import Foundation
import NXCore

/// A game of the player's own library for the state gallery's scenes: its title ID, names and artwork choice. Its artwork files are
/// copies in the gallery's own folder (GalleryRealCovers).
struct GalleryCover: Equatable {
    let id: UUID
    let titleID: String
    let name: String
    let titleNames: [String: String]
    let customName: String
    let artwork: GameArtwork
}

/// Copies the covers of the player's games into the gallery's temporary folder, so the scenes look like their library (#1459).
/// It only reads the real library file and the real artwork folder and copies files that are already there: it never writes to
/// either, never downloads and never touches the defaults. A game without any artwork file is left out.
enum GalleryRealCovers {
    /// The launcher's own library file and artwork folder (GameLibrary's and ArtworkStore's defaults).
    static var libraryFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NS Port Builder/library.json")
    }
    static var artworkFolder: URL { BannerCache.directory }

    private struct Snapshot: Decodable { let games: [LibraryGame] }

    /// The games of `libraryFile` with artwork in `artwork`, their files copied into `destination` (the artwork folder layout:
    /// `<TITLEID>.jpg`, `<TITLEID>/`, `custom/<game id>/`). At most `limit`.
    static func snapshot(libraryFile: URL = libraryFile, artwork: URL = artworkFolder, into destination: URL, limit: Int = 30) -> [GalleryCover] {
        guard let data = try? Data(contentsOf: libraryFile) else { return [] }
        let decoder = JSONDecoder()
        let games = (try? decoder.decode(Snapshot.self, from: data).games) ?? (try? decoder.decode([LibraryGame].self, from: data)) ?? []
        let fm = FileManager.default
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var covers: [GalleryCover] = []
        var seen: Set<String> = []
        for game in games where covers.count < limit {
            let id = game.titleID.uppercased()
            guard id.count == 16, UInt64(id, radix: 16) != nil, seen.insert(id).inserted else { continue }
            let sources = [artwork.appendingPathComponent(id + ".jpg"), artwork.appendingPathComponent(id, isDirectory: true),
                           artwork.appendingPathComponent("custom/" + game.id.uuidString, isDirectory: true)]
            let present = sources.filter { fm.fileExists(atPath: $0.path) }
            guard !present.isEmpty else { continue }
            for source in present {
                let target = destination.appendingPathComponent(String(source.path.dropFirst(artwork.path.count + 1)))
                try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !fm.fileExists(atPath: target.path) { try? fm.copyItem(at: source, to: target) }   // a copy, the source is left as it is
            }
            covers.append(GalleryCover(id: game.id, titleID: id, name: game.name, titleNames: game.titleNames,
                                       customName: game.customName, artwork: game.artwork))
        }
        return covers
    }
}

/// The gallery app's one snapshot of the player's covers, taken when it is first asked for and removed when the gallery quits.
enum GalleryCoverSource {
    static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nx-gallery-covers-" + UUID().uuidString, isDirectory: true)
    static let covers: [GalleryCover] = GalleryRealCovers.snapshot(into: folder)
    static func removeCopies() { try? FileManager.default.removeItem(at: folder) }
}

extension GalleryFixtures {
    /// Fixtures with the player's covers (`realCovers`, when the snapshot found any) or with the generated art.
    @MainActor static func make(lang: Lang, realCovers: Bool) -> GalleryFixtures {
        realCovers && !GalleryCoverSource.covers.isEmpty
            ? GalleryFixtures(lang: lang, covers: GalleryCoverSource.covers, coverFolder: GalleryCoverSource.folder)
            : GalleryFixtures(lang: lang)
    }
}
