import Foundation
import ShellUI

/// Manages writable per-game 16:9 banners under `<Documents>/Banners/<TitleID>/`:
/// - `custom.jpg`: user-cropped custom cover (highest priority)
/// - `auto.jpg`: automatically backfilled official 16:9 banner for legacy bundles lacking `banner.<ext>`
public enum GameBannerStore {
    public static let customFileName = "custom.jpg"
    public static let autoFileName = "auto.jpg"
    public static let maxRemoteBytes = 10 * 1024 * 1024
    public static let remoteTimeout: TimeInterval = 8

    public enum StoreError: Error, Equatable {
        case invalidTitleID
        case invalidImageData
    }

    public struct Resolution: Equatable, Sendable {
        /// Banner URLs in priority order (`custom.jpg`, bundled `entry.bannerURL`, `auto.jpg`).
        public var candidates: [URL]
        /// True when a user-saved `custom.jpg` exists on disk for this game.
        public var hasCustomCover: Bool

        public var primaryURL: URL? { candidates.first }
    }

    /// Normalizes a game title ID into a safe single directory component, rejecting traversal characters.
    public static func sanitizedTitleID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { return nil }
        if trimmed.contains("/") || trimmed.contains("\\") || trimmed.contains(":") || trimmed.contains("..") {
            return nil
        }
        if trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return nil
        }
        return trimmed.uppercased()
    }

    public static func gameDirectory(for titleID: String, bannersRoot: URL) -> URL? {
        guard let safe = sanitizedTitleID(titleID) else { return nil }
        return bannersRoot.appendingPathComponent(safe, isDirectory: true)
    }

    public static func customBannerURL(for titleID: String, bannersRoot: URL) -> URL? {
        gameDirectory(for: titleID, bannersRoot: bannersRoot)?.appendingPathComponent(customFileName, isDirectory: false)
    }

    public static func autoBannerURL(for titleID: String, bannersRoot: URL) -> URL? {
        gameDirectory(for: titleID, bannersRoot: bannersRoot)?.appendingPathComponent(autoFileName, isDirectory: false)
    }

    public static func hasCustomBanner(for titleID: String, bannersRoot: URL, fileManager fm: FileManager = .default) -> Bool {
        guard let url = customBannerURL(for: titleID, bannersRoot: bannersRoot) else { return false }
        return isNonEmptyRegularFile(url, fileManager: fm)
    }

    public static func hasAutoBanner(for titleID: String, bannersRoot: URL, fileManager fm: FileManager = .default) -> Bool {
        guard let url = autoBannerURL(for: titleID, bannersRoot: bannersRoot) else { return false }
        return isNonEmptyRegularFile(url, fileManager: fm)
    }

    /// Resolves banner priority:
    /// 1) `<bannersRoot>/<TitleID>/custom.jpg`
    /// 2) `entry.bannerURL` (`.framework/banner.<ext>`)
    /// 3) `<bannersRoot>/<TitleID>/auto.jpg`
    /// (4th level fallback to `entry.iconURL` happens in `ShellUI` when `GameTile.banner == nil`.)
    public static func resolve(for entry: CatalogueEntry, bannersRoot: URL, fileManager fm: FileManager = .default) -> Resolution {
        var candidates: [URL] = []
        var hasCustom = false

        if let custom = customBannerURL(for: entry.id, bannersRoot: bannersRoot),
           isNonEmptyRegularFile(custom, fileManager: fm) {
            candidates.append(custom)
            hasCustom = true
        }
        if let bundled = entry.bannerURL, isNonEmptyRegularFile(bundled, fileManager: fm) {
            candidates.append(bundled)
        }
        if let auto = autoBannerURL(for: entry.id, bannersRoot: bannersRoot),
           isNonEmptyRegularFile(auto, fileManager: fm) {
            candidates.append(auto)
        }
        return Resolution(candidates: candidates, hasCustomCover: hasCustom)
    }

    /// Validates and atomically writes `custom.jpg`, excluding `bannersRoot` from iCloud backup.
    @discardableResult
    public static func saveCustomBanner(
        _ data: Data,
        for titleID: String,
        bannersRoot: URL,
        fileManager fm: FileManager = .default
    ) throws -> URL {
        guard let target = customBannerURL(for: titleID, bannersRoot: bannersRoot) else {
            throw StoreError.invalidTitleID
        }
        return try writeValidatedBanner(data, to: target, bannersRoot: bannersRoot, fileManager: fm)
    }

    /// Validates and atomically writes `auto.jpg`, excluding `bannersRoot` from iCloud backup.
    @discardableResult
    public static func saveAutoBanner(
        _ data: Data,
        for titleID: String,
        bannersRoot: URL,
        fileManager fm: FileManager = .default
    ) throws -> URL {
        guard let target = autoBannerURL(for: titleID, bannersRoot: bannersRoot) else {
            throw StoreError.invalidTitleID
        }
        return try writeValidatedBanner(data, to: target, bannersRoot: bannersRoot, fileManager: fm)
    }

    /// Deletes `<bannersRoot>/<TitleID>/custom.jpg` if present and returns its URL for cache invalidation.
    @discardableResult
    public static func removeCustomBanner(
        for titleID: String,
        bannersRoot: URL,
        fileManager fm: FileManager = .default
    ) -> URL? {
        guard let target = customBannerURL(for: titleID, bannersRoot: bannersRoot) else { return nil }
        if fm.fileExists(atPath: target.path) {
            try? fm.removeItem(at: target)
        }
        return target
    }

    /// Single-point 720p banner fallback URL for any valid 16-hex Switch title ID.
    public static func nlibBannerURL(for titleID: String) -> URL? {
        guard let safe = sanitizedTitleID(titleID),
              safe.count == 16,
              safe.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) || ("A"..."F").contains($0) }) else {
            return nil
        }
        return URL(string: "https://api.nlib.cc/nx/\(safe)/banner/720p")
    }

    /// Ordered remote banner URLs to try when a game lacks bundled, custom, and auto-fetched banners:
    /// 1) Built-in `KnownGameBanners` table
    /// 2) Lightweight single-point fallback `https://api.nlib.cc/nx/<TID>/banner/720p`
    public static func autoBackfillURLs(
        for entry: CatalogueEntry,
        bannersRoot: URL,
        fileManager fm: FileManager = .default
    ) -> [URL] {
        guard entry.bannerURL == nil else { return [] }
        guard !hasCustomBanner(for: entry.id, bannersRoot: bannersRoot, fileManager: fm) else { return [] }
        guard !hasAutoBanner(for: entry.id, bannersRoot: bannersRoot, fileManager: fm) else { return [] }
        var urls: [URL] = []
        if let known = KnownGameBanners.url(for: entry.id) {
            urls.append(known)
        }
        if let nlib = nlibBannerURL(for: entry.id), !urls.contains(nlib) {
            urls.append(nlib)
        }
        return urls
    }

    /// First remote URL for missing-banner backfill, or nil when no backfill is needed.
    public static func needsAutoBackfill(
        for entry: CatalogueEntry,
        bannersRoot: URL,
        fileManager fm: FileManager = .default
    ) -> URL? {
        autoBackfillURLs(for: entry, bannersRoot: bannersRoot, fileManager: fm).first
    }

    /// Default network fetcher for missing-banner backfill (`URLSession.shared`, 8 s timeout, system proxy, 10 MB cap).
    public static func fetchRemoteBanner(from url: URL) async -> Data? {
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: remoteTimeout)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  !data.isEmpty,
                  data.count <= maxRemoteBytes else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    private static func writeValidatedBanner(
        _ data: Data,
        to target: URL,
        bannersRoot: URL,
        fileManager fm: FileManager
    ) throws -> URL {
        guard !data.isEmpty, Artwork(id: "validate", data: data) != nil else {
            throw StoreError.invalidImageData
        }
        let dir = target.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        BackupExclusion.exclude(bannersRoot)
        try data.write(to: target, options: .atomic)
        BackupExclusion.exclude(target)
        return target
    }

    private static func isNonEmptyRegularFile(_ url: URL, fileManager fm: FileManager) -> Bool {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              size > 0 else {
            return false
        }
        return true
    }
}
