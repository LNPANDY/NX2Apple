import AppKit
import ImageIO
import NXCore
import SwiftUI

/// Where an image sits when it fills a band (a hero, a card): the pure math, no views. The band shows the image at the
/// larger of the two scales that cover it, so one axis is cut. `focus` says which part stays, as CSS `object-position` does.
enum ArtworkFraming {
    /// A crop of this fraction or more is worth offering a focus point for. Less cuts too little to notice.
    static let threshold: CGFloat = 0.05

    /// The fraction of the image's width (a wide image) or height (a tall one) that the band cuts off.
    static func cropFraction(image: CGSize, band: CGSize) -> CGFloat {
        guard image.width > 0, image.height > 0, band.width > 0, band.height > 0 else { return 0 }
        let imageAspect = image.width / image.height, bandAspect = band.width / band.height
        return imageAspect > bandAspect ? 1 - bandAspect / imageAspect : 1 - imageAspect / bandAspect
    }

    static func needsFraming(image: CGSize, band: CGSize) -> Bool {
        cropFraction(image: image, band: band) >= threshold
    }

    /// How far to move the filled image from where it sits centred. Focus 0 puts its leading (or top) edge on the band's edge,
    /// 1 the trailing (or bottom) one, 0.5 leaves it centred. A focus outside 0...1 stops at the edge, so none is ever exposed.
    static func offset(image: CGSize, band: CGSize, focus: UnitPoint) -> CGSize {
        guard image.width > 0, image.height > 0, band.width > 0, band.height > 0 else { return .zero }
        let scale = max(band.width / image.width, band.height / image.height)
        let overflow = CGSize(width: image.width * scale - band.width, height: image.height * scale - band.height)
        func clamped(_ value: CGFloat) -> CGFloat { min(max(value, 0), 1) }
        return CGSize(width: overflow.width * (0.5 - clamped(focus.x)), height: overflow.height * (0.5 - clamped(focus.y)))
    }
}

/// The image filling its band, clipped, with `focus` deciding what the crop keeps. At the centre it draws exactly what
/// `Image(nsImage:).resizable().scaledToFill()` in a clipped frame does.
struct ArtworkFill: View {
    let image: NSImage
    var focus: UnitPoint = .center

    var body: some View {
        GeometryReader { band in
            Image(nsImage: image).resizable().interpolation(.high).antialiased(true).scaledToFill()   // smooth when scaled, no blur on top
                .frame(width: band.size.width, height: band.size.height)
                .offset(ArtworkFraming.offset(image: image.size, band: band.size, focus: focus))
                .clipped()
        }
    }
}

/// Artwork decoded at the size it is drawn at, and kept. A 1920×1080 key art on a 300 pt card is a few million pixels too
/// many, and the same file is drawn again at every redraw. Safe to call from any thread.
final class ArtworkImages: @unchecked Sendable {
    static let shared = ArtworkImages()

    /// Standard square icon tier (44–96 pt at 2x Retina).
    static let iconPixels = 192
    /// Compact 16:9 list thumbnail tier (e.g. Supported games 112×63 pt at 2x).
    static let listThumbPixels = 224
    /// Enough for a card, the console and the onboarding covers.
    static let cardPixels = 640
    /// The hero covers the window: twice the widest screen (Retina), never more than 4K.
    static var heroPixels: Int { min(3840, Int(2 * (NSScreen.screens.map(\.frame.width).max() ?? 1920))) }

    struct FileStamp: Equatable {
        let size: UInt64
        let modified: Date
    }

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 256 << 20   // bytes of decoded pixels: a library of cards and a few 4K heroes
        return cache
    }()

    /// How long a file's attributes are trusted. SwiftUI bodies ask for the same few files at every redraw, on the main thread.
    static let recheckInterval: TimeInterval = 2

    private let now: () -> Date
    private let readStamp: (URL) -> FileStamp?
    private let lock = NSLock()
    private var checked: [String: (stamp: FileStamp, at: Date)] = [:]   // existing files only, by path, behind `lock`

    init(now: @escaping () -> Date = Date.init,
         stat: ((URL) -> Date?)? = nil) {
        self.now = now
        if let stat {
            self.readStamp = { url in
                guard let modified = stat(url) else { return nil }
                let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
                return FileStamp(size: size, modified: modified)
            }
        } else {
            self.readStamp = { url in   // not URL.resourceValues, which a URL caches
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let modified = attrs[.modificationDate] as? Date else { return nil }
                let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
                return FileStamp(size: size, modified: modified)
            }
        }
    }

    /// Drops the cached stat record for `url` so an immediate replacement on disk is observed without waiting `recheckInterval`.
    func invalidate(at url: URL) {
        lock.lock()
        checked.removeValue(forKey: url.path)
        lock.unlock()
    }

    private func fileStamp(of url: URL) -> FileStamp? {
        let current = now()
        lock.lock()
        let known = checked[url.path]
        lock.unlock()
        if let known, current.timeIntervalSince(known.at) >= 0, current.timeIntervalSince(known.at) < Self.recheckInterval {
            return known.stamp
        }
        guard let stamp = readStamp(url) else {
            // Never negative-cache missing files: as soon as an artwork file lands on disk it must be visible immediately.
            lock.lock()
            checked.removeValue(forKey: url.path)
            lock.unlock()
            return nil
        }
        lock.lock()
        checked[url.path] = (stamp, current)
        lock.unlock()
        return stamp
    }

    private func cacheKey(for url: URL, stamp: FileStamp, maxPixel: Int, squareCrop: Bool) -> NSString {
        "\(url.path)|\(stamp.size)|\(stamp.modified.timeIntervalSinceReferenceDate)|\(maxPixel)|\(squareCrop ? 1 : 0)" as NSString
    }

    /// Returns an already-decoded image from memory without doing disk decode (safe to call from SwiftUI `body`).
    func cachedImage(at url: URL, maxPixel: Int, squareCrop: Bool = false) -> NSImage? {
        guard let stamp = fileStamp(of: url) else { return nil }
        return cache.object(forKey: cacheKey(for: url, stamp: stamp, maxPixel: maxPixel, squareCrop: squareCrop))
    }

    /// Decodes `url` off the main thread, fast-pathing hits already in memory.
    func loadImage(at url: URL, maxPixel: Int, squareCrop: Bool = false) async -> NSImage? {
        if let hit = cachedImage(at: url, maxPixel: maxPixel, squareCrop: squareCrop) { return hit }
        return await Task.detached(priority: .userInitiated) { [self] in
            self.image(at: url, maxPixel: maxPixel, squareCrop: squareCrop)
        }.value
    }

    /// The image at `url` with its longer side at most `maxPixel` (never enlarged), upright. When `squareCrop` is true, non-square
    /// images (such as 16:9 banners) are center-cropped into a square thumbnail. Failed decodes and missing files are never cached.
    func image(at url: URL, maxPixel: Int, squareCrop: Bool = false) -> NSImage? {
        let limit = max(1, maxPixel)
        guard let stamp = fileStamp(of: url) else { return nil }
        let key = cacheKey(for: url, stamp: stamp, maxPixel: limit, squareCrop: squareCrop)
        if let image = cache.object(forKey: key) { return image }
        LauncherWork.count(.artworkDecode)
        guard let image = Self.decode(url, maxPixel: limit, squareCrop: squareCrop)
                ?? Self.decodeFallback(url, maxPixel: limit, squareCrop: squareCrop) else { return nil }
        cache.setObject(image, forKey: key, cost: Self.estimatedCost(of: image))
        return image
    }

    private static func estimatedCost(of image: NSImage) -> Int {
        let repBytes = image.representations.reduce(0) { total, rep in
            let w = rep.pixelsWide > 0 ? rep.pixelsWide : Int(ceil(rep.size.width))
            let h = rep.pixelsHigh > 0 ? rep.pixelsHigh : Int(ceil(rep.size.height))
            return total + max(0, w) * max(0, h) * 4
        }
        if repBytes > 0 { return repBytes }
        let fallback = Int(ceil(image.size.width)) * Int(ceil(image.size.height)) * 4
        return max(4, fallback)
    }

    private static func bestFrameIndex(in source: CGImageSource, url: URL, targetPixel: Int) -> (index: Int, width: Int, height: Int)? {
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        // Multi-resolution icon containers (.icns) store multiple sizes; pick the smallest frame >= targetPixel, or the largest available.
        let scanAll = count > 1 && url.pathExtension.lowercased() == "icns"
        let limit = scanAll ? count : 1
        var bestAbove: (index: Int, width: Int, height: Int, side: Int)?
        var largest: (index: Int, width: Int, height: Int, side: Int)?
        for i in 0..<limit {
            guard let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int, w > 0,
                  let h = props[kCGImagePropertyPixelHeight] as? Int, h > 0 else { continue }
            let side = max(w, h)
            if side >= targetPixel {
                if bestAbove == nil || side < bestAbove!.side { bestAbove = (i, w, h, side) }
            }
            if largest == nil || side > largest!.side { largest = (i, w, h, side) }
        }
        if let chosen = bestAbove ?? largest { return (chosen.index, chosen.width, chosen.height) }
        return nil
    }

    private static func decode(_ url: URL, maxPixel: Int, squareCrop: Bool) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let frame = bestFrameIndex(in: source, url: url, targetPixel: maxPixel) else { return nil }
        let longSide = max(frame.width, frame.height)
        let shortSide = max(1, min(frame.width, frame.height))
        let requestedMax: Int
        if squareCrop && frame.width != frame.height {
            let scaled = Int(ceil(Double(maxPixel) * Double(longSide) / Double(shortSide)))
            requestedMax = min(longSide, min(maxPixel * 4, max(maxPixel, scaled)))
        } else {
            requestedMax = min(maxPixel, longSide)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: requestedMax,   // the thumbnail would be enlarged to the maximum
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, frame.index, options as CFDictionary) else { return nil }
        let finalCG = squareCrop ? centerSquare(thumbnail, maxPixel: maxPixel) : thumbnail
        let image = NSImage(size: NSSize(width: finalCG.width, height: finalCG.height))
        image.addRepresentation(NSBitmapImageRep(cgImage: finalCG))
        return image
    }

    private static func decodeFallback(_ url: URL, maxPixel: Int, squareCrop: Bool) -> NSImage? {
        guard let raw = NSImage(contentsOf: url) else { return nil }
        var proposed = NSRect(origin: .zero, size: NSSize(width: maxPixel, height: maxPixel))
        guard let cg = raw.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return nil }
        let processed = squareCrop ? centerSquare(cg, maxPixel: maxPixel) : downsample(cg, maxPixel: maxPixel)
        let image = NSImage(size: NSSize(width: processed.width, height: processed.height))
        image.addRepresentation(NSBitmapImageRep(cgImage: processed))
        return image
    }

    private static func centerSquare(_ cg: CGImage, maxPixel: Int) -> CGImage {
        let side = min(cg.width, cg.height)
        guard side > 0 else { return cg }
        let cropped: CGImage
        if cg.width == cg.height {
            cropped = cg
        } else {
            let rect = CGRect(x: (cg.width - side) / 2, y: (cg.height - side) / 2, width: side, height: side)
            cropped = cg.cropping(to: rect) ?? cg
        }
        return downsample(cropped, maxPixel: maxPixel)
    }

    private static func downsample(_ cg: CGImage, maxPixel: Int) -> CGImage {
        let longest = max(cg.width, cg.height)
        guard longest > maxPixel, longest > 0 else { return cg }
        let scale = Double(maxPixel) / Double(longest)
        let width = max(1, Int((Double(cg.width) * scale).rounded()))
        let height = max(1, Int((Double(cg.height) * scale).rounded()))
        let space = (cg.colorSpace?.model == .rgb ? cg.colorSpace : nil) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return cg }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage() ?? cg
    }
}
