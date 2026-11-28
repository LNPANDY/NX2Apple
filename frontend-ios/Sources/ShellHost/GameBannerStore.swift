import CoreGraphics
import Foundation
import ImageIO
import ShellUI
import UniformTypeIdentifiers

/// Manages writable per-game 16:9 banners under `<Documents>/Banners/<TitleID>/`:
/// - `custom.jpg`: user-cropped custom cover (highest priority)
/// - `auto.jpg`: automatically backfilled official 16:9 banner for legacy bundles lacking `banner.<ext>`
public enum GameBannerStore {
    public static let customFileName = "custom.jpg"
    public static let autoFileName = "auto.jpg"
    public static let maxRemoteBytes = 16 * 1024 * 1024
    public static let maxStoreHTMLBytes = 8 * 1024 * 1024
    public static let remoteTimeout: TimeInterval = 8
    public static let batchErrorBudget: TimeInterval = 24
    public static let storeRegions = ["US", "HK"]
    public static let browserUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

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

    public struct RemoteResponse: Sendable {
        public var statusCode: Int
        public var finalURL: URL
        public var data: Data

        public init(statusCode: Int, finalURL: URL, data: Data) {
            self.statusCode = statusCode
            self.finalURL = finalURL
            self.data = data
        }
    }

    public enum StoreFetchOutcome: Equatable, Sendable {
        case image(Data, sourceURL: URL)
        case notFound
        case transientFailure
    }

    public enum DirectImageOutcome: Equatable, Sendable {
        case image(Data)
        case notFound
        case transientFailure
    }

    public enum BackfillOutcome: Equatable, Sendable {
        case saved(URL)
        case notFound
        case transientFailure
    }

    public typealias StoreHTTPFetcher = @Sendable (URLRequest, Int) async throws -> RemoteResponse

    private enum TransportError: Error {
        case responseTooLarge
        case disallowedRedirect
        case missingHTTPResponse
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

    /// Single-point banner fallback URL for any valid 16-hex Switch title ID.
    ///
    /// nlib serves `720p` and `1080p` only: `1440p`, `2160p` and `original` answer 400.
    /// 1080p is the highest tier it offers (1920x1080, ~568 KB for a full-bleed banner),
    /// so that is the default; pass `720p` to fall back when a 1080p fetch fails.
    public static func nlibBannerURL(for titleID: String, quality: String = "1080p") -> URL? {
        guard let safe = sanitizedTitleID(titleID), KnownGameBanners.isValidTitleID(safe) else {
            return nil
        }
        return URL(string: "https://api.nlib.cc/nx/\(safe)/banner/\(quality)")
    }

    /// Rewrites the eShop's downscaled artwork URL into the full-size, full-bleed one.
    ///
    /// `assets.nintendo.com/image/upload/...` is a Cloudinary transform path, measured on
    /// v1.5.0-rc4 (2026-11):
    ///
    /// | transform                        | result      | letterbox |
    /// |----------------------------------|-------------|-----------|
    /// | `ar_16:9,c_lpad,w_930/b_white`   | 930x523     | white bars |
    /// | `ar_16:9,c_lpad,w_2560/b_white`  | 2560x1440   | white bars |
    /// | `ar_16:9,c_fill,w_2560`          | 2560x1440   | none       |
    ///
    /// So `c_lpad` (pad) becomes `c_fill` (crop to fill) and `b_white` (the padding colour)
    /// is dropped: without both, the fetched banner carries a white frame on all four sides,
    /// which is the one thing a full-bleed backdrop cannot hide.
    ///
    /// Anything not on `assets.nintendo.com` (the `img-eshop.cdn.nintendo.net` fallback, for
    /// one) has no transform path and is returned unchanged.
    static func upgradedArtworkURL(_ raw: URL) -> URL {
        let text = raw.absoluteString
        guard text.contains("assets.nintendo.com/image/upload") else { return raw }

        var out = text.replacingOccurrences(of: "c_lpad", with: "c_fill")
        out = out.replacingOccurrences(of: #"w_\d+"#, with: "w_2560", options: .regularExpression)
        out = out.replacingOccurrences(of: "/b_white/", with: "/")
        return URL(string: out) ?? raw
    }

    /// Regional Nintendo eShop redirect URL (`US`, `HK`) for any valid 16-hex Switch title ID.
    public static func storePageURL(for titleID: String, region: String) -> URL? {
        guard let safe = sanitizedTitleID(titleID), KnownGameBanners.isValidTitleID(safe) else {
            return nil
        }
        let reg = region.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !reg.isEmpty else { return nil }
        return URL(string: "https://ec.nintendo.com/apps/\(safe)/\(reg)")
    }

    /// Ordered remote banner URLs to try when a game lacks bundled, custom, and auto-fetched banners:
    /// 1) Built-in `KnownGameBanners` table
    /// 2) Lightweight single-point fallback `https://api.nlib.cc/nx/<TID>/banner/720p`
    public static func autoBackfillURLs(
        for entry: CatalogueEntry,
        bannersRoot: URL,
        fileManager fm: FileManager = .default
    ) -> [URL] {
        guard needsBackfill(for: entry, bannersRoot: bannersRoot, fileManager: fm) else { return [] }
        var urls: [URL] = []
        if let known = KnownGameBanners.url(for: entry.id) {
            urls.append(known)
        }
        if let nlib1080 = nlibBannerURL(for: entry.id, quality: "1080p"), !urls.contains(nlib1080) {
            urls.append(nlib1080)
        }
        // nlib's 1080p tier is not advertised by the service: keep 720p behind it, so a
        // 1080p refusal still ends with a banner instead of no banner.
        if let nlib720 = nlibBannerURL(for: entry.id, quality: "720p"), !urls.contains(nlib720) {
            urls.append(nlib720)
        }
        return urls
    }

    public static func needsBackfill(
        for entry: CatalogueEntry,
        bannersRoot: URL,
        fileManager fm: FileManager = .default
    ) -> Bool {
        guard entry.bannerURL == nil else { return false }
        guard !hasCustomBanner(for: entry.id, bannersRoot: bannersRoot, fileManager: fm) else { return false }
        guard !hasAutoBanner(for: entry.id, bannersRoot: bannersRoot, fileManager: fm) else { return false }
        return KnownGameBanners.url(for: entry.id) != nil || KnownGameBanners.isValidTitleID(entry.id)
    }

    /// First remote URL for missing-banner backfill, or nil when no backfill is needed.
    public static func needsAutoBackfill(
        for entry: CatalogueEntry,
        bannersRoot: URL,
        fileManager fm: FileManager = .default
    ) -> URL? {
        autoBackfillURLs(for: entry, bannersRoot: bannersRoot, fileManager: fm).first
    }

    /// Returns pixel dimensions when `data` is a bounded, decodable image with a recognized magic header.
    public static func imagePixelSize(_ data: Data, maxBytes: Int = maxRemoteBytes) -> (width: Int, height: Int)? {
        guard data.count >= 12, data.count <= maxBytes else { return nil }
        let bytes = [UInt8](data.prefix(12))
        let isJPEG = bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF
        let isPNG = bytes.prefix(8).elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let isWebP = bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46
            && bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50
        let isHEIF = bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70
        guard isJPEG || isPNG || isWebP || isHEIF else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0 else { return nil }
        return (image.width, image.height)
    }

    public static func isValidLandscapeImageData(_ data: Data, maxBytes: Int = maxRemoteBytes) -> Bool {
        guard let size = imagePixelSize(data, maxBytes: maxBytes) else { return false }
        return size.width > size.height
    }

    /// Returns JPEG bytes matching `auto.jpg`: preserves valid JPEG bytes verbatim and transcodes PNG/WebP/HEIF via ImageIO.
    public static func normalizedJPEGData(_ data: Data, quality: CGFloat = 0.92, maxBytes: Int = maxRemoteBytes) -> Data? {
        guard imagePixelSize(data, maxBytes: maxBytes) != nil else { return nil }
        let bytes = [UInt8](data.prefix(3))
        if bytes.count == 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
            return data
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest), out.length > 0 else { return nil }
        return out as Data
    }

    /// Extracts an official banner image URL from a Nintendo US/HK store HTML page.
    public static func extractNintendoStoreBannerURL(from html: String) -> URL? {
        if let url = extractFromNextData(html) { return url }
        if let url = extractFromAssetsRegex(html) { return url }
        if let url = extractFromOpenGraph(html) { return url }
        return nil
    }

    /// Probes Nintendo US -> HK official store pages for `titleID`, validates redirect hosts and landscape dimensions,
    /// and returns JPEG-normalized bytes.
    public static func fetchNintendoStoreBanner(
        titleID: String,
        transport: StoreHTTPFetcher? = nil
    ) async -> StoreFetchOutcome {
        guard let safe = sanitizedTitleID(titleID), KnownGameBanners.isValidTitleID(safe) else { return .notFound }
        let run = transport ?? defaultStoreTransport
        var hadTransientFailure = false

        for region in storeRegions {
            if Task.isCancelled { return .transientFailure }
            guard let pageURL = storePageURL(for: safe, region: region) else { continue }
            var pageReq = URLRequest(url: pageURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: remoteTimeout)
            pageReq.httpMethod = "GET"
            pageReq.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
            pageReq.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

            let pageResp: RemoteResponse
            do {
                pageResp = try await run(pageReq, maxStoreHTMLBytes)
            } catch {
                if !isPolicyRejection(error) { hadTransientFailure = true }
                continue
            }

            if pageResp.statusCode == 404 || pageResp.statusCode == 410 {
                continue
            }
            if pageResp.statusCode >= 500 {
                hadTransientFailure = true
                continue
            }
            guard (200...299).contains(pageResp.statusCode),
                  KnownGameBanners.isAllowedStoreURL(pageResp.finalURL),
                  pageResp.data.count <= maxStoreHTMLBytes else { continue }

            let html = String(decoding: pageResp.data, as: UTF8.self)
            guard let thumbnailURL = extractNintendoStoreBannerURL(from: html),
                  KnownGameBanners.isAllowedURL(thumbnailURL) else { continue }

            // The store page hands out a downscaled thumbnail; the same asset serves the full
            // 2560x1440 key art when the transform path is rewritten (see upgradedArtworkURL).
            let imageURL = upgradedArtworkURL(thumbnailURL)
            var imgReq = URLRequest(url: imageURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: remoteTimeout)
            imgReq.httpMethod = "GET"
            imgReq.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
            imgReq.setValue("image/jpeg,image/png,image/*;q=0.8", forHTTPHeaderField: "Accept")

            let imgResp: RemoteResponse
            do {
                imgResp = try await run(imgReq, maxRemoteBytes)
            } catch {
                if !isPolicyRejection(error) { hadTransientFailure = true }
                continue
            }
            if imgResp.statusCode >= 500 {
                hadTransientFailure = true
                continue
            }
            guard (200...299).contains(imgResp.statusCode),
                  KnownGameBanners.isAllowedURL(imgResp.finalURL),
                  imgResp.data.count <= maxRemoteBytes,
                  isValidLandscapeImageData(imgResp.data, maxBytes: maxRemoteBytes),
                  let jpeg = normalizedJPEGData(imgResp.data, maxBytes: maxRemoteBytes) else {
                continue
            }
            return .image(jpeg, sourceURL: imgResp.finalURL)
        }
        return hadTransientFailure ? .transientFailure : .notFound
    }

    /// Unified auto-banner backfill for one catalogue entry:
    /// 1) Built-in `KnownGameBanners`
    /// 2) Switch 2 (`0400...`): `ec.nintendo.com` (US -> HK) then `api.nlib.cc`
    ///    Switch 1 (`0100...`): `api.nlib.cc` then `ec.nintendo.com` (US -> HK)
    public static func fetchAndSaveAutoBanner(
        for entry: CatalogueEntry,
        bannersRoot: URL,
        fetchBannerData: @escaping @Sendable (URL) async -> Data?,
        fetchBannerOutcome: (@Sendable (URL) async -> DirectImageOutcome)? = nil,
        storeTransport: StoreHTTPFetcher? = nil,
        fileManager fm: FileManager = .default
    ) async -> BackfillOutcome {
        guard needsBackfill(for: entry, bannersRoot: bannersRoot, fileManager: fm) else { return .notFound }

        var hadTransientFailure = false

        func fetchDirect(_ url: URL) async -> Data? {
            if let fetchBannerOutcome {
                switch await fetchBannerOutcome(url) {
                case .image(let data):
                    return data
                case .transientFailure:
                    hadTransientFailure = true
                    return nil
                case .notFound:
                    return nil
                }
            }
            return await fetchBannerData(url)
        }

        if let known = KnownGameBanners.url(for: entry.id) {
            if Task.isCancelled { return .transientFailure }
            if let raw = await fetchDirect(known), !Task.isCancelled {
                let normalized = (known.host?.lowercased() == "assets.nintendo.com")
                    ? (normalizedJPEGData(raw) ?? raw) : raw
                if let saved = try? saveAutoBanner(normalized, for: entry.id, bannersRoot: bannersRoot, fileManager: fm) {
                    return .saved(saved)
                }
            }
        }

        func tryNlib() async -> URL? {
            guard !Task.isCancelled, let nlib = nlibBannerURL(for: entry.id) else { return nil }
            guard let data = await fetchDirect(nlib), !Task.isCancelled else { return nil }
            return try? saveAutoBanner(data, for: entry.id, bannersRoot: bannersRoot, fileManager: fm)
        }
        func tryStore() async -> URL? {
            switch await fetchNintendoStoreBanner(titleID: entry.id, transport: storeTransport) {
            case .image(let jpegData, _):
                guard !Task.isCancelled else {
                    hadTransientFailure = true
                    return nil
                }
                return try? saveAutoBanner(jpegData, for: entry.id, bannersRoot: bannersRoot, fileManager: fm)
            case .transientFailure:
                hadTransientFailure = true
                return nil
            case .notFound:
                return nil
            }
        }

        if KnownGameBanners.isSwitch2TitleID(entry.id) {
            if let saved = await tryStore() { return .saved(saved) }
            if let saved = await tryNlib() { return .saved(saved) }
        } else {
            if let saved = await tryNlib() { return .saved(saved) }
            if let saved = await tryStore() { return .saved(saved) }
        }
        return (Task.isCancelled || hadTransientFailure) ? .transientFailure : .notFound
    }

    /// Bounded, redirect-guarded image fetch that distinguishes permanent 404/policy rejection from transient 5xx/network errors.
    public static func fetchRemoteBannerOutcome(
        from url: URL,
        transport: StoreHTTPFetcher? = nil
    ) async -> DirectImageOutcome {
        guard KnownGameBanners.isAllowedURL(url) else { return .notFound }
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: remoteTimeout)
        request.httpMethod = "GET"
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("image/jpeg,image/png,image/*;q=0.8", forHTTPHeaderField: "Accept")
        let run = transport ?? defaultStoreTransport
        do {
            let resp = try await run(request, maxRemoteBytes)
            if resp.statusCode == 404 || resp.statusCode == 410 {
                return .notFound
            }
            if resp.statusCode >= 500 {
                return .transientFailure
            }
            guard (200...299).contains(resp.statusCode),
                  KnownGameBanners.isAllowedURL(resp.finalURL),
                  !resp.data.isEmpty,
                  resp.data.count <= maxRemoteBytes else {
                return .notFound
            }
            return .image(resp.data)
        } catch {
            return isPolicyRejection(error) ? .notFound : .transientFailure
        }
    }

    /// Default network fetcher for missing-banner backfill (`URLSession.shared`, 8 s timeout, system proxy, 16 MB cap).
    public static func fetchRemoteBanner(from url: URL) async -> Data? {
        if case .image(let data) = await fetchRemoteBannerOutcome(from: url) {
            return data
        }
        return nil
    }

    private static func extractFromNextData(_ html: String) -> URL? {
        guard let regex = try? NSRegularExpression(
            pattern: #"<script\b[^>]*\bid\s*=\s*["']__NEXT_DATA__["'][^>]*>([\s\S]*?)</script>"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let nsHTML = html as NSString
        guard let match = regex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: nsHTML.length)),
              match.numberOfRanges > 1,
              match.range(at: 1).location != NSNotFound else { return nil }
        let jsonText = nsHTML.substring(with: match.range(at: 1))
        guard let data = jsonText.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let props = root["props"] as? [String: Any],
              let pageProps = props["pageProps"] as? [String: Any],
              let linkedData = pageProps["linkedData"] else { return nil }

        let objects: [[String: Any]]
        if let dict = linkedData as? [String: Any] {
            objects = [dict]
        } else if let array = linkedData as? [Any] {
            objects = array.compactMap { $0 as? [String: Any] }
        } else {
            return nil
        }

        for obj in objects {
            if let raw = obj["image"] as? String, let url = validatedAssetsURL(raw) {
                return url
            }
            if let list = obj["image"] as? [String] {
                for raw in list {
                    if let url = validatedAssetsURL(raw) { return url }
                }
            }
        }
        return nil
    }

    private static func extractFromAssetsRegex(_ html: String) -> URL? {
        guard let regex = try? NSRegularExpression(
            pattern: #""image"\s*:\s*"(https://assets\.nintendo\.com/image/upload/[^"]*/store/software/switch2?/[0-9]+/[^"]+)""#,
            options: []
        ) else { return nil }
        let nsHTML = html as NSString
        guard let match = regex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: nsHTML.length)),
              match.numberOfRanges > 1,
              match.range(at: 1).location != NSNotFound else { return nil }
        return validatedAssetsURL(nsHTML.substring(with: match.range(at: 1)))
    }

    private static func extractFromOpenGraph(_ html: String) -> URL? {
        guard let metaRegex = try? NSRegularExpression(pattern: #"<meta\b[^>]+>"#, options: [.caseInsensitive]),
              let propRegex = try? NSRegularExpression(
                  pattern: #"\bproperty\s*=\s*["']og:image["']"#,
                  options: [.caseInsensitive]
              ),
              let contentRegex = try? NSRegularExpression(
                  pattern: #"\bcontent\s*=\s*["'](https://img-eshop\.cdn\.nintendo\.net/i/[0-9a-fA-F]+\.(?:jpg|png|webp))["']"#,
                  options: [.caseInsensitive]
              ) else { return nil }

        let nsHTML = html as NSString
        let matches = metaRegex.matches(in: html, options: [], range: NSRange(location: 0, length: nsHTML.length))
        for m in matches {
            let tag = nsHTML.substring(with: m.range)
            let nsTag = tag as NSString
            let tagRange = NSRange(location: 0, length: nsTag.length)
            guard propRegex.firstMatch(in: tag, options: [], range: tagRange) != nil,
                  let contentMatch = contentRegex.firstMatch(in: tag, options: [], range: tagRange),
                  contentMatch.numberOfRanges > 1,
                  contentMatch.range(at: 1).location != NSNotFound else { continue }
            let raw = nsTag.substring(with: contentMatch.range(at: 1))
            if let url = URL(string: raw), KnownGameBanners.isAllowedURL(url) {
                return url
            }
        }
        return nil
    }

    private static func validatedAssetsURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "assets.nintendo.com" else { return nil }
        return url
    }

    private static func isPolicyRejection(_ error: Error) -> Bool {
        if let err = error as? TransportError {
            return err == .disallowedRedirect || err == .responseTooLarge
        }
        return false
    }

    private static func isAllowedDestination(_ url: URL, forOriginal original: URL?) -> Bool {
        if let original, KnownGameBanners.isAllowedStoreURL(original) && original.host?.lowercased() == "ec.nintendo.com" {
            return KnownGameBanners.isAllowedStoreURL(url)
        }
        return KnownGameBanners.isAllowedURL(url)
    }

    private final class BoundedDataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let originalURL: URL?
        let maxBytes: Int
        private let onComplete: @Sendable (Result<RemoteResponse, Error>) -> Void
        private let lock = NSLock()
        private var buffer = Data()
        private var httpResponse: HTTPURLResponse?
        private var capturedError: Error?
        private var finished = false

        init(originalURL: URL?, maxBytes: Int, onComplete: @escaping @Sendable (Result<RemoteResponse, Error>) -> Void) {
            self.originalURL = originalURL
            self.maxBytes = maxBytes
            self.onComplete = onComplete
        }

        private func emitOnce(_ result: Result<RemoteResponse, Error>) {
            let shouldEmit = lock.withLock { () -> Bool in
                guard !finished else { return false }
                finished = true
                return true
            }
            if shouldEmit {
                onComplete(result)
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let target = request.url, isAllowedDestination(target, forOriginal: originalURL) else {
                lock.withLock { capturedError = TransportError.disallowedRedirect }
                completionHandler(nil)
                task.cancel()
                return
            }
            completionHandler(request)
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let http = response as? HTTPURLResponse, let finalURL = http.url else {
                lock.withLock { capturedError = TransportError.missingHTTPResponse }
                completionHandler(.cancel)
                return
            }
            guard isAllowedDestination(finalURL, forOriginal: originalURL) else {
                lock.withLock { capturedError = TransportError.disallowedRedirect }
                completionHandler(.cancel)
                return
            }
            if http.expectedContentLength > Int64(maxBytes) {
                lock.withLock { capturedError = TransportError.responseTooLarge }
                completionHandler(.cancel)
                return
            }
            lock.withLock { httpResponse = http }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let overflow = lock.withLock { () -> Bool in
                if data.count > maxBytes - buffer.count {
                    capturedError = TransportError.responseTooLarge
                    return true
                }
                buffer.append(data)
                return false
            }
            if overflow {
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let result: Result<RemoteResponse, Error> = lock.withLock {
                if let capturedError { return .failure(capturedError) }
                if let error { return .failure(error) }
                guard let http = httpResponse, let finalURL = http.url else {
                    return .failure(TransportError.missingHTTPResponse)
                }
                return .success(RemoteResponse(statusCode: http.statusCode, finalURL: finalURL, data: buffer))
            }
            emitOnce(result)
        }
    }

    private static let defaultStoreTransport: StoreHTTPFetcher = { request, maxBytes in
        let config = URLSessionConfiguration.ephemeral
        let timeout = max(2, request.timeoutInterval)
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = max(4, timeout * 1.5)
        final class TaskBox: @unchecked Sendable {
            private let lock = NSLock()
            private var task: URLSessionDataTask?
            private var cancelled = false
            func set(_ t: URLSessionDataTask) {
                let shouldCancel = lock.withLock { () -> Bool in
                    task = t
                    return cancelled
                }
                if shouldCancel { t.cancel() }
            }
            func cancel() {
                let current = lock.withLock { () -> URLSessionDataTask? in
                    cancelled = true
                    return task
                }
                current?.cancel()
            }
        }
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                let delegate = BoundedDataDelegate(originalURL: request.url, maxBytes: maxBytes) { result in
                    cont.resume(with: result)
                }
                let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
                let task = session.dataTask(with: request)
                box.set(task)
                task.resume()
                session.finishTasksAndInvalidate()
            }
        } onCancel: {
            box.cancel()
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
