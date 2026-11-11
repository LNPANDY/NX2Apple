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
final class ArtworkImages {
    static let shared = ArtworkImages()

    /// Enough for a card, the console and the onboarding covers.
    static let cardPixels = 640
    /// The hero covers the window: twice the widest screen (Retina), never more than 4K.
    static var heroPixels: Int { min(3840, Int(2 * (NSScreen.screens.map(\.frame.width).max() ?? 1920))) }

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 256 << 20   // bytes of decoded pixels: a library of cards and a few 4K heroes
        return cache
    }()

    /// How long a file's modification date is trusted. SwiftUI bodies ask for the same few files at every redraw, on the main thread.
    static let recheckInterval: TimeInterval = 2

    private let now: () -> Date
    private let stat: (URL) -> Date?
    private let lock = NSLock()
    private var checked: [String: (modified: Date?, at: Date)] = [:]   // by path, behind `lock`

    init(now: @escaping () -> Date = Date.init,
         stat: @escaping (URL) -> Date? = { url in   // not URL.resourceValues, which a URL caches
             (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
         }) {
        self.now = now
        self.stat = stat
    }

    private func modificationDate(of url: URL) -> Date? {
        let current = now()
        lock.lock()
        let known = checked[url.path]
        lock.unlock()
        if let known, current.timeIntervalSince(known.at) >= 0, current.timeIntervalSince(known.at) < Self.recheckInterval { return known.modified }
        let modified = stat(url)
        lock.lock()
        checked[url.path] = (modified, current)
        lock.unlock()
        return modified
    }

    /// The image at `url` with its longer side at most `maxPixel` (never enlarged), upright, from its first frame. The same
    /// instance until the file changes, which is noticed within `recheckInterval`. An image that ImageIO cannot make a thumbnail of (an .icns) is read whole.
    func image(at url: URL, maxPixel: Int) -> NSImage? {
        let modified = modificationDate(of: url)
        let key = "\(url.path)\n\(modified?.timeIntervalSinceReferenceDate ?? 0)\n\(maxPixel)" as NSString
        if let image = cache.object(forKey: key) { return image }
        LauncherWork.count(.artworkDecode)
        guard let image = Self.decode(url, maxPixel: maxPixel) ?? NSImage(contentsOf: url) else { return nil }
        let pixels = image.representations.first.map { $0.pixelsWide * $0.pixelsHigh } ?? 0
        cache.setObject(image, forKey: key, cost: pixels * 4)
        return image
    }

    private static func decode(_ url: URL, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixel, max(width, height)),   // the thumbnail would be enlarged to the maximum
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(size: NSSize(width: thumbnail.width, height: thumbnail.height))
        image.addRepresentation(NSBitmapImageRep(cgImage: thumbnail))
        return image
    }
}
