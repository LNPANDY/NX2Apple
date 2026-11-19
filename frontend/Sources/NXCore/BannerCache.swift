import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Where the eShop banners and cached icons live (the launcher's `ArtworkStore` downloads them, and `PackageControl` caches
/// offline NACP icons beside them). The shared app's install and `NXLauncher` sheets read them here, including on-demand
/// single-banner backfill and square fallback icon synthesis, with no AppKit or SwiftUI dependency.
package enum BannerCache {
    package typealias DataFetcher = @Sendable (URL, TimeInterval) -> Data?

    package static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NS Port Builder/artwork")

    package static let supportedExtensions = ["jpg", "png", "jpeg", "heic", "webp"]

    private static func safeTitleID(_ titleID: String) -> String? {
        let upper = titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !upper.isEmpty, upper != ".", upper != "..",
              !upper.contains("/"), !upper.contains("\\"), !upper.contains(":") else { return nil }
        return upper
    }

    /// Where a title's banner is kept; nil while it has none.
    package static func cached(_ titleID: String, in directory: URL = BannerCache.directory, fm: FileManager = .default) -> URL? {
        let id = titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !id.isEmpty else { return nil }
        for ext in supportedExtensions {
            let url = directory.appendingPathComponent(id + "." + ext)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Reads a cached title ID → banner URL entry from a local `index.json` without triggering network I/O.
    package static func indexBannerURL(for titleID: String, in directory: URL = BannerCache.directory) -> String? {
        let id = titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard KnownGameBanners.isValidTitleID(id),
              let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let banners = json["banners"] as? [String: String] else { return nil }
        let link = banners[id]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (link?.isEmpty == false) ? link : nil
    }

    /// Synchronous single-banner fetch for iOS packaging when the local cache has no banner yet.
    /// Reads only the local `index.json` (if present) and `KnownGameBanners`, never downloading the 90 MB title database.
    @discardableResult
    package static func ensureCachedBanner(
        titleID: String,
        banners: URL = BannerCache.directory,
        timeout: TimeInterval = 10,
        allowsFileURLs: Bool = false,
        fm: FileManager = .default,
        fetcher: DataFetcher? = nil
    ) -> URL? {
        let id = titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard KnownGameBanners.isValidTitleID(id) else { return nil }
        if let existing = cached(id, in: banners, fm: fm) { return existing }

        let indexLink = indexBannerURL(for: id, in: banners)
        var candidates: [(link: String, timeout: TimeInterval)] = []
        var seenLinks = Set<String>()
        func append(_ link: String?, timeout: TimeInterval) {
            guard let link, !link.isEmpty else { return }
            for cand in KnownGameBanners.downloadCandidates(for: link, lightweight: false) where seenLinks.insert(cand).inserted {
                candidates.append((cand, timeout))
            }
        }
        append(KnownGameBanners.bannerURL(for: id, preferred: indexLink), timeout: timeout)
        append(KnownGameBanners.nlibBannerURL(for: id), timeout: min(timeout, 8))

        let fetch = fetcher ?? defaultFetcher
        for item in candidates {
            guard let url = URL(string: item.link),
                  KnownGameBanners.isAllowedURL(url, allowsFileURLs: allowsFileURLs),
                  let data = fetch(url, item.timeout),
                  KnownGameBanners.isValidImageData(data) else { continue }
            do {
                try fm.createDirectory(at: banners, withIntermediateDirectories: true)
                let dest = banners.appendingPathComponent(id + ".jpg")
                try data.write(to: dest, options: .atomic)
                return dest
            } catch {
                return nil
            }
        }
        return nil
    }

    /// Center-cropped square PNG (`size × size`) derived from `image`, or nil if `image` has no pixels.
    package static func squarePNG(from image: CGImage, size: Int = 512) -> Data? {
        let side = min(image.width, image.height)
        guard side > 0, size > 0,
              let square = image.cropping(to: CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: size,
                  height: size,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let scaled = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, scaled, nil)
        return CGImageDestinationFinalize(dest) ? (out as Data) : nil
    }

    /// Generates `<framework>/icon.png` (512×512 PNG center-cropped from `bannerPath`) when the game package lacks its own `icon.png`.
    /// Existing native `icon.png` files are never overwritten.
    @discardableResult
    package static func ensureFallbackSquareIcon(
        inFramework framework: String,
        fromBanner bannerPath: String,
        size: Int = 512,
        fm: FileManager = .default
    ) -> Bool {
        let iconPath = framework + "/icon.png"
        guard !fm.fileExists(atPath: iconPath) else { return false }
        let bannerURL = URL(fileURLWithPath: bannerPath)
        guard let source = CGImageSourceCreateWithURL(bannerURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let pngData = squarePNG(from: image, size: size) else { return false }
        do {
            try pngData.write(to: URL(fileURLWithPath: iconPath), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static let defaultFetcher: DataFetcher = { url, timeout in
        // Avoid accidental live internet traffic during XCTest runs that did not inject a fake fetcher.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return nil
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = max(2, timeout)
        config.timeoutIntervalForResource = max(4, timeout * 1.5)
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: max(2, timeout))
        request.setValue("NX2Apple/1.5", forHTTPHeaderField: "User-Agent")

        final class Box: @unchecked Sendable { var data: Data? }
        let box = Box()
        let sema = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            defer { sema.signal() }
            guard error == nil, let data else { return }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { return }
            box.data = data
        }
        task.resume()
        _ = sema.wait(timeout: .now() + max(2, timeout * 1.5))
        return box.data
    }

    /// `<dir>/<TITLEID>/icon.jpg` (online square metadata icon).
    package static func iconFile(_ titleID: String, in directory: URL = BannerCache.directory) -> URL? {
        guard let id = safeTitleID(titleID) else { return nil }
        return directory.appendingPathComponent(id, isDirectory: true).appendingPathComponent("icon.jpg")
    }

    /// `<dir>/<TITLEID>/nacp-icon.jpg` (offline 256×256 JPEG icon extracted from the ROM's Control NCA).
    package static func nacpIconFile(_ titleID: String, in directory: URL = BannerCache.directory) -> URL? {
        guard let id = safeTitleID(titleID) else { return nil }
        return directory.appendingPathComponent(id, isDirectory: true).appendingPathComponent("nacp-icon.jpg")
    }

    /// Existing cached `nacp-icon.jpg`, or nil when not extracted yet.
    package static func cachedNacpIcon(_ titleID: String, in directory: URL = BannerCache.directory) -> URL? {
        guard let url = nacpIconFile(titleID, in: directory) else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Best cached square icon on disk: `icon.jpg` first, then offline `nacp-icon.jpg`.
    package static func cachedIcon(_ titleID: String, in directory: URL = BannerCache.directory) -> URL? {
        if let online = iconFile(titleID, in: directory), FileManager.default.fileExists(atPath: online.path) { return online }
        return cachedNacpIcon(titleID, in: directory)
    }
}
